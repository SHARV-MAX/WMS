// Supabase Edge Function: wms-api
// Deploy: supabase functions deploy wms-api --no-verify-jwt
// Auth: header  x-api-key: <key>   (key is created per company, only sha256 hash is stored)
//
// Routes (base: /functions/v1/wms-api)
//   POST   /orders                 create order (idempotent on order_number)
//   POST   /webhook/orders         inbound webhook (Shopify-style or generic) -> creates order
//   GET    /orders/:order_number   fetch order
//   POST   /orders/:order_number/cancel
//   GET    /inventory?sku=         stock by warehouse
//   POST   /skus                   upsert SKU
//   POST   /dispatch-webhooks      cron: deliver queued outbound webhooks (service use)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function authenticate(req: Request) {
  const key = req.headers.get("x-api-key");
  if (!key) return null;
  const { data } = await db
    .from("api_keys")
    .select("id, company_id, scopes, is_active")
    .eq("key_hash", await sha256(key))
    .maybeSingle();
  if (!data || !data.is_active) return null;
  db.from("api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", data.id).then(() => {});
  return data as { id: string; company_id: string; scopes: string[] };
}

// ---- Normalise Shopify-style / generic payloads into one internal shape ----
function normaliseOrder(p: any) {
  // Generic (our own) format
  if (p.order_number && p.items) return p;
  // Shopify orders/create
  if (p.line_items) {
    const a = p.shipping_address ?? {};
    return {
      order_number: String(p.name ?? p.order_number ?? p.id),
      channel: "shopify",
      channel_order_id: String(p.id),
      payment_mode: (p.financial_status === "pending" || (p.gateway ?? "").toLowerCase().includes("cod")) ? "cod" : "prepaid",
      order_total: Number(p.total_price ?? 0),
      customer: {
        name: `${a.first_name ?? p.customer?.first_name ?? ""} ${a.last_name ?? p.customer?.last_name ?? ""}`.trim(),
        phone: a.phone ?? p.phone ?? p.customer?.phone,
        email: p.email,
      },
      shipping_address: {
        line1: a.address1, line2: a.address2, city: a.city,
        state: a.province, pincode: a.zip, country: a.country_code ?? "IN",
      },
      items: p.line_items.map((l: any) => ({
        sku: l.sku, qty: l.quantity, unit_price: Number(l.price ?? 0),
      })),
    };
  }
  throw new Error("Unrecognised order payload");
}

function validate(o: any) {
  const errs: string[] = [];
  if (!o.order_number) errs.push("order_number is required");
  if (!o.customer?.name) errs.push("customer.name is required");
  const a = o.shipping_address ?? {};
  if (!a.line1 || !a.pincode) errs.push("shipping_address.line1 and pincode are required");
  if (!Array.isArray(o.items) || !o.items.length) errs.push("items[] is required");
  (o.items ?? []).forEach((i: any, n: number) => {
    if (!i.sku) errs.push(`items[${n}].sku is required`);
    if (!(i.qty > 0)) errs.push(`items[${n}].qty must be > 0`);
  });
  return errs;
}

async function createOrder(companyId: string, raw: any) {
  const o = normaliseOrder(raw);
  const errs = validate(o);
  if (errs.length) return { status: 422, body: { error: "validation_failed", details: errs } };

  // Idempotency: same order_number returns the existing order
  const { data: existing } = await db.from("orders").select("id,status")
    .eq("company_id", companyId).eq("order_number", o.order_number).maybeSingle();
  if (existing) return { status: 200, body: { duplicate: true, order_id: existing.id, status: existing.status } };

  // Resolve SKUs
  const skuCodes = o.items.map((i: any) => i.sku);
  const { data: skus } = await db.from("skus").select("id,sku").eq("company_id", companyId).in("sku", skuCodes);
  const map = new Map((skus ?? []).map((s) => [s.sku, s.id]));
  const missing = skuCodes.filter((c: string) => !map.has(c));
  if (missing.length) return { status: 422, body: { error: "unknown_sku", skus: missing } };

  // Warehouse: explicit code, else company's first active warehouse
  let warehouseId: string | null = null;
  if (o.warehouse_code) {
    const { data: w } = await db.from("warehouses").select("id").eq("company_id", companyId).eq("code", o.warehouse_code).maybeSingle();
    warehouseId = w?.id ?? null;
  }
  if (!warehouseId) {
    const { data: w } = await db.from("warehouses").select("id").eq("company_id", companyId).eq("is_active", true).limit(1).maybeSingle();
    warehouseId = w?.id ?? null;
  }

  const { data: order, error } = await db.from("orders").insert({
    company_id: companyId,
    order_number: o.order_number,
    channel: o.channel ?? "api",
    channel_order_id: o.channel_order_id,
    warehouse_id: warehouseId,
    payment_mode: o.payment_mode ?? "prepaid",
    cod_amount: o.payment_mode === "cod" ? (o.cod_amount ?? o.order_total ?? 0) : 0,
    order_total: o.order_total,
    customer: o.customer,
    shipping_address: o.shipping_address,
    billing_address: o.billing_address ?? o.shipping_address,
    order_date: o.order_date ?? new Date().toISOString(),
    status: "confirmed",
  }).select("id").single();
  if (error) return { status: 500, body: { error: error.message } };

  await db.from("order_items").insert(o.items.map((i: any) => ({
    company_id: companyId, order_id: order.id, sku_id: map.get(i.sku),
    qty: i.qty, unit_price: i.unit_price, tax_pct: i.tax_pct,
  })));

  // Try to reserve stock; if short, order stays 'confirmed' (visible as unallocated)
  const { data: allocated } = await db.rpc("allocate_order", { p_order: order.id });
  return { status: 201, body: { order_id: order.id, order_number: o.order_number, allocated: !!allocated } };
}

async function dispatchWebhooks() {
  const { data: queue } = await db.from("webhook_deliveries")
    .select("*, webhook_endpoints(url,secret)")
    .eq("status", "pending").lte("next_attempt_at", new Date().toISOString()).limit(50);
  for (const d of queue ?? []) {
    const body = JSON.stringify({ event: d.event, data: d.payload, sent_at: new Date().toISOString() });
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(d.webhook_endpoints.secret),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
    const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
    let code = 0;
    try {
      const r = await fetch(d.webhook_endpoints.url, {
        method: "POST", body,
        headers: { "content-type": "application/json", "x-wms-signature": hex, "x-wms-event": d.event },
      });
      code = r.status;
    } catch { /* network error */ }
    const ok = code >= 200 && code < 300;
    const attempts = d.attempts + 1;
    await db.from("webhook_deliveries").update({
      status: ok ? "sent" : attempts >= 6 ? "failed" : "pending",
      attempts, response_code: code,
      next_attempt_at: new Date(Date.now() + 2 ** attempts * 60_000).toISOString(), // exp backoff
    }).eq("id", d.id);
  }
  return { processed: queue?.length ?? 0 };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/(functions\/v1\/)?wms-api/, "") || "/";

  // Cron endpoint: protected by service key, not API key
  if (path === "/dispatch-webhooks") {
    if (req.headers.get("authorization") !== `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`)
      return json({ error: "unauthorized" }, 401);
    return json(await dispatchWebhooks());
  }

  const auth = await authenticate(req);
  if (!auth) return json({ error: "invalid_api_key" }, 401);
  const cid = auth.company_id;
  const need = (s: string) => auth.scopes.includes(s);

  try {
    // ---- Orders ----
    if (req.method === "POST" && (path === "/orders" || path === "/webhook/orders")) {
      if (!need("orders:write")) return json({ error: "forbidden" }, 403);
      const payload = await req.json();
      const res = await createOrder(cid, payload);
      if (path === "/webhook/orders")
        await db.from("inbound_webhook_log").insert({
          company_id: cid, source: req.headers.get("x-source") ?? "generic",
          payload, result: JSON.stringify(res.body).slice(0, 500),
        });
      return json(res.body, res.status);
    }

    let m = path.match(/^\/orders\/([^/]+)$/);
    if (req.method === "GET" && m) {
      if (!need("orders:read")) return json({ error: "forbidden" }, 403);
      const { data } = await db.from("orders").select("*, order_items(*, skus(sku,name))")
        .eq("company_id", cid).eq("order_number", decodeURIComponent(m[1])).maybeSingle();
      return data ? json(data) : json({ error: "not_found" }, 404);
    }

    m = path.match(/^\/orders\/([^/]+)\/cancel$/);
    if (req.method === "POST" && m) {
      if (!need("orders:write")) return json({ error: "forbidden" }, 403);
      const { data: o } = await db.from("orders").select("id,status,warehouse_id")
        .eq("company_id", cid).eq("order_number", decodeURIComponent(m[1])).maybeSingle();
      if (!o) return json({ error: "not_found" }, 404);
      if (["shipped", "delivered", "cancelled"].includes(o.status))
        return json({ error: `cannot_cancel_${o.status}` }, 409);
      // release reservation
      const { data: items } = await db.from("order_items").select("sku_id,qty_allocated").eq("order_id", o.id);
      for (const it of items ?? []) if (it.qty_allocated > 0)
        await db.from("inventory_ledger").insert([
          { company_id: cid, warehouse_id: o.warehouse_id, sku_id: it.sku_id, qty_delta: -it.qty_allocated, bucket: "reserved", ref_type: "order_cancel", ref_id: o.id },
          { company_id: cid, warehouse_id: o.warehouse_id, sku_id: it.sku_id, qty_delta: it.qty_allocated, bucket: "available", ref_type: "order_cancel", ref_id: o.id },
        ]);
      await db.from("orders").update({ status: "cancelled" }).eq("id", o.id);
      return json({ order_number: m[1], status: "cancelled" });
    }

    // ---- Inventory ----
    if (req.method === "GET" && path === "/inventory") {
      if (!need("inventory:read")) return json({ error: "forbidden" }, 403);
      let q = db.from("inventory_summary").select("warehouse_id,sku_id,available,reserved,damaged,skus(sku,name)").eq("company_id", cid);
      const sku = url.searchParams.get("sku");
      if (sku) { const { data: s } = await db.from("skus").select("id").eq("company_id", cid).eq("sku", sku).maybeSingle(); if (s) q = q.eq("sku_id", s.id); }
      const { data } = await q;
      return json({ data });
    }

    // ---- SKU upsert ----
    if (req.method === "POST" && path === "/skus") {
      const b = await req.json();
      const { error } = await db.from("skus").upsert({ company_id: cid, ...b }, { onConflict: "company_id,sku" });
      return error ? json({ error: error.message }, 400) : json({ ok: true }, 201);
    }

    return json({ error: "not_found" }, 404);
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 400);
  }
});
