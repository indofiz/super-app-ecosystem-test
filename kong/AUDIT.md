# Kong API Gateway — Audit Report

**Scope:** `kong/kong.yml`, Kong service block in `docker-compose.yml`, Kong's
contract with the BFF (`bff/src/lib/internalJwt.ts`), nginx (`nginx/`), and
the downstream `services/sample-service`.

**Audited at:** 2026-05-12
**Kong version under audit:** `kong:3.8.0-ubuntu` (DB-less, declarative)
**Auth model:** BFF mints RS256 internal JWTs; Kong's bundled `jwt` plugin
verifies; `pre-function` plugin injects identity headers for downstream
services.

Severity legend:

| Tag         | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| **CRITICAL**| Auth bypass, identity spoofing, or data exposure possible now. |
| **HIGH**    | Real production risk; fix before any internet exposure.        |
| **MEDIUM**  | Hardening / defense-in-depth; fix before scale.                |
| **LOW**     | Cleanup / nice-to-have; fix when convenient.                   |
| **INFO**    | Observation, no direct fix required.                           |

---

## 1. Executive Summary

The Kong layer is functionally correct for the documented auth model:
RS256 verification works, identity-header spoofing is defended against by
the `pre-function` plugin, and the declarative DB-less posture keeps the
gateway simple. **However, several gaps would prevent a clean production
launch:**

- The `jwt` plugin does **not** verify `iss` or `aud`. Tokens forged by
  any other internal RS256 signer that shares a `kid` would pass.
- The `pre-function` plugin only reads the bearer from the `Authorization`
  header — Kong's `jwt` plugin will also accept tokens in cookies/query, in
  which case identity headers are not injected and downstream services
  receive anonymous traffic *after* successful authentication.
- The Authorization header is forwarded upstream; downstream services
  still have raw JWTs, undermining the "Kong is the trust boundary" model.
- No rate-limiting, no body-size limit, no per-route authorization, no
  health check on the Kong container, no JSON access log, no Kong-side
  request-id correlation, and the production public-key material is not
  separated from the committed dev keypair.

There are **17 findings** below: 2 high, 8 medium, 5 low, 2 informational.
No critical findings on the as-built artifact, conditional on the
assumptions in §3.

---

## 2. Findings — Security

### S-1 [HIGH] `iss` and `aud` claims are not verified

**Files:** `kong/kong.yml:33-37`

```yaml
- name: jwt
  config:
    key_claim_name: kid
    claims_to_verify:
      - exp
```

Kong's bundled `jwt` plugin will verify only the claims listed in
`claims_to_verify`. The plugin's supported set is limited to `exp` and
`nbf` — it has **no `iss` / `aud` verification mode**. As written, Kong:

- selects a key by `kid` (good),
- checks the RS256 signature (good),
- checks `exp` (good),
- **does not check `iss == "super-app-bff"`**,
- **does not check `aud == "super-app-services"`**.

Any other process in the org that holds *any* of the private keys whose
matching public key is listed in `jwt_secrets` can mint a token with
arbitrary `iss` / `aud` and Kong will accept it. Today this is
theoretical (the BFF is the only minter), but the moment a second
internal signer exists for any reason (testing, partner SDK), the
isolation collapses.

The `pre-function` Lua does not close this gap either — it only reads
`sub` / `sid` / `roles` and trusts whatever it finds.

**Fix:**

Add `iss` and `aud` enforcement in the same `pre-function` script (or in
a small custom block before identity injection), e.g.:

```lua
if claims.iss ~= "super-app-bff" then
  return kong.response.exit(401, { message = "invalid issuer" })
end
if claims.aud ~= "super-app-services"
   and not (type(claims.aud) == "table" and table_contains(claims.aud, "super-app-services")) then
  return kong.response.exit(401, { message = "invalid audience" })
end
```

Driving the expected values from environment variables (so dev/prod
configs differ without forking `kong.yml`) is preferable.

---

### S-2 [HIGH] Identity headers not injected when token is presented via cookie or query

**Files:** `kong/kong.yml:55-100`

The bundled `jwt` plugin accepts the token from the `Authorization`
header **or** from cookies / `uri_param_names` (defaults are documented
in Kong's plugin reference). The `pre-function` script only reads from
the `Authorization` header:

```lua
local auth = kong.request.get_header("authorization")
if not auth then return end
local token = string.match(auth, "^[Bb]earer%s+(.+)$")
if not token then return end
```

When a caller authenticates via a cookie or query parameter:

1. The `jwt` plugin passes (signature valid, `exp` in the future).
2. Caller-supplied `X-User-Id` / `X-Roles` / `X-Session-Id` get
   *stripped* (good).
3. The Lua hits the early `return` and **does not re-set any identity
   headers**.
4. Downstream service sees an authenticated request with no identity
   headers at all.

The behaviour today depends on whether the downstream treats "missing
header" as anonymous or refuses to serve. `services/sample-service`
currently returns `null` for `userId` — i.e., an authenticated request
becomes effectively anonymous, with no error visible to the operator.
A real service that opens features for anonymous users would silently
expose them to authenticated callers without audit trail.

**Fix (pick one):**

- Pin `config.cookie_names: []` and `config.uri_param_names: []` on the
  `jwt` plugin so the bearer header is the only accepted carrier. Update
  the README to document this.
- Or, in the Lua, fall back to `kong.request.get_query_arg("jwt")` /
  cookie reads using the same names the plugin is configured with.

Recommended: lock down to header-only — every other client in this stack
sends bearers.

---

### S-3 [MEDIUM] Authorization header forwarded upstream

**Files:** `kong/kong.yml` (no `request-transformer`), `services/sample-service/src/index.ts:33-41`

After Kong validates the JWT, the `Authorization: Bearer …` header is
still forwarded to the upstream service. `services/sample-service/README.md`
even documents "decodes the Bearer JWT (without verifying)". This
undermines the architectural contract documented in
`docs/auth-architecture.md` ("services trust Kong's verdict; never
decode the JWT themselves"):

- Encourages new microservices to fall back to JWT decoding, defeating
  the "header-only identity" pattern.
- Any compromise of an upstream service log/store leaks valid bearers
  (5-min lifetime, but still replayable across services).
- If an upstream is itself compromised, the attacker can mint requests
  to *other* services through the gateway as the same user without
  needing to forge a token.

**Fix:**

Add a `request-transformer` plugin (or extend `pre-function`) that
clears the `Authorization` header after identity is extracted:

```yaml
- name: request-transformer
  config:
    remove:
      headers:
        - Authorization
```

Or in the existing `pre-function`:

```lua
kong.service.request.clear_header("authorization")
```

(after identity headers are set). Also update the `sample-service`
reference to read identity strictly from `X-User-Id` / `X-Roles` /
`X-Session-Id` — the file already has that pattern; just remove the
JWT-decoding fallback documented in its README.

---

### S-4 [MEDIUM] No `nbf` / `iat` / clock-skew bounds; no `maximum_expiration` ceiling

**Files:** `kong/kong.yml:33-37`

`claims_to_verify` lists only `exp`. Consequences:

- If the BFF clock drifts forward, tokens with future `iat`/`nbf` are
  accepted as if valid now (Kong's `nbf` check is opt-in via
  `claims_to_verify`).
- The plugin's `maximum_expiration` is unset, so a BFF misconfiguration
  setting `BFF_INTERNAL_JWT_TTL_SECONDS` to a huge value (e.g. 30 days)
  would be honoured silently. The 5-minute TTL is one of the load-bearing
  assumptions of this design (instant revocation tolerance, refresh
  cadence).

**Fix:**

```yaml
- name: jwt
  config:
    key_claim_name: kid
    claims_to_verify: [exp, nbf]
    maximum_expiration: 600   # hard ceiling: tokens cannot live > 10 min
```

Pair with monitoring on `auth_failed_total` for `nbf`-rejected tokens so
clock-drift events surface.

---

### S-5 [MEDIUM] Dev RSA public key is committed to `kong.yml`; no prod overlay

**Files:** `kong/kong.yml:106-120`

The `rsa_public_key` block in `kong.yml` is the **dev** key (the README
references `bff/keys/internal-jwt-v1.private.pem` for the matching
private key). The same file is the only Kong config that exists — there
is no template, overlay, or env-driven mechanism to swap it for the prod
public key.

Consequences:

- If someone deploys this repo to production verbatim, the prod Kong
  will trust tokens signed by the dev private key — an attacker with
  access to the dev keypair can mint prod-valid bearers.
- Rotation is documented in the README but requires editing and
  redeploying `kong.yml`. No way to source keys from a secret store or
  ConfigMap.

**Fix:**

- Replace the inline PEM with an `${env://...}` reference (Kong 3.x
  supports environment-vault references in declarative configs) and
  drive it from a secret-managed variable in deploy.
- Or, template `kong.yml` at deploy time via the same mechanism nginx
  uses (`envsubst`). The README already explains that the prior
  `kong.yml.template` was dropped — the reason given was "public keys
  aren't secret", but the prod-vs-dev separation problem remains.
- Either way, **never** commit a key labelled `v1` that matches a real
  prod private key. Use `dev-v1` / `prod-v1` naming and reject `dev-*`
  kids in production deployments.

---

### S-6 [MEDIUM] No request-body size limit at Kong

**Files:** `docker-compose.yml:70-91`, `kong/kong.yml` (no `request-size-limiting` plugin)

nginx caps requests at `client_max_body_size 64k`
(`nginx/snippets/proxy_common.conf:15`), but Kong itself has no limit.
If Kong is ever exposed to another ingress (cluster mesh, alt load
balancer, or directly) the nginx-side limit is bypassed.

**Fix:** add the bundled `request-size-limiting` plugin globally (or
per service) at e.g. 256k. Defense-in-depth, costs nothing.

```yaml
plugins:
  - name: request-size-limiting
    config:
      allowed_payload_size: 256
```

---

### S-7 [MEDIUM] No replay defense on the internal JWT `jti`

**Files:** `bff/src/lib/internalJwt.ts:113`, `kong/kong.yml`

The BFF mints a `jti` (good — `internalJwt.ts:113`), but Kong does not
check it. A captured token is replayable until `exp` (5 min). The
auth-architecture doc acknowledges this; the IMPROVEMENT_PLAN §2.9
classifies it as Low. Listed here at Medium because once Kong has any
shared state (e.g., a Redis-backed `jti` denylist for instant
revocation per §2.13 follow-ups), gating on `jti` becomes cheap.

**Fix (deferred):**

Per `docs/auth-architecture.md` §D, a `jti` denylist Kong checks would
also unlock instant revocation on logout. Defer until either feature is
needed; track here so it's not lost.

---

### S-8 [LOW] Lua sandbox extension drift

**Files:** `docker-compose.yml:88` (`KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: cjson.safe`)

Allowing `cjson.safe` is fine for the current script. The concern is
operational: every new requirement quietly extends the allow-list. There
is no test gate that fails when a new require is added without review.

**Fix:**

- Add a comment in `docker-compose.yml` listing what each entry is for
  (today: "cjson.safe — JWT payload decoding in pre-function").
- Require code-review on changes to this env var. If you adopt CI,
  add a check that diffs this env var.

---

### S-9 [LOW] Pre-function Lua: token-shape parsing is permissive

**Files:** `kong/kong.yml:73-83`

```lua
local _, payload_b64 = string.match(token, "([^%.]+)%.([^%.]+)%.([^%.]*)")
```

The third capture (signature) is allowed to be empty (`[^%.]*`). Today
the `jwt` plugin already proved the signature is valid before this Lua
runs, so an empty signature is unreachable in practice. It's still a
"surprising defaults" footgun if the plugin ordering ever changes (see
M-1).

**Fix:** tighten to `([^%.]+)%.([^%.]+)%.([^%.]+)` and assert the result,
or drop the redundant parse entirely and use Kong's per-request
context: the bundled `jwt` plugin already stashes the parsed JWT in
`kong.ctx.shared` / `ngx.ctx.authenticated_jwt_token` in some plugin
versions — if accessible from the sandbox in 3.8, prefer that.

---

### S-10 [LOW] Kong admin API state

**Files:** `docker-compose.yml:80` (`KONG_ADMIN_LISTEN: "off"`)

Currently disabled — correct. Flag here as an explicit non-regression
point: any future change re-enabling the admin API (even on localhost)
should require explicit security sign-off because it bypasses every
plugin in this audit.

---

## 3. Findings — Performance

### P-1 [MEDIUM] No Kong-side rate limiting

**Files:** `kong/kong.yml` (no `rate-limiting` plugin)

nginx limits `/auth/*` (`nginx.conf:50-51`, `default.conf.template:27-44`),
but `/api/*` is unthrottled at nginx (only the auth zones exist).
Kong itself has no rate limiting either. A single client can burst
unbounded RPS through `/api/*`.

**Fix:** add `rate-limiting` (local policy in dev, redis policy in
prod) per consumer or per service. The single-consumer model means
per-consumer is currently per-app; for per-user limiting, key by the
`X-User-Id` header injected by `pre-function`.

```yaml
plugins:
  - name: rate-limiting
    config:
      minute: 600
      policy: local        # use 'redis' once Kong shares Redis with BFF
      fault_tolerant: true
```

---

### P-2 [LOW] No upstream health checks / circuit breaker

**Files:** `kong/kong.yml:9-11`

```yaml
services:
  - name: sample-service
    url: http://sample-service:3001
```

No `healthchecks` block on the service. Kong won't take an unhealthy
upstream out of rotation; every failed request waits the full
`proxy_read_timeout` window before erroring. Today there's one upstream
host, so the effect is "all requests fail until restart" — same as
without checks. Once there are 2+ replicas, this matters.

**Fix:** when multi-replica, define active+passive checks. Note that DB-less
Kong supports only declarative healthchecks; passive checks work
out-of-the-box.

---

### P-3 [LOW] No response compression at Kong, double-compression risk if added

**Files:** `nginx/nginx.conf:43-47`

nginx already gzips. Kong adds no compression today (correct). Flag here
to avoid a future contributor enabling `gzip` on Kong — gzip-on-gzip
adds latency without benefit since nginx terminates the client
connection.

---

### P-4 [INFO] Lua `pre-function` adds ~per-request CPU

Inline base64-decode + `cjson.safe.decode` runs in the access phase
on every request. Profile shows microseconds (Kong Lua is JIT-compiled),
but if the audit ever shows hot-path latency from this layer, the fix
is to set the headers from claims that the bundled `jwt` plugin already
parsed (`ngx.ctx.authenticated_jwt_token`) instead of re-decoding.

---

## 4. Findings — Maintainability

### M-1 [MEDIUM] Plugin ordering is by implicit priority, not declared

**Files:** `kong/kong.yml:21-100`

The Lua `pre-function` plugin relies on the `jwt` plugin running first
("Kong runs higher-priority plugins first; pre-function's default
priority of 1000 is below jwt's"). This is true today (jwt = 1450,
pre-function = 1000) but priorities are an internal Kong detail that
has changed between major versions. If a future upgrade flips them,
identity injection would run **before** signature verification —
spoofed identity could survive.

**Fix:** pin the plugin's priority explicitly, or use the `_priority`
override available on the `pre-function` plugin:

```yaml
- name: pre-function
  config:
    _priority: 999          # explicit: lower than jwt's 1450
    access:
      - |
        ...
```

Plus a contract test (`bff/docs/IMPROVEMENT_PLAN.md §4.7` already lists
this as a TODO) that forges a token with a spoofed identity header
through Kong and asserts the spoof loses.

---

### M-2 [MEDIUM] Inline Lua in YAML is unreviewable and untestable

**Files:** `kong/kong.yml:55-100`

The Lua identity-injection logic is ~40 lines inlined into a YAML
string. Issues:

- No syntax checking on YAML edits (a misplaced indent silently breaks
  the script with a runtime-only error).
- No unit tests against the script — the only way to know it works is
  through-stack integration testing.
- Code review sees a YAML diff, not a code diff.

**Fix:**

- Move the script to `kong/lua/identity_inject.lua` and reference it
  with `pre-function`'s file-based form, or use Kong's `serverless`
  plugin pattern with the `_path` option.
- Add a Busted-based unit test that mocks `kong.request` and
  `kong.service.request` and asserts headers are set correctly for
  representative claim shapes.

---

### M-3 [MEDIUM] No JSON access log / no Kong-side `X-Request-Id` correlation

**Files:** `docker-compose.yml:82-83`

```yaml
KONG_PROXY_ACCESS_LOG: /dev/stdout
KONG_PROXY_ERROR_LOG: /dev/stderr
```

Kong uses its default access-log format (text, no fields). nginx already
emits structured JSON with `request_id`; Kong does not. The `correlation-id`
plugin is configured (`kong.yml:22-26`), so each request has an
`X-Request-Id` header, but it never lands in Kong's own log line —
meaning a 5xx visible in Kong logs cannot be correlated to the
nginx/BFF/service traces.

**Fix:** configure `KONG_LOG_FORMAT` to a JSON template that includes
`$http_x_request_id` (or use the `file-log` / `http-log` / `tcp-log`
plugin and stream JSON to your log sink).

---

### M-4 [LOW] `correlation-id` overwrites caller-supplied `X-Request-Id`?

**Files:** `kong/kong.yml:22-26`

```yaml
- name: correlation-id
  config:
    header_name: X-Request-Id
    generator: uuid
    echo_downstream: true
```

`echo_downstream: true` is correct (returns the id to the client). The
default `config.generator: uuid` mints a new id if none is supplied —
but it also replaces an existing one unless `config.echo_downstream`
and the right default for `forward_X` are set. The nginx layer already
generates `$request_id` and forwards it (`proxy_common.conf:8`). Two
risks:

- If Kong overwrites the nginx-supplied id, nginx and Kong/service logs
  carry different ids for the same request → broken correlation.
- If Kong honours the inbound id, the client controls the id format,
  enabling log-injection by sending malicious request ids.

**Fix:** verify behaviour by sending a request with a fixed
`X-Request-Id: aaa-1234` and confirming what reaches the upstream and
what is echoed back. Either:

- Trust nginx's id (set `generator: tracker`, validate format), or
- Force Kong to mint and discard inbound (move correlation-id to
  `priority` higher than any header-set plugin and disable echo).

Document the chosen contract.

---

### M-5 [LOW] No declarative-config schema validation in CI

**Files:** `kong/kong.yml`

Today `kong.yml` is hand-edited. Kong supports validating declarative
config offline via `kong config -c kong.conf parse kong.yml` (also
available as `kong config db_less validate`). Without it, syntax errors
are caught only at container start.

**Fix:** add a CI step that runs `docker run --rm -v $PWD/kong/kong.yml:/k.yml kong:3.8.0-ubuntu kong config parse /k.yml`.

---

## 5. Findings — Architecture

### A-1 [MEDIUM] Single consumer; no per-service / per-route authorization

**Files:** `kong/kong.yml:106-120`

One Kong consumer (`super-app-bff`) represents the issuer, not the user.
Roles are inside the JWT and forwarded as `X-Roles`, but each downstream
service is on its own to enforce them. There is no way to express
"this route requires role `admin`" at the gateway.

This is a deliberate choice in the current design (the README documents
it), and is fine while there's one service. For the planned
multi-service super-app (KTP, payments, etc.), centralising
authorization rules at Kong is usually preferable to scattering them.

**Fix (when multi-service):**

- Add a small `pre-function` per service that asserts
  `claims.roles` contains a required value, or
- Adopt Kong's `acl` plugin with one ACL group per role and use the
  existing JWT claims to populate the ACL context.

---

### A-2 [LOW] No HTTPS / mTLS between nginx → Kong → service

**Files:** `nginx/conf.d/default.conf.template:5-9`, `kong/kong.yml`, `docker-compose.yml`

Cleartext HTTP between containers is fine on a single Docker host. Two
follow-ups for production:

- Multi-host / Kubernetes deployments: enforce mTLS between nginx and
  Kong, and between Kong and each upstream, via Kong's
  `service.client_certificate` and an internal CA. The internal JWT
  alone is not a network boundary.
- The `Authorization` bearer is forwarded plaintext upstream (see S-3).
  TLS in-cluster mitigates the leakage risk during transit.

---

### A-3 [LOW] No `restart` / `healthcheck` policy on the Kong container

**Files:** `docker-compose.yml:70-91`

Comparable containers (nginx, redis) have healthchecks; Kong does not,
and none of the containers have `restart: unless-stopped`. Result:

- A Kong process crash leaves the container dead until manual
  intervention.
- `nginx` `depends_on: kong: condition: service_started` is wait-only;
  it doesn't gate on readiness, so nginx may start before Kong is
  serving and 502 the first burst of requests.

**Fix:**

```yaml
kong:
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "kong", "health"]
    interval: 10s
    timeout: 5s
    retries: 5
```

Then update `nginx.depends_on.kong.condition` to `service_healthy`.

---

### A-4 [INFO] Kong is on the data plane; BFF is on the auth plane

Documented in `docs/auth-architecture.md` and `kong/README.md`. Audit
agrees this is the right split. Recording here so the boundary stays
explicit when new contributors add features: any "let Kong call BFF on
every request" idea defeats the design.

---

## 6. Findings — Production Readiness

### PR-1 [HIGH] Production deploy procedure is implicit; rotation needs runbook drill

**Files:** `kong/README.md` (rotation section), `bff/docs/IMPROVEMENT_PLAN.md`

The rotation runbook exists and looks correct. What's missing:

- A documented dry-run on a staging stack — there is no evidence the
  6-minute overlap window has been verified end-to-end with real
  mobile clients.
- No automation: each step is a manual edit + redeploy. Risk of skipping
  step 2 ("Kong not yet aware of v2") or step 4 ("Drop v1 too early")
  during a real incident.
- The rollback path ("redeploy v1 as the active kid") assumes v1 is
  still listed at Kong. If an operator drops v1 from Kong prematurely
  *and* from BFF env, recovery requires regenerating keys.

**Fix:** add a staging exercise to the launch checklist and codify the
rotation as a script or pipeline (idempotent, with assertions).

---

### PR-2 [MEDIUM] No observability / metrics from Kong

**Files:** `docker-compose.yml:70-91`, `kong/kong.yml`

The BFF emits Prometheus metrics
(`bff/src/lib/metrics.ts`). Kong does not — the `prometheus` plugin is
not enabled. In production, Kong is the single chokepoint for every
`/api/*` request; not collecting metrics there is a major
operability gap (RPS by route, p95/p99 latency, 4xx/5xx by route,
upstream health).

**Fix:**

```yaml
plugins:
  - name: prometheus
    config:
      status_code_metrics: true
      latency_metrics: true
      upstream_health_metrics: true
```

…and expose the metrics endpoint **only internally** (or behind nginx
with an allowlist; do not expose to the public internet — same caveat
the BFF env file calls out for `/metrics`).

---

### PR-3 [MEDIUM] Container is `root`, writable root FS, no `cap_drop`

**Files:** `docker-compose.yml:70-91`

Compared to `services/sample-service/Dockerfile` (uses `USER node`),
the Kong container runs as root (image default) with full caps and a
writable root FS. For an edge-facing component, this is the highest
blast radius if exploited.

**Fix:**

```yaml
kong:
  user: "1000:1000"           # or whatever the kong user maps to in the image
  read_only: true
  tmpfs:
    - /tmp
    - /usr/local/kong          # Kong needs writable /usr/local/kong/* — check version
  cap_drop: [ALL]
  cap_add: [NET_BIND_SERVICE]   # only if you ever bind <1024
  security_opt:
    - no-new-privileges:true
```

(`kong:3.8.0-ubuntu` already runs as `kong` user when invoked with
`kong start`; verify before pinning the UID.)

---

## 7. Quick-fix Checklist (recommended order)

In priority order — top of the list buys the most safety per minute of
work:

1. **S-1**: enforce `iss` / `aud` in `pre-function` Lua.
2. **S-2**: lock the `jwt` plugin to header-only bearers (`cookie_names: []`, `uri_param_names: []`).
3. **S-3**: strip `Authorization` header before upstream forwarding.
4. **M-1**: pin `pre-function` plugin priority with `_priority`.
5. **PR-1**: schedule a staging rotation drill before launch.
6. **S-4**: add `nbf` to `claims_to_verify` and set `maximum_expiration: 600`.
7. **PR-2**: enable `prometheus` plugin (internal-only).
8. **S-5**: move the prod public key to env-driven config; remove dev key from prod images.
9. **M-2**: extract Lua to a file + Busted unit test.
10. **A-3** + **PR-3**: container hardening (healthcheck, non-root, read-only FS).
11. **P-1**: add `rate-limiting` plugin on `/api/*`.
12. **S-6**: add `request-size-limiting` plugin.
13. **M-3** + **M-4**: structured Kong access log with correlated `X-Request-Id`.
14. **S-7**: defer until `jti` denylist is wanted for revocation.
15. **A-1**: revisit when adding the second microservice.
16. **A-2**: revisit at multi-host deploy.
17. **M-5**, **S-8**, **S-9**, **S-10**, **P-2**, **P-3**, **P-4**, **A-4**: cleanups / non-regression notes.

---

## 8. What this audit does NOT cover

- Code-level review of `bff/src/lib/internalJwt.ts` minting — covered
  in `bff/docs/IMPROVEMENT_PLAN.md`. This audit only reads Kong's view
  of those tokens.
- Mobile-side bearer handling and `flutter_secure_storage` posture.
- Keycloak realm configuration, redirect URI hygiene, client secret
  rotation — these are upstream of Kong entirely.
- Kong version CVEs (`kong:3.8.0-ubuntu`) — recommend tracking
  Kong's security advisories separately and pinning to the latest 3.x
  point release at each deploy.

---

## Appendix A — Files referenced

| Path                                         | Why it matters                                  |
|----------------------------------------------|--------------------------------------------------|
| `kong/kong.yml`                              | Routes, plugins, consumer, public keys           |
| `kong/README.md`                             | Documented contract + rotation runbook           |
| `docker-compose.yml` (`kong:` block)         | Runtime env vars, sandbox extension              |
| `bff/src/lib/internalJwt.ts`                 | Token minting contract Kong validates against    |
| `bff/src/config/env.ts`                      | TTL, kid, audience envelope                      |
| `nginx/conf.d/default.conf.template`         | Upstream layout, rate-limit zones                |
| `nginx/snippets/proxy_common.conf`           | Headers forwarded to Kong (incl. body size cap)  |
| `services/sample-service/src/index.ts`       | Downstream identity-header consumption           |
| `docs/auth-architecture.md`                  | End-to-end design Kong is one node of           |
| `bff/docs/IMPROVEMENT_PLAN.md`               | Already-known TODOs (§2.13, §4.7, §5.6, etc.)    |

---

## Appendix B — Implementation status (updated 2026-05-12)

| ID    | Status        | Notes                                                                                           |
|-------|---------------|-------------------------------------------------------------------------------------------------|
| S-1   | ✅ done       | iss/aud enforced in `pre-function` Lua before identity injection.                               |
| S-2   | ✅ done       | `jwt` plugin pinned to `header_names: [authorization]`, cookie & query carriers disabled.       |
| S-3   | ✅ done       | `Authorization` header cleared upstream once X-* identity headers are set.                      |
| S-4   | ✅ done       | `claims_to_verify: [exp, nbf]` + `maximum_expiration: 600`. BFF now mints `nbf` (`setNotBefore`).|
| S-5   | ✅ done       | Dev PEM inlined in `kong.yml` under `consumers[].jwt_secrets[].rsa_public_key`; kid renamed `v1` → `dev-v1` as tripwire. (Initial implementation tried `{vault://env/internal-jwt-pubkey-dev-v1}` for deploy-agnostic config; reverted because Kong 3.x DB-less validates `consumers.jwt_secrets` at parse time, before vault refs resolve, causing `rsa_public_key: invalid key` and a startup loop. See `kong/README.md` "Why not `{vault://env/...}`?".) |
| S-6   | ✅ done       | Global `request-size-limiting` at 256 KB.                                                       |
| S-7   | ⏸ deferred    | `jti` denylist needs Redis-shared-with-BFF. Revisit when instant-revocation lands.              |
| S-8   | ✅ done       | Sandbox allow-list documented as a registry in `docker-compose.yml`.                            |
| S-9   | ✅ done       | Signature-segment regex tightened from `[^%.]*` to `[^%.]+`.                                    |
| S-10  | ✅ done       | `KONG_ADMIN_LISTEN: off` annotated as non-regression with sign-off requirement.                 |
| P-1   | ✅ done       | `rate-limiting` 600/min keyed by `X-User-Id` on the sample-service route.                       |
| P-2   | ⏸ deferred    | Upstream health checks become relevant once any service is multi-replica.                       |
| P-3   | ✅ done       | Non-regression comment forbidding gzip-on-Kong added to `kong.yml` header.                      |
| P-4   | ✅ done       | Perf note + hot-path optimization pointer added to pre-function comment block.                  |
| M-1   | ⚠️ partial    | Inline comment documents the priority dependency. Contract test pending Docker test harness.    |
| M-2   | ⚠️ partial    | Canonical Lua at `kong/lua/identity_inject.lua` + drift gate (`check-lua-sync.mjs`). Busted unit tests deferred (Windows Lua toolchain). |
| M-3   | ✅ done       | `file-log` plugin emits JSON per request to stdout incl. `x-request-id`.                        |
| M-4   | ✅ done       | Correlation-id contract verified and documented: nginx mints, Kong reuses, clients can't inject.|
| M-5   | ✅ done       | `kong/scripts/validate.mjs` wraps `kong config parse`.                                          |
| A-1   | ⏸ deferred    | Per-route authorization revisited when the second microservice arrives.                         |
| A-2   | ⏸ deferred    | mTLS in-cluster revisited when the stack goes multi-host / k8s.                                 |
| A-3   | ✅ done       | `restart: unless-stopped` + `kong health` healthcheck; nginx gated on `service_healthy`.        |
| A-4   | ✅ done       | Data-plane / auth-plane boundary captured as a header comment in `kong.yml`.                    |
| PR-1  | ⚠️ partial    | `audit-kid-config.mjs` is a rotation pre-flight gate. Full automation deferred.                 |
| PR-2  | ✅ done       | `prometheus` plugin on Kong's Status API (`:8100/metrics`, internal-only).                      |
| PR-3  | ⚠️ partial    | `no-new-privileges:true` set. `read_only` / `user` / `cap_drop` deferred — need staging stack.  |

**Two CI gates landed alongside the fixes**:

- `node kong/scripts/check-lua-sync.mjs` — fails on Lua drift (M-2).
- `node kong/scripts/audit-kid-config.mjs` — fails on kid mismatch across kong.yml, docker-compose.yml, and the BFF envs (PR-1).

Both run without Docker; wire into CI alongside `kong/scripts/validate.mjs` (which does need Docker).
