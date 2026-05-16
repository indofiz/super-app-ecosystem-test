# DATA.md — Models, BFF API Contracts, Storage Schema

Companion to [`SPEC.md`](SPEC.md). This is the *wire + persistence + model*
truth. There is **no Firestore** in this stack — all server state lives
behind the BFF (Redis sessions, Keycloak profiles). "Schema" here means
secure-storage keys + JWT claim shape + HTTP contracts.

---

## 1. Persistence: secure storage schema

`flutter_secure_storage` (Android `encryptedSharedPreferences`, iOS
keychain `first_unlock_this_device`). Three keys only:

| Key | Type | Notes |
|-----|------|-------|
| `access_token` | String | BFF-minted internal JWT. Max **16 KB** (write rejected + reported above; blocks a misrouted HTML payload bricking the keystore). |
| `session_id` | String | Opaque; BFF's Redis key for the Keycloak refresh_token. |
| `expires_at` | String | UTC ISO-8601. Fallback only — JWT `exp` is authoritative. |

`clear()` deletes all three. The refresh_token is **never** stored.

`StoredSession = (accessToken, sessionId, expiresAt)` — the thin on-disk
record. `core/storage/` knows nothing about JWT semantics; the decode
happens domain-side.

---

## 2. Domain models

### `AuthSession` (`features/auth/domain/auth_session.dart`)
Equatable. Built via `fromToken(accessToken, sessionId, expiresAt)` or
`fromStored(StoredSession)`.

| Field | Type | Source |
|-------|------|--------|
| `accessToken` | String | stored |
| `sessionId` | String | stored |
| `expiresAt` | DateTime | **JWT `exp` if present**, else the passed fallback |
| `email` | String? | JWT `email` |
| `emailVerified` | bool | JWT `email_verified == true` |
| `phoneNumber` | String? | JWT `phone_number` |
| `phoneNumberVerified` | bool | JWT `phone_number_verified == true` |

- `isExpired` → `now + kSessionExpirySkew (30s) > expiresAt`.
- `fullyVerified` → `emailVerified && phoneNumberVerified`.
- `toStored()` projects back to the 3-field record (drops JWT-derived
  fields — they re-decode on next read).
- Verified flags from a restored session are *replaced* by `/auth/me`
  via `confirmIdentity()` (the on-device JWT is unverified by the app).

### `JwtClaims` (`features/auth/domain/jwt_claims.dart`)
Pure payload peek. `fromToken(jwt)`:
- `<2` segments → `empty()` + report.
- header `alg` is `none`/empty → `empty()`; in **release** reports
  `fatal` (mis-shipped mock or downgrade attack).
- Reads: `email`, `email_verified`, `phone_number`,
  `phone_number_verified`, `sub`, `username`/`preferred_username`,
  `exp` (num or numeric string → UTC DateTime).
- Never verifies signature (Kong's job — internal JWT is **RS256**,
  BFF private key signs / Kong public key verifies). Defaults verified →
  `false`.

### `UserProfile` (from `/auth/me`)
`sub`, `username?`, `email?`, `emailVerified`, `phoneNumber?`,
`phoneNumberVerified`, `roles: List<String>`, `expiresAt?`,
`fullyVerified`.

### Failure types
- `AuthFailure { code: AuthErrorCode, diagnostic?, cause?, retryable }`
  — Equatable on `[code, diagnostic, retryable]` (`cause` excluded).
- `VerificationFailure { code, attemptsLeft?, diagnostic?, cause?,
  retryable }`.
- `diagnostic` = raw server `error_description` / platform message —
  **logs only, never UI**.

---

## 3. BFF API contracts

Base = `BFF_BASE_URL` — the single nginx origin
(`https://auth.pangkalpinangkota.go.id` in prod). nginx path-routes
`/auth/*` → BFF and `/api/*` → Kong → upstream; the app only ever knows
this one origin. All bodies JSON. The app uses three **separate** Dio
stacks (none share the `/api/*` auth+refresh interceptors, to avoid
refresh recursion):

- `BffAuthApi` — `/auth/refresh`, `/auth/logout`, `/auth/me`
- `BffVerificationApi` — `/auth/{email,phone}/{send,verify}-otp`
- `ApiClient.dio` — `/api/*` business calls (auto-bearer + 401-refresh)

Plus `flutter_appauth` → `/auth/authorize` + `/auth/token` (OAuth/PKCE).

### 3.1 Login — `flutter_appauth` → BFF
`authorizeAndExchangeCode` with `serviceConfiguration`:
- `authorizationEndpoint`: `{base}/auth/authorize`
- `tokenEndpoint`: `{base}/auth/token`
- `clientId`, `redirectUri`, `scopes`, `promptValues: ['login']`

Token response → AppAuth surfaces:
| Field | From | Required |
|-------|------|----------|
| `accessToken` | `access_token` (internal JWT) | yes |
| `accessTokenExpirationDateTime` | `expires_in` | yes |
| `session_id` | `tokenAdditionalParameters['session_id']` | yes |

Missing any → `AuthFailure(loginMissingFields)`.

### 3.2 `POST /auth/refresh`
- **Headers:** `Authorization: Bearer <jwt>` (tolerated up to 24 h past
  exp), `Content-Type: application/json`
- **Body:** `{ "session_id": "<sid>" }`
- **200:** `{ "access_token": "<jwt>", "expires_in": <int>,
  "session_id": "<sid>"? }` (`session_id` optional — omitted when
  rotation doesn't change it; fall back to request sid)
- **401 / body `{"error":"invalid_session"}`:** server session gone →
  wipe local, emit null, `AuthFailure(sessionExpired)`
- **other 4xx/5xx / timeout:** `AuthFailure(refreshFailed | network)`
- DTO: `RefreshResponseDto` — `access_token` req str, `expires_in` req
  int (accepts numeric string), `session_id` opt str.

### 3.3 `POST /auth/logout`
- **Headers:** `Authorization: Bearer <jwt>`, `Content-Type: json`
- **Body:** `{ "session_id": "<sid>" }`
- **204** expected. Best-effort: any failure logged, never re-thrown;
  local clear proceeds regardless (runs in parallel).

### 3.4 `GET /auth/me`
- **Headers:** `Authorization: Bearer <jwt>`
- **200:** REST camelCase (distinct from JWT snake_case):
  ```json
  {
    "sub": "string",
    "username": "string?",
    "email": "string?",
    "emailVerified": false,
    "phoneNumber": "string?",
    "phoneNumberVerified": false,
    "roles": ["string"],
    "expiresAt": "ISO-8601?"
  }
  ```
- DTO: `MeResponseDto` — `roles` eagerly materialized
  (`List<String>.from`, throws `BffParseFailure` at parse site on bad
  element); `expiresAt` informational only (JWT `exp` is the auth truth).

### 3.5 OTP — `POST /auth/{email,phone}/send-otp`
- **Headers:** `Authorization: Bearer <jwt>`, `Idempotency-Key:
  <128-bit b64url>`, `Content-Type: json`
- **Body:** `{}` (empty — **no phone/email on the wire**; BFF resolves
  destination from the Keycloak profile)
- **202:** `{ "delivery": "email"|"wa"?, "expires_in": <int>? }`
- **200:** `{ "verified": true }` (channel already verified — short
  circuit)
- Timeouts overridden to **30 s** (`kHttpReceiveTimeoutSlow`);
  `noRetry` (SMTP/Fonnte side effect — retry would double-send)
- DTO: `SendOtpResponseDto` — `delivery` opt, `expires_in` opt int,
  `verified` opt bool (→ `alreadyVerified`). Default TTL =
  `kOtpDefaultTtl` (300 s) if `expires_in` absent.

### 3.6 OTP — `POST /auth/{email,phone}/verify-otp`
- **Headers:** `Authorization: Bearer <jwt>`, `Idempotency-Key`,
  `Content-Type: json`
- **Body:** `{ "code": "<6 digits>" }` (**code only** — no phone, even
  for phone channel; BFF reads bound number from its OTP record)
- **200:** `{ "access_token": "<jwt>", "session_id": "<sid>",
  "expires_in": <int> }` — fresh session with the verified claim flipped;
  pushed via `AuthRepository.replaceSession`
- **410:** OTP expired / already consumed → `otpExpired`
- **422 + `detail.attempts_left` > 0:** `otpInvalid` (carries `attemptsLeft`)
- **422 + `detail.attempts_left` == 0:** `otpExhausted`
- `noRetry` (attempt counter side effect)
- DTO: `VerifyOtpResponseDto` — `access_token`, `session_id`,
  `expires_in` all **required** (verify always re-mints with fresh sid).

### 3.7 BFF error envelope
On error responses the BFF's error middleware returns this shape (parsed
by `bff_error.dart` → `describeBffError`). **`attempts_left` is nested
inside `detail`, not top-level:**
```json
{ "error": "machine_code",
  "error_description": "human text",
  "detail": { "attempts_left": 2 } }
```
- `describeBffError` → `BffErrorInfo { statusCode, isTimeout,
  errorDescription, attemptsLeft }`. It reads `error_description` from
  the top level and `attempts_left` from `detail` (`num` → int). It does
  **not** surface the `error` machine code — only the logging
  interceptor reads `body['error']` directly.
- `errorDescription` → `*Failure.diagnostic` (**logs only**, never UI).
- `detail.attempts_left` → `VerificationFailure.attemptsLeft`.
- Terse logging interceptor (`logBffErrorEnvelope: true`) logs **only**
  `error=<code>` + `attempts_left=<n>` (read from `detail`), never the
  full body — `error_description` can echo the user's typed OTP.
- Transport failures (timeout/connection drop) have **no** response body;
  `isTimeout` is the only signal.

---

## 4. DTO parse rules (`core/network/bff_parse.dart`)

Every DTO `fromJson` goes through these so contract drift surfaces as a
typed `BffParseFailure(field, reason)` at the parse site (never a
`TypeError` upstream):

- `requireBody` — non-null, non-empty map else `empty-body`.
- `requireString` / `optionalString` — type-checked.
- `requireInt` / `optionalInt` — accepts JSON number **or** numeric
  string (proxy stringification tolerance).
- `optionalBool` — `fallback` (default false) when absent.
- `reason` ∈ `missing | wrong-type:<T> | empty-body | not-an-object`.

`BffParseFailure` carries `field` + `reason` + optional `cause` for logs;
repositories catch it → feature-typed failure with the parse detail in
`diagnostic`.

---

## 5. Error code catalogues

### `AuthErrorCode` + `isRetryable`
| Code | Meaning | Retryable |
|------|---------|-----------|
| `sessionExpired` | server session gone (401/invalid_session) | ✗ |
| `loginCancelled` | user dismissed Custom Tab | ✓ |
| `loginTimedOut` | AppAuth never returned | ✓ |
| `loginPlatformError` | Custom Tabs missing / intent fail | ✗ |
| `loginMissingFields` | BFF token resp incomplete | ✗ |
| `notAuthenticated` | op needed a session, none in storage | ✗ |
| `refreshFailed` | /refresh non-401 failure | ✗ |
| `network` | transport timeout | ✓ |
| `unknown` | unrecognised | ✗ |

`isRetryable` is derived from the code (single source) — UI reads
`state.errorCode!.isRetryable`, not a duplicate bool.

### `VerificationErrorCode`
| Code | Meaning |
|------|---------|
| `sendOtpFailed` | send failed (non-transport) |
| `verifyOtpFailed` | verify failed (5xx/malformed) |
| `otpInvalid` | wrong code, attempts remain (carries `attemptsLeft`) |
| `otpExhausted` | attempts == 0, must re-request |
| `otpExpired` | record expired/consumed (410) |
| `notAuthenticated` | no session in storage |
| `network` | transport failure |
| `unknown` | catch-all |

---

## 6. Auth state machine (`AuthBloc`)

States: `AuthState { status: AuthStatus, session?, errorCode? }`.
`AuthStatus ∈ { unknown, unauthenticated, authenticating, authenticated }`.

```
unknown ──AuthStarted──┐
                        ├─ no session ───────────────► unauthenticated()
                        ├─ fresh session ────────────► authenticated  (+confirmIdentity)
                        └─ expired ──authenticating──► refresh()
                                                         ├ ok  → (stream) authenticated
                                                         └ fail→ unauthenticated(errorCode)

unauthenticated ──AuthLoginRequested──► authenticating ──► login()
                                                            ├ ok  → (stream) authenticated
                                                            └ fail→ unauthenticated(errorCode)

authenticated ──AuthLogoutRequested──► logout() ──(stream null)──► unauthenticated()
authenticated ──AuthRefreshRequested──► refresh() ──┘ (fail → unauthenticated(errorCode))
any ──repo.sessionChanges──► _onSessionChanged (only path to `authenticated`)
```

Rules: handlers never emit `authenticated`; `_onSessionChanged(null|expired)`
won't overwrite a handler-set error state nor churn a clean
`unauthenticated`.

---

## 7. Verification channel state machine (`VerificationBloc`)

`VerificationState { email: ChannelState, phone: ChannelState }` — two
independent channels in one bloc (per-channel `CancelToken`).

`ChannelState { status, expiresAt?, errorCode?, attemptsLeft? }`,
`status ∈ { idle, sending, awaitingCode, verifying, verified }`.

```
idle ──Send──► sending ──► awaitingCode ──Verify──► verifying ──► verified
                  └ fail → idle(+errorCode)              │
                                                         ├ otpInvalid & attemptsLeft>0 → awaitingCode(+errorCode,attemptsLeft)
                                                         └ otpExpired/exhausted/other  → idle(+errorCode)  (otpExpired clears expiresAt)
```

`copyWith` uses zero-arg closures to distinguish "leave" from "clear to
null". On `verified` the BFF re-minted JWT flows through
`AuthRepository.replaceSession` → `AuthBloc` picks it up via
`sessionChanges`; `VerificationBloc` does **not** wire back into auth.
