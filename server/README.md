# enana account service and Pro billing

This directory tracks the PocketBase account service separately from the
downloadable macOS/Windows client. Never include `pb_data`, SMTP credentials,
payment provider keys or subscription source URLs in a client package.

The billing foundation provides authenticated order/wallet APIs, atomic receipt
settlement, opt-in renewal, SMTP verification and a confirmation page. It has
real PocketBase integration tests. Deployment deliberately leaves receiving
disabled. The shared Mac/Windows dashboard now includes catalog checkout,
exact-amount invoices, wallet purchase, renewal consent and verification mail.
Official-node lease delivery and server-sharing controls remain separate work;
this is not a complete Pro launch. Official lines still show coming soon, with
an explicitly empty dedicated Claude pool.

The ordinary account service sources are now tracked here for reproducible
testing. User databases, SMTP passwords, provider keys, and upstream subscription
URLs are private deployment inputs and never part of these sources.

## Confirmed product decisions

| Term | Total USDT price |
| --- | ---: |
| 1 month | 4 |
| 3 months | 10 |
| 6 months | 19 |
| 12 months | 35 |
| 2 years | 56 |
| 3 years | 72 |
| 5 years | 100 |

Wallet renewal is 4 USDT per month and requires an explicit opt-in. Store all
money as integer micro-USDT and commit balances, ledger entries and entitlements
atomically. Only confirmed mainnet TRC20 USDT transfers may settle an order;
browser state and user-supplied transaction hashes cannot grant Pro.

The third-party official subscription has permission for sharing. Its source
URL and upstream credentials stay in protected server configuration. The local
proxy core must receive usable node connection details, so a computer owner can
inspect those details; hiding them in the dashboard does not provide DRM.

User servers enter a shared pool only after separate, explicit authorization.
Private encrypted configuration backup does not imply consent to sharing.
Only selected proxy outbound details may be shared; SSH passwords/keys and
other nodes remain private. Sharing requires moderator approval, and revocation
disables future distribution. Rotate credentials to invalidate copies already
delivered. The dedicated Claude pool must display “暂无” until actual approved
nodes exist; ordinary nodes are not advertised as clean dedicated addresses.

## Configure verification mail with Gmail

1. Sign in to the official sender `gococms@gmail.com` and enable Google Account
   two-step verification under **Security → How you sign in to Google**.
2. Open [App passwords](https://myaccount.google.com/apppasswords) and create a
   dedicated password named `enana SMTP`. Use this app password rather than the
   account login password. If the option is unavailable, check Google's
   [requirements](https://support.google.com/accounts/answer/185833); some
   managed accounts and Advanced Protection accounts cannot use app passwords.
3. Open PocketBase admin through an SSH tunnel. Production superuser access is
   restricted to loopback; do not open port 8090 to the Internet. For example,
   use `ssh -N -L 18090:127.0.0.1:8090 YOUR_CONFIGURED_ENANA_HOST` and visit
   `http://127.0.0.1:18090/_/` on the administrator's computer.
4. In **Settings → Mail settings**, set:

   | Setting | Value |
   | --- | --- |
   | SMTP enabled | Yes |
   | Host | `smtp.gmail.com` |
   | Port | `465` |
   | TLS | Yes |
   | Authentication | `PLAIN` |
   | Username | `gococms@gmail.com` |
   | Password | The dedicated Google app password |
   | Sender name | `enana` |
   | Sender address | `gococms@gmail.com` |

5. Save, then send a test message to an address you own using PocketBase's test
   control. Confirm delivery and spam-folder behavior before enabling customer
   verification. After the verification endpoint and page are deployed, test
   registration, resend, expired links and a successful verified account on both
   clients.

Do not paste the app password into chat, Git, shell command arguments, a client
configuration or an exported diagnostic. Enter it only in the tunneled admin
form or a protected administrator input file. Keep protected database backups; PocketBase stores mail configuration in
the server settings. Gmail account-password changes revoke app passwords, so
replace the SMTP app password after such a change.

Gmail SMTP and PocketBase mail configuration references:
[Google SMTP settings](https://support.google.com/mail/answer/7104828),
[PocketBase mail](https://pocketbase.io/docs/js-sending-emails/).

For deployment without opening the administrator UI, `server/admin/smtp.pb.js`
offers local `enana-smtp-configure INPUT_PATH BACKUP_PATH`, `enana-smtp-status`
and `enana-smtp-restore BACKUP_PATH` commands. Use an isolated `--hooksDir`
containing this reviewed helper, an empty migrations directory, the existing
enana database, and `--automigrate=false --hooksWatch=false`. The input contains
only `sender` and `password`; both the input and backup must be private files.
The helper saves a mode-600 settings backup and prints only safe status fields.
Remove the temporary input after configuration, restart only enana's PocketBase
unit to reload settings and check its health. Never load these administrator
commands in the HTTP daemon or include them in a client archive. The receiving
switch is independent of SMTP settings and must remain off until Pro delivery
is ready.

## Verify the foundation

Use Node 18+ and PocketBase 0.40.4. The integration test creates a disposable
database and local SMTP sink; it never copies production accounts or transfers
real money. `PB_BIN` is required, so a missing real database test cannot silently
pass.

```sh
PB_BIN=/absolute/path/to/pocketbase node --test \
  tests/billing-domain.test.js tests/billing-pocketbase.test.js \
  tests/email-verification-ui.test.js tests/billing-ui.test.js \
  tests/billing-smtp-admin.test.js
```

Run `python3 tests/billing-bridge.py` for the actual local CGI, authentication,
request normalization, upstream failure handling and credential redaction.

The test covers Mac/Windows sessions, unverified accounts, collection access,
provider health, concurrent duplicate checkout/receipts, exact decimal amounts,
wallet rollback, cancellations, late confirmations, renewal cron, email resend
and native PocketBase verification. Payment events and wallet entries are unique
independently of the scanner's local acknowledgement state.

## Protected configuration and deployment

Install `/etc/enana/billing.json` as root:enana, mode 640, in a 750 directory:

```json
{
  "payments_enabled": false,
  "addresses": ["VALIDATED_PUBLIC_TRC20_RECEIVE_ADDRESS"],
  "provider_key": "PRIVATE_TRONGRID_KEY",
  "scanner_secret": "PRIVATE_RANDOM_SECRET_AT_LEAST_32_CHARACTERS",
  "daily_budget": 90000
}
```

The scanner only calls the fixed mainnet `https://api.trongrid.io` origin. It
uses the indexer to discover transactions, then independently validates Solidity
receipts, the official USDT contract, successful execution, finalized height,
recipient and integer amount. Indexed amounts alone never grant Pro. Polling is
10 seconds for an active receive address and five minutes while idle; finality
and provider availability determine the actual response time. The optional daily
request budget is an application cap, not a claim about TronGrid's free quota.

Scanner state is private under `/var/lib/enana-cc/payments`. It rereads receive
history from deployment time, including expired-order transfers, so a delayed
index entry or interrupted pagination cannot be skipped by an advancing cursor.
Acknowledged receipt IDs suppress repeat receipt queries; a partial receipt
replays safely against DB uniqueness. Pagination is bounded to 100 pages; hitting
the cap marks the scanner unavailable and blocks new orders pending an operator
review. Monitor capacity before growing the receive history or payment volume.

`deploy-billing.sh STAGED_REPOSITORY PRIVATE_CONFIG` is an initial deployment on
the existing enana host. It validates receiving is off, backs up the stopped
enana database/configuration, migrates only enana, adds exact nginx routes and
installs `enana-payments.service`. It checks other service PIDs, other shared
configuration and all download/signed-content files remain unchanged. A failure
restores the enana snapshot; financial migration rollback never deletes rows.
Do not use this initial deployment script to overwrite a running paid service.

Gmail SMTP must be configured and real receipt acceptance validated before a
complete Pro release can enable receiving. Never enable payments as a substitute
for shipping the billing UI and official-node entitlement enforcement.

## Diagnostics upload (2.3.9)

`pb_migrations/1790000004_enana_diag.js` adds `diag_reports` (summary and full diagnostics per
device; every API rule is `null`, so only superusers can read it). `pb_hooks/enana_diag.js` and
`enana_diag.pb.js` implement `POST /api/enana/v1/diag`, `POST .../diag/full` and `DELETE .../diag`
with shape/size checks, per-device rate limits and retention (7 days, 200 summaries / 5 full
bundles per device, cascade delete with the account); see `docs/DIAGNOSTICS.md` and
`docs/CLOUD_API.md`. nginx exposes only an exact allow-list of API paths, so deploying needs one
extra step: run `python3 update-nginx-diag.py <current enana.cc.conf> <new file>`, review the diff,
`nginx -t`, then reload. It adds the two exact-path locations with their larger body limits and
touches nothing else. `tests/diag-pocketbase.test.js` runs all of this against a real PocketBase
(`PB_BIN=/path/to/pocketbase node --test tests/diag-pocketbase.test.js`).
