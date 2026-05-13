# Kong — API gateway

DB-less Kong (no Postgres) sitting behind nginx at `/api/*`. Configured
declaratively in `kong.yml`. Validates JWTs **issued by the BFF**, not by
Keycloak — see `bff/docs/IMPROVEMENT_PLAN.md` §2.2 for the architectural why.

For **deploying this stack on a single VPS** (Ubuntu LTS, TLS via
Let's Encrypt, BFF + nginx + Kong + Redis + sample-service all on one box),
see [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md).

## How auth works at this layer

The BFF talks to Keycloak (PKCE + OAuth2). After authenticating a user,
the BFF mints a short-lived **RS256 internal JWT** that mobile carries as
its Bearer. Kong's bundled `jwt` plugin verifies that JWT against the
**RSA public key** that matches the token's `kid` claim. Keycloak is never
in Kong's path, and Kong cannot mint tokens — it has the public key only.

```
mobile  ──Bearer <internal-jwt (RS256)>──►  Kong (jwt plugin)  ──►  upstream service
                                              ↑
                                              │ RS256 verify with
                                              │ rsa_public_key for
                                              │ token's kid claim
```

This means **no custom Kong image, no Lua plugin patches, no Keycloak JWKS
sync**. We use Kong's stock image and stock plugin.

## Files

```
kong.yml       # routes + services + bundled jwt plugin + one consumer (the BFF)
```

(There used to be a `Dockerfile` here that installed `kong-plugin-jwt-keycloak`.
We dropped it once the BFF started minting internal JWTs. There also used to
be a `kong.yml.template` rendered with `sed` on container start; that was
retired alongside the HS256→RS256 migration since the public key is no
longer secret.)

## Routes (current)

| External path | Upstream | Auth |
|---|---|---|
| `/api/profile`        | `sample-service:3001/`        | Bearer required |
| `/api/profile/health` | `sample-service:3001/health`  | Bearer required |

`strip_path: true` — Kong removes the `/api/profile` prefix before forwarding,
so the upstream service doesn't have to know its mount point.

## How Kong matches a token to a credential

`jwt` plugin config: `key_claim_name: kid`. Kong reads the token's payload
claim `kid`, finds the consumer credential whose `key:` field equals that
value, and uses that credential's `rsa_public_key` to verify the RS256
signature. The BFF mints `kid` in **both** the header (RFC 7515 standard)
and the payload (so this lookup works without a custom plugin).

## Reject conditions

The bundled `jwt` plugin returns 401 if any of these is true:

- No `Authorization: Bearer …` header — cookie/query carriers are
  disabled (`cookie_names: []`, `uri_param_names: []`; AUDIT S-2)
- Token's payload `kid` doesn't match a known credential
- Signature doesn't verify against the matched credential's `rsa_public_key`
- Algorithm doesn't match (`algorithm: RS256` is enforced per credential)
- `exp` is in the past, or `nbf` is in the future (both listed in
  `claims_to_verify`; AUDIT S-4)
- `exp - iat > 600 seconds` (`maximum_expiration: 600`; AUDIT S-4) —
  caps how long any internal token can live, regardless of what the BFF
  signed

The follow-up `pre-function` plugin returns 401 if:

- `iss` is not `super-app-bff` (AUDIT S-1)
- `aud` does not contain `super-app-services` (AUDIT S-1)

Authenticated requests are then subject to per-user rate limiting
(`limit_by: header`, `header_name: X-User-Id`) at **600 req/min/user**
(AUDIT P-1). Limit exceeded → `429 Too Many Requests`. Unauthenticated
requests never reach this plugin — they are 401'd at the `jwt` plugin
above.

The bundled `jwt` plugin has no `iss`/`aud` verification mode — the
plugin's `claims_to_verify` supports only `exp` and `nbf`. We enforce
issuer/audience in the Lua because, without it, any other internal
RS256 signer that shares a `kid` would be accepted.

## Identity headers (set by Kong, trusted by upstream)

After the `jwt` plugin validates a token, a `pre-function` Lua snippet runs
in the `access` phase and sets these upstream headers from the verified
JWT claims:

| Header | JWT claim | Type |
|---|---|---|
| `X-User-Id` | `sub` (Keycloak's stable user id) | string |
| `X-Session-Id` | `sid` (BFF session id) | string |
| `X-Roles` | `roles` joined by `,` | CSV |

**Spoof protection:** any inbound copies of these three headers are
**stripped first**, before the JWT is decoded. So a client cannot send
`X-User-Id: admin` and have it reach upstream — only Kong-set values
survive. Upstream services should read identity exclusively from these
headers and never decode the JWT themselves.

**Authorization stripped upstream** (AUDIT S-3): once identity is in
the `X-*` headers, the `pre-function` plugin clears the `Authorization`
header before forwarding. Upstreams never see the raw bearer — this
keeps a 5-minute replay window from leaking via service logs / stores
if any upstream is compromised, and forces every new microservice to
adopt the header-based identity pattern from day one.

The Lua doesn't re-verify the signature — by the time `pre-function`
runs, the bundled `jwt` plugin has already proven the token. We just
re-decode the base64url payload (manually, since `kong.plugins.jwt.jwt_parser`
isn't allowed inside the Lua sandbox) and forward fields we trust.

Kong needs `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe` for the
inline JSON decode to work (set in `docker-compose.yml`).

## Global plugins

These run for every route, not just `sample-service`:

| Plugin | Purpose | Reference |
|---|---|---|
| `request-size-limiting` | 256 KB cap on request bodies — defense-in-depth on top of nginx's 64 KB cap. | AUDIT S-6 |
| `prometheus` | RPS / latency / upstream-health metrics on `:8100/metrics` via Kong's Status API. **Internal-network only** — no host port mapping. | AUDIT PR-2 |
| `file-log` | One JSON object per request to container stdout — includes route, service, latencies, request headers (incl. `x-request-id`), response status. | AUDIT M-3 |

Status API (where `/metrics` lives) is exposed via
`KONG_STATUS_LISTEN=0.0.0.0:8100` in `docker-compose.yml`. Scraping from
the host requires either a host-port mapping (avoid; the audit calls this
out) or a sidecar / Prometheus running inside the compose network.

## Editing the pre-function Lua (AUDIT M-2, S-9)

The pre-function plugin's `access`-phase Lua lives in two places:

- `kong/lua/identity_inject.lua` — **canonical source.** Edit here first.
  Gets you IDE syntax highlighting and reviewable code-diffs.
- `kong/kong.yml` (under `pre-function.config.access`) — **what Kong
  actually runs.** Must be kept identical to the canonical file. Kong
  3.x's pre-function plugin has no file-reference syntax and the Lua
  sandbox blocks `io.open`/`dofile`, so the duplication is unavoidable.

Workflow:

```bash
# 1. Edit kong/lua/identity_inject.lua
# 2. Mirror the change into kong/kong.yml (indent + 14 spaces per line)
# 3. Verify the two are in sync:
node kong/scripts/check-lua-sync.mjs
```

`check-lua-sync` exits non-zero with a first-divergence diff if the two
copies have drifted. Wire it into CI when a CI pipeline lands.

The canonical file's body begins after the `-- @canonical-body-start`
sentinel line — that's how the drift gate locates the body. Leave it
in place when editing.

## Validating kong.yml (AUDIT M-5)

```bash
node kong/scripts/validate.mjs
```

Runs `kong config parse` inside the same Kong 3.8 image docker-compose
uses. Catches schema / syntax errors at edit time instead of at
container boot. Requires Docker to be running locally.

## Rotation pre-flight (AUDIT PR-1, partial)

```bash
node kong/scripts/audit-kid-config.mjs
```

Reads the kid configuration from all four sources (`kong/kong.yml`,
`docker-compose.yml`, workspace `.env`, `bff/.env`) and reports any
mismatch. The most common rotation failure is forgetting one of them —
e.g., adding `dev-v2` to the BFF's `BFF_INTERNAL_JWT_PUBLIC_KEYS` but
forgetting to append the matching `jwt_secrets` entry to `kong.yml`,
which leaves Kong rejecting every v2-signed token at the gateway. Run
before and after every step of the rotation runbook above.

(Historical note: an earlier version of this script and runbook tracked
`INTERNAL_JWT_PUBKEY_*` env vars in `docker-compose.yml` because the
PEM was sourced via `{vault://env/...}`. That indirection was removed —
see "Why not `{vault://env/...}`?" above — and the script now reports
those kong.yml entries as `(inline pem)` in its summary.)

Full automation of the rotation steps themselves is a future improvement
— it would have to coordinate edits across multiple files and trigger
container restarts, which is more orchestration than is justified while
the deploy is single-host docker-compose.

## Container health (AUDIT A-3, PR-3)

The Kong container has:

- `restart: unless-stopped` — orchestrators recreate on crash instead
  of leaving the edge dead.
- `healthcheck` running `kong health` every 10s — drives Compose's
  `service_healthy` gate so nginx only starts forwarding once Kong has
  loaded `kong.yml` and is serving.
- `security_opt: [no-new-privileges:true]` — blocks privilege escalation
  inside the container.

The fuller hardening the audit recommends — `read_only: true` + tmpfs,
explicit `user:`, `cap_drop: [ALL]` — is **not** applied yet. The
kong:3.8.0-ubuntu entrypoint runs briefly as root to set up its nginx
prefix (`/usr/local/kong/*`) and write pid files; enabling these
restrictions without a staging stack to verify can break startup. Track
as a TODO and add once a staging environment exists.

## Request-id correlation (AUDIT M-4)

Every request line in the system carries the same `X-Request-Id`:

1. nginx mints `$request_id` (32-char hex) for the request.
2. `proxy_common.conf` does `proxy_set_header X-Request-Id $request_id`,
   which OVERWRITES any client-supplied X-Request-Id before it reaches
   Kong. → Clients cannot inject log-poisoning ids.
3. Kong's `correlation-id` plugin sees the header is already set and
   REUSES it (only generates when the header is missing).
4. The same id is forwarded to the upstream service and echoed back to
   the client (`echo_downstream: true`).

So nginx, Kong, file-log JSON, BFF logs, sample-service logs, and the
client all share one id per request.

## Adding more services

> **Full guide:** [`docs/adding-a-service.md`](../docs/adding-a-service.md)
> walks through both authenticated and public service paths with validation,
> smoke tests, and the common-mistakes table. The quick reference below is
> the minimum yaml — read the guide for the rationale, the public-service
> variant, and the per-route role check pattern.

Append to `kong.yml`:

```yaml
- name: my-service
  url: http://my-service:3002
  routes:
    - paths: [/api/my]
      strip_path: true
  plugins:
    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []
    # Don't forget:
    #  - the iss/aud + identity-injection pre-function — copy it verbatim
    #    from sample-service or factor into a shared snippet
    #  - a per-service rate-limiting plugin keyed by X-User-Id
```

The same consumer handles auth for every service — no per-service consumer
needed since they all trust the BFF as the issuer. If you ever want
per-service authorization (e.g., this service only accepts tokens with a
specific role), use Kong's [pre-function plugin](https://docs.konghq.com/hub/kong-inc/pre-function/)
to inspect `kong.request.get_header("authorization")`'s decoded claims, or
have the upstream service decode the JWT and check `roles` itself.

## Key sourcing (where the public key comes from)

The committed `kong.yml` inlines the dev RSA public PEM directly under
`consumers[].jwt_secrets[].rsa_public_key`:

```yaml
- key: dev-v1
  algorithm: RS256
  rsa_public_key: |
    -----BEGIN PUBLIC KEY-----
    ...dev public key...
    -----END PUBLIC KEY-----
```

The dev PEM is not secret — its matching private key is committed under
`bff/keys/` for local development.

### Why not `{vault://env/...}`?

An earlier iteration sourced the PEM from an env var via the env vault
(`rsa_public_key: "{vault://env/internal-jwt-pubkey-dev-v1}"`) so the
file would be deploy-agnostic. **It does not work** in Kong 3.x DB-less
mode: the `consumers.jwt_secrets` entity is validated at config-parse
time, before vault references are resolved, so the literal placeholder
string reaches the RS256 conditional validator and fails as
`rsa_public_key: invalid key`. `init_by_lua` aborts, the container
restart-loops, the `kong health` healthcheck never passes, and Compose
reports `dependency failed to start: container super-app-kong is
unhealthy` for nginx. Inlining sidesteps the parse-time vs lazy-resolve
ordering problem entirely. Vault references still work for *plugin*
config fields — they're resolved on first plugin invocation, not at
parse time.

### Promoting to non-dev environments (AUDIT S-5)

A real deployment must do all of the following — Kong will not accept a
token whose kid doesn't match a `jwt_secrets` entry:

1. **Mint a fresh keypair** in the target environment's secret manager
   (not on a developer laptop). Choose a non-dev kid, e.g. `prod-v1`.
2. **Render a prod `kong.yml` for the deploy artifact** with the prod
   PEM inlined:
   ```yaml
   - key: prod-v1
     algorithm: RS256
     rsa_public_key: |
       -----BEGIN PUBLIC KEY-----
       ...prod public key from your secret manager...
       -----END PUBLIC KEY-----
   ```
   The `dev-v1` entry must not appear in a prod kong.yml. The PEM itself
   isn't secret (only the private half is) but treating the prod kong.yml
   as a build artifact rather than a committed file keeps prod kids out
   of git history.
3. **Update BFF env**: `BFF_INTERNAL_JWT_ACTIVE_KID=prod-v1`,
   `BFF_INTERNAL_JWT_PRIVATE_KEY=...prod private...`, and add prod-v1
   to `BFF_INTERNAL_JWT_PUBLIC_KEYS`.

The kid prefix is a tripwire: if you ever see `kid=dev-*` in a prod log,
something is misconfigured and Kong should already have rejected the
token. We rely on the prefix because dev and prod kong.yml differ only
in the inlined PEM and the kid name — the rest of the file is identical.

## Key rotation (zero-downtime)

The BFF and Kong each support multiple keys at once. To rotate
`dev-v1` → `dev-v2` (or `prod-v1` → `prod-v2`):

1. **Generate v2 in BFF**: `cd bff && npm run gen:keys dev-v2`. Save the
   printed public PEM — you'll paste it into `kong/kong.yml` next.
2. **Add v2 to Kong**, leaving v1 in place. Append a second entry under
   `consumers[].jwt_secrets` with the new PEM inlined:
   ```yaml
   consumers:
     - username: super-app-bff
       jwt_secrets:
         - key: dev-v1
           algorithm: RS256
           rsa_public_key: |
             -----BEGIN PUBLIC KEY-----
             ...v1 public key...
             -----END PUBLIC KEY-----
         - key: dev-v2                                      # new
           algorithm: RS256
           rsa_public_key: |
             -----BEGIN PUBLIC KEY-----
             ...v2 public key...
             -----END PUBLIC KEY-----
   ```
   Deploy Kong (`docker compose up -d --force-recreate kong`). Both kids
   verify.
3. **Cut BFF over to v2**: in BFF env, set `BFF_INTERNAL_JWT_ACTIVE_KID=dev-v2`,
   append v2 to `BFF_INTERNAL_JWT_PUBLIC_KEYS`, swap
   `BFF_INTERNAL_JWT_PRIVATE_KEY` to v2's private. Deploy. New tokens carry
   `kid=dev-v2`; v1 tokens keep verifying until they age out.
4. **Wait** `BFF_INTERNAL_JWT_TTL_SECONDS + 1m` (default: 6 minutes). All
   v1-signed tokens have now expired.
5. **Drop v1**: remove from BFF env's `BFF_INTERNAL_JWT_PUBLIC_KEYS` and
   delete the v1 entry from `kong.yml`'s `jwt_secrets`. Redeploy.

Skipping step 2 (Kong not yet aware of v2) → v2 tokens 401 at the gateway.
Skipping step 4 → in-flight v1 tokens 401 prematurely. Fail forward, not
back: if step 3 went wrong, redeploy v1 as the active kid; v1 is still
listed at Kong from step 2.

## Testing

You need a JWT minted by the BFF (real or fake). Two ways:

```bash
# 1. Through the real BFF auth flow:
#    Log in via mobile (USE_MOCK_AUTH=false) → copy the access_token from
#    the Home screen.
TOKEN="<paste>"
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/profile

# 2. Quick mint-a-test-token script (Node REPL — uses the dev private key):
node --input-type=module -e "
import { SignJWT, importPKCS8 } from 'jose';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
const pem = readFileSync('bff/keys/internal-jwt-v1.private.pem', 'utf8');
const key = await importPKCS8(pem, 'RS256');
const t = await new SignJWT({ sid: 'sid-test', roles: ['citizen'], kid: 'v1' })
  .setProtectedHeader({ alg: 'RS256', typ: 'JWT', kid: 'v1' })
  .setIssuer('super-app-bff').setAudience('super-app-services').setSubject('user-test')
  .setIssuedAt().setExpirationTime('5m').setJti(randomUUID()).sign(key);
console.log(t);
"
```

Negative case (always returns 401):

```bash
curl -i http://localhost:8080/api/profile                                  # no bearer
curl -i -H "Authorization: Bearer not.a.jwt" http://localhost:8080/api/profile
```

## Troubleshooting

- **All requests 401 even with a bearer that looks fine**: confirm the
  token's `kid` (header *and* payload) matches a `key:` field under the
  consumer's `jwt_secrets` in `kong.yml`, and that the RSA public key in
  Kong corresponds to the private key currently in `BFF_INTERNAL_JWT_PRIVATE_KEY`.
- **`401: No credentials found for given 'kid'`**: Kong saw the token's
  `kid` claim but doesn't have a matching credential. Either Kong is on
  an older `kong.yml`, or the BFF is signing with a kid that hasn't been
  added to Kong yet (rotation step 2 was skipped).
- **`401: Invalid signature`**: kid matched, but Kong's public key doesn't
  pair with the BFF's private key. Most likely the dev keypair was
  regenerated on the BFF side without updating `kong.yml`.
- **Updated `kong.yml` doesn't take effect**: `docker compose restart kong`
  (DB-less reloads at process start).
