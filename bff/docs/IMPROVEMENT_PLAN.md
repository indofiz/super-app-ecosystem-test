# BFF Improvement Plan — Production Readiness, Security, Maintainability & Architecture

> Scope: `bff/` only (Express 5 + Pino + ioredis + jose + zod). Mobile is the primary client; web admin is a likely future client. Trust model is **BFF-only** — no client ever sees Keycloak or holds a refresh token.
>
> Reviewer date: 2026-05-10. Codebase commit at review time corresponds to the structure documented in `bff/README.md`.

## Changelog

- **2026-05-11 (§2.3 — KC JWT signature verification)** — `id_token` and `access_token` are now verified against KC's JWKS via `jose.createRemoteJWKSet` + `jwtVerify` instead of decoded blindly. New `src/lib/keycloakJwt.ts` exports `createKeycloakJwtVerifier({ keycloak, issuer, clientId, jwks?, metrics? })`; the production path resolves `jwks_uri` from KC discovery (1s timeout, 30s clock skew tolerance), tests inject a local JWKS via the `jwks` option. id_token also enforces `aud === KC_CLIENT_ID` and `azp === KC_CLIENT_ID` when present. All three call sites migrated: `callback.ts` verifies before persisting to `bffcode:*` (failure → deeplink `error=server_error`, no record stored); `token.ts` re-verifies on read from Redis (failure → 401 `invalid_grant`); `refresh.ts` verifies the refreshed pair and **purges the session** on failure (mirrors §5.3 semantics). `extractProfile` → async `verifyAndExtractProfile`. `src/lib/jwt.ts` deleted entirely. New `auth_failed_total` reasons: `idtoken_verify_failed`, `accesstoken_verify_failed`. New `test/helpers/fakeKc.ts` (RS256 keypair + `signKcToken` + `fakeKcJwks` + a rogue keypair for forgery tests). New `test/keycloakJwt.test.ts` (14 tests covering rogue-key, wrong-aud, wrong-iss, azp-mismatch, payload-tamper, Redis poisoning, refresh returns rogue tokens, metric increments). Total tests: 59 (was 45).
- **2026-05-10 (Phase B bundle — observability + Redis rate limiter)** — §3.5 (Redis-backed rate limiter via `rate-limit-redis`, plus a new `/auth/me` limiter keyed on `sid`) and §3.1 (prom-client `/metrics`, OpenTelemetry tracing scaffolding, real `/healthz`/`/readyz`/`/livez`) all landed. Counters are now global across replicas. KC client emits `keycloak_request_duration_seconds`. Auth handlers emit `auth_token_mint_total{kind}` and the error middleware emits `auth_failed_total{reason}`. `/metrics` is gated by `METRICS_ENABLED` (default off); tracing is gated by `TRACING_ENABLED` and bootstraps via dynamic-import in `index.ts` so auto-instrumentations patch in time. New env: `METRICS_ENABLED`, `TRACING_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `BUILD_COMMIT`, `BUILD_VERSION`. New tests: `metrics.test.ts`, `health.test.ts`, `rateLimit.test.ts`.
- **2026-05-10 (Phase A bundle)** — §2.1 (bearer required + sid binding on `/refresh` and `/logout`), §2.4 (PKCE `plain` rejected), §3.3 (process-level error handlers), §5.3 (KC `invalid_grant` purges session), and the new §2.13 (Kong injects `X-User-Id` / `X-Roles` / `X-Session-Id` from verified JWT) all landed. Mobile updated to send `Authorization: Bearer` on `/refresh` and `/logout`. Rate-limit middleware refactored to per-app factories so vitest runs don't share counters.
- **2026-05-10** — §2.2 (HS256 secret → RS256 + kid-based rotation), §2.11 (.dockerignore), and the §2.2-related parts of §4.10 (threat model + rotation runbook in `bff/README.md`) **landed**. Internal JWTs are now RS256; Kong holds public keys only; rotation is a documented overlap-window procedure. See "Status: DONE" notes in §2.2 and §2.11. The `verifyAllowingExpired` API listed under §7's `internalJwt.ts` row has also shipped — it is the prerequisite for the §2.1 fix.

---

## 0. TL;DR — Top 10 Things to Fix Before Calling This "Production-Ready"

| # | Area | Issue | Severity | Effort | Status |
|---|---|---|---|---|---|
| 1 | Security | `/auth/refresh` and `/auth/logout` accept `session_id` in body with **no bearer required** — `session_id` becomes a bearer credential. | **High** | S | **✅ done 2026-05-10** |
| 2 | Security | `BFF_INTERNAL_JWT_SECRET` is HS256 + sed-templated into `kong.yml` on container start. Symmetric secret duplicated across processes & rendered to disk. | **High** | M | **✅ done 2026-05-10** |
| 3 | Security | `id_token` is decoded **without signature verification** (`decodeJwtPayload`). Belt-and-braces: verify against KC JWKS. | Medium | S | **✅ done 2026-05-11** |
| 4 | Security | PKCE method `plain` is accepted. For mobile we should **only** allow `S256`. | Medium | XS | **✅ done 2026-05-10** |
| 5 | Production | Rate limiter uses **in-memory store**. Multi-replica deploy = limits effectively ×N. | **High** | S | **✅ done 2026-05-10** |
| 6 | Production | No `/metrics`, no tracing, `/healthz` is a constant `ok`. Nothing for SRE to alert on. | **High** | M | **✅ done 2026-05-10** |
| 7 | Production | Graceful shutdown disconnects Redis immediately and `setTimeout(1000)` is too short for K8s `terminationGracePeriodSeconds`. | Medium | S | open |
| 8 | Production | No process-level handlers for `uncaughtException` / `unhandledRejection` — silent crashes possible. | Medium | XS | **✅ done 2026-05-10** |
| 9 | Maintainability | Express request typing leaks (`(req as unknown as {id})`). Use `declare module 'express-serve-static-core'`. | Low | XS | open |
| 10 | Architecture | Stores duplicate the same JSON+TTL+`getdel` boilerplate. Extract `RedisJsonStore<T>`. | Low | S | open |

Estimates: XS<1h, S~half-day, M=1–2 days, L>2 days.

---

## 1. Architecture Snapshot (As-Is)

```
HTTP ──▶ nginx ──▶ Kong (/api, validates internal JWT) ──▶ services/*
                ╰─▶ BFF  (/auth/*)  ──▶ Keycloak  (OIDC: /authorize, /token, /logout)
                                    ──▶ Redis    (authstate, bffcode, session)
```

- `index.ts` builds env → logger → redis → keycloak client → JWT issuer → stores → app. Manual DI, all wiring in one place. Good.
- `app.ts` is a pure Express **factory**: `createApp({ env, log, redis, authDeps })`. Tests reuse it. Good.
- Layering: `handlers` (HTTP boundary) ← inject → `stores` (Redis) + `lib/keycloak` (OIDC) + `lib/internalJwt`. Clean.
- State: 100% Redis (`authstate:*`, `bffcode:*`, `session:*`). Horizontal-scale safe **except for the rate limiter** (see §3.5).
- Tokens: Keycloak's `access_token`/`refresh_token` never leave the BFF. The mobile carries an **RS256 internal JWT** (5-min default; was HS256 until §2.2 landed) + an opaque `session_id`. BFF holds the private signing key; Kong holds public keys only and selects the right one by the token's `kid` claim.

The high-level design is correct and matches the documented BFF-only stance. The remaining work is hardening the edges.

---

## 2. Security

### 2.1 [HIGH] `session_id` is currently a bearer credential on `/auth/refresh` and `/auth/logout`

> **✅ Status: DONE — 2026-05-10.** New `src/middleware/sessionAuth.ts` exposes `requireSessionBearer(issuer, mode)`; the router applies it in `allowExpired` mode (24h grace) to `/refresh` and `/logout`, and in `strict` mode to `/me`. Handlers verify `claims.sid === body.session_id` and return `401 sid_mismatch` otherwise. Mobile (`mobile/lib/features/auth/data/bff_auth_api.dart`) updated to attach `Authorization: Bearer` on both endpoints. Tests in `bff/test/auth.flow.test.ts` cover all six paths (no-bearer, sid-mismatch, malformed-bearer, expired-bearer, post-logout, idempotent).

**File:** `src/auth/handlers/refresh.ts:9-29`, `src/auth/handlers/logout.ts:7-25`

`/auth/refresh` and `/auth/logout` only validate that `session_id` exists in Redis. There is no `Authorization: Bearer <internal-jwt>` check, no binding to the caller. Anyone who exfiltrates a `session_id` (logs, screen scrape, network capture before TLS terminates internally, secure-storage compromise) can:

- mint fresh access tokens indefinitely (until session TTL expires; sliding TTL means *forever* in practice)
- log the user out

**Fix:** require a valid (possibly expired-OK) internal JWT, then verify `claims.sid === body.session_id`.

```ts
// proposed: src/middleware/sessionAuth.ts
export const requireSessionBearer = (issuer: InternalJwtIssuer): RequestHandler =>
  async (req, _res, next) => {
    try {
      const auth = req.headers.authorization ?? '';
      if (!auth.startsWith('Bearer ')) throw unauthorized('missing_bearer', 'Bearer required');
      // For /refresh we may want to accept *recently-expired* tokens. Use a
      // separate verifier path that ignores `exp` but still validates iss/aud
      // and signature. For /logout require a fully-valid token.
      const claims = await issuer.verifyAllowingExpired(token);
      (req as RequestWithClaims).claims = claims;
      next();
    } catch (e) { next(e); }
  };
```

Then in handler: `if (claims.sid !== body.session_id) throw unauthorized(...)`.

For `/logout` accept either valid or recently-expired bearer (the user is leaving anyway). For `/refresh` require either a fully-valid bearer or one that expired ≤24h ago, to allow reasonable "I came back tomorrow" UX.

### 2.2 [HIGH] HS256 internal JWT secret duplicated across BFF + Kong via templated file

> **✅ Status: DONE — 2026-05-10.** Migrated to RS256 with `kid`-based rotation. BFF holds the private key; Kong's bundled `jwt` plugin verifies via static `rsa_public_key` entries (one per `kid`) and looks up credentials by `key_claim_name: kid`. The `sed`-templated `kong.yml.template` is gone — replaced by a static, committed `kong/kong.yml`. `BFF_INTERNAL_JWT_SECRET` is gone from env, schema, and the Kong service. New: `/.well-known/jwks.json`, `npm run gen:keys` script, `verifyAllowingExpired()`, rotation runbook in `bff/README.md` and `kong/README.md`. Verified end-to-end: token signed with the dev private key → `HTTP 200` through Kong; tampered/unknown-kid/no-bearer → `HTTP 401`.
>
> Sections below are kept as historical context for **why** the migration was needed.

**Files:** `bff/src/lib/internalJwt.ts`, root `docker-compose.yml:81-89`

The BFF mints HS256, Kong's `jwt` plugin validates with the same shared secret. Today the secret is `sed`-substituted into `/tmp/kong.yml` at container start. Issues:

- Symmetric: any process holding the secret can also **mint** valid tokens. If an attacker compromises Kong (the perimeter, exposed to nginx), they forge BFF-grade tokens.
- Secret materialized to disk inside the container. Survives across `docker exec` shells, observable in process listing during start (`sed "s|...|VALUE|g"`).
- Rotation is "restart everything at once."

**Fix (recommended for v1.0):** switch to **RS256 or EdDSA** with a JWKS endpoint on the BFF.

- BFF holds the private key (mounted from a secret manager: K8s Secret, Vault, or sealed-secret).
- BFF exposes `GET /.well-known/jwks.json` (public keys only).
- Kong uses the `jwt-signer` or `openid-connect` plugin and points to the BFF JWKS.
- Rotation: add a new key with new `kid`; serve both for an overlap window; retire old.

**Fallback (if RS256 isn't possible right now):** at minimum, stop rendering the secret to a file. Use Kong's environment-vault reference or build kong.yml from a config map at deploy time, never at runtime via `sed` on the secret.

### 2.3 [MEDIUM] `id_token` accepted without signature verification

> **✅ Status: DONE — 2026-05-11.** `src/lib/keycloakJwt.ts` exports `createKeycloakJwtVerifier({ keycloak, issuer, clientId, jwks?, metrics?, clockTolerance? })` returning `{ verifyIdToken, verifyAccessToken }`. Production resolves the JWKS lazily from `disc.jwks_uri` with a 1s `timeoutDuration`; tests inject a local JWKS via `jwks` for hermetic runs. `verifyIdToken` enforces `iss`, `aud === KC_CLIENT_ID`, signature, and `azp === KC_CLIENT_ID` when present. `verifyAccessToken` enforces `iss` + signature + `exp` (no aud — KC access tokens don't carry a stable one). On failure: throws `KeycloakJwtVerificationError` and bumps `auth_failed_total{reason=idtoken_verify_failed|accesstoken_verify_failed}`. `lib/jwt.ts` deleted. Sites updated:
>
> - **`callback.ts`** — verifies id_token immediately after `exchangeCode`, BEFORE writing the bffcode record. On failure: deeplinks `error=server_error` and no Redis write. Empty-sub fallback gone — id_token must be present.
> - **`token.ts`** — `extractProfile` is now `verifyAndExtractProfile` (async). Re-verifies tokens loaded from `bffcode:*` Redis records (the §2.3 "single layer of defence" site). On failure: `401 invalid_grant`.
> - **`refresh.ts`** — verifies the refreshed token pair and **purges the session** on failure (mirrors §5.3 — upstream view of this session is broken; force re-auth).
>
> Tests: `test/keycloakJwt.test.ts` covers rogue-key, wrong-aud, wrong-iss, azp-mismatch, payload-tamper, Redis poisoning, KC-returns-rogue-on-refresh, and metric increments. All 59 tests pass after migration.

**File:** ~~`src/lib/jwt.ts`~~ (deleted), used in `src/auth/handlers/callback.ts:55-57` and `src/auth/handlers/token.ts:36-37`

The comment correctly notes "we trust the transport." That is true for the **callback** handler (we just got the token from KC over TLS in the same request). But:

- `token.ts:extractProfile()` decodes the access_token + id_token *from Redis* (after callback stored them). The trust chain still holds (we put them there), but it's a single layer of defense.
- A future refactor that loads tokens from a less-trusted place would silently inherit "decode without verify."

**Fix:** verify signature against KC JWKS (jose's `createRemoteJWKSet` + `jwtVerify`). Cache the JWKS, refresh on `kid` miss. Issue counters in metrics.

```ts
// lib/keycloak.ts
import { createRemoteJWKSet, jwtVerify } from 'jose';
const jwks = createRemoteJWKSet(new URL(disc.jwks_uri!));
const { payload } = await jwtVerify(idToken, jwks, { issuer: KC_ISSUER, audience: KC_CLIENT_ID });
```

This also kills off `lib/jwt.ts`'s unverified decoder entirely.

### 2.4 [MEDIUM] PKCE `plain` is accepted

> **✅ Status: DONE — 2026-05-10.** `PkceMethod` is now `'S256'`-only; `parsePkceMethod` throws on anything else, and the throw is caught in `authorize.ts` to return `400 invalid_request`. `verifyChallenge` lost its `method` parameter. `appChallengeMethod` removed from `AuthStateRecord` and `BffCodeRecord`.

**File:** `src/lib/pkce.ts:5-11`

`parsePkceMethod` accepts `'plain'`. RFC 7636 strongly discourages it. Mobile client supports S256 (Flutter `oauth2_client` / `flutter_appauth` both do). Reject `plain` and require `S256`.

```ts
const isValidMethod = (m: string): m is 'S256' => m === 'S256';
export const parsePkceMethod = (raw: string | undefined): 'S256' => {
  if ((raw ?? 'S256') !== 'S256') throw new Error(`Only S256 allowed`);
  return 'S256';
};
```

This also lets you simplify `verifyChallenge` — drop the `'plain'` branch.

### 2.5 [MEDIUM] No back-channel logout from Keycloak

If a user logs out elsewhere (web, kiosk), the BFF session in Redis stays alive until TTL expiry. KC supports back-channel logout (RFC 8628-adjacent). Add an endpoint:

- `POST /auth/back-channel-logout` (Keycloak-side configured), receives `logout_token`, validates against JWKS, deletes matching `session:*` rows by `sub`/`sid`.
- Maintain a `sub → [sessionId,...]` index in Redis (`SADD`/`SREM` on session create/delete) so revocation is O(1) per user.

### 2.6 [LOW] `helmet` defaults — review for API context

For a JSON-only API, default helmet is mostly inert (CSP doesn't apply). What you *do* want explicitly:

- `Strict-Transport-Security` only after you've confirmed TLS termination is at nginx (helmet enables this by default — fine).
- `X-Content-Type-Options: nosniff`.
- Disable `Cross-Origin-Resource-Policy: same-origin` if a future web client at a different origin needs to call this.

Action: explicit `helmet({ contentSecurityPolicy: false, crossOriginResourcePolicy: false })` and document why each toggle.

### 2.7 [LOW] `trust proxy: 1` is brittle

**File:** `src/app.ts:23`

`app.set('trust proxy', 1)` trusts exactly one hop. If you later add Cloudflare or another LB, X-Forwarded-For becomes spoofable and rate limiting / IP logging breaks.

**Fix:** make it env-driven. `TRUST_PROXY=loopback,linklocal,uniquelocal` or a CIDR list. Wire to `app.set('trust proxy', env.TRUST_PROXY)`.

### 2.8 [LOW] `redact.paths` may not match what you expect

**File:** `src/lib/logger.ts:8-26`

Pino redaction paths like `'*.access_token'` only match **one level deep** from the root, not "any depth." If pino-http logs a deeply nested object, those keys won't be scrubbed.

Action: write a focused test that logs `{ res: { body: { access_token: 'X' } } }` through pino-http and asserts `'X'` doesn't appear. Add explicit nested paths if the wildcard doesn't catch them.

### 2.9 [LOW] No replay protection on the internal JWT

`jti` is set but never tracked. Acceptable for short-lived (5-min) tokens, but document the assumption explicitly. If you ever raise TTL, you'll want a `jti` denylist in Redis.

### 2.10 [LOW] OIDC discovery cached forever

**File:** `src/lib/keycloak.ts:33-46`

Once loaded, `this.discovery` is never refreshed. KC config changes require a BFF restart. Add a soft TTL (e.g., 1h) and a force-refresh on `404`/`410` from the token endpoint.

### 2.11 [LOW] No `.dockerignore`

> **✅ Status: DONE — 2026-05-10.** Added `bff/.dockerignore` covering the listed patterns plus `keys/` (the new RS256 key material directory introduced by §2.2). Also added `keys/` to `bff/.gitignore`.

Dockerfile copies `package.json` and `src` explicitly so this is OK today, but a future `COPY . .` will quietly suck in `.env`, `dist/`, `node_modules`. Add:

```
node_modules
dist
.env
.env.*
!.env.example
test
*.log
.git
.github
```

### 2.13 [HIGH] Kong does not inject identity headers — modules can't trust caller-supplied X-User-Id

> **✅ Status: DONE — 2026-05-10.** Closes the architectural gap between the as-built code and `superapp_internal_jwt_topology.svg` (which states "modules trust X-User-Id from Kong").

**Files:** `kong/kong.yml`, `services/sample-service/src/index.ts`, `docker-compose.yml`.

The diagram commits Kong to injecting `X-User-Id` and `X-Roles` so downstream services can read identity from headers instead of decoding JWTs themselves. The bundled `jwt` plugin doesn't do this — it only sets `X-Consumer-Username` (= `super-app-bff`, the issuer, not the end user). Without the fix, downstream services either:

- decode the JWT themselves (every new module reimplements the parser — bad), or
- treat the request as anonymous (security hole).

**Fix shipped:** added Kong's bundled `pre-function` plugin in the `access` phase (runs after `jwt` validates) which:

1. **Strips inbound `X-User-Id`, `X-Roles`, `X-Session-Id`** so a caller can't spoof them past Kong.
2. Decodes the (already-verified) JWT payload via `cjson.safe` and **re-sets** the same headers from the trusted `sub` / `roles` / `sid` claims.

`KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe` is set on the Kong service to allow the cjson require inside the sandbox. The bundled `kong.plugins.jwt.jwt_parser` is NOT used (sandbox blocks it); we re-decode the base64url payload inline since the signature is already trusted by the time pre-function runs.

The sample-service was updated (`/whoami` endpoint and the existing `/`) to read identity from headers as a reference implementation.

**Smoke-tested live:**
- Valid bearer → upstream sees the JWT-derived `userId` / `roles` / `sessionId`.
- Caller sends `X-User-Id: hax-admin` along with the bearer → upstream still sees the *real* `userId` (spoof stripped, JWT claim wins).
- No bearer → 401 from the `jwt` plugin (pre-function never runs).

### 2.12 [LOW] `.env` is present in working tree

`bff/.env` exists at the repo root (visible in `Get-ChildItem -Force`). Confirm `.gitignore` excludes it; rotate any secret that has ever been committed. (Verify with `git log --all -- bff/.env`.)

> **Partial as of 2026-05-10.** As a side effect of §2.2 landing, the old HS256 `BFF_INTERNAL_JWT_SECRET` is no longer in any `.env` file (replaced by RS256 key material). The action item that remains: confirm the workspace `.env` and `bff/.env` are properly gitignored and audit `git log --all` for any historical commit of the prior HS256 value — if one is found, treat the value as compromised even though it has been retired.

---

## 3. Production Readiness

### 3.1 Observability (currently: pino logs only)

> **✅ Status: DONE — 2026-05-10.** All three slices landed:
>
> - **Metrics** — `src/lib/metrics.ts` builds a dedicated `prom-client` registry; `src/middleware/metrics.ts` records `http_requests_total{route,method,status}` and `http_request_duration_seconds{route,method}` with a route allowlist (cardinality guard via `normalizeRoute()`). KC client emits `keycloak_request_duration_seconds{op,outcome}`. Auth handlers emit `auth_token_mint_total{kind=token|refresh}`. Error middleware emits `auth_failed_total{reason}`. `/metrics` is gated by `METRICS_ENABLED` (default off — production must additionally block at the perimeter).
> - **Tracing** — `src/observability/tracing.ts` boots `@opentelemetry/sdk-node` with OTLP exporter and `getNodeAutoInstrumentations` (fs disabled). Bootstrap sequence in `index.ts`: `loadEnv → startTracing → dynamic import('./app.js')` so http/express/axios prototypes get patched in time. Gated by `TRACING_ENABLED`. Resource attributes include `service.name`, `service.version`, `deployment.environment`, `service.commit`.
> - **Health** — `/healthz` returns `{ status, version, commit, uptime_s }`. `/readyz` adds Redis ping + KC discovery, each with a 1s timeout, 503 on failure with structured `checks` object. New `/livez` uses `perf_hooks.monitorEventLoopDelay` and returns 503 when p99 > 1000ms. See `test/health.test.ts`.

Add three things:

**Metrics.** `prom-client` exposed at `GET /metrics` (allowlisted to nginx/Prometheus only via `internal` block):

- `http_requests_total{route, method, status}`
- `http_request_duration_seconds{route, method}` (histogram)
- `keycloak_request_duration_seconds{op=discovery|exchange|refresh|end_session, outcome}`
- `redis_command_duration_seconds{cmd, outcome}`
- `auth_session_active` (gauge — sample via Redis SCAN periodically, or maintain a `cnt:sessions` counter)
- `auth_token_mint_total{kind=token|refresh}`
- `auth_failed_total{reason=invalid_state|pkce_mismatch|...}`

**Tracing.** OpenTelemetry SDK + auto-instrumentations for `http`, `express`, `ioredis`, `axios`. Send to OTLP collector. Propagate `traceparent` to Keycloak so KC traces line up if SSO is also instrumented.

**Health.** `/healthz` should remain dumb-fast (just "process is alive"). `/readyz` should additionally:

- check Redis ping (already does)
- fetch KC discovery if not yet cached (already does *implicitly*; do it explicitly with a 1s timeout so a slow KC fails ready instead of failing the next request)
- return a structured payload that includes commit SHA + version

Add a third probe: `/livez` for K8s liveness (only fails if event loop is wedged — `event-loop-lag` > 1s for 30s).

### 3.2 Graceful shutdown

**File:** `src/index.ts:47-54`

Current code:

```ts
server.close(() => log.info('http server closed'));
redis.disconnect();
setTimeout(() => process.exit(0), 1000).unref();
```

Problems:

- `server.close()` is async, but the next two lines run immediately. In-flight requests may already be in the middle of a Redis call when `disconnect()` yanks the socket → spurious 5xx during deploy.
- 1s exit budget is too tight. K8s `terminationGracePeriodSeconds` defaults 30s; we should use most of it.
- Logger is never flushed.

Fix:

```ts
const shutdown = async (signal: string) => {
  log.info({ signal }, 'shutting down');
  server.closeIdleConnections?.();          // Node 18.2+: stop accepting new
  await new Promise<void>((r) => server.close(() => r()));
  await redis.quit();                       // graceful, vs disconnect()
  await new Promise<void>((r) => log.flush(r));
  process.exit(0);
};
const force = setTimeout(() => process.exit(1), 25_000).unref();
process.on('SIGTERM', () => void shutdown('SIGTERM').finally(() => clearTimeout(force)));
process.on('SIGINT',  () => void shutdown('SIGINT'));
```

### 3.3 Process-level error handlers

Missing entirely. Add in `index.ts`:

```ts
process.on('unhandledRejection', (reason) => {
  log.fatal({ err: reason }, 'unhandledRejection');
  process.exit(1);
});
process.on('uncaughtException', (err) => {
  log.fatal({ err }, 'uncaughtException');
  process.exit(1);
});
```

### 3.4 Dockerfile

**File:** `bff/Dockerfile`

Improvements (in priority order):

1. Add `HEALTHCHECK` that hits `/readyz`.
2. Pin Node by digest, not just `node:20-alpine`. Track via Renovate/Dependabot.
3. `RUN npm ci --omit=dev` directly in the runtime stage rather than copying `node_modules` from build → smaller image, no dev deps. Or use `pnpm` with deploy mode.
4. Add `--init` (or include `tini`) so PID 1 reaps child processes and forwards signals (matters for graceful shutdown).
5. Run as non-root (already `USER node` — good).
6. Drop write permissions on `/app` (`chown -R node:node /app && chmod -R a-w /app`).
7. Set `NODE_OPTIONS=--enable-source-maps` if you keep source maps. Build currently emits them (`sourceMap: true`). Either keep + ship + decode in logs, or drop them in prod.

### 3.5 Rate limiter — swap to Redis store

> **✅ Status: DONE — 2026-05-10.** `src/middleware/rateLimit.ts` now wraps `rate-limit-redis` and the four factories (`buildAuthorizeLimiter`, `buildTokenLimiter`, `buildRefreshLimiter`, `buildMeLimiter`) all accept the `Redis` client injected through `AuthRouterDeps.redis`. Each limiter has a unique key prefix (`rl:authorize:`, `rl:token:`, `rl:refresh:`, `rl:me:`). The `/auth/me` limiter is keyed on `req.claims.sid` so per-session enumeration is bounded. Tests: `test/rateLimit.test.ts` covers (a) 11th /token call returns 429, (b) two app instances sharing a Redis instance share the counter (proves it's global), (c) different endpoints have independent counters via prefix.

**File:** `src/middleware/rateLimit.ts`

`express-rate-limit`'s default in-memory store is per-process. Two replicas → effective limit doubles per attacker IP. Use `rate-limit-redis` with the existing `Redis` client.

```ts
import RedisStore from 'rate-limit-redis';
export const buildAuthorizeLimiter = (redis: Redis) => rateLimit({
  store: new RedisStore({ sendCommand: (...args) => redis.call(...args) }),
  windowMs: 60_000, limit: 30, ...
});
```

Plumb the `redis` client into the auth router build so middleware can use it.

Add a third limiter on `/auth/me` (cheap to call but enables session enumeration): 60/min/IP, keyed on `claims.sid` if bearer is present.

### 3.6 Keycloak HTTP client hardening

**File:** `src/lib/keycloak.ts`

- 10s timeout is fine, but no retry. Add **bounded retries** for **idempotent** ops only: `getDiscovery` (3 retries, exponential backoff with jitter, max 5s total). **Never retry** `exchangeCode` or `refresh` — they're single-use upstream and a retry on a 502 might burn your code.
- Carry `x-request-id` outbound: `headers: { 'x-request-id': req.id }`. Requires plumbing the request-id through, or using `axios.create()` per-request with the header.
- Limit response size (`maxContentLength`/`maxBodyLength`) to e.g. 64 KB — KC token responses are tiny; defending against a hostile/compromised KC.
- Validate response shape with zod before trusting fields.

### 3.7 CI/CD missing

Add a `.github/workflows/bff.yml` (or whatever your CI is) with:

- `npm ci`
- `npm run typecheck && npm run lint && npm test`
- `npm audit --omit=dev --audit-level=high`
- Docker build + Trivy scan
- Optionally: `osv-scanner` for transitive deps
- Push image with semver + commit SHA tags

### 3.8 No load / soak / chaos testing

For a citizen-facing super app this is non-optional eventually. Recommend:

- **k6 script** for the auth flow (`/authorize → /callback → /token → /refresh`). Targets: P95 < 300ms at 200 RPS sustained, no error-rate above 0.1%. Include a Keycloak stub for repeatable runs.
- **Chaos**: drop Redis for 30s, confirm BFF returns 503 cleanly and recovers; same for KC.

---

## 4. Maintainability

### 4.1 Extract `RedisJsonStore<T>` to remove store boilerplate

**Files:** `src/auth/stores/{authState,bffCode,session}.store.ts`

All three stores do the same thing: namespace key → JSON serialize → `SET EX` / `GET[DEL]` → JSON deserialize. ~80% identical code. Extract:

```ts
// src/lib/redisJsonStore.ts
export class RedisJsonStore<T> {
  constructor(
    private readonly redis: Redis,
    private readonly prefix: string,
    private readonly ttlSeconds: number,
  ) {}
  private k(id: string) { return `${this.prefix}:${id}`; }
  async put(id: string, v: T): Promise<void> {
    await this.redis.set(this.k(id), JSON.stringify(v), 'EX', this.ttlSeconds);
  }
  async get(id: string): Promise<T | null> {
    const raw = await this.redis.get(this.k(id));
    return raw ? (JSON.parse(raw) as T) : null;
  }
  async take(id: string): Promise<T | null> {
    const raw = await this.redis.getdel(this.k(id));
    return raw ? (JSON.parse(raw) as T) : null;
  }
  async delete(id: string): Promise<void> { await this.redis.del(this.k(id)); }
}
```

Then `AuthStateStore = new RedisJsonStore<AuthStateRecord>(redis, 'authstate', ttl)`. Stores file shrinks to type definitions + factories. Keeps the same atomic `getdel` semantics.

### 4.2 Type the augmented Express request properly

**Files:** `src/middleware/requestId.ts:10`, `src/auth/handlers/me.ts` (if claims are added)

Currently:

```ts
(req as unknown as { id: string }).id = id;
```

Replace with module augmentation in `src/types/express.d.ts`:

```ts
import 'express';
declare module 'express-serve-static-core' {
  interface Request {
    id: string;
    claims?: InternalJwtVerifiedClaims;
  }
}
```

Add the file to `tsconfig.json` `"include"`.

### 4.3 Promote handler orchestration into a service layer (optional)

Handlers currently mix HTTP parsing + orchestration logic. As features grow, this gets harder to test in isolation. Split:

- `auth/handlers/*` → only `(req → parsed input) → service.method(input) → res`
- `auth/services/authService.ts` → orchestrates stores + Keycloak + JWT issuer, returns plain DTOs

This is a refactor for when complexity warrants it. Today the handlers are still readable; revisit when you add the second realm or social-login path.

### 4.4 Lint: tighten the ruleset

`eslint.config.mjs` has the basics. Add:

- `eslint-plugin-import` with `import/order` (group: builtin / external / parent / sibling).
- `eslint-plugin-n` for Node-specific gotchas (e.g., always specify `.js` ext in NodeNext — already convention here, lint can enforce).
- `eslint-plugin-security` for catching obvious patterns.
- `@typescript-eslint/no-floating-promises: error` — already implied by recommended? Verify; promises are everywhere here.
- `@typescript-eslint/no-misused-promises`.

Add `husky` + `lint-staged` for pre-commit lint on staged files. Optional but cheap.

### 4.5 Prettier config

`.prettierrc.json` exists — confirm it's wired into the lint command (it is via `eslint-config-prettier`). Document the rule in `README.md` under "Style".

### 4.6 Test coverage gaps

Currently strong on the happy path. Missing:

- Replay of `bff_authcode` (second `/auth/token` with same code → 401).
- Expired `authstate` (state timed out before callback).
- `redirect_uri` mismatch at `/auth/token` (consumed code, but body has wrong redirect).
- `client_id` mismatch at `/auth/token`.
- `/auth/refresh` when KC returns `invalid_grant` (refresh token revoked) — session must be cleared, not orphaned.
- `/auth/logout` idempotency (call twice).
- `/auth/me` with valid bearer but session deleted (= 401, currently).
- Rate-limit triggers (mock the limiter window or use a small window for the test).
- Env validation: missing `BFF_INTERNAL_JWT_SECRET`, secret < 32 chars.
- `decodeJwtPayload` malformed input.

Set a **coverage gate** at 80% lines / 70% branches in CI.

### 4.7 Contract test against Kong's `jwt` plugin

Kong's `jwt` plugin is an external integration. A small contract test:

- Mint an internal JWT.
- Run Kong locally with the templated config (Docker test container).
- Assert request through Kong → 200; tampered token → 401.

Catches drift in algorithm config, audience claim handling, etc.

### 4.8 OpenAPI spec

There's no machine-readable spec. Generate one from zod schemas (`zod-to-openapi`) and serve at `/openapi.json` (gated). Mobile/web SDKs can be generated from it. Ties documentation to code so it can't drift.

### 4.9 Replace `axios` with `undici` / native `fetch` (optional)

Saves ~1 dependency, identical capability for this use case. Low-priority cosmetic cleanup.

### 4.10 README updates

`README.md` is good for onboarding. Add:

- Threat model section (one paragraph: what we defend against, what we don't).
- ~~"How to rotate `BFF_INTERNAL_JWT_SECRET`" runbook.~~ Done 2026-05-10 — see "Key rotation runbook" in `bff/README.md` (and the matching one in `kong/README.md`). The rotation primitive is now a `kid` overlap window, not secret swap.
- ~~"How to revoke a session" runbook (delete `session:<sid>` key in Redis).~~ Done 2026-05-10 — see "Session revocation runbook" in `bff/README.md`.
- ~~Threat model section~~ Done 2026-05-10 — see "Threat model (short)" in `bff/README.md`.
- Link to this improvement plan.

---

## 5. Reliability / Edge Cases

### 5.1 Session sliding TTL is one-sided

**File:** `src/auth/stores/session.store.ts:36-39`

`update()` re-sets with full TTL, `get()` doesn't. Net effect: a user who gets `/auth/me`'d every minute but never refreshes the token will be evicted at 30d wallclock anyway. That may be the intent (force a refresh roundtrip every 30d) — document it.

If the intent is "active users stay forever," call `EXPIRE` in `get()` too. Trade-off: more Redis writes, less control over forced re-auth.

### 5.2 Discovery race on first request

Two concurrent first requests will both fire `getDiscovery()`. Harmless but wasteful. Wrap with a `Promise` cache:

```ts
private discoveryPromise?: Promise<OidcDiscovery>;
async getDiscovery() {
  if (this.discovery) return this.discovery;
  if (!this.discoveryPromise) this.discoveryPromise = this.loadDiscovery();
  return this.discoveryPromise;
}
```

### 5.3 Refresh failure with rotated upstream token leaves session orphaned

> **✅ Status: DONE — 2026-05-10.** `keycloak.ts` exports a typed `InvalidGrantError`; `refresh()` throws it when KC's body says `error: invalid_grant`. The `/refresh` handler catches it, calls `sessionStore.delete(session_id)`, and returns `401 invalid_session`. Subsequent calls return `401 invalid_session` from the missing-session branch — no orphaned KC retries. Test in `auth.flow.test.ts` covers both the immediate purge and the second call.


If `keycloak.refresh()` throws (e.g., KC says `invalid_grant`), the BFF currently returns 502/upstream and leaves `session:*` intact. The user can never recover — every refresh will keep failing on the dead refresh token.

Fix: catch `invalid_grant` specifically, **delete the session**, return 401 with `error: 'invalid_session'` so the client knows to re-auth from `/auth/authorize`.

### 5.4 Body parsers cover unused content types

`express.urlencoded({ extended: false })` is mounted globally but no auth handler reads `application/x-www-form-urlencoded`. Drop it or scope to specific routes. Reduces parsing surface.

### 5.5 No timeout on Express handlers

If KC hangs (its timeout is 10s, but cascading failures), the inbound HTTP request just sits there. Add a per-route timeout (e.g., `connect-timeout` or a small middleware that races with `req.setTimeout`).

### 5.6 Logout revokes refresh token but **not** outstanding internal JWTs

`/auth/logout` deletes the `session:*` row, so `/auth/me` and `/auth/refresh` will fail. But Kong's `jwt` plugin doesn't talk to Redis — it validates HS256 signature only. Result: an already-issued internal JWT remains valid at downstream services until its 5-min TTL expires.

Mitigation options:

1. Document and accept the 5-min revocation lag. Realistic for citizen apps.
2. Have Kong call a cheap "is sid alive?" plugin (`pre-function` plugin checking Redis). Adds latency.
3. Move all sensitive endpoints behind a BFF-side allowlist that re-checks `session:*` on each request. Loses the Kong/JWT decoupling benefit.

Option 1 is fine for v1 — surface this in the threat-model README.

---

## 6. Suggested Phased Roadmap

### Phase A — Security Must-Fix (1 sprint)
- ~~§2.1 require bearer on `/refresh` and `/logout`~~ — **done 2026-05-10**
- ~~§2.4 reject `plain` PKCE~~ — **done 2026-05-10**
- ~~§3.5 Redis-backed rate limiter~~ — **done 2026-05-10** *(swapped to `rate-limit-redis`; new `/auth/me` limiter)*
- §3.2 graceful shutdown
- ~~§3.3 process-level error handlers~~ — **done 2026-05-10**
- ~~§2.11 `.dockerignore`~~ — **done 2026-05-10**
- ~~§5.3 clean up session on refresh failure~~ — **done 2026-05-10**
- ~~§2.13 Kong injects identity headers~~ — **done 2026-05-10** *(new — closes diagram contract)*

### Phase B — Production Readiness (1–2 sprints)
- ~~§3.1 metrics + tracing + better health~~ — **done 2026-05-10**
- §3.6 KC client retries + outbound request-id + zod validation of responses
- §3.4 Dockerfile hardening (HEALTHCHECK, init, non-writable FS)
- §3.7 CI pipeline with audit + Trivy
- §4.6 expand test coverage + coverage gate

### Phase C — Hardening + Hygiene (1 sprint)
- ~~§2.2 RS256/EdDSA + JWKS (drops the shared-secret problem)~~ — **done 2026-05-10**
- ~~§2.3 verify id_token signature~~ — **done 2026-05-11**
- §2.5 KC back-channel logout listener
- §4.1 `RedisJsonStore<T>`
- §4.2 typed Express augmentation
- §4.4 lint tightening + husky
- §4.8 OpenAPI from zod

### Phase D — Scale + Polish
- §3.8 k6 load tests + chaos drills
- §4.7 Kong contract test
- §4.3 service-layer split (only if handler size justifies)
- §5.6 revisit revocation propagation strategy with real metrics

---

## 7. Appendix: File-Level Findings (Quick Index)

| File | Notes |
|---|---|
| `src/index.ts` | ~~Add unhandled error handlers;~~ Done 2026-05-10. Fix shutdown sequencing & timeout; flush logger before exit (still §3.2). |
| `src/app.ts` | Make `trust proxy` env-driven; explicit helmet config; drop urlencoded parser if unused; consider `app.disable('etag')` for API. ~~Mount metrics middleware + `/metrics` route + pass `keycloak`/`metrics` through `AppDeps`.~~ Done 2026-05-10 (§3.1). |
| `src/health/router.ts` | ~~`/healthz` returns just `{status:'ok'}`; replace with version+commit, add `/readyz` (Redis + KC discovery, 1s timeout each), add `/livez` (event-loop p99).~~ Done 2026-05-10 (§3.1). Signature is now `buildHealthRouter({ redis, keycloak, env })`. |
| `src/lib/metrics.ts` | NEW 2026-05-10 (§3.1). `buildMetrics()` returns a `MetricsBundle` with a dedicated `Registry` and the http/KC/auth counters. `normalizeRoute()` collapses unknown routes to `'other'` to bound cardinality. |
| `src/middleware/metrics.ts` | NEW 2026-05-10 (§3.1). Records `http_requests_total` + `http_request_duration_seconds` on `res.finish`. |
| `src/observability/tracing.ts` | NEW 2026-05-10 (§3.1). `startTracing(env)` boots `@opentelemetry/sdk-node` with auto-instrumentations + OTLP exporter. Idempotent. `index.ts` calls it before dynamic-importing `app.js`. |
| `src/config/env.ts` | Add `TRUST_PROXY`. ~~Add `OTEL_*`, `METRICS_ENABLED`.~~ Done 2026-05-10 (§3.1) — `METRICS_ENABLED`, `TRACING_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `BUILD_COMMIT`, `BUILD_VERSION`. ~~Validate `BFF_INTERNAL_JWT_SECRET` entropy with a stronger heuristic if HS256 stays.~~ HS256 retired in §2.2 — the schema now parses `BFF_INTERNAL_JWT_PRIVATE_KEY` (base64 PKCS#8) and `BFF_INTERNAL_JWT_PUBLIC_KEYS` (JSON of `{kid, pem}`) and cross-checks `ACTIVE_KID`. |
| `src/auth/router.ts` | ~~Apply session-bearer middleware to `/refresh` and `/logout`.~~ Done 2026-05-10. ~~Inject Redis to allow Redis-backed rate limiters.~~ Done 2026-05-10 — `AuthRouterDeps.redis` now injects the client; all four limiters (`/authorize`, `/token`, `/refresh`, `/me`) use `rate-limit-redis`. Optional `metrics` field threads counters into handlers. |
| `src/auth/handlers/authorize.ts` | OK overall. Consider stricter scope allowlist (env-driven) instead of free-form passthrough. |
| `src/auth/handlers/callback.ts` | ~~Verify id_token signature before reading sub.~~ Done 2026-05-11 (§2.3) — `keycloakJwtVerifier.verifyIdToken()` runs before the bffcode store write; failure → deeplink `error=server_error`, no Redis write. ~~Drop empty-sub fallback.~~ Done 2026-05-11. Failsafe error redirect if `appRedirectUri` parsing fails. |
| `src/auth/handlers/token.ts` | Move PKCE check before client_id/redirect_uri checks (cheaper to fail fast on signature, but order is fine either way). ~~Drop the empty-sub fallback path.~~ Done 2026-05-11. Bumps `auth_token_mint_total{kind=token}` on success path 2026-05-10 (§3.1). ~~`extractProfile` re-verifies tokens loaded from Redis~~ — `verifyAndExtractProfile` 2026-05-11 (§2.3); failure → `401 invalid_grant`. |
| `src/auth/handlers/refresh.ts` | ~~Require bearer + sid match; on KC invalid_grant, purge session.~~ Done 2026-05-10. Bumps `auth_token_mint_total{kind=refresh}` on success path 2026-05-10 (§3.1). ~~Verify refreshed tokens before extracting profile.~~ Done 2026-05-11 (§2.3) — failure also purges the session and returns `401 invalid_session`. |
| `src/auth/handlers/logout.ts` | ~~Require bearer + sid match;~~ Done 2026-05-10. Tolerate missing session (already 204 idempotent). |
| `src/auth/handlers/me.ts` | ~~Add a per-IP/per-sid rate limit.~~ Done 2026-05-10 (§3.5) — `buildMeLimiter` keys on `req.claims.sid`, 60/min. Consider returning a stable etag if profile is in-cache to allow HTTP-level caching by clients. |
| `src/auth/stores/*` | Extract `RedisJsonStore<T>`. `appChallengeMethod` field removed from `AuthStateRecord`/`BffCodeRecord` 2026-05-10 (§2.4). |
| `src/lib/keycloak.ts` | Retry discovery with jitter; outbound request-id; zod-validate responses; cap response size; soft-TTL the discovery cache. ~~Surface `invalid_grant` as a typed error so callers can purge sessions.~~ Done 2026-05-10 (§5.3) — exports `InvalidGrantError`. ~~Instrument with `keycloak_request_duration_seconds`.~~ Done 2026-05-10 (§3.1) — `time(op, fn)` wrapper, `outcome` label distinguishes ok / invalid_grant / error. |
| `src/middleware/error.ts` | Include `requestId` in the error response body for support correlation. Hide error_description in production for 5xx; map a stable `code` instead. ~~Bump `auth_failed_total{reason}` on 4xx with allowlisted reasons.~~ Done 2026-05-10 (§3.1). |
| `src/lib/internalJwt.ts` | ~~Plan move to RS256/EdDSA + JWKS endpoint. Add `verifyAllowingExpired` for logout/refresh-grace flows.~~ **Done 2026-05-10.** Async factory `InternalJwtIssuer.create({...})`; signs RS256 with `kid` in header+payload; verifies by selecting the public key for the token's `kid`; exposes `getJwks()` (served at `/.well-known/jwks.json` via `src/wellKnown/router.ts`); `verifyAllowingExpired()` available for §2.1. |
| ~~`src/lib/jwt.ts`~~ | ~~Delete once §2.3 lands and replace with verified jose path.~~ **Deleted 2026-05-11** (§2.3). Replaced by `src/lib/keycloakJwt.ts`. |
| `src/lib/keycloakJwt.ts` | NEW 2026-05-11 (§2.3). Exports `createKeycloakJwtVerifier(...)`, `KeycloakJwtVerificationError`. Lazy-resolves JWKS from KC discovery, 1s timeout, 30s clock tolerance. Test-mode injection via `jwks` option. |
| `src/lib/logger.ts` | Add explicit nested redact paths or write a redaction test. |
| `src/lib/pkce.ts` | Drop `plain`. |
| `src/lib/redis.ts` | Tune `connectTimeout`, `keepAlive`, `reconnectOnError` for known transient errors; consider `tls` settings when KC sits behind managed Redis (Memorystore/ElastiCache). |
| `src/middleware/rateLimit.ts` | ~~Redis store; build dynamically with `redis` injected.~~ Done 2026-05-10. All factories take `(redis: Redis)` and instantiate `rate-limit-redis` `RedisStore` with per-limiter prefixes. New `buildMeLimiter` is keyed on `req.claims.sid`. |
| `src/middleware/sessionAuth.ts` | NEW 2026-05-10 (§2.1). Exports `requireSessionBearer(issuer, mode)`. Mode `strict` for `/me`, `allowExpired` (24h grace) for `/refresh` and `/logout`. |
| `src/middleware/requestId.ts` | Validate inbound id (UUID-ish) — never echo arbitrary user-supplied header values into logs/responses. |
| `Dockerfile` | HEALTHCHECK, init, install with `--omit=dev` directly in runtime stage, drop write perms. |
| `docker-compose.yml` (root) | ~~Stop sed-templating the secret; use Kong env vault or a config-map step.~~ **Done 2026-05-10.** `sed` entrypoint removed; Kong service no longer takes any JWT secret env var; `kong/kong.yml` is mounted directly read-only. |
| `test/` | Add the gaps in §4.6; add a coverage gate. |

---

*Generated 2026-05-10. Owner: BFF maintainers. Review cadence: quarterly, or after any incident touching auth/session/Redis.*
