# Authentication Architecture

How the super-app handles identity end-to-end: the BFF mints short-lived
internal JWTs after authenticating a user against Keycloak, and Kong
validates those internal tokens on every API call. Mobile and downstream
services never see Keycloak tokens directly.

> **Looking for register / OTP / NIK / WhatsApp verify / reset
> password?** Those are *pre-login* ceremonies and live in their own
> doc: [`registration-and-verification.md`](registration-and-verification.md).
> This doc covers only the steady-state login/refresh/logout loop and
> the internal-JWT token model.

> **Diagrams.** This document is the prose version. The canonical visuals
> live in [`diagrams/`](diagrams/) — see
> [`flow-login.svg`](diagrams/flow-login.svg),
> [`flow-refresh.svg`](diagrams/flow-refresh.svg),
> [`flow-logout.svg`](diagrams/flow-logout.svg),
> [`flow-data-plane-request.svg`](diagrams/flow-data-plane-request.svg),
> [`internal-jwt-lifecycle.svg`](diagrams/internal-jwt-lifecycle.svg), and
> [`trust-boundaries.svg`](diagrams/trust-boundaries.svg). The root
> [`README.md`](../README.md) embeds them in narrative order.

---

## TL;DR — does every request go through the BFF?

**No.** The BFF is the *auth boundary*; it only handles auth ceremony.
Once authenticated, mobile holds a short-lived internal JWT that Kong can
validate on its own. Every business API call goes mobile → nginx → Kong
→ service, with the BFF off the hot path.

| Operation                              | Frequency             | Touches BFF? |
|----------------------------------------|-----------------------|:-------------:|
| Login                                  | once per session      | **Yes**       |
| Refresh internal JWT                   | every ~5 min          | **Yes**       |
| Logout                                 | once                  | **Yes**       |
| `GET /api/profile`, `POST /api/...` …  | every user action     | **No**        |

---

## Mental model: two planes

```
╔══════════════════ AUTH PLANE (rare) ══════════════════╗
║                                                         ║
║   mobile ──► nginx ──► BFF ──► Keycloak                ║
║                         │                               ║
║                         ▼                               ║
║                       Redis  (long-lived refresh tokens)║
║                                                         ║
║   used for: login, refresh, logout                     ║
╚═════════════════════════════════════════════════════════╝

╔══════════════ DATA PLANE (every request) ════════════════╗
║                                                            ║
║   mobile ──► nginx ──► Kong ──► sample-service             ║
║                         │                                  ║
║                         └─ validates internal JWT          ║
║                            (Kong's bundled `jwt` plugin,   ║
║                            RS256; BFF holds private key,   ║
║                            Kong holds public PEM by kid)   ║
║                                                            ║
║   used for: every business request                         ║
╚════════════════════════════════════════════════════════════╝
```

- **Auth plane** centralizes complexity: PKCE, OAuth2, Redis sessions, Keycloak
  discovery, refresh-token rotation. Lives entirely in the BFF.
- **Data plane** is intentionally simple: validate signature, forward the
  request. Microservices never call Keycloak; they trust Kong's verdict.

This is how super-apps scale to many services without each service having to
re-implement auth.

---

## Token model

Two JWTs exist in this system:

### 1. Keycloak access_token (issued by Keycloak)
- Issuer: `https://sso.pangkalpinangkota.go.id/realms/pangkalpinang`
- Algorithm: RS256 (key rotated periodically by Keycloak)
- **Stays inside the BFF.** Mobile never sees it. Services never see it.
- The BFF receives it once during login, uses it to extract the user's
  identity and roles, then discards it. The `refresh_token` is stored in
  Redis keyed by `session_id`.

### 2. Internal JWT (issued by the BFF)
- Issuer: `super-app-bff` (configurable via `BFF_INTERNAL_JWT_ISSUER`)
- Audience: `super-app-services` (configurable via `BFF_INTERNAL_JWT_AUDIENCE`)
- Algorithm: **RS256 (asymmetric)**. The BFF holds the PKCS#8 private key in
  process env (`BFF_INTERNAL_JWT_PRIVATE_KEY`); Kong holds only the matching
  SPKI public PEM keyed by `kid` (`jwt_secrets[].rsa_public_key` in
  `kong/kong.yml`). **Kong cannot mint tokens — compromise of the gateway
  does not give an attacker the ability to forge user identity.**
- Short-lived: **5 minutes** (`BFF_INTERNAL_JWT_TTL_SECONDS`).
- This is what mobile holds and sends as `Authorization: Bearer …`.

Sample header:

```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "dev-v1"
}
```

Sample payload:

```json
{
  "iss": "super-app-bff",
  "aud": "super-app-services",
  "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "sid": "abc123…opaque…",
  "username": "andi.permana",
  "email": "andi@pangkalpinangkota.go.id",
  "roles": ["citizen", "verified"],
  "iat": 1746788400,
  "nbf": 1746788400,
  "exp": 1746788700,
  "jti": "uuid-for-replay-defense",
  "kid": "dev-v1"
}
```

You own this schema. Add `tenant_id`, drop fields services shouldn't see, map
Keycloak roles into your own role taxonomy — all in the BFF.

> **Why `kid` appears in both the header and the payload.** Kong's bundled
> `jwt` plugin looks up the consumer credential by a **payload claim**
> (configured `key_claim_name: kid` in `kong/kong.yml`), not by the JOSE
> header. The BFF therefore stamps the `kid` into both places so that
> standard JOSE libraries and Kong's lookup both work without a custom
> plugin. See [`diagrams/internal-jwt-lifecycle.svg`](diagrams/internal-jwt-lifecycle.svg).

---

## Flows

### A. Login (once per session)

```
mobile          nginx          BFF              Redis        Keycloak
  │               │             │                 │              │
  │  GET /auth/authorize?code_challenge=APPCH&state=APPS         │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │ store {APPCH,…} │              │
  │               │             │ ───────────────►│              │
  │               │             │                 │              │
  │ ◄────────── 302 to Keycloak login URL ───────│              │
  │                                                                │
  │ (browser → Keycloak: user enters credentials)                  │
  │ ────────────────────────────────────────────────────────────►│
  │ ◄──── 302 to /auth/callback?code=KCCODE ─────────────────────│
  │               │             │                 │              │
  │  GET /auth/callback?code=KCCODE                              │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │  POST /token    │              │
  │               │             │ ──────────────────────────────►│
  │               │             │ ◄── KC tokens (access+refresh+id) ─
  │               │             │                 │              │
  │               │             │ extract {sub, username, email, │
  │               │             │          realm_access.roles}   │
  │               │             │                 │              │
  │               │             │ store refresh_token + profile  │
  │               │             │ ───────────────►│              │
  │               │             │                 │              │
  │ ◄────────── 302 to deeplink?code=BFFCODE ────│              │
  │               │             │                 │              │
  │  POST /auth/token { code: BFFCODE, code_verifier }           │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │ verify PKCE     │              │
  │               │             │                 │              │
  │               │             │ ★ MINT INTERNAL JWT            │
  │               │             │   payload: {sub, sid, roles, kid,…}
  │               │             │   RS256(private key, kid=active)
  │               │             │   exp: now+5min, nbf: now       │
  │               │             │                 │              │
  │ ◄─{ access_token: <internal-jwt>, expires_in: 300, session_id }
```

### B. Normal API call (the 99% case)

```
mobile          nginx           Kong              sample-service
  │               │              │                     │
  │  GET /api/profile                                  │
  │  Authorization: Bearer <internal-jwt>              │
  │ ────────────► │ ───────────► │                     │
  │               │              │ ★ jwt plugin:       │
  │               │              │   - kid → rsa_public_key lookup
  │               │              │   - RS256 signature │
  │               │              │   - exp not past, nbf not future
  │               │              │   - exp-iat ≤ 600 s │
  │               │              │ ★ pre-function:     │
  │               │              │   - strip caller X-* headers
  │               │              │   - decode payload  │
  │               │              │   - enforce iss + aud
  │               │              │   - set X-User-Id / X-Session-Id / X-Roles
  │               │              │   - CLEAR Authorization
  │               │              │                     │
  │               │              │ forward (NO bearer; trusted X-* only)
  │               │              │ ──────────────────► │
  │               │              │                     │
  │               │              │                     │ (reads X-User-Id
  │               │              │                     │  / X-Roles from
  │               │              │                     │  trusted headers;
  │               │              │                     │  never sees the JWT)
  │               │              │ ◄─── { profile JSON } 
  │ ◄─────────────│              │                     │

           BFF NEVER INVOLVED IN THIS PATH
```

### C. Refresh (every ~5 min, triggered by 401 from Kong)

The mobile auth-bloc catches the 401, calls `/auth/refresh`, then retries
the original request with the new bearer.

```
mobile          nginx          BFF              Redis        Keycloak
  │  POST /auth/refresh { session_id }            │              │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │ load session    │              │
  │               │             │ ◄───────────────│              │
  │               │             │                 │              │
  │               │             │ POST /token     │              │
  │               │             │ grant=refresh_token             │
  │               │             │ ──────────────────────────────►│
  │               │             │ ◄── new KC tokens (rotated) ──│
  │               │             │                 │              │
  │               │             │ ★ MINT NEW INTERNAL JWT        │
  │               │             │                 │              │
  │               │             │ update session  │              │
  │               │             │ (new refresh_token + profile)  │
  │               │             │ ───────────────►│              │
  │               │             │                 │              │
  │ ◄─{ access_token: <new-internal-jwt>, session_id }           │
```

### D. Logout — app-initiated

```
mobile          nginx          BFF              Redis        Keycloak
  │  POST /auth/logout { session_id }             │              │
  │  Authorization: Bearer <internal-jwt>         │              │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │ verify bearer + sid bind       │
  │               │             │ load session    │              │
  │               │             │ ◄───────────────│              │
  │               │             │ end_session (best-effort)      │
  │               │             │ ──────────────────────────────►│
  │               │             │ DEL session:SID │              │
  │               │             │ SREM userSessions:<sub> SID    │
  │               │             │ ───────────────►│              │
  │ ◄────── 204 ──│             │                 │              │
```

After logout: mobile wipes secure storage. Any in-flight internal JWT is
still technically valid until its 5-minute `exp`. Acceptable for normal
logout. For instant revocation: add a `jti` denylist Kong checks (defer
until needed).

### D'. Back-channel logout — Keycloak-initiated (OIDC)

When a user logs out elsewhere (admin force-logout, KC admin UI, another
client in the same SSO session), Keycloak POSTs a signed `logout_token`
to the BFF. The BFF verifies it against Keycloak's JWKS, then uses the
`userSessions:<sub>` Redis set as a reverse index to find and delete
every session belonging to that user.

```
Keycloak                       BFF                       Redis
  │  POST /auth/back-channel-logout                       │
  │  Content-Type: application/x-www-form-urlencoded     │
  │  logout_token=<signed JWT>                            │
  │ ────────────────────────►  │                          │
  │                            │ verify via KC JWKS       │
  │                            │ require events claim     │
  │                            │ require sub (or sid)     │
  │                            │ forbid nonce             │
  │                            │ SMEMBERS userSessions:<sub>
  │                            │ ────────────────────►    │
  │                            │ for each sid:            │
  │                            │   DEL session:sid        │
  │                            │   SREM userSessions:<sub> sid
  │                            │ ────────────────────►    │
  │ ◄─── 200 OK ───────────────│                          │
```

The `userSessions:<sub>` set exists exactly so this purge is O(k) for
one user, not O(n) SCAN over the keyspace. See
[`diagrams/redis-keyspace.svg`](diagrams/redis-keyspace.svg) and
[`diagrams/flow-logout.svg`](diagrams/flow-logout.svg).

### E. Profile fetch (`/auth/me`)

Since mobile no longer has a Keycloak `id_token`, it fetches profile data
from the BFF directly:

```
mobile           nginx          BFF              Redis
  │                │             │                 │
  │  GET /auth/me                                  │
  │  Authorization: Bearer <internal-jwt>          │
  │ ─────────────► │ ──────────► │                 │
  │                │             │ verify bearer   │
  │                │             │ → { sub, sid }  │
  │                │             │                 │
  │                │             │ load session    │
  │                │             │ ◄───────────────│
  │                │             │                 │
  │ ◄── { sub, username, email, roles, expiresAt } │
```

The session record stores a profile snapshot taken at login/refresh time.
Always fresh enough for UI; refresh cycle bounds staleness to ≤5 min.

---

## Adding a new microservice

> **Full step-by-step:** [`adding-a-service.md`](adding-a-service.md)
> covers both **authenticated** services (the common case below) and
> **public** services (no bearer required), plus validation scripts,
> smoke tests, role-check options, and a common-mistakes table.

Quick summary — to add `ktp-service` (id-card lookups), as an example:

1. Drop the service in `services/ktp-service/`. The service code reads
   identity from the trusted headers Kong injects — **never the
   `Authorization` header (Kong strips it before forwarding)** and
   never the JWT itself:
   ```ts
   const userId  = req.headers['x-user-id']     as string | undefined;
   const sid     = req.headers['x-session-id']  as string | undefined;
   const roles   = ((req.headers['x-roles'] as string | undefined) ?? '')
                     .split(',').filter(Boolean);
   ```
   See `services/sample-service/src/index.ts` for the full reference
   pattern.

2. Add to `kong/kong.yml`. Copy the `sample-service` plugin block — the
   ordering of `jwt` → `pre-function` → `rate-limiting` is load-bearing:
   ```yaml
   - name: ktp-service
     url: http://ktp-service:3002
     routes:
       - paths: [/api/ktp]
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
       - name: pre-function           # copy verbatim from sample-service —
         config: { access: [ ... ] }  # strips inbound X-*, decodes payload,
                                       # enforces iss/aud, sets X-User-Id /
                                       # X-Session-Id / X-Roles, clears
                                       # Authorization upstream.
       - name: rate-limiting
         config: { minute: 600, policy: local, limit_by: header,
                   header_name: X-User-Id, fault_tolerant: true }
   ```
   The same `super-app-bff` consumer (already declared in `kong.yml`)
   handles auth for every service — no per-service consumer needed.

3. Add the service to `docker-compose.yml`.

4. `docker compose up -d`. Done.

No service-side auth library. No JWKS handling. No Keycloak knowledge. No
JWT decoding. A new service onboards in an afternoon.

> **Per-service authorization** (e.g. "this endpoint requires the
> `verified` role) can be done in the service by reading `X-Roles`, or in
> Kong by extending the `pre-function` block with a role check. The
> identity-injection diagram
> ([`diagrams/kong-identity-injection.svg`](diagrams/kong-identity-injection.svg))
> shows the request shape on each side of Kong.

---

## Tradeoffs

| Concern | Reality |
|---|---|
| "Two tokens is more complex" | The mobile dev sees one `access_token`. Complexity lives in the BFF. |
| "Revocation isn't instant" | Up to 5 min lag (the internal JWT TTL). For normal logout, fine. For instant revocation, add a `jti` denylist Kong checks. |
| "What if BFF goes down?" | New logins fail; existing users keep working until their internal JWT expires (≤5 min). Run BFF with replicas. |
| "Can a service call Keycloak as the user?" | Not directly — only BFF has the KC token. Services that need this call BFF server-to-server. Rare. |
| "Compromise of the gateway?" | Kong holds only the public PEM. It cannot mint tokens; it can only verify them. The signing key never leaves the BFF process. |
| "Internal key rotation?" | Yearly or on suspected leak. Kong supports multiple `jwt_secrets` (kid-keyed) per consumer; rotation is zero-downtime — overlap the old and new kid for at least `TTL + grace`, then drop the old. See "Rotation procedure" below. |
| "Audit / 'who did what'?" | Internal JWT carries `sub` (Keycloak user UUID). Kong injects it as `X-User-Id` for the service. Services log with `X-User-Id` and `X-Request-Id` — correlation without raw KC tokens floating around. |

---

## Components

| Component | Role | Talks to |
|---|---|---|
| **mobile** (Flutter) | UI; holds `internal_jwt` + `session_id` in `flutter_secure_storage` | nginx |
| **nginx** | Edge reverse proxy, TLS termination (prod), rate limiting | BFF, Kong |
| **BFF** (Express + TS) | Auth ceremony: PKCE, KC handshake, mints internal JWTs, manages Redis sessions | Keycloak, Redis |
| **Redis** | Session store: `session_id → {refresh_token, profile}` | BFF |
| **Keycloak** (external) | Identity provider; issues KC access/refresh/id tokens | BFF only |
| **Kong** | Data-plane API gateway: validates internal JWTs (bundled `jwt` plugin, RS256, public PEM by `kid`), enforces `iss` / `aud` and injects `X-User-Id` / `X-Session-Id` / `X-Roles` via a `pre-function` block, strips `Authorization` before forwarding upstream | services |
| **services/** (e.g. `sample-service`) | Business logic; trusts Kong's validation | service-specific (DB, etc.) |

---

## Operational notes

- **Internal JWT TTL**: 5 minutes. Configurable via `BFF_INTERNAL_JWT_TTL_SECONDS` (capped at 30 min by env-schema; the Kong `maximum_expiration: 600` ceiling also caps this on the verify side).
- **Session TTL**: 30 days (matches Keycloak refresh_token lifetime). Slid forward on every `/auth/me` call (AUDIT §5.1).
- **Clock skew tolerance**: Kong's `jwt` plugin checks `exp` and `nbf`. The BFF stamps `nbf=iat` (`setNotBefore('0s')`) so a future-dated token from a clock-drifted BFF is caught at the gateway. `verifyAllowingExpired` on `/auth/refresh` and `/auth/logout` uses a tight 60 s `clockTolerance` on the signature path, then handles "expired within 24 h grace" explicitly.
- **Logging**: never log the JWT, only `sub` and `request_id`. The BFF's pino redaction paths already cover this; do the same in services.

- **Key management**:
  - **Dev**: a committed RSA keypair under `bff/keys/` with `kid=dev-v1`. Public PEM is **inlined directly** in `kong/kong.yml` under `consumers[].jwt_secrets[].rsa_public_key` (block scalar). The matching private key is supplied to the BFF via `BFF_INTERNAL_JWT_PRIVATE_KEY` (base64 PKCS#8 PEM). The `dev-` prefix is a tripwire — a `kid=dev-*` in a prod log is a configuration alarm.
  - **Prod**: mint a fresh keypair in the target environment (a secret manager, **not a developer laptop**) using `kid=prod-v1`. The deploy artifact ships a prod `kong.yml` with the prod public PEM inlined under that kid. The kid name appears in three files (`bff/.env`, workspace `.env`, prod `kong.yml`); a pre-flight check `node kong/scripts/audit-kid-config.mjs` reports any divergence.
  - **Why inline and not `{vault://env/...}`**: Kong 3.x DB-less validates `consumers.jwt_secrets` at config-parse time, before vault references resolve, so a `{vault://env/...}` placeholder reaches the RS256 validator as a literal string and fails as `rsa_public_key: invalid key`. Kong won't start and Compose reports `dependency failed to start: container super-app-kong is unhealthy`. Inlining sidesteps the ordering problem; the public PEM isn't a secret on either side. See `kong/README.md` "Why not `{vault://env/...}`?" for the full background.

- **Rotation procedure (zero-downtime)** — illustrated in [`diagrams/internal-jwt-lifecycle.svg`](diagrams/internal-jwt-lifecycle.svg):
  1. **Generate the new keypair.** `cd bff && npm run gen:keys dev-v2` (or `prod-v2`). Prints env-paste material for BFF and the public PEM to inline in `kong/kong.yml`.
  2. **Add the new kid at Kong, leaving the old kid in place.** Append a second entry under `consumers[].jwt_secrets` in `kong/kong.yml`, with the new public PEM inlined under `rsa_public_key: |`. Redeploy Kong (`docker compose up -d --force-recreate kong`). Kong now accepts tokens signed under **either** kid.
  3. **Cut the BFF over.** Set `BFF_INTERNAL_JWT_ACTIVE_KID=dev-v2`, swap `BFF_INTERNAL_JWT_PRIVATE_KEY` to the new private key, and append v2 to `BFF_INTERNAL_JWT_PUBLIC_KEYS` so the JWKS endpoint and verify path know both kids. Redeploy BFF. New tokens carry `kid=dev-v2`; existing v1 tokens keep verifying at Kong until they age out.
  4. **Wait `BFF_INTERNAL_JWT_TTL_SECONDS + 1 min`** (default 6 minutes). All v1-signed tokens have now expired.
  5. **Drop the old kid.** Remove v1 from `BFF_INTERNAL_JWT_PUBLIC_KEYS` and delete the v1 entry from `kong.yml`'s `jwt_secrets`. Redeploy. Done.

  Skipping step 2 → v2 tokens 401 at the gateway (Kong has no public key for that kid). Skipping step 4 → in-flight v1 tokens 401 prematurely. Run `audit-kid-config.mjs` before and after each step.
