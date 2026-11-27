# Own WMS

EasyEcom-style multi-client WMS. Frontend: single `index.html` on GitHub Pages. Backend: Supabase (Postgres + Auth + Edge Function).

- **Live backend**: Supabase project `own-wms` (`lzwbgpolslygbiypjhpg`, ap-south-1)
- **API base**: `https://lzwbgpolslygbiypjhpg.supabase.co/functions/v1/wms-api`
- **Frontend**: `index.html` (login, orders with pick/pack/ship flow, inventory, SKUs, warehouses, PO/GRN, API keys, webhooks)

## Hosting on GitHub Pages
1. Push this folder to a repo's `main` branch.
2. Repo **Settings → Pages → Source: GitHub Actions**. The included workflow publishes `index.html`.
3. In Supabase **Authentication → URL Configuration**, set Site URL to your Pages URL (needed for email-confirmation links).

## Repo layout
- `index.html` – the web app (uses the publishable key; data is protected by row-level security)
- `supabase/functions/wms-api/index.ts` – REST + webhook API (deployed with JWT verification off; authenticates with `x-api-key`)
- `supabase/migrations/` – SQL applied to the project (see `0002_fixes_and_ui_functions.sql` for the final, corrected version)
- `docs/BUILD_PLAN.md` – architecture and roadmap

## Outbound webhook dispatch
Events are queued in `webhook_deliveries`. To deliver them, call every minute (pg_cron or any scheduler):
`POST /functions/v1/wms-api/dispatch-webhooks` with `Authorization: Bearer <service_role key>`.
Never put the service-role key in the frontend or the repo.
