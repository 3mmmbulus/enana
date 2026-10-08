# Pro billing foundation (cloud service)

This backend is implemented and the shared Mac/Windows dashboard ships the
membership page (prices, wallet, invoices, email verification). Receiving of
new payments is **disabled by server configuration** (`payments_enabled=false` in
`/etc/enana/billing.json`) until go-live: `GET billing` then reports
`payments_available:false`, checkout answers `503 E_PAYMENTS_UNAVAILABLE`, and the
dashboard shows an explicit "payments are not open yet" notice instead of a
working pay button. Existing wallet balances stay readable and usable.
All customer APIs require the same user token and device session as CLOUD_API.
Billing collections have no public REST access. Verified email is required to
create an invoice, buy from balance or change automatic renewal.

| Method / path below `/api/enana/v1/` | Body / result |
| --- | --- |
| GET `billing` | Catalog, verified-email state, provider availability, wallet, plan, recent orders and ledger |
| POST `billing/checkout` | `request_key`, `kind:"plan"`, `sku`; or `kind:"topup"`, decimal-string `amount` |
| GET `billing/order?id=…` | The current user's invoice only |
| POST `billing/cancel` | `id`; pending invoice becomes cancelled |
| POST `billing/purchase` | `request_key`, `sku`; spends existing balance atomically |
| POST `billing/auto-renew` | `enabled` boolean; defaults off |
| GET `email/status` | Account email, verified state, configured mail availability |
| POST `email/send` | Sends to the authenticated account's email; 60-second cooldown |

`request_key` is a client-generated random UUID (16–80 alphanumeric, hyphen or
underscore characters). Reusing it with the same purchase is idempotent; changing
the purchase returns `E_REQUEST_CONFLICT`. The server determines price and term:
`m1=4`, `m3=10`, `m6=19`, `y1=35`, `y2=56`, `y3=72`, `y5=100` USDT. Prices are
totals, not monthly rates. Top-ups are 4–1000 USDT with at most six decimal places.

Invoices are mainnet TRC20 USDT only and last 30 minutes. `amount` is a six-decimal
string, slightly above the catalog price (less than 0.01 USDT); the checkout UI
must show and copy this exact amount. The difference remains in the user's
wallet. Address/amount pairs are never reused, even after cancellation or
expiry, so a delayed transfer cannot pay another user's later invoice. One
unexpired pending invoice is allowed per user. Never round the displayed amount.

Receipt acceptance uses the **block time**, not when the scanner notices it.
An in-time plan payment deposits the full amount, deducts the catalog price and
extends Pro atomically. Expired or cancelled payments stay in the wallet with
`credited_late`; a changed disabled/unverified account retains funds without
receiving Pro. Wrong amounts or unmatched transactions are recorded for
operator review and do not automatically grant entitlements. A second distinct
transfer to an already-paid quote is also retained as unmatched for review.

Automatic renewal is an explicit opt-in at 4 USDT/month. Enabling it while the
account is expired/free and funded charges the first month immediately; the UI
must disclose that action. The cron processes eligible accounts each minute.
No missed months are backcharged; a renewal starts at the current time. Calendar
months use UTC and clamp month-end dates. Turning renewal off does not cancel
the already-paid term. Insufficient balance cannot partially debit or grant Pro.

Only the loopback scanner with a private service key may call
`/api/enana/internal/billing/{work,event,health}`. These routes are excluded from
public nginx. User-submitted transaction IDs, frontend state, indexer token
names and floating-point amounts cannot confirm payment. A healthy scanner
heartbeat within 180 seconds is required for new invoices; existing balances
remain accessible during provider outages.

Official route nodes are delivered by `GET nodes` (see CLOUD_API.md) only to an active Pro
plan with a verified email; nothing in the billing flow can unlock them early. When a
payment, wallet purchase or renewal changes the plan, the dashboard asks the local helper
for `GET /api/plan?refresh=1` (a synchronous cloud refresh) and the helper then syncs the
official nodes in the background.

Email activation uses PocketBase's native POST
`/api/collections/users/confirm-verification`. Mail links carry the token in a
fragment on `https://enana.cc/verify`, which removes it from browser history and
requires an explicit confirmation click. Existing unverified users keep local
and free functionality. SMTP uses the official Gmail sender with a dedicated
Google app password; configuration steps are in `server/README.md`.
