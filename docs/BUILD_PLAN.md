# Own WMS (EasyEcom-style) — Build Plan

Stack: Supabase (Postgres + Auth + Edge Functions) + web UI. Multi-client SaaS.

## 1. Architecture

```
Shopify / Zoho / ERP / Marketplaces
        │  POST /orders  or  /webhook/orders   (x-api-key)
        ▼
 Edge Function  wms-api  ──►  Postgres (RLS per company_id)
        ▲                          │ trigger on order status change
        │                          ▼
  Web UI (Supabase Auth)     webhook_deliveries queue
                                   │ cron every minute: /dispatch-webhooks
                                   ▼
                       Client system (HMAC-signed, retries with backoff)
```

- **Tenant isolation**: every table has `company_id`; RLS uses `company_users`. API keys map to one company.
- **Inventory** is a ledger (`inventory_ledger`); stock = sum of deltas by bucket (available / reserved / damaged / quarantine). No stock number is ever overwritten, so every change is auditable.
- **Idempotency**: `unique(company_id, order_number)`. Re-sending the same order from a webhook retry returns the existing order.

## 2. Modules mapped to EasyEcom

| EasyEcom area | Here | V1 status |
|---|---|---|
| Create order API / webhook | `POST /orders`, `POST /webhook/orders` (generic + Shopify format) | Done in `wms-api` |
| Order status updates | `orders.status` + history + outbound webhooks | Done (schema + trigger) |
| Cancel order | `POST /orders/:no/cancel` (releases reservation) | Done |
| Inventory API | `GET /inventory` | Done |
| SKU/Product master | `POST /skus`, `skus` table | Done |
| Multi-warehouse, bins | `warehouses`, `locations` | Schema |
| PO / GRN | `purchase_orders`, `grns`, `complete_grn()` | Schema + DB function; needs UI |
| Pick / Pack / Manifest | `picklists`, `manifests` | Schema; needs UI + endpoints |
| Courier / AWB | `couriers.config` | Phase 2 (Delhivery/BlueDart APIs) |
| RTO / Returns | `returns`, `return_items` | Schema; needs UI |
| Reports | views on ledger/orders | Phase 3 |

## 3. API reference (v1)

Auth: header `x-api-key: <key>`. Base: `https://<project>.supabase.co/functions/v1/wms-api`

**Create order**
```json
POST /orders
{
  "order_number": "BH-10045",
  "channel": "shopify",
  "payment_mode": "cod",
  "order_total": 1499,
  "warehouse_code": "BHIWANDI",
  "customer": {"name": "Asha Rao", "phone": "98XXXXXX10", "email": "asha@x.com"},
  "shipping_address": {"line1": "12 MG Road", "city": "Pune", "state": "MH", "pincode": "411001"},
  "items": [{"sku": "HEMP-OIL-30", "qty": 2, "unit_price": 749}]
}
```
Responses: `201 {order_id, allocated}` · `200 {duplicate:true}` · `422 {error:"unknown_sku"|"validation_failed"}`

Other: `GET /orders/:order_number`, `POST /orders/:order_number/cancel`, `GET /inventory?sku=`, `POST /skus`.

**Outbound webhooks** (WMS → client): events `order.created`, `order.packed`, `order.shipped`, `order.delivered`, `order.cancelled`, `inventory.updated`, `grn.completed`. Header `x-wms-signature` = HMAC-SHA256 of the body using the endpoint secret. Retries 6 times with exponential backoff.

## 3a. Known gaps in this first drop (be aware)
- Order status transitions beyond `allocated` (picking, packed, shipped) are DB-level only; the UI/endpoints for them are Phase 2.
- API keys are not yet creatable from a UI. Create one by inserting a row with `key_hash = sha256(your_key)`.
- Webhook dispatch needs a cron (pg_cron or Supabase Scheduled Function calling `/dispatch-webhooks` with the service key every minute).
- Not yet tested against a live database. Nothing has been deployed.
- Rate limiting, billing/plans, and per-client branding (SaaS layer) are not built.

## 4. Roadmap

1. **Phase 1 (this drop)**: schema, order/inventory/SKU API, inbound webhook, outbound webhook queue.
2. **Phase 2**: Web UI (login, orders list, create order, inventory, SKU master, API-key & webhook settings), pick → pack → manifest flow, GRN screens.
3. **Phase 3**: Courier integrations + AWB labels, returns/QC, reports/dashboard, barcode scanning (mobile web).
4. **Phase 4 (SaaS)**: onboarding, plans/billing, usage limits, audit log, role permissions.

## 5. Deploy steps

1. Create a Supabase project, run `schema.sql` in the SQL editor.
2. `supabase functions deploy wms-api --no-verify-jwt`
3. Insert a company, a warehouse, SKUs, and an API key hash.
4. Schedule `POST /dispatch-webhooks` (Bearer service-role key) every minute.
5. Test with the sample payload above.
