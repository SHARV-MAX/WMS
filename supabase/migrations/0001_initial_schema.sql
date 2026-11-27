-- =====================================================================
-- Own WMS (EasyEcom-style) — multi-tenant Postgres schema for Supabase
-- Every business table carries company_id; RLS isolates tenants.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- Tenancy & access ----------
create table companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  gstin text,
  created_at timestamptz default now()
);

create table company_users (
  company_id uuid references companies(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  role text not null default 'operator' check (role in ('owner','admin','manager','operator','viewer')),
  primary key (company_id, user_id)
);

-- API credentials for external systems (Shopify, Zoho, ERP etc.)
create table api_keys (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  label text,
  key_prefix text not null,                 -- first 8 chars, shown in UI
  key_hash text not null unique,            -- sha256 of full key
  scopes text[] default '{orders:write,orders:read,inventory:read}',
  is_active boolean default true,
  last_used_at timestamptz,
  created_at timestamptz default now()
);

-- Subscriptions to outbound webhooks (WMS -> client system)
create table webhook_endpoints (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  url text not null,
  secret text not null,
  events text[] not null default '{order.created,order.packed,order.shipped,order.delivered,order.cancelled,inventory.updated,grn.completed}',
  is_active boolean default true
);

create table webhook_deliveries (
  id bigserial primary key,
  company_id uuid not null,
  endpoint_id uuid references webhook_endpoints(id) on delete cascade,
  event text not null,
  payload jsonb not null,
  status text default 'pending' check (status in ('pending','sent','failed')),
  attempts int default 0,
  next_attempt_at timestamptz default now(),
  response_code int,
  created_at timestamptz default now()
);

-- Inbound webhook log (client system -> WMS), for audit + replay
create table inbound_webhook_log (
  id bigserial primary key,
  company_id uuid not null,
  source text,
  payload jsonb,
  result text,
  created_at timestamptz default now()
);

-- ---------- Masters ----------
create table warehouses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  code text not null,
  name text not null,
  address jsonb,
  is_active boolean default true,
  unique (company_id, code)
);

create table locations (                       -- bins / racks / zones
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  warehouse_id uuid not null references warehouses(id) on delete cascade,
  code text not null,
  type text default 'storage' check (type in ('storage','pick','receiving','quarantine','returns','damaged')),
  unique (warehouse_id, code)
);

create table skus (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  sku text not null,
  name text not null,
  ean text,
  hsn text,
  mrp numeric(12,2),
  cost numeric(12,2),
  weight_g int,
  length_cm numeric, width_cm numeric, height_cm numeric,
  batch_tracked boolean default false,
  is_active boolean default true,
  unique (company_id, sku)
);

create table vendors (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null,
  gstin text,
  contact jsonb
);

create table couriers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null,                           -- Delhivery, BlueDart ...
  config jsonb default '{}'::jsonb,
  is_active boolean default true
);

-- ---------- Inventory (ledger is the source of truth) ----------
create table inventory_ledger (
  id bigserial primary key,
  company_id uuid not null,
  warehouse_id uuid not null references warehouses(id),
  location_id uuid references locations(id),
  sku_id uuid not null references skus(id),
  batch_no text,
  expiry_date date,
  qty_delta int not null,                       -- + in, - out
  bucket text not null default 'available' check (bucket in ('available','reserved','damaged','quarantine','in_transit')),
  ref_type text not null,                       -- grn, order_reserve, order_ship, adjustment, return, transfer
  ref_id uuid,
  note text,
  created_by uuid,
  created_at timestamptz default now()
);
create index on inventory_ledger (company_id, warehouse_id, sku_id, bucket);

create view inventory_summary as
select company_id, warehouse_id, sku_id,
  sum(qty_delta) filter (where bucket='available')  as available,
  sum(qty_delta) filter (where bucket='reserved')   as reserved,
  sum(qty_delta) filter (where bucket='damaged')    as damaged,
  sum(qty_delta) filter (where bucket='quarantine') as quarantine
from inventory_ledger
group by company_id, warehouse_id, sku_id;

-- ---------- Inbound ----------
create table purchase_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  po_number text not null,
  vendor_id uuid references vendors(id),
  warehouse_id uuid references warehouses(id),
  status text default 'open' check (status in ('draft','open','partial','received','cancelled')),
  expected_date date,
  created_at timestamptz default now(),
  unique (company_id, po_number)
);
create table purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  po_id uuid not null references purchase_orders(id) on delete cascade,
  sku_id uuid not null references skus(id),
  qty_ordered int not null,
  qty_received int default 0,
  unit_cost numeric(12,2)
);
create table grns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  grn_number text not null,
  po_id uuid references purchase_orders(id),
  warehouse_id uuid not null references warehouses(id),
  status text default 'draft' check (status in ('draft','completed')),
  received_at timestamptz,
  unique (company_id, grn_number)
);
create table grn_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  grn_id uuid not null references grns(id) on delete cascade,
  sku_id uuid not null references skus(id),
  location_id uuid references locations(id),
  qty_good int not null default 0,
  qty_damaged int not null default 0,
  batch_no text, expiry_date date
);

-- ---------- Orders / Outbound ----------
create table orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  order_number text not null,                   -- client's order no
  channel text default 'api',                   -- shopify, amazon, manual, api ...
  channel_order_id text,
  warehouse_id uuid references warehouses(id),
  status text not null default 'confirmed' check (status in
    ('pending','confirmed','on_hold','allocated','picking','packed','manifested','shipped','delivered','cancelled','rto_initiated','rto_received')),
  payment_mode text default 'prepaid' check (payment_mode in ('prepaid','cod')),
  cod_amount numeric(12,2) default 0,
  order_total numeric(12,2),
  customer jsonb not null,                      -- {name, phone, email}
  shipping_address jsonb not null,              -- {line1,line2,city,state,pincode,country}
  billing_address jsonb,
  courier_id uuid references couriers(id),
  awb text,
  invoice_no text,
  order_date timestamptz default now(),
  meta jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (company_id, order_number)             -- idempotency key for API/webhook
);
create index on orders (company_id, status);
create index on orders (company_id, awb);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  order_id uuid not null references orders(id) on delete cascade,
  sku_id uuid not null references skus(id),
  qty int not null check (qty > 0),
  qty_allocated int default 0,
  qty_shipped int default 0,
  unit_price numeric(12,2),
  tax_pct numeric(5,2)
);

create table order_status_history (
  id bigserial primary key,
  company_id uuid not null,
  order_id uuid not null references orders(id) on delete cascade,
  from_status text, to_status text not null,
  note text, created_by uuid,
  created_at timestamptz default now()
);

create table picklists (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  warehouse_id uuid not null references warehouses(id),
  picklist_no text not null,
  status text default 'open' check (status in ('open','in_progress','completed')),
  created_at timestamptz default now(),
  unique (company_id, picklist_no)
);
create table picklist_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  picklist_id uuid not null references picklists(id) on delete cascade,
  order_id uuid not null references orders(id),
  sku_id uuid not null references skus(id),
  location_id uuid references locations(id),
  qty int not null, qty_picked int default 0
);

create table manifests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  courier_id uuid references couriers(id),
  manifest_no text not null,
  status text default 'open' check (status in ('open','handed_over')),
  handed_over_at timestamptz,
  unique (company_id, manifest_no)
);
create table manifest_orders (
  manifest_id uuid references manifests(id) on delete cascade,
  order_id uuid references orders(id),
  primary key (manifest_id, order_id)
);

-- ---------- Returns ----------
create table returns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  order_id uuid references orders(id),
  type text default 'rto' check (type in ('rto','customer_return')),
  status text default 'initiated' check (status in ('initiated','received','qc_done','closed')),
  created_at timestamptz default now()
);
create table return_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  return_id uuid not null references returns(id) on delete cascade,
  sku_id uuid not null references skus(id),
  qty int not null,
  qc_result text check (qc_result in ('good','damaged','reject')),
  restock_location_id uuid references locations(id)
);

-- ---------- Helpers ----------
create or replace function my_company_ids() returns setof uuid
language sql stable security definer as $$
  select company_id from company_users where user_id = auth.uid()
$$;

create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger trg_orders_touch before update on orders
  for each row execute function touch_updated_at();

-- Log every status change + queue outbound webhooks
create or replace function on_order_status_change() returns trigger language plpgsql security definer as $$
begin
  if (tg_op = 'INSERT') or (old.status is distinct from new.status) then
    insert into order_status_history(company_id, order_id, from_status, to_status)
    values (new.company_id, new.id, case when tg_op='UPDATE' then old.status end, new.status);

    insert into webhook_deliveries(company_id, endpoint_id, event, payload)
    select new.company_id, e.id, 'order.' ||
             case new.status when 'confirmed' then 'created' else new.status end,
           jsonb_build_object('order_id', new.id, 'order_number', new.order_number,
                              'status', new.status, 'awb', new.awb)
    from webhook_endpoints e
    where e.company_id = new.company_id and e.is_active
      and ('order.' || case new.status when 'confirmed' then 'created' else new.status end) = any(e.events);
  end if;
  return new;
end $$;
create trigger trg_order_status after insert or update of status on orders
  for each row execute function on_order_status_change();

-- Allocate (reserve) stock for an order from its warehouse. Returns true if fully allocated.
create or replace function allocate_order(p_order uuid) returns boolean
language plpgsql security definer as $$
declare o orders; it record; avail int; ok boolean := true;
begin
  select * into o from orders where id = p_order for update;
  if o.warehouse_id is null then return false; end if;
  for it in select * from order_items where order_id = p_order loop
    select coalesce(available,0) into avail from inventory_summary
      where warehouse_id = o.warehouse_id and sku_id = it.sku_id;
    if coalesce(avail,0) >= it.qty then
      insert into inventory_ledger(company_id,warehouse_id,sku_id,qty_delta,bucket,ref_type,ref_id)
        values (o.company_id,o.warehouse_id,it.sku_id,-it.qty,'available','order_reserve',o.id),
               (o.company_id,o.warehouse_id,it.sku_id, it.qty,'reserved','order_reserve',o.id);
      update order_items set qty_allocated = it.qty where id = it.id;
    else ok := false; end if;
  end loop;
  if ok then update orders set status='allocated' where id = p_order and status in ('confirmed','pending'); end if;
  return ok;
end $$;

-- Complete a GRN: books good/damaged qty into the ledger and updates PO
create or replace function complete_grn(p_grn uuid) returns void
language plpgsql security definer as $$
declare g grns; i record;
begin
  select * into g from grns where id = p_grn for update;
  if g.status = 'completed' then return; end if;
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

-- ---------- Row Level Security ----------
do $$
declare t text;
begin
  for t in select unnest(array[
    'company_users','api_keys','webhook_endpoints','webhook_deliveries','inbound_webhook_log',
    'warehouses','locations','skus','vendors','couriers','inventory_ledger',
    'purchase_orders','purchase_order_items','grns','grn_items',
    'orders','order_items','order_status_history','picklists','picklist_items',
    'manifests','manifest_orders','returns','return_items'])
  loop
    execute format('alter table %I enable row level security', t);
    if t = 'manifest_orders' then
      execute 'create policy tenant on manifest_orders using (manifest_id in (select id from manifests where company_id in (select my_company_ids())))';
    else
      execute format('create policy tenant on %I using (company_id in (select my_company_ids())) with check (company_id in (select my_company_ids()))', t);
    end if;
  end loop;
end $$;
alter table companies enable row level security;
create policy tenant on companies using (id in (select my_company_ids()));
