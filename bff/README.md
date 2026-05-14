# Super App BFF

Backend for Frontend for the Pangkal Pinang super app ecosystem. Wraps Keycloak
SSO behind a session-id-based contract so client apps (Flutter, future web
admin, etc.) never see Keycloak directly and never hold a refresh token.

## Endpoints

| Method | Path                       | Purpose |
|---|---|---|
| `GET`  | `/auth/authorize`          | OAuth-shaped entry. Validates app PKCE, redirects user to Keycloak with the BFF's own PKCE pair. |
| `GET`  | `/auth/callback`           | Internal — Keycloak redirects here. BFF exchanges Keycloak `code` for tokens, mints a one-time `bff_authcode`, redirects user back to the app's deeplink. |
| `POST` | `/auth/token`              | App POSTs `code + code_verifier` → `{access_token, token_type, expires_in, scope, session_id}`. PKCE verified here. The internal JWT *is* `access_token`; Keycloak's `id_token` never leaves the BFF. |
| `POST` | `/auth/refresh`            | Header `Authorization: Bearer <jwt>` + body `{session_id}` → fresh `access_token`. Bearer's `sid` claim must match `session_id`. Accepts bearers expired ≤24h. |
| `POST` | `/auth/logout`             | Header `Authorization: Bearer <jwt>` + body `{session_id}` → invalidates Redis + Keycloak session. Same bearer/`sid` binding as `/refresh`. |
| `GET`  | `/auth/me`                 | Header `Authorization: Bearer <jwt>` (strict, no grace window) → `{sub, username, email, emailVerified, phoneNumber, phoneNumberVerified, roles, expiresAt}`. Reads the profile snapshot saved at login/refresh; bounded staleness ≤ refresh cycle. |
| `POST` | `/auth/email/send-otp`     | Sends a 6-digit OTP to the session's email via SMTP. Bearer required. `202 {delivery, expires_in}` (or `200 {verified:true}` if already verified). Per-`sub` rate-limited to 3/10min. |
| `POST` | `/auth/email/verify-otp`   | Body `{code}`. On success, sets `emailVerified=true` in Keycloak via Admin API, re-mints the internal JWT with `email_verified=true`, returns `{verified, access_token, expires_in, session_id}`. Errors: `422 otp_invalid` (with `detail.attempts_left`), `410 otp_expired` / `otp_exhausted`. |
| `POST` | `/auth/phone/send-otp`     | Body `{phone}` in `^\+62\d{8,12}$`. Sends WA OTP via Fonnte. Same response/limits as email send. |
| `POST` | `/auth/phone/verify-otp`   | Body `{phone, code}`. Phone in body must match the issued OTP's destination. Writes `phoneNumber` + `phoneNumberVerified=true` to Keycloak. Re-mints internal JWT. Same error vocabulary as email verify. |
| `GET`  | `/healthz`                 | Liveness — no I/O. Cheap; used by compose / k8s startup probes. |
| `GET`  | `/readyz`                  | Readiness — pings Redis (1s timeout) and Keycloak discovery (1s timeout). 503 on any failure. |
| `GET`  | `/livez`                   | Liveness with event-loop check. 503 if loop p99 > 1 s. |
| `GET`  | `/metrics`                 | prom-client metrics (gated by `METRICS_ENABLED`). Internal-only — never expose to the public internet. |
| `GET`  | `/.well-known/jwks.json`   | JWKS for the internal JWT public keys (so anything other than Kong can verify a BFF-minted bearer if it wants to). |

The refresh token never leaves the BFF. The app holds only `access_token` +
`session_id`.

## Auth flow

```
 App                BFF                                Keycloak
  │ /authorize?...&state=APP&code_challenge=APPCH       │
  │ ─────────────────►                                  │
  │                  │ store {APPCH, deeplink, APP} → BFFS in Redis
  │                  │ /protocol/openid-connect/auth?client_id=super-app-bff
  │                  │ &state=BFFS&code_challenge=BFFCH
  │                  │ ──────────────────────────────►  │
  │                  │ ◄────── code=KCCODE&state=BFFS ──│
  │                  │ POST /token (grant=auth_code, code_verifier=BFFCV, client_secret)
  │                  │ ──────────────────────────────►  │
  │                  │ ◄────────── tokens ──────────────│
  │                  │ store tokens → BFFCODE (single-use, 5m)
  │ ◄── deeplink?code=BFFCODE&state=APP ────            │
  │                  │                                  │
  │ POST /auth/token                                    │
  │   {code: BFFCODE, code_verifier: APPCV}             │
  │ ─────────────────►                                  │
  │                  │ verify APPCV ↔ APPCH (PKCE)
  │                  │ generate session_id, store {refresh_token, sub} in Redis
  │ ◄── {access_token, expires_in, session_id} ─────────│
```

## Run locally

```bash
cp .env.example .env       # then fill KC_CLIENT_SECRET when you have it
npm install
npm run gen:keys           # generate dev RSA keypair → bff/keys/ + paste output into .env
docker compose up -d redis # start Redis only (uses bff/docker-compose.yml)
npm run dev                # tsx watch on src/index.ts
```

Visit `http://localhost:3000/healthz` to confirm.

The full stack (nginx + BFF + Redis + Kong + sample-service) lives in the
**workspace-level** `docker-compose.yml` at the repo root:

```bash
cd ..                      # repo root
docker compose up -d --build
curl http://localhost:8080/healthz   # proxied through nginx → BFF
```

For a guided **production deployment on a single VPS** (Ubuntu LTS, real
TLS via Let's Encrypt, firewall, ops), see
[`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md).

## Test

```bash
npm test           # vitest run, in-memory Redis (ioredis-mock), Keycloak stubbed
npm run typecheck  # tsc --noEmit (src + test)
npm run lint
```

Tests cover the full happy path (`/authorize → /callback → /token → /refresh →
/logout`) plus rejection cases (unknown client, bad redirect_uri, PKCE
mismatch). No live Keycloak or Redis required.

## Environment

See `.env.example`. The non-obvious knobs:

- `ALLOWED_APP_CLIENTS` — CSV of `client_id` values the app may send. **Not** relayed to Keycloak; this is the BFF's own allowlist.
- `ALLOWED_APP_REDIRECT_URIS` — CSV exact-match allowlist for deeplink return URIs. Anything not on this list is rejected at `/auth/authorize`.
- `PUBLIC_BASE_URL` — must be reachable from the user's browser during the OAuth redirect. The BFF builds its own callback URL as `${PUBLIC_BASE_URL}/auth/callback`. Register this with Keycloak.
- `KC_SCOPES` — must include `phone` for the verification flow to read `phone_number_verified` from upstream. Default does this.
- `SMTP_USER` / `SMTP_PASS` — Gmail App Password (NOT the regular password). 2-Step Verification must be on for the sending account. See `.env.example` for the link to generate one. Leave blank in dev to log OTPs to stdout instead of mailing them.
- `FONNTE_TOKEN` — device token from https://md.fonnte.com after connecting a WhatsApp number. Leave blank in dev to log OTPs to stdout.
- `OTP_TTL_SECONDS` / `OTP_MAX_ATTEMPTS` — OTP validity window and per-OTP wrong-guess budget.

## Redis keyspace

| Key | TTL | Notes |
|---|---|---|
| `authstate:<bff_state>` | 10m | App PKCE + deeplink, generated at `/authorize`, single-use at `/callback`. |
| `bffcode:<bff_authcode>` | 5m | Tokens received from Keycloak, single-use at `/token`. |
| `session:<session_id>` | 30d | Long-lived: refresh_token, sub, profile snapshot. Rotated on `/refresh`. |
| `otp:<channel>:<sub>` | 5m | One in-flight OTP per (email\|phone, user). Plaintext code never stored — only `sha256(code:sub)`. |
| `otp:<channel>:<sub>:attempts` | 5m | Wrong-guess counter. INCR per failed verify; purged together with the record on success or exhaustion. |

## Security notes

- All `/auth/*` responses set `Cache-Control: no-store`.
- Tokens, codes, and `session_id` are redacted from pino logs.
- `helmet` defaults applied. `express-rate-limit` on `/authorize` (30/min/IP), `/token` and `/refresh` (10/min/IP). Limiters are **per-app factories** (not module-level singletons) so tests get isolated counters; multi-replica deploys still need the §3.5 Redis-backed swap to enforce real cluster-wide limits.
- `/auth/refresh`, `/auth/logout`, `/auth/me` all require `Authorization: Bearer <internal-jwt>`. `/refresh` and `/logout` additionally bind `claims.sid === body.session_id` — a leaked `session_id` alone is not enough. `/refresh` and `/logout` accept a bearer expired by up to 24h (so a returning user doesn't have to re-auth before refreshing).
- PKCE is **S256-only**. `plain` is rejected at `/auth/authorize` with `400 invalid_request`.
- Single-use codes are deleted via `GETDEL` (atomic).
- Logout is best-effort to Keycloak — the local session is always wiped even if Keycloak is unreachable.
- KC `invalid_grant` on `/auth/refresh` purges the local session and returns `401 invalid_session` so the client knows to start a fresh `/authorize` flow.
- Process-level `unhandledRejection` and `uncaughtException` handlers exit 1 and let the orchestrator restart the BFF — silent crashes are gone.

## Threat model (short)

What we defend against:

- **Compromise of the API gateway (Kong) does not let an attacker mint user tokens.** Internal JWTs are RS256 — Kong holds only the public key. The signing key never leaves the BFF process. (Was HS256-shared until §2.2 of `docs/IMPROVEMENT_PLAN.md` landed.)
- **A stolen `access_token` is bounded.** TTL is 5 minutes. Refresh requires `session_id`, which lives in Redis on the BFF side and is wiped on logout.
- **A stolen `session_id` is bounded.** It cannot be used directly against downstream services — only against `/auth/refresh` and `/auth/logout`, which are rate-limited. (Hardening to require a bearer-bound caller is tracked as §2.1.)
- **Keycloak credentials never leave the BFF.** The mobile app holds neither the Keycloak `access_token` nor `refresh_token`.

What we do *not* defend against:

- Logout has up to a 5-minute revocation lag at downstream services (Kong only checks JWT signature + exp, not Redis). Documented limitation; see IMPROVEMENT_PLAN §5.6.
- Compromise of the BFF host. The private key is in process memory; an attacker with code execution on the BFF can mint tokens.

## Internal JWT — what it looks like

Header: `{ alg: "RS256", typ: "JWT", kid: "v1" }`. Payload claims: `iss`, `aud`, `sub`, `sid`, `iat`, `exp`, `jti`, `kid`, plus optional `username`/`email`/`roles`. The `kid` appears in *both* header and payload — Kong's bundled `jwt` plugin looks it up by payload claim (`key_claim_name=kid`) to select the right RSA public key.

## Key rotation runbook

Goal: replace the active signing key with zero downtime, no failed verifications.

1. Generate v2 keypair: `npm run gen:keys v2`. This writes new PEMs to `bff/keys/` and prints env-paste material.
2. Update `kong/kong.yml` to list **both** v1 and v2 under `consumers[0].jwt_secrets`. Deploy Kong. Kong now accepts tokens signed under either kid.
3. Update BFF env:
   - `BFF_INTERNAL_JWT_ACTIVE_KID=v2` (signs with v2 going forward)
   - Append v2 to `BFF_INTERNAL_JWT_PUBLIC_KEYS` so the JWKS endpoint and verify path know about both.
   - Replace `BFF_INTERNAL_JWT_PRIVATE_KEY` with v2's private key.
   Deploy BFF.
4. Wait `BFF_INTERNAL_JWT_TTL_SECONDS + safety` (5 min + 1 min = 6 min). All v1-signed tokens have now expired.
5. Drop v1 from BFF env (`BFF_INTERNAL_JWT_PUBLIC_KEYS`) and from `kong/kong.yml`. Deploy. Done.

If you skip step 2 (Kong not yet aware of v2), v2-signed tokens will 401 at the gateway. If you skip step 4 and remove v1 too early, in-flight v1 tokens will start failing.

## Session revocation runbook

1. Find the `session_id` (in BFF logs or by `sub` if the user is authenticated and has called `/auth/me` recently).
2. `redis-cli DEL session:<session_id>` — `/auth/refresh` and `/auth/me` immediately fail.
3. Outstanding internal JWTs remain valid at Kong until their `exp` (≤5 min). For higher-stakes endpoints, gate them behind the BFF rather than Kong-only, so the session lookup runs per-request.

## Project layout

```
src/
  index.ts             bootstrap
  app.ts               express factory (composable for tests)
  config/env.ts        zod-validated env
  lib/
    redis.ts           ioredis singleton
    logger.ts          pino with token-redacting paths
    keycloak.ts        OIDC discovery + token/refresh/end-session
    pkce.ts            S256/plain verify
    ids.ts             crypto-random base64url ids
    jwt.ts             unverified JWT payload decoder (TLS-trusted only)
    internalJwt.ts     RS256 issuer (mints + verifies BFF-internal JWTs by kid)
    errors.ts          HttpError
  auth/
    stores/            authState / bffCode / session (Redis-backed)
    handlers/          authorize / callback / token / refresh / logout
    router.ts
  health/router.ts
  wellKnown/router.ts  /.well-known/jwks.json (JWKS for the internal JWT)
  middleware/          error / requestId / rateLimit
test/
  pkce.test.ts
  auth.flow.test.ts    full flow with ioredis-mock + stubbed Keycloak
```
