-- Applied on top of 0001 (original draft). Together they equal the live database.

-- 1) Stock view must respect tenant RLS and never return NULL
drop view if exists inventory_summary;
create view inventory_summary with (security_invoker = true) as
select company_id, warehouse_id, sku_id,
  coalesce(sum(qty_delta) filter (where bucket='available'),0)  as available,
  coalesce(sum(qty_delta) filter (where bucket='reserved'),0)   as reserved,
  coalesce(sum(qty_delta) filter (where bucket='damaged'),0)    as damaged,
  coalesce(sum(qty_delta) filter (where bucket='quarantine'),0) as quarantine
from inventory_ledger group by company_id, warehouse_id, sku_id;

-- 2) Pin search_path on security-definer / trigger functions
alter function my_company_ids() set search_path = public;
alter function touch_updated_at() set search_path = public;
alter function on_order_status_change() set search_path = public;
alter function allocate_order(uuid) set search_path = public;

-- 3) complete_grn: tenant check added
create or replace function complete_grn(p_grn uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g grns; i record;
begin
  select * into g from grns where id = p_grn for update;
  if g.status = 'completed' then return; end if;
  if g.company_id not in (select my_company_ids()) and auth.role() <> 'service_role' then
    raise exception 'forbidden';
  end if;
  for i in select * from grn_items where grn_id = p_grn loop
    if i.qty_good > 0 then
      insert into inventory_ledger(company_id,warehouse_id,location_id,sku_id,batch_no,expiry_date,qty_delta,bucket,ref_type,ref_id)
      values (g.company_id,g.warehouse_id,i.location_id,i.sku_id,i.batch_no,i.expiry_date,i.qty_good,'available','grn',g.id);
    end if;
    if i.qty_damaged > 0 then
      insert into inventory_ledger(company_id,warehouse_id,location_id,sku_id,qty_delta,bucket,ref_type,ref_id)
      values (g.company_id,g.warehouse_id,i.location_id,i.sku_id,i.qty_damaged,'damaged','grn',g.id);
    end if;
    if g.po_id is not null then
      update purchase_order_items set qty_received = qty_received + i.qty_good + i.qty_damaged
        where po_id = g.po_id and sku_id = i.sku_id;
    end if;
  end loop;
  update grns set status='completed', received_at=now() where id = p_grn;
  if g.po_id is not null then
    update purchase_orders set status = case when exists
      (select 1 from purchase_order_items where po_id=g.po_id and qty_received < qty_ordered)
      then 'partial' else 'received' end where id = g.po_id;
  end if;
end $$;

-- 4) Signup + API-key helpers
create or replace function create_company(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into companies(name) values (p_name) returning id into cid;
  insert into company_users(company_id, user_id, role) values (cid, auth.uid(), 'owner');
  return cid;
end $$;

create or replace function create_api_key(p_company uuid, p_label text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  if p_company not in (select my_company_ids()) then raise exception 'forbidden'; end if;
  k := 'wms_' || encode(gen_random_bytes(24), 'hex');
  insert into api_keys(company_id, label, key_prefix, key_hash)
  values (p_company, p_label, left(k, 8), encode(digest(k, 'sha256'), 'hex'));
  return k;
end $$;

-- 5) UI order functions
create or replace function allocate_order_ui(p_order uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select company_id into cid from orders where id = p_order;
  if cid is null or cid not in (select my_company_ids()) then raise exception 'forbidden'; end if;
  return allocate_order(p_order);
end $$;

create or replace function advance_order(p_order uuid, p_status text, p_awb text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o orders; it record;
begin
  select * into o from orders where id = p_order for update;
  if o.id is null or o.company_id not in (select my_company_ids()) then raise exception 'forbidden'; end if;
  if not (
    (o.status = 'allocated'  and p_status in ('picking','cancelled','on_hold')) or
    (o.status = 'confirmed'  and p_status in ('cancelled','on_hold')) or
    (o.status = 'on_hold'    and p_status in ('confirmed','cancelled')) or
    (o.status = 'picking'    and p_status in ('packed','cancelled')) or
    (o.status = 'packed'     and p_status in ('manifested','cancelled')) or
    (o.status = 'manifested' and p_status in ('shipped')) or
    (o.status = 'shipped'    and p_status in ('delivered','rto_initiated')) or
    (o.status = 'rto_initiated' and p_status in ('rto_received'))
  ) then raise exception 'invalid transition % -> %', o.status, p_status; end if;
  if p_status = 'shipped' then
    for it in select * from order_items where order_id = p_order and qty_allocated > 0 loop
      insert into inventory_ledger(company_id,warehouse_id,sku_id,qty_delta,bucket,ref_type,ref_id)
        values (o.company_id,o.warehouse_id,it.sku_id,-it.qty_allocated,'reserved','order_ship',o.id);
      update order_items set qty_shipped = qty_allocated where id = it.id;
    end loop;
  elsif p_status = 'cancelled' then
    for it in select * from order_items where order_id = p_order and qty_allocated > 0 loop
      insert into inventory_ledger(company_id,warehouse_id,sku_id,qty_delta,bucket,ref_type,ref_id)
        values (o.company_id,o.warehouse_id,it.sku_id,-it.qty_allocated,'reserved','order_cancel',o.id),
               (o.company_id,o.warehouse_id,it.sku_id, it.qty_allocated,'available','order_cancel',o.id);
      update order_items set qty_allocated = 0 where id = it.id;
    end loop;
  elsif p_status = 'rto_received' then
    for it in select * from order_items where order_id = p_order and qty_shipped > 0 loop
      insert into inventory_ledger(company_id,warehouse_id,sku_id,qty_delta,bucket,ref_type,ref_id)
        values (o.company_id,o.warehouse_id,it.sku_id,it.qty_shipped,'quarantine','return',o.id);
    end loop;
  end if;
  update orders set status = p_status, awb = coalesce(p_awb, awb) where id = p_order;
end $$;

-- 6) Grants
revoke execute on function allocate_order(uuid) from public, anon, authenticated;
revoke execute on function on_order_status_change() from public, anon, authenticated;
revoke execute on function complete_grn(uuid), create_company(text), create_api_key(uuid, text), allocate_order_ui(uuid), advance_order(uuid, text, text) from public, anon;
grant execute on function complete_grn(uuid), create_company(text), create_api_key(uuid, text), allocate_order_ui(uuid), advance_order(uuid, text, text) to authenticated;
