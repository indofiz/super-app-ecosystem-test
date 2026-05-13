# Adding a New Service Behind Kong

A step-by-step guide for backend developers. Walks you from "I want to add
a new microservice" to "it's deployed and reachable at
`/api/<your-prefix>`", for both **authenticated** services (the common
case) and **public** services (rare; no bearer required).

If you only need a quick reference, jump to the **[Checklist](#checklist)**
at the bottom. Otherwise, read top-to-bottom.

> **Big picture.** Mobile and any other client hit nginx at `/api/*`.
> nginx forwards everything under `/api/` to Kong. Kong matches routes by
> path, runs the access-phase plugins for that route, and forwards to the
> upstream container. Your service never opens a host port — Kong is the
> only thing that talks to it.
>
> See [`diagrams/architecture-overview.svg`](diagrams/architecture-overview.svg)
> for the full picture and
> [`diagrams/flow-data-plane-request.svg`](diagrams/flow-data-plane-request.svg)
> for what happens to a single request.

---

## 1. Decide first: does this service need auth?

| If… | Then you want… | Worked example |
|---|---|---|
| The endpoint reads or writes user-specific data | **Authenticated service** (Path A) | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| The endpoint requires a Keycloak role | **Authenticated service** + per-route role check (Path A + §6) | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| The endpoint is admin-only | **Authenticated service** + role check | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| The endpoint accepts file uploads larger than the 256 KB default | **Authenticated service** + per-service `request-size-limiting` | [§9.2 `e-perizinan-service`](#92-e-perizinan-service-path-a--pdf-uploads) |
| The endpoint is a public catalogue, status page, or open data | **Public service** (Path B) | [§9.3 `status-service`](#93-status-service-path-b--proxy-cache) |
| The endpoint accepts callbacks from a third party (webhook) that has its **own** signature/secret you'll verify in the service | **Public service** (Path B) | [§9.4 `wa-webhook-service`](#94-wa-webhook-service-path-b--hmac) |
| The service itself runs on **another VPS**, a private LAN host, or shared hosting (WHM/cPanel — typically PHP) | **Off-VPS upstream** (Path C) — combine with Path A or Path B for the auth chain | [§9.5](#95-legacy-citizen-db-path-c1a-private-lan) / [§9.6](#96-e-sampah-service-path-c1b--public-https) / [§9.7](#97-citizen-api-path-c1c-cpanelwhm-php) |

**Default to Path A.** This stack is designed so the gateway enforces auth
and downstream services are dumb. Choosing Path B means giving up Kong's
per-user rate limit and identity injection — only do it when there's no
user to identify in the first place. Path C is orthogonal — it's *where*
the upstream lives, not *whether* it requires auth; you still pick A or B
for the plugin chain.

A single service can host both kinds of routes; just split the path
prefixes (e.g. `/api/ktp` authenticated, `/api/ktp/public` not).

---

## 2. Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Service directory | `services/<name>-service/` | `services/ktp-service/` |
| Container name | `super-app-<name>-service` | `super-app-ktp-service` |
| Internal port | Pick a free 3xxx port; document it | `3002` |
| Path prefix (Kong) | `/api/<name>` (auth) or `/api/public/<name>` (public) | `/api/ktp` |
| Kong service name | `<name>-service` (same as directory) | `ktp-service` |

The `/api/public/` convention for unauthenticated routes is **load-bearing**
for code review — `grep -r '/api/public' kong/kong.yml` is how a reviewer
confirms which routes intentionally bypass auth.

---

## 3. Path A — Authenticated service (the common case)

We'll add `ktp-service` (id-card lookups) on port `3002`, reachable at
`/api/ktp`.

### 3.1 Bootstrap the service code

Copy the `sample-service` skeleton. It already has the right shape (no
auth code, reads identity from trusted headers, returns the request id):

```bash
cp -r services/sample-service services/ktp-service
cd services/ktp-service
```

Then:

- Rename the package: edit `package.json` — set `"name": "ktp-service"`.
- Change the listening port — edit `src/index.ts`:
  ```ts
  const PORT = Number(process.env['PORT'] ?? 3002);
  ```
- Update the `EXPOSE` line in `Dockerfile` to match (`EXPOSE 3002`).
- Write your real handlers (DB lookups, business logic). **Do not add an
  auth library.** Kong is the auth boundary.

### 3.2 Read identity from trusted headers — never the JWT

Kong's `pre-function` plugin verifies the JWT, then re-sets these headers
from the **verified** claims and strips the `Authorization` header before
forwarding. The reference pattern (already in `sample-service/src/index.ts`):

```ts
import express, { type Request } from 'express';

const identityFromHeaders = (req: Request) => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',')
               .map((r) => r.trim())
               .filter(Boolean),
});

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'ktp-service' });
});

app.get('/lookup/:nik', (req, res) => {
  const { userId, roles } = identityFromHeaders(req);
  if (!userId) {
    // Shouldn't happen — Kong only forwards if jwt + pre-function passed.
    // 401 is for "Kong was bypassed somehow"; treat as a programming error.
    return res.status(401).json({ error: 'unauthenticated' });
  }
  // …do the actual lookup…
  res.json({ nik: req.params.nik, requestedBy: userId, roles });
});

app.listen(Number(process.env['PORT'] ?? 3002));
```

**Things to never do:**

- Don't read `req.headers.authorization`. Kong strips it before forwarding
  ([diagram: kong-identity-injection.svg](diagrams/kong-identity-injection.svg)).
- Don't decode the JWT yourself. The plugin already did.
- Don't trust `X-User-Id` if you bypass Kong (e.g., a sidecar that hits
  the service directly). The service must only be reachable via Kong.

### 3.3 Register the service in Kong

Edit `kong/kong.yml`. Under the top-level `services:` array, append a
new block. The plugin chain is the **same** as `sample-service` — that's
the whole point. Don't omit any plugin.

```yaml
services:
  # ─── existing sample-service block stays as-is ───
  - name: sample-service
    # ...

  # ─── new service ───
  - name: ktp-service
    url: http://ktp-service:3002         # docker DNS = container_name

    routes:
      - name: ktp-lookup
        paths:
          - /api/ktp
        strip_path: true
        # GET /api/ktp/lookup/123  →  upstream sees GET /lookup/123

    plugins:
      # Mint and reuse the per-request id. Same as sample-service.
      - name: correlation-id
        config:
          header_name: X-Request-Id
          generator: uuid
          echo_downstream: true

      # Verify the BFF-minted RS256 internal JWT. NEVER omit this on an
      # authenticated service. The maximum_expiration ceiling caps TTL
      # at 10 minutes regardless of what the BFF signed (AUDIT S-4).
      - name: jwt
        config:
          key_claim_name: kid
          claims_to_verify: [exp, nbf]
          maximum_expiration: 600
          header_names: [authorization]       # carrier locked (AUDIT S-2)
          cookie_names: []
          uri_param_names: []

      # iss/aud enforcement + identity injection + Authorization strip.
      # COPY VERBATIM from the sample-service block. The Lua body must
      # match kong/lua/identity_inject.lua — the check-lua-sync script
      # enforces this for the sample-service copy; if you change it for
      # ktp-service, you've forked the contract.
      - name: pre-function
        config:
          access:
            - |
              -- same Lua as sample-service — paste from kong.yml
              -- (or factor out — see §5 if you need per-route auth)

      # Per-user rate limit. Keyed by the X-User-Id Kong just injected.
      # 600/min is the project default; tune per service if needed.
      - name: rate-limiting
        config:
          minute: 600
          policy: local
          fault_tolerant: true
          limit_by: header
          header_name: X-User-Id
```

**Important:** you do **not** add a new consumer. The single
`super-app-bff` consumer already declared in `kong.yml` represents the
issuer (the BFF), not the user. Kong looks up the consumer's
`jwt_secrets` by `kid` claim — that's the same lookup for every service.

### 3.4 Wire the container

Edit the workspace-level `docker-compose.yml`:

```yaml
services:
  # ─── existing services stay as-is ───

  ktp-service:
    build: ./services/ktp-service
    container_name: super-app-ktp-service
    environment:
      NODE_ENV: production
      PORT: 3002
    # No host port mapping — only Kong talks to it.
    # Optional: add a healthcheck if you want kong's depends_on to gate
    # on `service_healthy` instead of `service_started`.
    # healthcheck:
    #   test: ["CMD", "wget", "-qO-", "http://localhost:3002/health"]
    #   interval: 10s
    #   timeout: 3s
    #   retries: 5
```

Then make Kong wait for it on startup. Edit the `kong:` block's
`depends_on` to include the new service:

```yaml
kong:
  # ...existing config...
  depends_on:
    sample-service:
      condition: service_started
    ktp-service:                 # ← add this
      condition: service_started
```

See [`diagrams/compose-startup-order.svg`](diagrams/compose-startup-order.svg)
for the full dependency DAG.

### 3.5 Validate before booting

Three scripts catch the common edit mistakes:

```bash
# Lint kong.yml against the real Kong 3.8 schema (needs Docker):
node kong/scripts/validate.mjs

# Confirm the Lua mirror is intact (the pre-function body in kong.yml
# must match kong/lua/identity_inject.lua exactly):
node kong/scripts/check-lua-sync.mjs

# Confirm BFF + Kong + docker-compose agree on the active kid set:
node kong/scripts/audit-kid-config.mjs
```

All three should print OK. If any fails, fix before continuing.

### 3.6 Build and smoke-test

```bash
docker compose up -d --build ktp-service kong
# Kong reloads its declarative config at container start, so kong needs
# to be rebuilt/restarted too. --build for the new service.

# Without bearer → 401 from Kong (jwt plugin, no credentials).
curl -i http://localhost:8080/api/ktp/lookup/123

# Mint a test token from the dev keypair and call through.
TOKEN=$(node --input-type=module -e "
import { SignJWT, importPKCS8 } from 'jose';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
const pem = readFileSync('bff/keys/internal-jwt-dev-v1.private.pem', 'utf8');
const key = await importPKCS8(pem, 'RS256');
const t = await new SignJWT({ sid: 'sid-test', roles: ['citizen'], kid: 'dev-v1' })
  .setProtectedHeader({ alg: 'RS256', typ: 'JWT', kid: 'dev-v1' })
  .setIssuer('super-app-bff').setAudience('super-app-services').setSubject('user-test')
  .setIssuedAt().setNotBefore('0s').setExpirationTime('5m').setJti(randomUUID()).sign(key);
console.log(t);
")

curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/ktp/lookup/123 | jq .
# Expected: 200 with { nik, requestedBy: "user-test", roles: ["citizen"] }
```

Confirm in the response that:

- `requestedBy` matches the token's `sub` (proof that Kong injected
  `X-User-Id` from the verified claim, not from a caller-supplied header).
- `roles` matches what's in the JWT (proof of `X-Roles` injection).
- The `Authorization` header is NOT echoed back. Add a debug log in your
  service to verify it sees `req.headers.authorization === undefined`.

### 3.7 Wire mobile (optional)

If the mobile app should call the new endpoint, the path goes through
the existing `ApiClient` (Dio) instance — no auth code needed in the
feature module:

```dart
// mobile/lib/features/ktp/data/ktp_api.dart
class KtpApi {
  KtpApi({required this.dio});
  final Dio dio;

  Future<Map<String, dynamic>> lookup(String nik) async {
    final res = await dio.get<Map<String, dynamic>>('/api/ktp/lookup/$nik');
    return res.data!;
  }
}
```

The `_AuthInterceptor` attaches the bearer; the `_RefreshInterceptor`
handles a 401 transparently. See
[`diagrams/mobile-architecture.svg`](diagrams/mobile-architecture.svg).

---

## 4. Path B — Public (no-auth) service

Use this only when the endpoint is **inherently** anonymous: a city
service status page, a public outage feed, a third-party webhook
receiver. **There is no per-user identity, so there is no per-user rate
limit either — protect with IP rate-limiting and accept the limitation.**

We'll add `status-service` on port `3003`, reachable at
`/api/public/status`.

### 4.1 Bootstrap the service

Same as 3.1 — copy `sample-service` as a starting point. Strip out the
identity-from-headers helper if you don't need it. Public services should
not assume any `X-*` header is present.

### 4.2 Register the service in Kong — explicit no-auth

```yaml
services:
  - name: status-service
    url: http://status-service:3003

    routes:
      - name: status-public
        paths:
          - /api/public/status        # ← /api/public/ prefix is the convention
        strip_path: true

    plugins:
      # Still mint / propagate the request id — public services log too.
      - name: correlation-id
        config:
          header_name: X-Request-Id
          generator: uuid
          echo_downstream: true

      # NO `jwt` plugin.
      # NO `pre-function` plugin (nothing to inject).

      # IP-based rate limit — there's no X-User-Id to key by.
      # Pick a number that fits the public endpoint's profile; this is
      # what protects you from someone bursting the public path.
      - name: rate-limiting
        config:
          minute: 120                # tune per endpoint
          policy: local
          fault_tolerant: true
          limit_by: ip
```

**Things you should think about for a public service:**

| Concern | Mitigation |
|---|---|
| Cache poisoning via headers | Service should reject inputs from `X-User-Id` (treat as untrusted; ignore). |
| Hot-path performance | Public endpoints get scraped by bots; use HTTP caching headers and tune `minute:` aggressively. |
| Data exposure | The whole internet can read this. Audit what you return. |
| Webhook authenticity | If accepting third-party webhooks, verify the third party's signature **inside your service** (e.g., HMAC of the request body against a shared secret). Kong won't help here. |
| Abuse logging | Confirm `X-Request-Id` shows up in your service logs even without a user id. |

### 4.3 Container + smoke test

Container wiring is identical to §3.4 — just different port and name.

Smoke test:

```bash
docker compose up -d --build status-service kong

curl -s http://localhost:8080/api/public/status | jq .
# Expected: 200 with whatever your public payload is. No bearer required.

# Confirm rate limit kicks in (IP-based):
for i in {1..200}; do curl -so /dev/null -w "%{http_code} " http://localhost:8080/api/public/status; done
# At some point you should see 429 Too Many Requests.
```

---

## 5. Path C — Remote / off-VPS upstream

The auth contract is unchanged from Path A. What changes is networking,
TLS, the Host header, and how you stop someone from hitting the backend
directly without going through Kong.

Three sub-cases — pick the one that matches your upstream:

| Sub-case | Upstream URL example | Typical situation | Worked example |
|---|---|---|---|
| **C.1a Private LAN** | `http://10.0.5.20:3001` | Another VPS in the same provider VLAN | [§9.5 `legacy-citizen-db`](#95-legacy-citizen-db-path-c1a-private-lan) |
| **C.1b Public HTTPS** | `https://sampah.pangkalpinangkota.go.id` | Another VPS with its own Let's Encrypt cert | [§9.6 `e-sampah-service`](#96-e-sampah-service-path-c1b--public-https) |
| **C.1c WHM / cPanel PHP** | `https://services.pangkalpinangkota.go.id/citizen-api` | Shared hosting, Apache + PHP, AutoSSL | [§9.7 `citizen-api`](#97-citizen-api-path-c1c-cpanelwhm-php) |

We'll use the C.1c example (`citizen-api`, a PHP service on cPanel) since
it touches every concern. C.1a and C.1b are strict subsets — pull out the
TLS bits or the virtual-host bits as needed.

> **Path C requires you to combine with Path A or B.** Most of the time
> you want the Path A plugin chain (jwt + pre-function + per-user
> rate-limit). The only difference is the `url:`, a few TLS / timeout
> knobs, and the **direct-access lockdown** in §5.3.

### 5.1 Register the service in Kong

```yaml
services:
  - name: citizen-api
    url: https://services.pangkalpinangkota.go.id/citizen-api  # C.1c

    # HTTPS to the upstream — verify cert against system CAs.
    # Default is true; spelled out for clarity. Set false only for
    # internal CAs you can't import, and never in production.
    tls_verify: true

    # Tighten timeouts. Across the open Internet, Kong's default 60s is
    # too generous — budget closer to the user-felt p99.
    connect_timeout: 5000
    write_timeout: 10000
    read_timeout: 15000

    routes:
      - name: citizen
        paths: [/api/citizen]
        strip_path: true
        # CRITICAL for virtual-hosted backends (cPanel, nginx vhosts):
        # preserve_host: false sends `Host: services.pangkalpinangkota.go.id`
        # — the upstream URL's host — so cPanel picks the right site.
        # Setting it true would send your edge host (api.pangkalpinangkota.go.id)
        # and cPanel would route to the default vhost (or 404).
        preserve_host: false

    plugins:
      # Same chain as Path A — copy verbatim from sample-service. Pasted
      # in compact form here; expand from §3.3 for the inline comments.
      - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }
      - name: jwt
        config:
          key_claim_name: kid
          claims_to_verify: [exp, nbf]
          maximum_expiration: 600
          header_names: [authorization]
          cookie_names: []
          uri_param_names: []
      - name: pre-function
        config:
          access:
            - |
              -- IDENTICAL Lua to sample-service. Do not fork.
              -- (paste the full body from kong/kong.yml here)

      # NEW for Path C — inject a shared secret the backend verifies.
      # See §5.3 for the why and the matching backend code.
      - name: request-transformer
        config:
          add:
            headers:
              - "X-Gateway-Secret:{vault://env/citizen-api-gateway-secret}"

      - name: rate-limiting
        config:
          minute: 600
          policy: local
          fault_tolerant: true
          limit_by: header
          header_name: X-User-Id

    # Passive health checks — Kong pulls the upstream out of rotation
    # after repeated failures instead of waiting the full read_timeout
    # on every request. Active checks need the Admin API (off in this
    # stack); passive is enough.
    healthchecks:
      passive:
        healthy:
          successes: 5
        unhealthy:
          tcp_failures: 2
          http_failures: 5
          timeouts: 3
```

For **C.1a (private LAN)**: same block, but `url: http://10.0.5.20:3001`
and drop the `tls_verify` line. The shared-secret lockdown (§5.3) is
still recommended.

For **C.1b (public HTTPS, no virtual-host concern)**: same block as C.1c.
The `preserve_host: false` is still correct.

Then set the secret in `docker-compose.yml` under the `kong:` service env:

```yaml
kong:
  environment:
    # ...existing env vars...
    CITIZEN_API_GATEWAY_SECRET: ${CITIZEN_API_GATEWAY_SECRET}
```

…and the actual value in your workspace `.env` (never committed):

```bash
# .env
CITIZEN_API_GATEWAY_SECRET=<long random; rotate quarterly>
```

The `{vault://env/citizen-api-gateway-secret}` reference in `kong.yml`
resolves the env var at Kong startup, so the secret never lives in the
committed file.

### 5.2 Reading identity in the backend (PHP example)

Same model as Path A — read `X-User-Id` / `X-Roles` / `X-Session-Id`,
never `Authorization` (Kong strips it). The PHP equivalent of
`services/sample-service/src/index.ts`:

```php
<?php
// citizen-api/lookup.php
declare(strict_types=1);
require __DIR__ . '/_gateway_guard.php';   // §5.3 — verifies X-Gateway-Secret

$userId    = $_SERVER['HTTP_X_USER_ID']    ?? null;
$sessionId = $_SERVER['HTTP_X_SESSION_ID'] ?? null;
$rolesCsv  = $_SERVER['HTTP_X_ROLES']      ?? '';
$roles     = array_values(array_filter(array_map('trim', explode(',', $rolesCsv))));
$requestId = $_SERVER['HTTP_X_REQUEST_ID'] ?? null;

if ($userId === null) {
    http_response_code(401);
    echo json_encode(['error' => 'no identity from gateway']);
    exit;
}

// Log with X-Request-Id so log lines correlate with nginx / Kong / BFF.
error_log(sprintf('[%s] citizen-api lookup user=%s roles=%s',
    $requestId ?? '-', $userId, implode(',', $roles)));

// ...your business logic...
header('Content-Type: application/json');
echo json_encode(['user' => $userId, 'roles' => $roles]);
```

**Things to NOT do on the PHP side** (the same prohibitions as Path A,
worth restating because PHP shared hosting tends to encourage them):

- Don't read `$_SERVER['HTTP_AUTHORIZATION']`. Kong strips it.
- Don't decode any JWT — Kong already verified it.
- Don't start a PHP session keyed on `X-User-Id`. There's no browser
  session in this flow; mobile is a token-bearer client.
- Don't store `X-User-Id` anywhere persistent without also storing the
  `X-Request-Id` for audit correlation.

### 5.3 Lock down direct access to the backend

A leaked or guessed backend URL is now an auth-bypass vector — the
backend trusts `X-User-Id`, and anyone who reaches it directly can
synthesize that header. Pick one defence (or both):

**Pattern 1 — IP allowlist (cheapest, breaks if Kong's IP moves).**

In cPanel: WHM → Security Center → Host Access Control → service `httpd`,
allow only the Kong VPS's egress IP, deny all.

Or per-site via `.htaccess`:

```apache
# /home/<user>/public_html/citizen-api/.htaccess
<RequireAll>
  Require ip <KONG_VPS_PUBLIC_IP>
</RequireAll>
```

**Pattern 2 — Shared secret header (survives IP changes).** Kong injects
`X-Gateway-Secret: <value>` (configured in §5.1); the backend verifies it
on every request:

```php
<?php
// citizen-api/_gateway_guard.php
declare(strict_types=1);

$expected  = getenv('GATEWAY_SECRET') ?: '';
$presented = $_SERVER['HTTP_X_GATEWAY_SECRET'] ?? '';

if ($expected === '' || $presented === '' || !hash_equals($expected, $presented)) {
    http_response_code(401);
    exit('not via gateway');
}
```

Set `GATEWAY_SECRET` on the cPanel environment (the right place varies
by host — `.htaccess` `SetEnv`, a per-account env file, or the
hosting-panel UI). Match the value Kong injects.

`hash_equals` (not `==`) is required — string comparison would leak the
secret via timing.

**Recommended:** both. Pattern 1 is the static defence; Pattern 2 catches
the moment Pattern 1 breaks (IP change, routing leak, new egress NAT).
Rotate the secret quarterly — overlap two valid values during the deploy
window the same way you'd overlap two kids during a JWT rotation.

### 5.4 Validate + smoke test

```bash
node kong/scripts/validate.mjs           # schema-checks the new yaml
docker compose up -d --force-recreate kong

# 1. Without bearer → Kong 401.
curl -i http://localhost:8080/api/citizen/lookup.php

# 2. With bearer → routed to backend, identity from claims.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/citizen/lookup.php | jq .
# Expected: 200 with { user: "<sub from token>", roles: [...] }

# 3. CRITICAL — try to reach the backend DIRECTLY:
curl -i -H "X-User-Id: admin" -H "X-Roles: admin" \
  https://services.pangkalpinangkota.go.id/citizen-api/lookup.php
# Expected: 401 (gateway secret missing) or 403 (IP not allowed).
# A 200 here means §5.3 is incomplete — anyone can impersonate any user.
```

The §5.4 step 3 test is the one that proves the off-VPS lockdown works.
If you can hit the backend directly with a spoofed `X-User-Id`, the
entire authentication model is bypassed regardless of how perfectly Kong
is configured. Do not skip it.

### 5.5 Common mistakes — Path C specific

| Symptom | Likely cause | Fix |
|---|---|---|
| `502 Bad Gateway` immediately on every request | Kong container can't resolve the upstream DNS | `docker compose exec kong getent hosts services.pangkalpinangkota.go.id`. If empty, check `/etc/resolv.conf` inside the container; on Docker Desktop the default resolver is usually fine, on VPS Docker you may need `dns:` in the compose service block. |
| `502 Bad Gateway` after a delay | TLS verification failed — upstream cert chain is incomplete or issuer not trusted | `openssl s_client -connect <host>:443 -showcerts`. The cert chain must include intermediates. Re-issue with `fullchain.pem`. As a last resort `tls_verify: false` (NOT in prod). |
| WHM/cPanel returns the wrong site's HTML, or a default landing page | `preserve_host: true` sent the edge host; cPanel routed to the wrong vhost | Set `preserve_host: false` (pin it explicitly). |
| `Authorization: Bearer …` reaches the PHP script | `pre-function` plugin is missing, or attached to the route instead of the service, or its priority got overridden | Confirm the plugin is on the service block, default priority. Run `check-lua-sync.mjs`. |
| Backend accepts a curl with chosen `X-User-Id` | §5.3 lockdown not implemented (or not enforced on this path/route) | Pattern 1 + Pattern 2 from §5.3. Both. |
| Latency spikes only on Path C routes | You're paying the inter-VPS RTT every request — Mobile sees 401-then-refresh-then-retry = 3× that RTT | If unavoidable, raise `BFF_INTERNAL_JWT_TTL_SECONDS` (within the 600s cap Kong enforces) so refresh fires less often. Or move latency-sensitive routes back into the local Docker stack. |
| Secret rotation requires a `kong.yml` edit | You inlined the literal secret instead of using env-vault | Switch to `{vault://env/citizen-api-gateway-secret}` and set the env var in `docker-compose.yml`. |
| Healthcheck doesn't pull the upstream out of rotation when the backend goes down | DB-less Kong doesn't run active healthchecks; passive only counts real traffic | Confirm `passive` block is present; on a near-idle service it'll take `tcp_failures: 2` real attempts before Kong reacts. |
| `request-transformer` plugin doesn't add the header | Plugin scoped wrong, or `vault://` env var unset at Kong startup | Confirm `CITIZEN_API_GATEWAY_SECRET` is in `docker-compose.yml`'s `kong.environment:` and the workspace `.env` has a value. Restart Kong. |

---

## 6. Per-route authorization (role checks)

Both paths get identity injection for free, but **role enforcement** is
your call. Two options:

### Option 1 — check in the service (simplest)

The `X-Roles` header is a comma-separated CSV of the user's roles:

```ts
app.delete('/lookup/:nik', (req, res) => {
  const { roles } = identityFromHeaders(req);
  if (!roles.includes('admin')) {
    return res.status(403).json({ error: 'forbidden' });
  }
  // ...
});
```

Easy. The drawback is that the policy lives in service code, so changing
"which role can delete" requires redeploying the service.

### Option 2 — check in Kong (centralised)

Add an extra `pre-function` block (or extend the existing one) on the
specific route that requires a role:

```yaml
- name: ktp-service
  url: http://ktp-service:3002
  routes:
    - name: ktp-admin-only
      paths: [/api/ktp/admin]
      strip_path: true
      plugins:
        # extra plugin scoped to this route only
        - name: pre-function
          config:
            _priority: 999            # explicit: below jwt(1450), above limit(910)
            access:
              - |
                local roles = kong.request.get_header("X-Roles") or ""
                if not string.find("," .. roles .. ",", ",admin,", 1, true) then
                  return kong.response.exit(403, { message = "forbidden" })
                end
  plugins:
    # ...all the service-level plugins from §3.3 still apply globally...
```

Route-scoped plugins run **after** service-scoped plugins. By the time
this Lua runs, the service-level `pre-function` has already verified
`iss`/`aud` and injected `X-Roles` from the JWT — so reading the header
here is safe.

---

## 7. Validation cheatsheet

| Command | What it catches |
|---|---|
| `node kong/scripts/validate.mjs` | YAML / schema errors in `kong.yml` (uses Docker to run `kong config parse`) |
| `node kong/scripts/check-lua-sync.mjs` | Drift between `kong/lua/identity_inject.lua` and the inline `pre-function` body in `kong.yml` |
| `node kong/scripts/audit-kid-config.mjs` | A kid declared in one file but missing in another (BFF env / workspace `.env` / `kong.yml` / `docker-compose.yml`) |

Run all three before every deploy. They have zero external dependencies
beyond Node and (for `validate.mjs`) Docker.

---

## 8. Common mistakes

| Symptom | Likely cause | Fix |
|---|---|---|
| Every request returns 401 even with a known-good bearer | The service block has no `jwt` plugin, or the `key_claim_name` was forgotten so Kong looks up by `iss` and finds nothing | Re-check §3.3 — copy the **whole** plugin chain. |
| 401 with `"No credentials found for given 'kid'"` | The token's `kid` isn't in `consumers[0].jwt_secrets` — either Kong is on stale config or you're testing with a token signed by a kid that was already rotated out | `docker compose restart kong`; run `audit-kid-config.mjs`. |
| 401 with `"invalid issuer"` or `"invalid audience"` | Your test token has different `iss`/`aud` than the Lua's hardcoded `super-app-bff` / `super-app-services` | Match the values in `bff/src/lib/internalJwt.ts`. |
| Service receives `Authorization` header anyway | You pasted the `pre-function` plugin but with a different priority, so it ran **before** `jwt` | Don't override `_priority` on the service-level pre-function. |
| Service receives `X-User-Id: admin` from a malicious client | You forgot the `pre-function` plugin — the strip-then-set step never ran | Add the plugin (§3.3). |
| Plugin block is parsed but doesn't run | YAML indentation off by two spaces under `config:` | `node kong/scripts/validate.mjs` catches this. |
| Mobile app gets a 502 immediately after deploy | Kong restarted but the new upstream container isn't ready | Add a `healthcheck` to the service and `condition: service_healthy` to Kong's `depends_on`. |
| Tests that worked yesterday 401 today | The dev keypair was regenerated without redeploying Kong | The PEM that Kong has and the private key the BFF holds must be a pair; regenerate together. |

---

## Checklist

Use this as a single-page summary when adding a service.

### For an authenticated service (Path A)

- [ ] Copy `services/sample-service/` to `services/<name>-service/`.
- [ ] Set the listening port and update `Dockerfile` `EXPOSE`.
- [ ] In service code: read identity from `X-User-Id` / `X-Roles` / `X-Session-Id` only. Never read `Authorization`. Never decode the JWT.
- [ ] Add a `services:` entry in `kong/kong.yml` with the full plugin chain: `correlation-id`, `jwt`, `pre-function`, `rate-limiting`. Keep the `pre-function` body identical to `sample-service`.
- [ ] Set `strip_path: true` so the upstream sees a path it owns.
- [ ] Add the service to `docker-compose.yml` with no host port mapping.
- [ ] Add the service to Kong's `depends_on:`.
- [ ] Run `validate.mjs`, `check-lua-sync.mjs`, `audit-kid-config.mjs` — all OK.
- [ ] `docker compose up -d --build`. Smoke-test with and without a bearer.
- [ ] Confirm in the response that `X-Authorization` is gone and `X-User-Id` matches the token's `sub`.

### For a public service (Path B)

- [ ] Use the `/api/public/` path prefix so reviewers can see at a glance that auth is intentionally skipped.
- [ ] Service block has **no** `jwt` plugin and **no** `pre-function` plugin.
- [ ] Service block has `rate-limiting` with `limit_by: ip` and a sensible `minute:` ceiling.
- [ ] Service code does not trust any `X-*` header (no user identity exists).
- [ ] Any third-party authenticity (webhook signing) is verified **inside** the service.
- [ ] Smoke-test that the endpoint works without a bearer, and that `429` kicks in under burst.

### For an off-VPS upstream (Path C — combines with A or B above)

- [ ] Pick the right sub-case: C.1a private LAN / C.1b public HTTPS / C.1c WHM-cPanel.
- [ ] Set the right `url:` — full URL including scheme, host, and path prefix on the upstream side.
- [ ] For HTTPS upstreams: `tls_verify: true` (the default — pin it). Confirm the cert chain is complete with `openssl s_client`.
- [ ] For virtual-hosted backends (cPanel, nginx vhosts): `preserve_host: false` (the default — pin it).
- [ ] Tighten `connect_timeout` / `read_timeout` / `write_timeout` for inter-VPS RTT.
- [ ] **Lock down direct access:** IP allowlist (Pattern 1) + shared-secret header (Pattern 2) — both, ideally. Inject the secret via `request-transformer` referencing `{vault://env/...}`; never inline.
- [ ] Set the secret value in `docker-compose.yml` `kong.environment:` and the workspace `.env`. Confirm Kong sees it at startup.
- [ ] Backend reads identity from `X-User-Id` / `X-Roles` / `X-Session-Id` only; verifies the gateway secret on every request using `hash_equals` (or the equivalent constant-time compare).
- [ ] Add a `passive` healthcheck so a flaky upstream gets pulled out of rotation.
- [ ] **Smoke test step 3 (direct bypass):** `curl` the backend's public URL with a spoofed `X-User-Id`. Must return 401 or 403. A 200 here means the lockdown is incomplete.

---

## 9. Worked examples

The sections above are the reference. This section is a cookbook: seven
complete, copy-pasteable cases — full `kong.yml` blocks, full
`docker-compose.yml` diffs, full backend skeletons, full smoke tests.

| § | Service | Path | What's different |
|---|---|---|---|
| [9.1](#91-e-ktp-service-path-a--role-check) | `e-ktp-service` | A | Reference local-auth service, with a role check for write endpoints |
| [9.2](#92-e-perizinan-service-path-a--pdf-uploads) | `e-perizinan-service` | A | Raises per-service body limit for permit-application PDF uploads |
| [9.3](#93-status-service-path-b--proxy-cache) | `status-service` | B | Public city-service status page with proxy-cache and IP rate limit |
| [9.4](#94-wa-webhook-service-path-b--hmac) | `wa-webhook-service` | B | WhatsApp Business inbound webhook — HMAC verified in-service |
| [9.5](#95-legacy-citizen-db-path-c1a-private-lan) | `legacy-citizen-db` | C.1a | Sibling VPS over private LAN, plain HTTP, shared-secret only |
| [9.6](#96-e-sampah-service-path-c1b--public-https) | `e-sampah-service` | C.1b | **Real production case** — separate VPS, public HTTPS, full lockdown |
| [9.7](#97-citizen-api-path-c1c-cpanelwhm-php) | `citizen-api` | C.1c | PHP on cPanel/WHM shared hosting, AutoSSL, .htaccess lockdown |

---

### 9.1 `e-ktp-service` (Path A + role check)

**Scenario.** Disdukcapil exposes a read API for citizens to look up their
own NIK record, and a write API for staff (`pegawai-disdukcapil` role) to
correct a record. Both endpoints live in the same service, on the same
prefix; the role check splits them.

**Path classification.** Path A — a local Node service in the Docker
stack, fully behind Kong. The plugin chain is the standard one. Role
enforcement uses §6 Option 1 (in-service), because the policy is
end-point-specific and the team would rather edit TS than `kong.yml`.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: e-ktp-service
  url: http://e-ktp-service:3002

  routes:
    - name: e-ktp
      paths: [/api/ktp]
      strip_path: true
      # GET  /api/ktp/lookup/<nik>  → upstream sees GET  /lookup/<nik>
      # POST /api/ktp/correct/<nik> → upstream sees POST /correct/<nik>

  plugins:
    - name: correlation-id
      config:
        header_name: X-Request-Id
        generator: uuid
        echo_downstream: true

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- IDENTICAL to sample-service. Paste the full body from
            -- kong/kong.yml here. check-lua-sync.mjs only gates the
            -- sample-service copy; this one is a contract you maintain.

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id
```

#### `docker-compose.yml` — append under `services:`

```yaml
e-ktp-service:
  build: ./services/e-ktp-service
  container_name: super-app-e-ktp-service
  environment:
    NODE_ENV: production
    PORT: 3002
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:3002/health"]
    interval: 10s
    timeout: 3s
    retries: 5
```

And add to `kong:`'s `depends_on:`:

```yaml
kong:
  depends_on:
    sample-service: { condition: service_started }
    e-ktp-service:  { condition: service_healthy }   # ← new
```

#### `services/e-ktp-service/src/index.ts`

```ts
import express, { type Request, type Response, type NextFunction } from 'express';

const PORT = Number(process.env['PORT'] ?? 3002);

type Identity = {
  userId: string | null;
  sessionId: string | null;
  roles: string[];
};

const identityFromHeaders = (req: Request): Identity => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',').map((r) => r.trim()).filter(Boolean),
});

const requireRole = (role: string) =>
  (req: Request, res: Response, next: NextFunction) => {
    const { roles } = identityFromHeaders(req);
    if (!roles.includes(role)) {
      return res.status(403).json({ error: 'forbidden', requires: role });
    }
    next();
  };

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'e-ktp-service' });
});

app.get('/lookup/:nik', (req, res) => {
  const { userId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...DB lookup, return the citizen's own record only...
  res.json({ nik: req.params.nik, requestedBy: userId });
});

app.post('/correct/:nik', requireRole('pegawai-disdukcapil'), (req, res) => {
  const { userId } = identityFromHeaders(req);
  // ...apply the correction, audit log keyed on userId + X-Request-Id...
  res.json({ nik: req.params.nik, correctedBy: userId, body: req.body });
});

app.listen(PORT, () => console.log(`e-ktp-service on :${PORT}`));
```

#### Smoke test

```bash
docker compose up -d --build e-ktp-service kong

# Read endpoint as a citizen — should succeed.
TOKEN_CITIZEN=$(./scripts/mint-test-token.sh --roles citizen --sub user-123)
curl -s -H "Authorization: Bearer $TOKEN_CITIZEN" \
  http://localhost:8080/api/ktp/lookup/1271010101010001 | jq .
# Expected: 200 { "nik": "...", "requestedBy": "user-123" }

# Write endpoint as a citizen — 403.
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST -H "Authorization: Bearer $TOKEN_CITIZEN" \
  -H "Content-Type: application/json" -d '{"name":"x"}' \
  http://localhost:8080/api/ktp/correct/1271010101010001
# Expected: 403

# Write endpoint as staff — 200.
TOKEN_STAFF=$(./scripts/mint-test-token.sh --roles pegawai-disdukcapil --sub staff-7)
curl -s -X POST -H "Authorization: Bearer $TOKEN_STAFF" \
  -H "Content-Type: application/json" -d '{"name":"x"}' \
  http://localhost:8080/api/ktp/correct/1271010101010001 | jq .
# Expected: 200 { "correctedBy": "staff-7", ... }
```

#### Pitfalls specific to §9.1

| Symptom | Cause | Fix |
|---|---|---|
| Role check passes for nobody | `X-Roles` is `null` because the JWT had no `roles` claim | Verify the BFF copies the Keycloak role-mapping into the internal JWT — see `bff/src/lib/internalJwt.ts`. |
| Citizen can read another citizen's NIK | You forgot to constrain `lookup` to `userId`'s own NIK | The role gate doesn't replace per-row authorization. Filter the DB query by `userId` too. |
| Staff role works in dev, fails in prod | Keycloak realm role isn't named `pegawai-disdukcapil` in prod | Realm roles are env-specific; check the Keycloak admin console matches the string in `requireRole(...)`. |

---

### 9.2 `e-perizinan-service` (Path A + PDF uploads)

**Scenario.** Permit application service. Citizens submit a PDF of their
supporting documents along with the application form. Default request-size
ceiling (256 KB at Kong, 64 KB at nginx) blocks anything useful — both
need raising on this route only.

**Path classification.** Path A — local Node service. The only deviation
from §9.1 is per-service `request-size-limiting` config and an nginx
client-body-size bump on the matching location.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: e-perizinan-service
  url: http://e-perizinan-service:3004

  routes:
    - name: e-perizinan
      paths: [/api/perizinan]
      strip_path: true

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- IDENTICAL Lua to sample-service.

    # ── PER-SERVICE override of the global 256 KB cap (AUDIT S-6). ──
    # Plugin instance scoped to this service overrides the global
    # request-size-limiting declared at the root of kong.yml. 5 MB matches
    # the practical ceiling of a scanned multi-page PDF; larger raises
    # the cost-of-abuse for a malicious upload, so don't bump higher
    # without a real document type that needs it.
    - name: request-size-limiting
      config:
        allowed_payload_size: 5120
        size_unit: kilobytes
        require_content_length: true   # reject chunked uploads with no size

    - name: rate-limiting
      config:
        # tighter than default because uploads are expensive
        minute: 60
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id
```

#### `nginx/conf.d/api.conf` — raise client body limit on the matching prefix

```nginx
# nginx terminates the client TLS connection BEFORE Kong sees the request,
# so its body-size cap (default 1m or the project's 64k) clamps first.
# Raise it only on /api/perizinan/ so other routes keep the tight default.
location /api/perizinan/ {
  client_max_body_size 5m;        # match Kong's 5120 KB
  client_body_timeout 30s;        # don't let a slow upload tie up workers
  proxy_request_buffering off;    # stream straight to Kong, don't buffer

  include /etc/nginx/snippets/proxy_common.conf;
  proxy_pass http://kong:8000;
}
```

#### `docker-compose.yml` — append under `services:`

```yaml
e-perizinan-service:
  build: ./services/e-perizinan-service
  container_name: super-app-e-perizinan-service
  environment:
    NODE_ENV: production
    PORT: 3004
    # Where uploaded PDFs land. In a real deploy this is an object-store
    # client (S3-compatible MinIO, etc.), not the local FS.
    UPLOAD_DIR: /var/lib/perizinan/uploads
  volumes:
    - perizinan-uploads:/var/lib/perizinan/uploads
  restart: unless-stopped

volumes:
  perizinan-uploads:
```

#### `services/e-perizinan-service/src/index.ts`

```ts
import express, { type Request } from 'express';
import multer from 'multer';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3004);
const UPLOAD_DIR = process.env['UPLOAD_DIR'] ?? '/tmp';

const identityFromHeaders = (req: Request) => ({
  userId: (req.headers['x-user-id'] as string | undefined) ?? null,
  requestId: (req.headers['x-request-id'] as string | undefined) ?? null,
});

const upload = multer({
  dest: UPLOAD_DIR,
  limits: {
    // belt-and-braces: Kong already enforces 5 MB, but the service should
    // refuse anything larger so memory doesn't spike if Kong is ever bypassed
    fileSize: 5 * 1024 * 1024,
    files: 1,
  },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype !== 'application/pdf') {
      return cb(new Error('only application/pdf accepted'));
    }
    cb(null, true);
  },
});

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/apply', upload.single('document'), (req, res) => {
  const { userId, requestId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  if (!req.file) return res.status(400).json({ error: 'document required' });

  const applicationId = randomUUID();
  // ...persist application row keyed by applicationId, userId, req.file.path...

  res.status(202).json({
    applicationId,
    appliedBy: userId,
    requestId,
    fileSize: req.file.size,
  });
});

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build e-perizinan-service kong nginx

# Tiny file — accepted.
echo "%PDF-1.4 small" > /tmp/small.pdf
curl -s -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/small.pdf;type=application/pdf" \
  http://localhost:8080/api/perizinan/apply | jq .
# Expected: 202 with applicationId

# 6 MB file — Kong's request-size-limiting plugin rejects at 413.
dd if=/dev/zero of=/tmp/big.pdf bs=1M count=6 status=none
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/big.pdf;type=application/pdf" \
  http://localhost:8080/api/perizinan/apply
# Expected: 413 Request Entity Too Large

# Wrong content type — service rejects at 400 (Kong doesn't filter MIME).
echo "not a pdf" > /tmp/notpdf.txt
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/notpdf.txt;type=text/plain" \
  http://localhost:8080/api/perizinan/apply
# Expected: 400
```

#### Pitfalls specific to §9.2

| Symptom | Cause | Fix |
|---|---|---|
| `413` even on a 1 MB upload | nginx's `client_max_body_size` is still the default 1m | Raise it on the matching `location` block (see `api.conf` above). |
| Upload hangs and times out | `proxy_request_buffering on` + slow client = nginx buffers full file before Kong sees a byte | Set `proxy_request_buffering off` on the upload route. |
| Disk fills up in dev | Tests upload then crash before cleanup | Mount the volume to `tmpfs` in dev compose, or wire a cron to drop files older than N days. |
| Service OOMs on a valid 5 MB PDF | `multer` is buffering in memory instead of streaming to disk | Use `multer({ dest, ... })` not `multer.memoryStorage()`. |
| File parts arrive but `req.file` is undefined | Form field name in the client doesn't match `upload.single('document')` | Either rename the form field or change the multer call. |

---

### 9.3 `status-service` (Path B + proxy-cache)

**Scenario.** Public-facing status page that lists which city services are
up. Hit by scrapers, embedded in the city homepage, no user identity ever.
Heavy reads — caching at Kong saves the upstream entirely on a hit.

**Path classification.** Path B. No `jwt`, no `pre-function`. IP rate
limit + `proxy-cache` plugin so a burst of identical requests answers
from RAM.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: status-service
  url: http://status-service:3005

  routes:
    - name: status-public
      paths: [/api/public/status]
      strip_path: true
      # The /api/public/ prefix is load-bearing for code review:
      # grep -r '/api/public' kong/kong.yml confirms which routes
      # intentionally skip auth. See §2.

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    # NO jwt plugin. NO pre-function plugin.

    # Cache GETs for 30s. The upstream re-computes status by polling
    # internal services on a 60s schedule; 30s at the edge halves the
    # upstream load with at-worst-30s staleness.
    - name: proxy-cache
      config:
        response_code: [200]
        request_method: [GET, HEAD]
        content_type: ["application/json", "application/json; charset=utf-8"]
        cache_ttl: 30
        strategy: memory
        memory:
          dictionary_name: kong_db_cache   # the default in-memory dict

    # IP rate limit — there's no X-User-Id to key by.
    # 120/min/IP is the project default for public endpoints; tune to
    # the legitimate scraping pattern (city homepage poll = ~1/min).
    - name: rate-limiting
      config:
        minute: 120
        policy: local
        fault_tolerant: true
        limit_by: ip
```

#### `docker-compose.yml`

```yaml
status-service:
  build: ./services/status-service
  container_name: super-app-status-service
  environment:
    NODE_ENV: production
    PORT: 3005
  restart: unless-stopped
```

Add `status-service: { condition: service_started }` to `kong:`'s
`depends_on:`.

#### `services/status-service/src/index.ts`

```ts
import express from 'express';

const PORT = Number(process.env['PORT'] ?? 3005);

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// In real life this is polled in the background and cached in-process,
// not computed per request.
app.get('/', (_req, res) => {
  res.setHeader('Cache-Control', 'public, max-age=30');
  res.json({
    asOf: new Date().toISOString(),
    services: [
      { name: 'e-ktp',     status: 'up'   },
      { name: 'e-sampah',  status: 'up'   },
      { name: 'perizinan', status: 'degraded', note: 'PDF render slow' },
    ],
  });
});

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build status-service kong

# Anonymous access works.
curl -s http://localhost:8080/api/public/status | jq .

# Cache hit on the 2nd request — look for X-Cache-Status: Hit.
curl -sI http://localhost:8080/api/public/status | grep -i x-cache-status
curl -sI http://localhost:8080/api/public/status | grep -i x-cache-status
# 1st: X-Cache-Status: Miss
# 2nd: X-Cache-Status: Hit

# Rate limit kicks in around the 121st request from the same IP.
for i in {1..200}; do
  curl -so /dev/null -w "%{http_code} " http://localhost:8080/api/public/status
done | tr ' ' '\n' | sort | uniq -c
# Expected: ~120 lines of "200", remainder "429"
```

#### Pitfalls specific to §9.3

| Symptom | Cause | Fix |
|---|---|---|
| `proxy-cache` never hits | Upstream sets `Cache-Control: no-store` or `private` | The plugin honors upstream cache headers. Either change the service's response or set `cache_control: false` on the plugin to force-cache. |
| Cache keyed wrong — every IP gets a fresh miss | `proxy-cache` defaults include the request's `Host`/`URI`/`query` but not `X-Forwarded-For` | Default key is fine for an anonymous endpoint. If you ever vary by query string, confirm `vary_query_params:` matches what callers send. |
| `429` triggers at 5 req/sec even though `minute: 120` | A bot is using a single IP that's actually a NAT in front of a city office | `limit_by: ip` with `fault_tolerant: true` is the right setup; raise `minute:` for the NAT IP via a per-route plugin instance, or accept it. |
| The service is reachable directly from the host | You added a `ports:` mapping by reflex | Remove it. Public services are still only reachable via Kong. |

---

### 9.4 `wa-webhook-service` (Path B + HMAC)

**Scenario.** WhatsApp Business API delivers inbound messages by POSTing
to a public URL. The third party signs each POST with HMAC-SHA256 of the
body, using a shared secret only Meta and the service know. Kong cannot
verify this — the secret isn't ours and the signature mechanism is
provider-specific. So the route is Path B at Kong (no JWT), and HMAC
verification happens inside the service on every request.

**Path classification.** Path B + in-service HMAC verification.
Specifically a webhook receiver: anonymous to Kong, authenticated by
Meta's signature inside the service.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: wa-webhook-service
  url: http://wa-webhook-service:3006

  routes:
    - name: wa-webhook
      paths: [/api/public/webhooks/whatsapp]
      strip_path: true
      methods: [GET, POST]
      # GET = Meta's verification handshake; POST = inbound message.

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    # NO jwt. NO pre-function. Auth is the upstream's HMAC check.

    # IP rate limit. Meta posts from a known IP range — set this loose
    # enough not to drop bursts during a campaign, tight enough that a
    # leaked URL doesn't get overwhelmed.
    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: ip
```

> **Stricter alternative:** Kong's bundled `ip-restriction` plugin can
> allowlist Meta's egress IP ranges directly at the gateway. Meta
> publishes the list and rotates it occasionally — automating that sync
> is more orchestration than is justified for a single webhook. Leave
> the IP filter to the service or accept that the HMAC check is the only
> authenticity gate.

#### `docker-compose.yml`

```yaml
wa-webhook-service:
  build: ./services/wa-webhook-service
  container_name: super-app-wa-webhook-service
  environment:
    NODE_ENV: production
    PORT: 3006
    # The shared secret Meta configured for this webhook. Comes from
    # ${WA_APP_SECRET} in your workspace .env (never committed).
    WA_APP_SECRET: ${WA_APP_SECRET}
    # The verify-token Meta sends on the GET handshake.
    WA_VERIFY_TOKEN: ${WA_VERIFY_TOKEN}
  restart: unless-stopped
```

#### `services/wa-webhook-service/src/index.ts`

```ts
import express, { type Request, type Response, type NextFunction } from 'express';
import { createHmac, timingSafeEqual } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3006);
const APP_SECRET = process.env['WA_APP_SECRET'] ?? '';
const VERIFY_TOKEN = process.env['WA_VERIFY_TOKEN'] ?? '';

const app = express();
app.disable('x-powered-by');

// Capture the RAW request body — we need exact bytes to recompute HMAC.
// express.json() would re-serialize and the signature would never match.
app.use(express.raw({ type: 'application/json', limit: '256kb' }));

const verifyMetaSignature = (req: Request, res: Response, next: NextFunction) => {
  const sigHeader = req.header('x-hub-signature-256') ?? '';
  // Meta sends "sha256=<hex>"
  if (!sigHeader.startsWith('sha256=')) {
    return res.status(401).json({ error: 'missing signature' });
  }
  const presented = Buffer.from(sigHeader.slice('sha256='.length), 'hex');
  const expected = createHmac('sha256', APP_SECRET)
    .update(req.body as Buffer)
    .digest();

  // Constant-time compare. Length mismatch must short-circuit safely.
  if (presented.length !== expected.length ||
      !timingSafeEqual(presented, expected)) {
    return res.status(401).json({ error: 'bad signature' });
  }
  next();
};

// Meta's verification handshake: GET with hub.mode / hub.challenge / hub.verify_token.
app.get('/', (req, res) => {
  const mode = req.query['hub.mode'];
  const token = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];
  if (mode === 'subscribe' && token === VERIFY_TOKEN) {
    return res.status(200).send(String(challenge ?? ''));
  }
  res.sendStatus(403);
});

// Inbound message POST.
app.post('/', verifyMetaSignature, (req, res) => {
  const payload = JSON.parse((req.body as Buffer).toString('utf8'));
  // ...enqueue payload for async processing; ack within 200ms or Meta retries...
  res.sendStatus(200);
});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build wa-webhook-service kong

# 1) GET handshake — match the verify token.
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://localhost:8080/api/public/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=$WA_VERIFY_TOKEN&hub.challenge=test"
# Expected: 200

# 2) GET handshake — wrong token.
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://localhost:8080/api/public/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test"
# Expected: 403

# 3) POST without signature → 401 from the service.
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  -H "Content-Type: application/json" -d '{"messages":[]}' \
  http://localhost:8080/api/public/webhooks/whatsapp
# Expected: 401

# 4) POST with a correct signature → 200.
BODY='{"object":"whatsapp_business_account","entry":[]}'
SIG="sha256=$(printf %s "$BODY" | openssl dgst -sha256 -hmac "$WA_APP_SECRET" -binary | xxd -p -c 256)"
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$BODY" \
  http://localhost:8080/api/public/webhooks/whatsapp
# Expected: 200
```

#### Pitfalls specific to §9.4

| Symptom | Cause | Fix |
|---|---|---|
| HMAC never matches | `express.json()` re-parsed the body, the verifier hashed the re-serialized JSON | Use `express.raw({ type: 'application/json' })` and hash `req.body` (a Buffer). |
| HMAC matches in dev, fails in prod | Prod has a different `WA_APP_SECRET`; you copied the dev one | Sync the secret with Meta's dashboard per environment. |
| Constant-time compare crashes on length mismatch | `timingSafeEqual` throws when buffers differ in length | Check `presented.length === expected.length` before calling it. |
| Meta retries the same message forever | Service returned non-2xx, or took longer than ~20s to ack | Ack within 200ms; do work async (queue). |
| Webhook URL leaks → spam to the endpoint | The URL is public by design | Rely on the HMAC check — without the secret, an attacker only causes IP-rate-limited 401 noise. |

---

### 9.5 `legacy-citizen-db` (Path C.1a private LAN)

**Scenario.** An existing Java service running on a sibling VPS in the
same provider VLAN. Reachable from Kong on `http://10.0.5.20:8080`. No
TLS (private LAN), no virtual hosts. You don't own the codebase and
adding the gateway-guard middleware needs a coordinated deploy with the
other team.

**Path classification.** Path C.1a — plain HTTP over private LAN. Same
auth plugin chain as Path A; the differences are `url:`, no TLS knobs,
no `preserve_host` concern, and a more minimal direct-access lockdown
(only Pattern 2 shared-secret is portable; LAN IPs are already a partial
allowlist).

#### `kong/kong.yml` — append under `services:`

```yaml
- name: legacy-citizen-db
  url: http://10.0.5.20:8080
  # No tls_verify — plain HTTP. Acceptable ONLY because the path is
  # provider-VLAN-private. If this VPS ever moves to a different
  # network segment, switch to https:// and re-add tls_verify: true.

  connect_timeout: 3000
  read_timeout: 10000
  write_timeout: 10000

  routes:
    - name: legacy-citizen
      paths: [/api/legacy/citizen]
      strip_path: true
      # No preserve_host needed — the upstream is single-vhost.

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }
    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []
    - name: pre-function
      config:
        access:
          - |
            -- IDENTICAL Lua to sample-service.

    # Shared-secret header — see §5.3 Pattern 2. The legacy service's
    # only auth gate is this header; verify on every inbound.
    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/legacy-citizen-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — Kong env

```yaml
kong:
  environment:
    LEGACY_CITIZEN_GATEWAY_SECRET: ${LEGACY_CITIZEN_GATEWAY_SECRET}
```

…and `.env` (never committed):

```bash
LEGACY_CITIZEN_GATEWAY_SECRET=<32+ random bytes; rotate quarterly>
```

#### Backend snippet (Java/Spring servlet filter)

```java
// LegacyCitizenDB — add this filter on the inbound path.
public class GatewayGuardFilter implements Filter {
  private final byte[] expected;

  public GatewayGuardFilter() {
    String env = System.getenv("GATEWAY_SECRET");
    if (env == null || env.isEmpty()) {
      throw new IllegalStateException("GATEWAY_SECRET unset");
    }
    this.expected = env.getBytes(StandardCharsets.UTF_8);
  }

  @Override
  public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
      throws IOException, ServletException {
    HttpServletRequest http = (HttpServletRequest) req;
    String presentedStr = http.getHeader("X-Gateway-Secret");
    if (presentedStr == null) { deny((HttpServletResponse) res); return; }
    byte[] presented = presentedStr.getBytes(StandardCharsets.UTF_8);
    // Constant-time compare; length mismatch fails safely.
    if (presented.length != expected.length
        || !MessageDigest.isEqual(presented, expected)) {
      deny((HttpServletResponse) res);
      return;
    }
    // From here, trust X-User-Id / X-Roles / X-Session-Id.
    chain.doFilter(req, res);
  }

  private void deny(HttpServletResponse res) throws IOException {
    res.setStatus(401);
    res.getWriter().write("not via gateway");
  }
}
```

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Without bearer → Kong 401 (jwt plugin).
curl -i http://localhost:8080/api/legacy/citizen/lookup

# 2) With bearer → routed to legacy service, identity injected.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/legacy/citizen/lookup | jq .

# 3) CRITICAL — try the backend directly from another box on the same VLAN.
ssh ops@10.0.5.21 'curl -i -H "X-User-Id: admin" http://10.0.5.20:8080/lookup'
# Expected: 401 from the legacy service (gateway secret missing).
# A 200 means the GatewayGuardFilter isn't wired in — fix BEFORE rolling
# the route into production.
```

#### Pitfalls specific to §9.5

| Symptom | Cause | Fix |
|---|---|---|
| 502 immediately, but the legacy box pings fine | Docker on the Kong host can't see the VLAN | Confirm Docker isn't using a NAT mode that blocks 10.0.0.0/8. `docker compose exec kong ping 10.0.5.20`. |
| Direct curl from an admin's laptop hits the legacy service | The "private LAN" is reachable from the office VPN | The LAN is not a security boundary — the shared-secret check is. Trust the guard, not the network. |
| Filter rejects everything in prod | Backend env var name doesn't match what Kong injects | Filter reads `GATEWAY_SECRET`; Kong injects `X-Gateway-Secret`. The values must match; the env-var name on the backend can be whatever you want. |
| Latency p99 spikes around 60s | Legacy box dropped a connection silently; Kong waited the full default `read_timeout` | The 10s `read_timeout` above caps this. Lower further if the legacy box is reliably faster. |

---

### 9.6 `e-sampah-service` (Path C.1b — public HTTPS)

> **This is your actual production case.** The e-sampah service is a
> Node/Express app running on a separate VPS, reachable at
> `https://sampah.pangkalpinangkota.go.id` with its own Let's Encrypt
> certificate. The auth contract is identical to a local service — what
> changes is networking, TLS, and the lockdown.

**Scenario.** Citizens report illegal-dumping locations and view their
own reports. Disdamkar staff (`pegawai-disdamkar`) review and close
reports. Service runs on its own VPS (separate from the Kong VPS) for
team/deployment isolation.

**Path classification.** Path C.1b — public HTTPS to a single-vhost
backend. No cPanel concerns. Full lockdown: IP allowlist *and*
shared-secret header. The plugin chain matches Path A.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: e-sampah-service
  url: https://sampah.pangkalpinangkota.go.id

  # Verify the upstream's cert against system CAs. Default true; pinned
  # here so a future edit can't silently disable TLS verification.
  tls_verify: true

  # Inter-VPS RTT in the same region is single-digit ms; mobile p99 budget
  # is ~2s end-to-end. These three caps keep a slow upstream from holding
  # a Kong worker for a full minute.
  connect_timeout: 5000
  write_timeout: 10000
  read_timeout: 15000

  routes:
    - name: e-sampah
      paths: [/api/sampah]
      strip_path: true
      # Single vhost backend, but pin preserve_host: false explicitly so
      # the upstream's nginx routes to the right server{} block. Default
      # is false; this is belt-and-braces against a future edit.
      preserve_host: false

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- IDENTICAL Lua to sample-service. Do not fork the body.

    # Direct-access lockdown — Pattern 2 (shared secret). Pattern 1 (IP
    # allowlist) is configured on the e-sampah VPS firewall, see §9.6
    # "VPS-side firewall" below.
    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/e-sampah-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — Kong env

```yaml
kong:
  environment:
    # ...existing env vars...
    E_SAMPAH_GATEWAY_SECRET: ${E_SAMPAH_GATEWAY_SECRET}
```

And in workspace `.env` (never committed):

```bash
E_SAMPAH_GATEWAY_SECRET=<32+ random bytes; rotate quarterly>
```

The same value must be set in the e-sampah VPS's own env so its guard
middleware can verify the header.

#### e-sampah VPS — backend (`server.ts`)

```ts
import express, { type Request, type Response, type NextFunction } from 'express';
import { timingSafeEqual } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3000);
const GATEWAY_SECRET = process.env['GATEWAY_SECRET'] ?? '';
if (!GATEWAY_SECRET) {
  throw new Error('GATEWAY_SECRET unset — refusing to start');
}
const expectedBuf = Buffer.from(GATEWAY_SECRET, 'utf8');

// Reject any request not arriving via the Kong gateway. Runs BEFORE any
// route — so /health and /metrics also need the header (or move the
// guard below them if you expose those publicly).
const gatewayGuard = (req: Request, res: Response, next: NextFunction) => {
  const presented = req.header('x-gateway-secret') ?? '';
  if (!presented) return res.status(401).end('not via gateway');
  const presentedBuf = Buffer.from(presented, 'utf8');
  if (presentedBuf.length !== expectedBuf.length ||
      !timingSafeEqual(presentedBuf, expectedBuf)) {
    return res.status(401).end('not via gateway');
  }
  next();
};

type Identity = {
  userId: string | null;
  sessionId: string | null;
  roles: string[];
  requestId: string | null;
};

const identityFromHeaders = (req: Request): Identity => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',').map((r) => r.trim()).filter(Boolean),
  requestId: (req.headers['x-request-id'] as string | undefined) ?? null,
});

const requireRole = (role: string) =>
  (req: Request, res: Response, next: NextFunction) => {
    const { roles } = identityFromHeaders(req);
    if (!roles.includes(role)) {
      return res.status(403).json({ error: 'forbidden', requires: role });
    }
    next();
  };

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));
app.use(gatewayGuard);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/reports', (req, res) => {
  const { userId, requestId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...persist the report row keyed by userId + requestId for audit correlation...
  res.status(201).json({ reportedBy: userId, requestId, body: req.body });
});

app.get('/reports/mine', (req, res) => {
  const { userId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...return reports WHERE reporter_user_id = userId only...
  res.json({ user: userId, reports: [] });
});

app.post('/reports/:id/close', requireRole('pegawai-disdamkar'), (req, res) => {
  const { userId } = identityFromHeaders(req);
  res.json({ closedBy: userId, reportId: req.params.id });
});

app.listen(PORT, () => console.log(`e-sampah on :${PORT}`));
```

#### e-sampah VPS — firewall (Pattern 1 IP allowlist)

The Kong VPS has a stable egress IP — let's call it `203.0.113.10`.
Lock the e-sampah VPS to only accept inbound HTTPS from it:

```bash
# On the e-sampah VPS, as root.
ufw default deny incoming
ufw default allow outgoing
ufw allow from <admin-bastion-ip> to any port 22 proto tcp     # SSH only from your bastion
ufw allow from 203.0.113.10       to any port 443 proto tcp    # HTTPS only from Kong
ufw enable
ufw status verbose
```

If Kong is behind a managed load balancer with a rotating egress, use
the LB provider's stable egress range instead, or skip Pattern 1 and
rely on Pattern 2 alone (the shared secret). Document which you chose
in the e-sampah VPS's runbook.

#### e-sampah VPS — TLS

The VPS terminates TLS with its own Let's Encrypt cert (separate from
the Kong VPS's cert). Nothing about the Kong stack needs to change for
that — `tls_verify: true` on Kong's side just needs the cert chain to be
complete:

```bash
# From any box, confirm the chain is valid (intermediates included):
openssl s_client -connect sampah.pangkalpinangkota.go.id:443 -showcerts </dev/null
# Look for "Verify return code: 0 (ok)" at the end.
```

If you see `unable to get local issuer certificate`, the VPS is serving
the leaf cert without the Let's Encrypt intermediates — reissue with
`fullchain.pem`, not just `cert.pem`. Kong will 502 every request
otherwise.

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Without bearer → Kong 401.
curl -i http://localhost:8080/api/sampah/reports/mine
# Expected: 401 from Kong's jwt plugin.

# 2) With a citizen bearer → identity injected, report list returns.
TOKEN=$(./scripts/mint-test-token.sh --roles citizen --sub user-42)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/sampah/reports/mine | jq .
# Expected: 200 { "user": "user-42", "reports": [] }

# 3) Citizen tries to close a report → 403 from the role gate.
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/sampah/reports/r-1/close
# Expected: 403

# 4) Staff bearer can close.
TOKEN_STAFF=$(./scripts/mint-test-token.sh --roles pegawai-disdamkar --sub staff-3)
curl -s -X POST -H "Authorization: Bearer $TOKEN_STAFF" \
  http://localhost:8080/api/sampah/reports/r-1/close | jq .
# Expected: 200 { "closedBy": "staff-3", "reportId": "r-1" }

# 5) CRITICAL — hit the backend's PUBLIC URL directly with spoofed identity.
curl -i -H "X-User-Id: admin" -H "X-Roles: pegawai-disdamkar" \
  https://sampah.pangkalpinangkota.go.id/reports/mine
# Expected: 401 ("not via gateway") if Pattern 2 is wired, OR
#           connection refused / timeout if Pattern 1 firewall is active.
# A 200 here means BOTH lockdowns are missing. Do NOT roll out until fixed.
```

The step-5 test is the one that proves the chain is sound. If a
spoofed-header curl from your laptop succeeds, the entire identity model
is bypassable — neither the JWT chain nor the role gate matters.

#### Pitfalls specific to §9.6

| Symptom | Cause | Fix |
|---|---|---|
| `502 Bad Gateway` immediately on every request | DNS doesn't resolve inside the Kong container | `docker compose exec kong getent hosts sampah.pangkalpinangkota.go.id`. If empty, add `dns: [1.1.1.1, 8.8.8.8]` to the `kong:` compose block. |
| `502 Bad Gateway` after a delay | TLS chain incomplete on the e-sampah VPS | `openssl s_client -showcerts` and confirm full chain. Reissue with `fullchain.pem`. |
| All requests 401 "not via gateway" | `E_SAMPAH_GATEWAY_SECRET` mismatch between Kong env and e-sampah VPS env | Re-sync. The secret must be byte-identical; quote carefully in shell scripts (no trailing newline). |
| Inter-VPS p99 > 200ms | Kong host and e-sampah host are in different regions | Move them to the same region/AZ, or accept the cost and tune `BFF_INTERNAL_JWT_TTL_SECONDS` upward (within Kong's 600s `maximum_expiration` cap) to reduce refresh frequency. |
| Direct-bypass test (step 5) returns 200 | Either Pattern 1 firewall isn't enforcing or `gatewayGuard` isn't installed first in the middleware chain | Confirm `app.use(gatewayGuard)` runs before any route handler. Confirm `ufw status` shows `Status: active`. |
| `kong reload` doesn't pick up new YAML | DB-less Kong only re-reads `kong.yml` at container start | `docker compose restart kong`. |
| Secret rotation requires a Kong restart | Yes — `{vault://env/...}` is resolved at startup, not per request | Plan rotation: dual-accept on the e-sampah side first (accept old AND new), flip Kong's env, restart Kong, then drop the old secret on e-sampah. Mirrors the JWT key rotation runbook in `kong/README.md`. |

---

### 9.7 `citizen-api` (Path C.1c cPanel/WHM PHP)

**Scenario.** Existing PHP service hosted on shared cPanel hosting at
`https://services.pangkalpinangkota.go.id/citizen-api`. AutoSSL handles
TLS. The hosting account is shared with other tenants; you can edit
`.htaccess`, `.env`, and the PHP source, but not the Apache or
mod_security config.

**Path classification.** Path C.1c — public HTTPS into a virtual-hosted
backend. Two extra concerns over §9.6: `preserve_host: false` is
load-bearing (the upstream Apache routes by Host header), and the
lockdown lives in `.htaccess` instead of `ufw`.

#### `kong/kong.yml` — append under `services:`

```yaml
- name: citizen-api
  url: https://services.pangkalpinangkota.go.id/citizen-api

  tls_verify: true
  connect_timeout: 5000
  write_timeout: 10000
  read_timeout: 15000

  routes:
    - name: citizen
      paths: [/api/citizen]
      strip_path: true
      # LOAD-BEARING for cPanel: false sends `Host: services.pangkalpinangkota.go.id`
      # (the upstream URL's host), so Apache picks the right vhost.
      # true would send the edge host and cPanel would 404 or route to
      # the default vhost. Default is false; pinned for the next reader.
      preserve_host: false

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- IDENTICAL Lua to sample-service.

    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/citizen-api-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — Kong env

```yaml
kong:
  environment:
    CITIZEN_API_GATEWAY_SECRET: ${CITIZEN_API_GATEWAY_SECRET}
```

…and workspace `.env`:

```bash
CITIZEN_API_GATEWAY_SECRET=<32+ random bytes; rotate quarterly>
```

#### cPanel `.htaccess` — Pattern 1 IP allowlist

Drop this file at the document root of `citizen-api/`. Apache evaluates
it before any PHP runs:

```apache
# /home/<user>/public_html/citizen-api/.htaccess
<RequireAll>
  Require ip <KONG_VPS_PUBLIC_IP>
  # Optional second line if Kong has multiple egress IPs:
  # Require ip <KONG_VPS_PUBLIC_IP_BACKUP>
</RequireAll>

# Also disable directory listings, regardless of the allowlist.
Options -Indexes

# Belt-and-braces: deny any request without the gateway secret header.
# Apache's RewriteCond can short-circuit before PHP loads.
RewriteEngine On
RewriteCond %{HTTP:X-Gateway-Secret} ^$
RewriteRule .* - [F,L]
```

The Apache-level `RewriteCond` only checks the header is *present* —
it can't verify the value (no constant-time compare in Apache rewrite
rules). The PHP guard below does the actual verification.

#### cPanel — `.env` and PHP guard

`.env` (sits outside the document root; never web-accessible):

```bash
# /home/<user>/citizen-api-config/.env
GATEWAY_SECRET=<same value as workspace .env's CITIZEN_API_GATEWAY_SECRET>
```

`_gateway_guard.php` — required from every endpoint:

```php
<?php
// /home/<user>/public_html/citizen-api/_gateway_guard.php
declare(strict_types=1);

// Load GATEWAY_SECRET from an env file outside the docroot. PHP's
// getenv() inherits the shell env on Apache mod_php only if you set
// SetEnv in .htaccess; the env-file approach below is more portable.
$envPath = '/home/<user>/citizen-api-config/.env';
$expected = '';
if (is_readable($envPath)) {
    foreach (file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match('/^GATEWAY_SECRET=(.*)$/', $line, $m)) {
            $expected = $m[1];
            break;
        }
    }
}

$presented = $_SERVER['HTTP_X_GATEWAY_SECRET'] ?? '';

if ($expected === '' || $presented === '' || !hash_equals($expected, $presented)) {
    http_response_code(401);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'not via gateway']);
    exit;
}
```

`lookup.php` — example endpoint:

```php
<?php
// /home/<user>/public_html/citizen-api/lookup.php
declare(strict_types=1);
require __DIR__ . '/_gateway_guard.php';

$userId    = $_SERVER['HTTP_X_USER_ID']    ?? null;
$sessionId = $_SERVER['HTTP_X_SESSION_ID'] ?? null;
$rolesCsv  = $_SERVER['HTTP_X_ROLES']      ?? '';
$roles     = array_values(array_filter(array_map('trim', explode(',', $rolesCsv))));
$requestId = $_SERVER['HTTP_X_REQUEST_ID'] ?? null;

if ($userId === null) {
    http_response_code(401);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'no identity from gateway']);
    exit;
}

// Correlate to nginx/Kong/BFF logs.
error_log(sprintf('[%s] citizen-api lookup user=%s roles=%s',
    $requestId ?? '-', $userId, implode(',', $roles)));

header('Content-Type: application/json');
echo json_encode([
    'user'      => $userId,
    'roles'     => $roles,
    'requestId' => $requestId,
]);
```

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Without bearer → Kong 401.
curl -i http://localhost:8080/api/citizen/lookup.php
# Expected: 401 from Kong's jwt plugin.

# 2) With bearer → identity injected, PHP returns the user.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/citizen/lookup.php | jq .
# Expected: 200 { "user": "<sub from token>", "roles": [...] }

# 3) CRITICAL — hit the backend's PUBLIC URL directly with spoofed identity.
curl -i -H "X-User-Id: admin" -H "X-Roles: admin" \
  https://services.pangkalpinangkota.go.id/citizen-api/lookup.php
# Expected: 401 (gateway secret missing) or 403 (IP not in allowlist).
# A 200 here means BOTH lockdowns failed. Do not roll out.

# 4) From the Kong VPS host (which IS allowed), but WITHOUT the secret header:
ssh ops@<KONG_VPS> 'curl -i https://services.pangkalpinangkota.go.id/citizen-api/lookup.php'
# Expected: 401 (the RewriteCond in .htaccess catches missing X-Gateway-Secret).
# Confirms Pattern 2 still works even from inside Pattern 1's allowlist.
```

#### Pitfalls specific to §9.7

| Symptom | Cause | Fix |
|---|---|---|
| cPanel returns the wrong site's HTML | `preserve_host: true` sent the edge host; Apache routed to the default vhost | Set `preserve_host: false` (default; pin explicitly). |
| 500 with no PHP log entry | mod_security on shared hosting blocked the request | Check cPanel's mod_security logs (Security → ModSecurity). Whitelist the rule ID if it's a false positive. |
| `.htaccess` is ignored | `AllowOverride None` set by the host | Open a ticket with the cPanel provider to enable `AllowOverride All` on the docroot. |
| PHP can't read `_gateway_guard.php`'s env file | Path is wrong, or file mode denies the PHP user | `ls -la /home/<user>/citizen-api-config/.env` must be readable by the cPanel user. `chmod 600` and same owner. |
| Apache `RewriteCond` doesn't catch missing header | mod_rewrite isn't enabled or `.htaccess` rules aren't loading | `a2enmod rewrite` on the server side (the host has to do this); confirm with `<IfModule mod_rewrite.c>` wrapped test. |
| `hash_equals` not defined | PHP < 5.6 on the shared host | Ask the host to bump the PHP version on the account, or use `password_verify` with a hashed expected value as a workaround. |
| Direct-bypass test (step 3) returns 200 | `.htaccess` exists but `RequireAll` isn't enforced (Apache 2.2 vs 2.4 syntax mismatch) | Apache 2.4 uses `Require ip`; 2.2 used `Allow from`. Confirm the Apache version with the cPanel provider and match the syntax. |
| Secret rotation requires editing `.htaccess` | You inlined the secret in `.htaccess` | Don't. The secret only lives in cPanel's `.env` and Kong's compose env. `.htaccess` only checks presence. |

---

## See also

- [`kong/README.md`](../kong/README.md) — full plugin reference, kid rotation runbook.
- [`docs/auth-architecture.md`](auth-architecture.md) — why the gateway split looks the way it does.
- [`docs/DEPLOYMENT.md`](DEPLOYMENT.md) — single-VPS deploy and TLS bootstrap.
- [`docs/diagrams/flow-data-plane-request.svg`](diagrams/flow-data-plane-request.svg) — sequence of what happens on `/api/*`.
- [`docs/diagrams/kong-identity-injection.svg`](diagrams/kong-identity-injection.svg) — what the request shape looks like before vs after the `pre-function` plugin.
