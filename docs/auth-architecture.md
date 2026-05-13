# Authentication Architecture

How the super-app handles identity end-to-end: the BFF mints short-lived
internal JWTs after authenticating a user against Keycloak, and Kong
validates those internal tokens on every API call. Mobile and downstream
services never see Keycloak tokens directly.

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
║                            HS256, single shared secret)    ║
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
- Issuer: `super-app-bff` (configurable)
- Algorithm: HS256, signed with `BFF_INTERNAL_JWT_SECRET` (shared by BFF and Kong)
- Short-lived: **5 minutes**
- This is what mobile holds and sends as `Authorization: Bearer …`

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
  "exp": 1746788700,
  "jti": "uuid-for-replay-defense"
}
```

You own this schema. Add `tenant_id`, drop fields services shouldn't see, map
Keycloak roles into your own role taxonomy — all in the BFF.

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
  │               │             │   payload: {sub, sid, roles,…} │
  │               │             │   HS256(BFF_INTERNAL_JWT_SECRET)
  │               │             │   exp: now+5min                │
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
  │               │              │ ★ validate JWT      │
  │               │              │   - HS256 signature │
  │               │              │   - exp not in past │
  │               │              │   - iss → consumer  │
  │               │              │                     │
  │               │              │ forward (with bearer)
  │               │              │ ──────────────────► │
  │               │              │                     │
  │               │              │                     │ (decodes JWT
  │               │              │                     │  for `sub`,
  │               │              │                     │  no auth code)
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

### D. Logout

```
mobile          nginx          BFF              Redis        Keycloak
  │  POST /auth/logout { session_id }             │              │
  │ ────────────► │ ──────────► │                 │              │
  │               │             │ load session    │              │
  │               │             │ ◄───────────────│              │
  │               │             │ end_session     │              │
  │               │             │ ──────────────────────────────►│
  │               │             │ delete session  │              │
  │               │             │ ───────────────►│              │
  │ ◄────── 204 ──│             │                 │              │
```

After logout: mobile wipes secure storage. Any in-flight internal JWT is
still technically valid until its 5-minute `exp`. Acceptable for normal
logout. For instant revocation: add a `jti` denylist Kong checks (defer
until needed).

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

Steps to add `ktp-service` (id-card lookups), as an example:

1. Drop the service in `services/ktp-service/`. The service code reads
   `req.headers.authorization` and decodes the JWT for the `sub` —
   no signature verification needed (Kong did it).
2. Add to `kong/kong.yml`:
   ```yaml
   - name: ktp-service
     url: http://ktp-service:3002
     routes:
       - paths: [/api/ktp]
         strip_path: true
     plugins:
       - name: jwt
         config:
           claims_to_verify: [exp]
   ```
3. Add the service to `docker-compose.yml`.
4. `docker compose up -d`. Done.

No service-side auth library. No JWKS handling. No Keycloak knowledge.
A new service onboards in an afternoon.

---

## Tradeoffs

| Concern | Reality |
|---|---|
| "Two tokens is more complex" | The mobile dev sees one `access_token`. Complexity lives in the BFF. |
| "Revocation isn't instant" | Up to 5 min lag (the internal JWT TTL). For normal logout, fine. For instant revocation, add a `jti` denylist Kong checks. |
| "What if BFF goes down?" | New logins fail; existing users keep working until their internal JWT expires (≤5 min). Run BFF with replicas. |
| "Can a service call Keycloak as the user?" | Not directly — only BFF has the KC token. Services that need this call BFF server-to-server. Rare. |
| "Internal secret rotation?" | Yearly or on suspected leak. Kong supports multiple `jwt_secrets` per consumer; rotation is zero-downtime via `kid` in the JWT header. |
| "Audit / 'who did what'?" | Internal JWT carries `sub` (Keycloak user UUID). Services log requests with `X-User-Id`. Correlate logs without raw KC tokens floating around. |

---

## Components

| Component | Role | Talks to |
|---|---|---|
| **mobile** (Flutter) | UI; holds `internal_jwt` + `session_id` in `flutter_secure_storage` | nginx |
| **nginx** | Edge reverse proxy, TLS termination (prod), rate limiting | BFF, Kong |
| **BFF** (Express + TS) | Auth ceremony: PKCE, KC handshake, mints internal JWTs, manages Redis sessions | Keycloak, Redis |
| **Redis** | Session store: `session_id → {refresh_token, profile}` | BFF |
| **Keycloak** (external) | Identity provider; issues KC access/refresh/id tokens | BFF only |
| **Kong** | API gateway: validates internal JWTs with bundled `jwt` plugin | services |
| **services/** (e.g. `sample-service`) | Business logic; trusts Kong's validation | service-specific (DB, etc.) |

---

## Operational notes

- **Internal JWT TTL**: 5 minutes. Configurable via `BFF_INTERNAL_JWT_TTL_SECONDS`.
- **Session TTL**: 30 days (matches Keycloak refresh_token lifetime).
- **Clock skew tolerance**: Kong's `jwt` plugin defaults to a small leeway; tune via `maximum_expiration` if needed.
- **Logging**: never log the JWT, only `sub` and `request_id`. The BFF's pino redaction paths already cover this; do the same in services.
- **Secret management**: `BFF_INTERNAL_JWT_SECRET` is a single 32+ byte random string in the workspace `.env`, passed to both BFF and Kong via compose. Production: pull from a secret manager (Vault / AWS Secrets Manager / GCP Secret Manager) and inject as env at deploy time.
- **Rotation procedure (zero-downtime)**:
  1. Generate `BFF_INTERNAL_JWT_SECRET_V2`.
  2. Deploy BFF with both v1 (existing) and v2 (new). BFF signs new tokens with v2 (`kid: v2` in header).
  3. Deploy Kong with both `jwt_secrets` entries. Kong accepts tokens signed by either key based on `kid`.
  4. Wait until all v1-signed tokens expire (~5 min after step 2).
  5. Remove v1 from both BFF and Kong.
