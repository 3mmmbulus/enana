# Pro billing (cloud service)

The PocketBase account service sells Pro terms for mainnet TRC20 USDT and keeps a
USDT wallet per account. The shared Mac/Windows dashboard shows the membership
page (terms, wallet, invoices, automatic renewal, email verification) through the
local helper. Receiving is switched by server configuration (`payments_enabled`
in `/etc/enana/billing.json`, plus a healthy scanner heartbeat): while it is off,
`GET billing` reports `payments_available:false`, checkout answers
`503 E_PAYMENTS_UNAVAILABLE` and the dashboard says that payments are not open
instead of offering a pay button. Existing wallet balances stay readable and
usable either way.

All customer APIs require the same user token and device session as CLOUD_API.
Billing collections have no public REST access. A verified email is required to
create an invoice, buy from the balance or change automatic renewal. Money is
integer micro-USDT internally and a six-decimal string (`"4.100000"`) in every
answer.

| Method / path below `/api/enana/v1/` | Body / result |
| --- | --- |
| GET `billing` | Catalog, email state, `payments_available`, wallet, plan, one page of orders (see "Orders paging"), the 40 newest ledger rows, `order_ttl` (3600) and `lease_ttl` (86400) |
| POST `billing/checkout` | `request_key`, `kind:"plan"`, `sku`; or `kind:"topup"`, whole-USDT string `amount` → `{ok, order}` |
| GET `billing/order?id=…` | The current user's order only |
| POST `billing/cancel` | `id`; a pending order becomes `cancelled` (its amount stays reserved, see below) |
| POST `billing/order/recheck` | `id`; asks the scanner to look at this order's address now (pending or manual orders inside their 24 h lease; once per 30 s) |
| POST `billing/purchase` | `request_key`, `sku`; spends the existing balance atomically → `{ok, expires_at}` |
| POST `billing/auto-renew` | `enabled` boolean (default off) → `{ok, auto_renew, charged, balance, monthly_price, needs_topup}` |
| GET `email/status` | Account email, verified state, configured mail availability |
| POST `email/send` | Sends to the authenticated account's email; 60-second cooldown |

`request_key` is a client-generated random UUID (16–80 alphanumeric, hyphen or
underscore characters). Reusing it with the same purchase is idempotent and
returns the original order; changing the purchase returns `E_REQUEST_CONFLICT`.

## Prices and top-ups

The server determines price and term: `m1=4`, `m3=10`, `m6=19`, `y1=35`,
`y2=56`, `y3=72`, `y5=100` USDT. Prices are totals, not monthly rates; the
monthly renewal price is 4 USDT (`wallet.monthly_price`). Top-ups are **whole
USDT from 4 to 1000**: `amount` must be a string matching `^[1-9][0-9]{0,3}$`
with a value of 4–1000. Decimals, signs, padding, numbers that are not strings
and anything else are refused with `400 E_INVALID`; the distinguishing decimals of
an invoice are always chosen by the server.

## Invoices: amount, payment window, reservation

An order carries `price` (the catalog price or the top-up) and `amount` (what to
pay, exactly). The address/amount pair identifies the payment, so it is unique
among the reservations described below:

1. **Base price first.** If the price itself is free on any receiving address,
   the order takes it (`amount == price`, the first free address in the
   configured order).
2. **Tails** only when every address already holds the base price, in this order,
   each tail tried on every address before the next tail:
   - one decimal: +0.1, +0.2 … +0.9;
   - two decimals that are not whole tenths: +0.01 … +0.09, +0.11 … +0.99
     (+0.10, +0.20 … are skipped: they equal a one-decimal tail);
   - three decimals that are not whole hundredths: +0.001 … +0.009, +0.011 … +0.999.

   That is 999 tails, never more than three decimals and never a change of the
   units digit, so every amount of a price lies in `[price, price + 0.999]`
   (stored maximum: 1000.999 USDT for a 1000 USDT top-up, migration
   `1790000006_billing_amount.js`).
3. When all 1000 amounts of a price are reserved on every address, checkout
   answers `503 E_QUOTE_CAPACITY` and logs `enana-billing-alert quote_capacity`
   (add receiving addresses).

The client shows and copies `amount` exactly and never rounds it. When a plan
invoice is paid, the full amount is deposited and the catalog price is deducted
in the same transaction, so the tail stays in the wallet; a top-up deposits the
full amount.

Every order has two times (unix seconds):

- `pay_by` = creation + 1 hour: the **payment window**. The dashboard counts down
  to it, the scanner polls the address every ~10 seconds until then, and only an
  order inside its window blocks a new one (`409 E_ORDER_PENDING`: one open
  invoice at a time). Clients must use `pay_by`, never `expires_at`, to decide
  whether an order is still payable or blocking.
- `expires_at` = creation + 24 hours: the **reservation (lease)**. Until then the
  address/amount pair is not handed to anyone else, whatever the order's status
  (pending, cancelled, manual), so a late transfer can never pay someone else's
  invoice. A paid order releases its pair at once. A correct transfer whose block
  time is inside the lease still activates the order even after `pay_by`.

`status` is `pending`, `paid`, `cancelled`, `manual` (under operator review) or
`expired` (shown for a pending order whose lease has ended; it is not stored).

## Order limit

At most **5 orders per account in any rolling 24 hours**, counting every order of
any kind and status (cancelled ones included). An idempotent replay of an
existing `request_key` is answered before the check and never counts. The
sixth checkout answers:

```json
HTTP 429  {"ok":false,"code":"E_ORDER_LIMIT","message":"E_ORDER_LIMIT","limit":5,"retry_after":3600}
```

`retry_after` is the number of seconds (1–86400) until the oldest counted order
is 24 hours old, i.e. until a new order is allowed again. The limit is checked
after the replay branch and after `E_ORDER_PENDING`, before an amount is
reserved, inside the checkout transaction.

## Orders paging

`GET billing` takes two optional query parameters:

| Parameter | Values | Default |
| --- | --- | --- |
| `orders_page` | integer 1–1000 | 1 |
| `orders_per_page` | integer 5–30 | 30 |

`orders` is that page, newest first, and the answer adds `orders_total` (all
orders of the account), `orders_page` and `orders_per_page`. A page past the end
is an empty list. An empty value is the same as leaving the parameter out; any
other value outside the range (`0`, `01`, `1.5`, `abc` …) answers `400 E_INVALID`.
Without a query the answer is exactly as before (the 30 newest orders) plus the
three new fields, so older clients keep working. Paging changes only `orders`;
the wallet, plan and ledger are always the same.

## Receipts

Receipt acceptance uses the **block time**, not when the scanner notices the
transfer. A transfer settles an order automatically only when exactly one unpaid
order on that address has exactly that amount and its lease covers the block
time, and the order is still `pending`. Everything else goes to the operator
queue and the order (if any) shows `manual`: underpaid or overpaid amounts,
transfers to a cancelled order or after the 24-hour lease, a second transfer to a
paid order, several candidate orders, unknown transfers, and plan payments of a
disabled/unverified account. Nothing in the queue is credited, refunded or
activated automatically; an operator resolves each item with a note
(`activate`, `refund` with the refund transaction hash, or `note`) through the
superuser-only `admin/billing/manual` routes.

`POST billing/order/recheck` puts the order's address into the scanner's next
pass (for 5 minutes); it answers `409 E_EXPIRED` after the lease and
`429 E_RATE_LIMITED` within 30 seconds of the last recheck of that order.

## Automatic renewal

Automatic renewal is an explicit opt-in at 4 USDT/month. Enabling it while the
account is free or expired and the balance covers a month charges that month
immediately. The answer says what happened:

| Field | Meaning |
| --- | --- |
| `auto_renew` | the saved setting |
| `charged` | `true` when a month was bought from the balance by this request |
| `balance` | the wallet balance after the request (six-decimal string) |
| `monthly_price` | `"4.000000"` |
| `needs_topup` | `true` when renewal is on and the balance is below one month: nothing is charged until a top-up makes it enough |

Enabling with an empty wallet is allowed and saved (`charged:false`,
`needs_topup:true`). The cron job checks eligible accounts each minute, and a
paid top-up renews at once. No missed months are backcharged; a renewal starts
at the current time. Calendar months use UTC and clamp month-end dates. Turning
renewal off does not cancel the already-paid term. Insufficient balance cannot
partially debit or grant Pro.

## Error codes

| Code | HTTP | When |
| --- | --- | --- |
| `E_INVALID` | 400 | Malformed body, unknown term, top-up not a whole 4–1000, bad paging value (409: recheck of an order that is neither pending nor manual) |
| `E_REQUEST_KEY` | 400 | `request_key` missing or malformed |
| `E_AUTH` | 401 | Token or device session not valid |
| `E_EMAIL_UNVERIFIED` | 403 | Verified email required |
| `E_NOT_FOUND` | 404 | Not this account's order |
| `E_REQUEST_CONFLICT` | 409 | `request_key` reused for a different purchase |
| `E_ORDER_PENDING` | 409 | Another order is inside its 1-hour payment window |
| `E_BALANCE` | 409 | Balance too low for a wallet purchase |
| `E_ALREADY_UNLIMITED` | 409 | The plan has no end date |
| `E_EXPIRED` | 409 | Recheck after the 24-hour lease |
| `E_ORDER_LIMIT` | 429 | 5 orders in the last 24 hours (`limit`, `retry_after`) |
| `E_RATE_LIMITED` | 429 | Recheck within 30 seconds |
| `E_MAIL_WAIT` | 429 | Verification mail within 60 seconds |
| `E_PAYMENTS_UNAVAILABLE` | 503 | Receiving off or scanner unhealthy |
| `E_QUOTE_CAPACITY` | 503 | Every amount of this price is reserved |
| `E_MAIL_UNAVAILABLE` | 503 | Mail is not configured or failed |
| `E_BILLING_INTERNAL` | 500 | Unexpected server error (nothing is assumed to have happened) |

## Local helper (`/api/billing…` on the computer)

The dashboard never talks to the cloud directly. The local helper (`lib/api.sh`,
`lib/billing.sh`) maps `GET /api/billing`, `POST /api/billing/checkout`,
`GET /api/billing/order`, `POST /api/billing/cancel`,
`POST /api/billing/order/recheck`, `POST /api/billing/purchase`,
`POST /api/billing/auto-renew`, `GET /api/email/status` and `POST /api/email/send`
to the routes above with the device's cloud session. It sends only allow-listed
body fields (top-ups: whole USDT 4–1000, checked locally), forwards only the two
validated paging parameters for `GET /api/billing` (same ranges as above; an
empty value is left out, any other invalid value is refused locally with
`E_INVALID` and nothing is sent; other query parameters are never forwarded),
and filters every answer: a cloud error is relayed as `{ok:false, code}` only,
except `E_ORDER_LIMIT`, which also carries `limit` (1–1000) and `retry_after`
(1–86400) when they are integers in range. Local errors are HTTP 200 with
`ok:false`, so the local dashboard stays unlocked; `E_AUTH`, `E_SERVER_ERROR`,
`E_RATE_LIMITED` and `E_ACCOUNT_UNREACHABLE` describe a missing session, a broken
answer, a foreign 429 and an unreachable service.

## Scanner

Only the loopback scanner with a private service key may call
`/api/enana/internal/billing/{work,event,health}`. These routes are excluded from
public nginx. User-submitted transaction IDs, frontend state, indexer token
names and floating-point amounts cannot confirm payment. A healthy scanner
heartbeat within 180 seconds is required for new invoices; existing balances
remain accessible during provider outages. Deploying a billing update on a
running host is `server/update-billing.sh` (see `server/README.md`).

## Official nodes and email

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
