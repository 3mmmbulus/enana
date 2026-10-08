# enana account service and Pro billing

This directory tracks the PocketBase account service separately from the
downloadable macOS/Windows client. Never include `pb_data`, SMTP credentials,
payment provider keys or subscription source URLs in a client package.

The billing foundation provides authenticated order/wallet APIs, atomic receipt
settlement, opt-in renewal, SMTP verification and a confirmation page. It has
real PocketBase integration tests. Deployment deliberately leaves receiving
disabled. The shared Mac/Windows dashboard now includes catalog checkout,
exact-amount invoices, wallet purchase, renewal consent and verification mail.
Official lines are fed by privately configured third-party subscription sources
(see "Official route nodes" below) and switch on by themselves once at least one
fresh approved node exists; until then they keep showing "coming soon". Server
sharing controls remain separate work, with an explicitly empty dedicated Claude
pool; this is not a complete Pro launch. The dashboard states every reason a
purchase is unavailable (receiving not open, email unverified, unfinished
invoice, expired sign-in) next to the buttons instead of only dimming them.

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
  tests/official-domain.test.js tests/official-pocketbase.test.js \
  tests/email-verification-ui.test.js tests/billing-ui.test.js \
  tests/billing-plan-ui.test.js tests/billing-smtp-admin.test.js
python3 tests/billing-bridge.py && python3 tests/official-bridge.py
```

`tests/official-pocketbase.test.js` starts a local HTTPS server that plays the third-party
subscription (synthetic `*.example.invalid` nodes, a made-up token, a throw-away certificate
trusted only by the PocketBase child through `SSL_CERT_FILE`; it needs `openssl` and Linux).

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

## Official route nodes (third-party subscription)

The nodes Pro members receive ("官方线路") come from third-party subscription URLs. A subscription
URL carries a token, so it is a secret: it lives only in a private root-only file on the server and
is never committed, logged, stored in the database, returned by any route, or placed in a client
package. The design takes a **list** of sources so more can be added later.

**1. Create `/etc/enana/official.json`** (`update-official.sh --set-source` below writes it for you; owner `root:enana`, mode 640, in the 750 `/etc/enana`
directory; `deploy-billing.sh` validates it structurally without printing it and fixes the mode):

```json
{
  "sources": [
    { "id": "main", "url": "https://example.invalid/subs/TOKEN", "ua": "sing-box/1.12.0", "prefix": "官方-", "enabled": true }
  ],
  "ttl_hours": 24
}
```

| Field | Meaning |
| --- | --- |
| `id` | `[a-z0-9-]`, 1-16 characters, unique. Internal only; never sent to clients. |
| `url` | `https://` only (no user:password@). Redirects are followed by PocketBase's HTTP client, so use a provider you trust. |
| `ua` | User-Agent. A `sing-box/<version>` agent makes the provider return one complete sing-box JSON, which is the only format parsed (Clash YAML and share-link fallbacks are intentionally not implemented). Default `sing-box/1.12.0`. |
| `prefix` | Tag prefix; always forced to start with the reserved `官方-` so a user import can never collide with an official tag. |
| `enabled` | `false` retires the source's nodes at the next run. |
| `ttl_hours` | How long a fetched node stays servable without a new successful fetch (default 24, clamped 2-168). |

Up to 8 sources are read. A malformed entry is ignored (and its nodes retired); an unreadable or
missing file never retires anything. `ENANA_OFFICIAL_CONFIG` overrides the path, like billing's
`ENANA_BILLING_CONFIG`.

**2. Deploy.** `deploy-billing.sh` installs `enana_official.pb.js`, `enana_official.js` and
`enana_official_domain.js` next to the billing hooks (no schema change: the existing empty
`official_nodes` collection is used, with `node_key = <source id>~<hash of tag>`). nginx already
allow-lists `nodes`; the operator routes below are not in the public allow-list and require a
superuser, who is restricted to loopback.

On a host where `deploy-billing.sh` already ran, do **not** run it again (its nginx step refuses an
already-updated configuration and rolls back). Use `update-official.sh` instead. Put the checked-out
repository on the server (git clone or rsync; below it is `/root/enana-stage`) and, as root:

```sh
S=/root/enana-stage
bash $S/server/update-official.sh --set-source $S   # type the source URL at the hidden prompt (id "main"; --id NAME adds another)
bash $S/server/update-official.sh --check $S        # validate and list what would change; changes nothing
bash $S/server/update-official.sh $S                # install + restart + verify; rolls back by itself on any failure
bash $S/server/update-official.sh --sync            # sign in as the PocketBase superuser, fetch now, show counts
```

`--set-source` reads the URL without echo, validates it with the same rules the server applies (https only, no
`user:password@`, no spaces), merges it into `/etc/enana/official.json` (root:enana, 640; a 700 backup of the
previous file is kept under `/var/backups/enana/releases/`) and never prints it. The install refuses unless
billing is deployed, PocketBase is healthy, the staged hooks parse and an existing `official.json` is valid;
it takes `deploy-billing.sh`'s lock, backs up the four files it replaces
(`/var/backups/enana/releases/official-<UTC time>-<pid>`, mode 700), restarts only `enana-pocketbase.service`,
waits for `/api/health`, checks that the operator routes answer 401/403 (404 means the hooks did not load),
and that every other running service, the nginx/systemd files and `enana-payments.service` are unchanged. If
any step after the first change fails it restores the old files, restarts PocketBase again and exits
non-zero. Running it again when nothing changed restarts nothing. It never reads or writes
`/etc/enana/billing.json`, so it cannot switch payment receiving on or off. `--sync` exits 3 when a source
failed to fetch (error codes as below). `tests/update-official.sh` exercises all of this against a fake host.

The manual equivalent (no backup, no rollback) is:

```sh
for f in enana_lib.js enana_official.pb.js enana_official.js enana_official_domain.js; do
  install -m 644 -o root -g root server/pb_hooks/$f /opt/enana-cc/pb_hooks/$f
done
systemctl restart enana-pocketbase.service
```

Until `/etc/enana/official.json` exists with at least one working source, nothing changes for users:
the official card keeps saying "coming soon".

**3. Check it** (superuser token through the loopback/SSH tunnel; read the password without echoing it):

```sh
read -rsp 'superuser password: ' PW; echo
SUPER=$(curl -s -X POST http://127.0.0.1:8090/api/collections/_superusers/auth-with-password \
  -H 'Content-Type: application/json' -d "{\"identity\":\"ADMIN_EMAIL\",\"password\":\"$PW\"}" | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')
curl -s -X POST http://127.0.0.1:8090/api/enana/admin/official/sync   -H "Authorization: $SUPER"   # fetch now
curl -s          http://127.0.0.1:8090/api/enana/admin/official/status -H "Authorization: $SUPER"   # counts, last success
```

Both answers contain only source ids, node counts, skipped counts and short error codes
(`network`, `http_<status>`, `empty`, `too_large`, `bad_format`, `no_nodes`, `store`).

**What happens.** An hourly cron (`enana_official_sync`, 23 minutes past) fetches each enabled source
that has not succeeded in the last ~3 hours (a failing source is retried hourly), parses the sing-box
JSON, keeps only real proxy outbounds (`trojan http socks tuic hysteria2 vless vmess shadowsocks
anytls`), drops selectors / urltest / direct / block / dns and the "traffic left / expires"
pseudo-nodes, rebuilds every outbound from a per-protocol allow-list (no `detour`, bind interfaces,
DNS settings or local file paths), writes `type` then `tag` first and sorts the other keys so equal data
gives equal bytes, prefixes and de-duplicates tags, and upserts the rows in one transaction
(vanished nodes are deleted). Any failure (network, non-200, oversized body, not JSON, zero usable
nodes) leaves the existing rows untouched; they simply stop being served when `fresh_until` passes.
PocketBase's `$http.send` has no size limit option: the 4 MiB cap rejects an oversized body after it
was read. Logs record only source id, counts and error codes. To hide one node, set `enabled` to false
on its `official_nodes` row in the admin UI; later syncs refresh the node but do not re-enable it.

`GET /api/enana/v1/nodes` serves the rows only to an active Pro plan with a verified email (see
`docs/CLOUD_API.md`); the plan's `official_proxy` feature stops saying "coming soon" as soon as one
fresh approved node exists, and `official.available/nodes` come from the same table. Rotating a
token is an edit of the file, then the next hourly run (or the `sync` call above).

Official node credentials are not viewable or exportable in the clients, and they disappear when the
membership ends (clients keep them for up to 3 days offline). The local proxy core necessarily
receives usable credentials, so this is access control, not DRM.

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
