# Official nodes and voluntary sharing (2.3.8)

The shared macOS/Windows client supports official nodes alongside user servers.
Receiving remains disabled until real mail and TRC20 receipt acceptance. This
implementation does not claim a complete paid launch or Windows guest TUN/OAuth
acceptance. The dedicated Claude pool has no verified clean nodes and shows empty.

## Delivery and routing

`GET /api/enana/v1/nodes` requires a valid user token, a live owned device session,
verified email and an active plan containing `official_proxy`. Free, expired,
unverified, disabled or revoked accounts receive no credentials. Direct REST
access to `official_nodes` and `server_share_events` is administrator-only.

The local cloud bridge declares `X-Enana-Client-Version`; versions before 2.3.8
receive no nodes and keep the legacy coming-soon plan state, so an older client
cannot claim that a catalog has been applied.

The response contains `user_id`, `session_id`, `entitled`, `email_verified`,
`reason`, `expires_at` and validated proxy outbounds. Expiry is the earliest of
one hour, the active subscription expiry, device-session expiry and node freshness.
Denied responses contain an empty list with a reason and a fresh metadata lease;
an already-expired subscription cannot prevent the client applying an empty list.

The private client cache `official.json` is session-bound and separate from
`servers.jsonl`, subscription URLs and encrypted backups. Local roles live in
`official.roles.json`. The first official node defaults to PIN, other nodes to
Auto; existing user PIN nodes keep their order and default. Users can choose
PIN/Auto/Off roles. The source uses opaque reserved `enana-official-*` tags,
cannot override user tags, and uses the same app/website PIN/Global/direct rules
and localhost/LAN/TUN exclusions as user nodes. No special OAuth domain patch
exists.

The UI's **Refresh and apply** action uses the existing configuration transaction:
generate, sing-box check, apply/restart, readiness and rollback. Opening/refreshing
the page only reads metadata. Background checks every ten minutes renew unchanged
leases. In System Proxy mode catalog changes apply through the transaction. TUN
changes stage a private candidate and require interactive administrator approval;
a timer never opens an authorization prompt. Expired or withdrawn access pauses
the proxy and closes existing connections if the running config contains official
nodes. Re-enabling is blocked until refresh applies a valid/empty catalog. An
offline expiry is detected on the next maintenance tick (normally within a minute).
User servers and preferences remain available after applying that catalog.

Credentials are omitted from server-table responses, reveal actions, diagnostics
and backup/sync snapshots. Logout deletes official caches, pending files, role
overrides and cached plans, including transaction backups. Late responses cannot
repopulate a different account's UI/cache. The client core must still possess
usable credentials: this is access control for new deliveries, not DRM, and cannot
hide configuration from the computer's owner or revoke already-copied credentials.

## Sharing is a separate authorization

Cloud backup is encrypted and does not grant server-sharing rights. A user opens
an owned manual node's action dialog, chooses **Share with Pro users**, reads the
credential/bandwidth disclosure, then explicitly consents and passes password
verification. Only that proxy outbound is uploaded unencrypted. The bridge never
uploads SSH passwords/private keys, subscriptions, other nodes or sync snapshots.
Official/derived/subscription nodes cannot be shared by the local client.

| Route below `/api/enana/v1/` | Contract |
| --- | --- |
| GET `servers/shares` | Own metadata only: key, label, review state and expiry |
| POST `servers/share` | `key` (32 hex), boolean `consent`; enable also requires `revision:"server-sharing-v1"`, `label`, validated `outbound` |

The server creates its own owner-qualified key. Every mutation rechecks ownership,
user and session in a database transaction. Enabling requires verified email,
allows at most ten active shares per owner, and grants seven-day freshness. New
credentials require operator review; renewing identical credentials preserves
approval. Disabled/unverified owners, missing consent, stale shares or unapproved
nodes are never distributed. No automatic renewal/upload is implied by login.

Revocation disables new delivery and clears the stored outbound immediately,
while retaining credential-free consent/review history. Rotate the server's proxy
credentials to invalidate already-delivered copies. A locally marked shared node
must be revoked online before deletion; local deletion cannot silently leave that
share active. Remote shares may outlive logout/uninstall until consent expires or
is revoked; accounts and already-approved cloud data are not deleted by uninstall.

The validator supports common HTTP/SOCKS/Trojan/SS/VLESS/VMess/TUIC/Hysteria2/AnyTLS
outbounds with bounded fields, public IPv4/DNS endpoints and selected TLS/transports.
Unknown extension fields, private/literal IPv6 endpoints, file paths, detours,
interfaces and insecure TLS are refused. Additional protocols require review and
validation rather than accepting arbitrary sing-box configuration.

## Private server operation

`/etc/enana/official-source.json` contains only the authorized upstream HTTPS URL,
mode 640 root:enana. Never add it to Git, client archives, logs or screenshots.
`enana-catalog-refresh.service` parses the private source with the shared importer,
validates all accepted nodes, updates the catalog atomically and disables removed
official nodes. The timer refreshes every six hours; existing node freshness lasts
two days if the source becomes unavailable, bounded by an upstream expiry header. A failure cannot extend the old expiry
or replace the catalog with an empty response.

Local-only administrator commands (`server/admin`, never production HTTP hooks):

```sh
pocketbase enana-nodes-import PRIVATE_INPUT.json --dir=PB_DATA --hooksDir=ADMIN --migrationsDir=MIGRATIONS
pocketbase enana-share-review shared-OWNER_ID-KEY approve --dir=PB_DATA --hooksDir=ADMIN --migrationsDir=MIGRATIONS
```

Private import input: `nodes:[{key,label,outbound}]`, `fresh_until` (future Unix
seconds, at most seven days). Official imports are approved by the operator and
marked `general`; nothing infers that a regional node is a clean Claude node.
Operator review requires current verified owner consent and valid proxy data.

`server/deploy-nodes.sh` is for the existing integration host with receiving off.
It validates the real source before stopping enana, backs up its SQLite data,
installs additive migrations/hooks and only the exact sharing nginx routes, and
checks other service PIDs, configurations, downloads and the receiving config.
Rollback restores the previous enana code; after reopening public writes it keeps
financial data rather than restoring an older database snapshot. Repeated/future
paid-host deployments require the same reviewed constraints, not blind replacement.

## Verification

Real PocketBase tests cover entitlement/session gates, both platform sessions,
private collection access, consent/review/renew/change/revoke, disabled owners
and stale nodes. Real CGI/shell tests cover redaction, step-up, targeted uploads,
PIN/Auto generation, cache expiry and backup/logout isolation. UI tests prove
read-only page loads, confirmation, cancellation and account-switch race handling.
Native Windows CI checks actual sing-box configurations in both capture modes;
interactive guest UAC, TUN traffic and native-app OAuth remain on-device tests.
