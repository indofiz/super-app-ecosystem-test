# Infrastructure Audit Scorecard — `super-app-ecosystem-test`

**Auditor stance:** senior infra / auth / architecture reviewer.
**Audit date:** 2026-05-14
**Scope:** `bff/`, `nginx/`, `kong/`, `docker-compose.yml`, plus cross-checks against `services/sample-service/` and the in-repo `AUDIT.md` / `IMPROVEMENT_PLAN.md` close-out tables (verified against actual code, not just claims).
**Scoring scale:** 0–10 per dimension. 5 = ships, 7 = solid, 8 = strong, 9 = excellent, 10 = world-class.

---

## 0. Executive verdict

A **well-thought-out, deliberately small auth/data-plane stack** built on a clean two-plane mental model: BFF owns OAuth + signs RS256 internal JWTs; Kong only verifies; nginx is the only public socket. The codebase shows clear evidence of *iterated* hardening — every non-trivial decision is anchored to an `AUDIT-*` finding with a "why we did this" comment. Trust boundaries match the diagrams.

**Overall: 8.3 / 10 — production-ready for a small/medium municipal deployment behind a single VPS; not yet ready for multi-region or multi-instance horizontal scale.**

| Component                    | Perf | Security | Maintainability | Prod-Ready | Observability | **Overall** |
|------------------------------|-----:|---------:|----------------:|-----------:|--------------:|------------:|
| **BFF** (Express 5 / TS)     |  8.0 | **9.2**  |             8.5 |        8.5 |           8.0 |    **8.5**  |
| **nginx** (1.27-alpine edge) |  8.0 |     9.0  |             7.5 |        8.5 |           8.0 |    **8.2**  |
| **Kong** (3.8 DB-less)       |  8.0 |     8.5  |             7.5 |        8.0 |           8.0 |    **8.0**  |

---

## 1. BFF — `bff/` — **8.5 / 10**

### Performance — 8.0
**Evidence**
- `bff/src/lib/keycloak.ts:95-105` — axios with HTTP/HTTPS keep-alive agents (`maxSockets=50`), 10s timeout, bounded response size (64 KB).
- `bff/src/lib/keycloak.ts:155-188` — **stale-while-revalidate** for OIDC discovery (1h TTL), single in-flight cold fetch (no thundering-herd).
- `bff/src/lib/keycloakJwt.ts:116` — `createRemoteJWKSet` with 1s fetch timeout; automatic JWKS rotation on `kid` mismatch (`invalidateDiscovery()`).
- `bff/src/health/router.ts:39` — `monitorEventLoopDelay` histogram for p99 wedge detection on `/livez`.

**Strengths**
- All hot paths are I/O-bounded and async; no sync crypto on every request.
- Redis used both as session store and rate-limit backplane (`bff/src/middleware/rateLimit.ts`) → counters are global across replicas.

**Gaps**
- Single Node process per container; no clustering. Sane choice for a small auth BFF, but document the scaling axis (vertical first, then horizontal via Redis-shared state — already in place).
- No connection-pool tuning hints for `ioredis` beyond defaults. Acceptable for current load.

---

### Security — 9.2 (strongest component)
**Evidence**
- **Asymmetric internal JWT (RS256)** — private key only in BFF, public PEM only in Kong (`bff/src/lib/internalJwt.ts:75`).
- **Double-PKCE**, both legs `S256`-only (`bff/src/lib/pkce.ts:9-11`); `plain` hard-rejected.
- **Single-use OAuth handshake records** via Redis `GETDEL` (`bff/src/auth/stores/redisJson.store.ts:39-42`).
- **id_token + access_token signature verification** against KC JWKS on *every* code exchange and refresh (`bff/src/lib/keycloakJwt.ts`), plus **`azp` check** (line 168) — belt-and-braces over jose's `aud` check.
- **Bearer + session_id binding** (`bff/src/middleware/sessionAuth.ts` + `auth/handlers/refresh.ts:40`) — a leaked `session_id` alone cannot refresh.
- **TTL ceilings on env** (`bff/src/config/env.ts:42-59,124`) — typo foot-guns (extra zero → 8-month session) caught at boot.
- **Generic 401s** on bearer verify failure (no oracle leakage; `sessionAuth.ts:43`).
- **Helmet + CORS + body-limit 64 KB + per-route urlencoded** (no global form parser → `auth/handlers/token.ts:35`).
- **Logger redaction list** (`bff/src/lib/logger.ts:8-39`) — explicit shapes incl. nested tokens.
- **Generic public error vocabulary** with detail kept server-side (`bff/src/lib/errors.ts` + `middleware/error.ts:23`) — defeats zod-message-echo oracles.
- **Express trust-proxy is env-driven** (`config/env.ts:73-84`) — adding a CDN hop can't silently make XFF spoofable.
- **Trust-proxy default = `loopback`** (safe), `disable('x-powered-by')`, `disable('etag')`.

**Gaps (all known/documented)**
- **No `jti` denylist** → instant revocation impossible until TTL (≤5 min). Acknowledged in `README.md:113-115`. Acceptable; revisit only if regulator demands.
- **`/metrics` route** is env-gated but relies on perimeter to block — explicitly called out at `app.ts:57-59`.
- `client_secret` lives in process env, not a vault. Fine for VPS deployment; promote to secret manager when moving to k8s.

---

### Maintainability — 8.5
**Strengths**
- **Zod-validated env** with helpful error reporting (`config/env.ts:147-162`), incl. cross-field check (active kid must exist in public keys map).
- **Generic `RedisJsonStore<T>`** base (`auth/stores/redisJson.store.ts`) — eliminates `JSON.stringify + SET EX + GETDEL` duplication and adds schema-on-read.
- **Pure factory functions** for every handler (`makeXHandler(deps)`) → trivially testable with `ioredis-mock`.
- **Strict TS, ESM, vitest, eslint + typescript-eslint**, dedicated test tsconfig.
- Every non-obvious decision is anchored to an `AUDIT-*` ID with the original reasoning. **Excellent comment-as-changelog discipline.**

**Gaps**
- Audit-ID comments are great today but will rot once audits #N+10 land — consider archiving them in CHANGELOG/ADR once audit close-out is complete.
- Two-handler symmetry (`token.ts` vs `refresh.ts`) has light duplication in profile-extraction + session-put-then-mint sequence; refactoring opportunity once a 3rd similar handler appears.

---

### Production-Readiness — 8.5
**Evidence**
- **Graceful shutdown** with bounded 25s force-exit watchdog timed below k8s default `terminationGracePeriodSeconds=30` (`bff/src/index.ts:89-118`). `unref()`'d only inside the shutdown path — won't kill a healthy process.
- **Three distinct probes**: `/healthz` (cheap), `/readyz` (Redis + KC discovery, 1s each), `/livez` (event-loop p99).
- **Dockerfile is hardened**: multi-stage build, `npm prune --omit=dev`, non-root user, `chmod a-w` on `dist`/`node_modules`, `tini` PID-1, `--enable-source-maps`, `HEALTHCHECK` baked in.
- **Per-request timeout** (`middleware/timeout.ts`) — slow upstream cleanly 504s without holding inbound socket.
- **Restart policy `unless-stopped`** on all containers.
- **Compose health dependency ordering** is correct (nginx waits for BFF + Kong `service_healthy`, not just `service_started`).

**Gaps**
- Single instance only; no readiness signal for `kid` rotation completion.
- No CI artifact for the env-paste material generated by `npm run gen:keys` — manual step.

---

### Observability — 8.0
- pino-http JSON logs + `X-Request-Id` via AsyncLocalStorage threaded into outbound KC calls.
- prom-client custom metrics: `http_requests_total`, `http_request_duration_seconds`, `keycloak_request_duration_seconds{op,outcome}`, `auth_token_mint_total{kind}`, `auth_failed_total{reason}` — **good label cardinality discipline** (route allowlist with `other` collapse, `metrics.ts:76-95`).
- OTEL tracing gated by `TRACING_ENABLED`; bootstrap is correctly placed **before** dynamic imports (`index.ts:11-17`) — a real footgun the team avoided.
- **Gap:** no Sentry-style structured error tracking; no log-sampling for high-volume `/auth/me` polling.

---

## 2. nginx — `nginx/` — **8.2 / 10**

### Performance — 8.0
**Evidence**
- `nginx.conf:1-7` — `worker_processes auto`, `worker_rlimit_nofile 65535`, `worker_connections 4096`, `multi_accept on`.
- `nginx.conf:13-15` — `sendfile`, `tcp_nopush`, `tcp_nodelay` on.
- `conf.d/default.conf.template:1-17` — `keepalive 64` + `keepalive_requests 1000` per upstream pool to both BFF and Kong.
- `nginx.conf:74-86` — gzip on with `comp_level 5` and `application/problem+json` + `application/vnd.api+json` in `gzip_types`.
- TLS overlay enables **HTTP/2** (`conf.d-tls/default.conf.template:84`).

**Gaps**
- **Upstream DNS staleness** (§P-1, deferred): nginx resolves `bff`/`kong` once at start. If a container is recreated with a new IP, traffic dies until reload. Acceptable on docker-compose with stable `container_name`s; **must** be revisited on k8s.
- No `proxy_cache` for any read-mostly endpoint (e.g., `/.well-known/jwks.json`). Cheap improvement (5-min cache) if mobile traffic grows.

---

### Security — 9.0
**Evidence**
- **`default_server 444` sink** on `:80` and `:443` (`default.conf.template:24-29`, `conf.d-tls/...:18-30`) — Host-header-spoof and unsolicited-Host traffic dropped without bytes back.
- **Slow-loris defenses**: `client_header_timeout 10s`, `client_body_timeout 10s`, `send_timeout 10s`, `reset_timedout_connection on` (`nginx.conf:21-24`).
- **Per-IP connection cap**: `limit_conn perip 32` (`nginx.conf:28`).
- **Three independent rate-limit zones** (auth_token 10r/s, auth_default 30r/s, api_default 100r/s) — `/auth/token` & `/auth/refresh` get the tighter zone via exact-match `location =` (priority over prefix).
- **`set_real_ip_from` allowlist + `real_ip_recursive`** (`nginx.conf:41-46`) — XFF spoofing fixed in advance of LB rollout.
- **OAuth `code`/`state` excluded from access logs** (`$args` intentionally omitted, line 53-69).
- **Security headers** (`snippets/security_headers.conf`): X-Content-Type-Options, X-Frame-Options DENY, Referrer-Policy no-referrer, COOP same-origin, CORP same-origin, **a thorough Permissions-Policy that disallows every powerful browser feature with `()`**.
- **TLS overlay (Mozilla Intermediate)**: TLSv1.2/1.3, OCSP stapling + `ssl_stapling_verify`, `ssl_session_tickets off`, HSTS 1y on TLS responses only, `preload` deliberately omitted.
- **`$request_id` is server-minted** via `proxy_set_header X-Request-Id $request_id` — overwrites any client value → log-poisoning impossible.
- **Body caps**: 4 MB global for `/api/*`, **tightened to 64 KB on every `/auth/*` block**.

**Gaps**
- No WAF (ModSecurity / Coraza). Not strictly required for an internal-citizen API surface, but worth considering before a public-facing launch.
- TLS ciphers list is current Mozilla Intermediate; refresh annually (no automation in repo).

---

### Maintainability — 7.5
- Two parallel templates (`conf.d/` HTTP, `conf.d-tls/` HTTPS) with duplicated `location` blocks. §M-1/M-2 deferred — acceptable but every future routing change must touch both.
- Snippets (`proxy_common.conf`, `security_headers.conf`) are nicely factored — DRY where it matters most.
- envsubst-based entrypoint (`docker-entrypoint.d/15-select-tls.envsh`) is simple and predictable.

---

### Production-Readiness — 8.5
- **ACME HTTP-01 webroot** wired into both HTTP-only and TLS overlays — renewals don't require a downtime window.
- **Healthcheck via `/readyz`** validates the full nginx → BFF → Redis/KC chain (`docker-compose.yml:47-52`).
- **nginx-prometheus-exporter** sidecar already wired (no host port).
- **`auth-access.log`** symlinked to `/dev/stdout` in Dockerfile — no log loss across container recreate.
- Cert mount `:ro` and certbot webroot as a named volume.

**Gaps**
- No in-stack renewal cron — relies on host `certbot` one-shot from `docs/DEPLOYMENT.md`. Fine for VPS; document a Cron/systemd timer in the deploy guide.

---

### Observability — 8.0
- Single JSON access log with `req_id`, `upstream_addr`, `upstream_status`, `upstream_time`, `request_time`.
- `stub_status` exposed only on internal `:8081` (Docker bridge allowlist).
- Request-ID correlation across nginx → Kong → BFF → service is solid.

---

## 3. Kong — `kong/` — **8.0 / 10**

### Performance — 8.0
**Evidence**
- **DB-less declarative mode** (`KONG_DATABASE: "off"`) — no Postgres on the hot path.
- Pre-function Lua is JIT-compiled in OpenResty; base64 + cjson decode is microseconds (acknowledged in `kong.yml:127-131`).
- **`policy: local`** rate-limiting → in-process counters, zero round-trips.
- Kong does **not** double-compress (gzip on nginx only) — explicit decision (`kong.yml:17-20`).

**Gaps**
- `policy: local` is single-instance; horizontal scaling requires switch to `policy: redis` (already noted in the in-line comment).
- JWT payload is decoded twice (once in pre-function for header injection, once in bundled `jwt` for signature verify). LuaJIT makes this cheap but it's a candidate for `kong.ctx.shared` stashing if profiling ever flags it (also noted in `kong.yml:128-131`).

---

### Security — 8.5
**Evidence**
- **`iss` and `aud` enforced in `pre-function`** (closes original §S-1 HIGH from `kong/AUDIT.md`).
- **`header_names: [authorization]` + `cookie_names: []` + `uri_param_names: []`** — bearer carrier locked to a single channel (closes §S-2 HIGH).
- **`post-function` strips `Authorization` upstream** — services never see raw bearers (closes §S-3). Note the **load-bearing comment** about why this is NOT in pre-function (would 401 every request because pre-function priority 1,000,000 runs before jwt at 1450).
- **Identity-header spoof defense**: caller-supplied `X-User-Id`/`X-Roles`/`X-Session-Id` cleared **before** any Lua trust logic runs.
- **`maximum_expiration: 600s`** + **`nbf` enforced** — caps a BFF misconfig that mints long-lived tokens, and rejects future-dated tokens from a clock-drifted BFF.
- **Admin API disabled** (`KONG_ADMIN_LISTEN: "off"`) — re-enabling bypasses every plugin; comment explicitly demands security sign-off.
- **`KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: cjson.safe`** — minimal explicit allow-list, registry kept in docker-compose comment.
- **`security_opt: no-new-privileges:true`**; full `read_only` + `cap_drop` deferred to staging validation (PR-3) — pragmatic.
- **Per-user RL keyed on freshly-injected `X-User-Id`** (priority 910 < pre-function 1,000,000) → unauthenticated traffic rejected at jwt (1450) before reaching RL.
- **`request-size-limiting` 256 KB** as a Kong-side defense in case Kong is ever fronted by something other than nginx.
- **dev-/prod-kid prefix tripwire** — `dev-*` kid surfacing in prod logs is an alarm.

**Gaps**
- **`fault_tolerant: true`** on rate-limiting → fails **open** if the local store hiccups. Defensible (availability over precision for a 600/min/user limit) but worth documenting in the runbook.
- **`iss`/`aud` are hardcoded literal strings** in the Lua. Env-driving would require extending the Lua sandbox or routing through Kong's vault API — explicit deferral noted at `kong.yml:170-175`. Acceptable.
- **No `jti` denylist** — same architectural choice as BFF.
- **No per-route RBAC**; `/api/profile` is open to any authenticated user. When real services land, expect to add `acl` plugin or claim-based authorization in-handler.

---

### Maintainability — 7.5
- **Lua mirrored** between `kong/lua/identity_inject.lua` (canonical, reviewable) and `kong.yml` (executed) — drift detected by `kong/scripts/check-lua-sync.mjs`. Smart workaround for Kong's no-file-reference limitation, but a CI step has to actually run for the gate to bite.
- **`kong/scripts/audit-kid-config.mjs`** cross-checks the four files that must agree on the active kid — excellent operational hygiene.
- Plugin priorities are explicitly enumerated in the in-line comment. **Future Kong upgrades** that shift bundled plugin priorities would break the ordering assumption silently — pin Kong version (already done at `3.8.0-ubuntu`) and re-verify on every bump.
- Long inline Lua inside YAML is the maintainability ceiling here. As the script grows, consider a custom plugin in a side-car Lua image.

---

### Production-Readiness — 8.0
- `kong health` healthcheck with `start_period: 15s` — proper readiness, not just "container exists".
- Declarative DB-less = no migration story to manage.
- `restart: unless-stopped`, `KONG_LOG_LEVEL: notice`, stdout/stderr logging.
- Single Kong instance — `policy: local` RL and inline declarative config bound us to vertical scale for now.
- **Kid-rotation runbook** documented; prod deploy artifact ships separate `kong.yml` with prod PEM inlined (intentional, not vault-resolved, because Kong 3.x validates `jwt_secrets` at parse-time **before** vault references resolve — this is a real Kong bug surface and the team correctly worked around it; see `kong.yml:302-313`).

---

### Observability — 8.0
- **`prometheus` plugin** with `status_code_metrics`, `latency_metrics`, `upstream_health_metrics` on internal `:8100`.
- **`file-log`** JSON to `/dev/stdout` — includes x-request-id, route, service, latencies.
- **`correlation-id` reuses** nginx-minted `X-Request-Id` (since pre-function/jwt cannot change that). End-to-end correlation works.

---

## 4. Cross-cutting strengths (what's unusually good)

1. **Auth-boundary discipline.** Nothing east of the BFF talks to Keycloak. Nothing west of Kong decodes JWTs. The "two-plane" mental model isn't aspirational — it's enforced by trust contracts (RS256 asymmetric key split, header-only carrier, `post-function` bearer strip, `Authorization` not forwarded).
2. **Stripped-then-set identity injection.** Kong's pre-function clears caller-supplied identity headers *before* parsing the token — closing the obvious "send `X-User-Id: admin`" attack at the gateway.
3. **Schema-validate-at-the-edge everywhere.** zod on inbound requests, zod on KC token responses, zod on Redis-stored records (schema-on-read), zod on env. Type drift surfaces at I/O boundaries rather than as deep `TypeError`s.
4. **Operational paranoia paid down.** AUDIT close-out tables in `nginx/AUDIT.md` and `kong/AUDIT.md` show **0 critical, 0 high open**. Findings are tracked, fixed, and the fixes have inline anchors to the original AUDIT IDs.
5. **The `kid` story is genuinely good.** Active kid validated against public-key map at boot, `dev-`/`prod-` prefix tripwire, audit script cross-checks four config files, JWKS publishing on the BFF, Kong looks up by kid (not iss), rotation runbook documented.

---

## 5. Top remaining risks (prioritized)

| # | Risk                                                  | Where                                       | Severity | Mitigation                                                                                       |
|---|-------------------------------------------------------|---------------------------------------------|----------|---------------------------------------------------------------------------------------------------|
| 1 | Horizontal scale will break Kong's rate limit         | `kong.yml:243-249` `policy: local`          | MEDIUM   | Switch to `policy: redis` sharing the BFF's Redis when a 2nd Kong instance is added.              |
| 2 | Upstream DNS staleness on container recreate          | `nginx/conf.d/*.template`                   | MEDIUM   | On k8s, switch to `resolver` + variable upstream, or rely on ClusterIP stability.                 |
| 3 | No `jti` denylist → revocation window = TTL           | acknowledged                                | MEDIUM   | Acceptable for citizen super-app; deferred until a compliance trigger.                            |
| 4 | `iss`/`aud` hardcoded in Lua                          | `kong.yml:175-176`                          | LOW      | Env-drive via Kong vault when extending sandbox is worth it; safe today.                          |
| 5 | Two nginx templates duplicated (HTTP/TLS)             | §M-1 deferred                               | LOW      | Extract shared `location` blocks via `include` when a third route family is added.                |
| 6 | Kong runs as root briefly (PR-3 partial)              | `docker-compose.yml:132-137`                | LOW      | Add `user:`, `read_only:`, `cap_drop: [ALL]` after staging validation.                            |
| 7 | Manual cert renewal                                   | `nginx/AUDIT.md` deploy section             | LOW      | Add a systemd timer or sidecar certbot to compose.                                                |
| 8 | No CI gate runs `check-lua-sync.mjs` / `audit-kid-config.mjs` | `kong/scripts/`                     | LOW      | Wire both into CI so drift is caught in PRs, not at deploy.                                       |

---

## 6. Recommendation

Ship to a **single-VPS production** today. Before promoting to **multi-region or horizontal scale**, close items #1 and #2 from the risk table above, and wire #8 (CI gates) so the audit-debt the team has paid down stays paid down.

The architecture is right for the problem (BFF-mediated SSO with header-only identity downstream), the implementation matches the architecture, and the audit trail is exemplary. **Few teams at this scope ship code this carefully.**
