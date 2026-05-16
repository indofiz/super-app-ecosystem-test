# SPEC.md — Master Spec: BFF-Mediated SSO Auth Stack

> **Purpose of this document set.** This project (`smart_app_test`) is a
> **reference / dummy implementation** of the authentication +
> verification stack for the Pangkal Pinang city super-app. It exists so
> the same structure can be re-implemented in the **real main app**. These
> four docs describe *what* the stack does, *how* it is layered, and the
> *invariants* that must survive the port — not the cosmetic UI (the real
> app has its own, better UI; see `DESIGN.md`).

Companion docs: [`DATA.md`](DATA.md) (models + API contracts),
[`DESIGN.md`](DESIGN.md) (routes + screen states), [`TASKS.md`](TASKS.md)
(implementation checklist).

---

## 1. Product goal

A citizen logs into the super-app once via city SSO (Keycloak) and gets a
session. Some city services require a **verified email** and **verified
WhatsApp number**; the app nudges (soft-gates) the user to verify both,
but never hard-blocks the home screen.

Two features, decoupled:

- **auth** — login, session restore, silent refresh, logout, profile.
- **verification** — email/phone OTP send + verify; on success the BFF
  re-mints the session JWT with the verified flag flipped.

---

## 2. The single most important rule: the BFF boundary

**The mobile app NEVER talks to Keycloak (the IdP) directly.**

One nginx domain (`auth.pangkalpinangkota.go.id` in prod) fronts
everything; routing is **path-based**:

```
                          nginx (auth.pangkalpinangkota.go.id)
                          /auth/*  ─────────►  ┌─────┐  OIDC   ┌──────────┐
 ┌────────┐  OAuth/PKCE deeplink               │ BFF │ ──────► │ Keycloak │
 │ Mobile │ ─────────────────────────────────► │     │ ◄────── │  (IdP)   │
 │ (this) │ ◄───────────────────────────────── └─────┘         └──────────┘
 └────────┘  internal JWT + sid                   │
      │     /api/*  ──────────► ┌──────┐           └ Redis: session_id →
      └─────────────────────────│ Kong │ ──► upstream     Keycloak refresh_token
            (Bearer JWT)        └──────┘     services
```

- Single base = `BFF_BASE_URL` (the nginx origin). nginx routes
  `/auth/*` → **BFF**, `/api/*` → **Kong** → upstream services. The app
  only ever knows the one origin; it never addresses BFF/Kong/Keycloak
  hosts directly.
- `flutter_appauth` is pointed at **BFF** endpoints via nginx
  (`$BFF_BASE_URL/auth/authorize`, `/auth/token`), *not* Keycloak's.
- The BFF performs the OAuth/PKCE handshake with Keycloak, then mints a
  short-lived **internal JWT**, **RS256** (asymmetric — BFF signs with
  the private key, Kong verifies with the public key), returned to the
  app as its `Bearer`. (All source comments now consistently say RS256;
  the app verifies no signature itself, but the algorithm dictates Kong's
  verification config — see §10.)
- Keycloak's `access_token` / `refresh_token` **never reach the device**.
  The refresh_token lives in Redis on the BFF, keyed by an opaque
  `session_id`.
- The app stores exactly three things: `accessToken` (internal JWT),
  `session_id`, `expiresAt`. Nothing else is persistable.
- `/api/*` calls flow nginx → **Kong** → upstream. Kong verifies the JWT
  signature; the app does **not** (it only decodes the payload for UI
  gating).

**Why this matters for the port:** every secret (Keycloak client secret,
Fonnte/WhatsApp API key, SMTP creds) stays on the BFF. The app ships a
bundled `.env` that is **public data** — treat anything in the APK as
readable by an attacker. See §6.

---

## 3. Architecture & layering

Feature-first Clean Architecture. Strict dependency direction:
`presentation → domain ← data`, with a shared `core/` kernel.

```
lib/
  core/                         shared kernel (no feature imports upward)
    config/    app_config.dart, auth_timings.dart
    http/      api_client.dart           (/api/* Dio: auth + 401-refresh)
    network/   dio_factory.dart, retry_interceptor.dart,
               bff_parse.dart, bff_error.dart, cancelled_exception.dart,
               *_logging_interceptor.dart, api_failure.dart
    storage/   secure_store.dart, stored_session.dart
    jwt/       jwt_codec.dart            (base64url segment codec only)
    router/    app_router.dart, auth_status_listenable.dart
    logging/   auth_log.dart, error_reporter.dart
    boot/      boot_failure_app.dart
  features/
    auth/
      domain/        auth_repository.dart (abstract), auth_session.dart,
                     auth_status.dart, auth_error_code.dart, jwt_claims.dart
      data/          bff_auth_repository.dart, mock_auth_repository.dart,
                     bff_auth_api.dart, datasources/, dto/
      presentation/  bloc/ (auth_bloc + event + state + listenable),
                     screens/ (login, splash), auth_error_l10n.dart
    verification/    same shape (domain / data / presentation)
    home/            presentation only (consumes AuthBloc)
  app.dart                       widget tree, DI providers, router mount
  main.dart                      composition root + global error wiring
```

### Layer rules (must survive the port)

1. **`domain/` is framework-free.** No `flutter_bloc`, no `dio` (except
   `CancelToken` as a cancellation primitive), no widgets. The router
   depends on `AuthStatus` (a domain enum) — *not* on the Bloc.
2. **`data/` throws typed failures only.** `AuthFailure(AuthErrorCode)` /
   `VerificationFailure(VerificationErrorCode)`. Raw `DioException`,
   `TypeError`, parse errors never escape the repository. User-facing
   strings are *never* built below `presentation/`.
3. **`presentation/` maps codes → localized copy** via `AppLocalizations`
   (`auth_error_l10n.dart`, `verification_error_l10n.dart`).
4. **Repositories orchestrate; datasources do I/O.**
   - `*RemoteDataSource` wraps the HTTP `*Api` (Dio shape hidden).
   - `AuthLocalDataSource` wraps `SecureStore` (on-disk shape hidden).
   - Repos hold the datasources and own the orchestration logic only.
5. **One composition root.** `main.dart` is the only place that decides
   mock-vs-BFF and wires the graph. Everything else receives
   dependencies; nothing news-up a repository.
6. **DTOs are wire-shape; domain models are app-shape.** Conversion
   happens in the repository. DTOs validate via `bff_parse.dart` so
   contract drift = `BffParseFailure` at the parse site, never a
   `TypeError` three layers up.

---

## 4. State management (Bloc) — the source-of-truth rule

`flutter_bloc`. The crucial invariant (do not "simplify" this away in the
port — it kills a real race):

- **Bloc handlers emit ONLY transient + error states:** `authenticating`,
  `unauthenticated()`, `unauthenticated(errorCode:)`.
- **The `authenticated` state is driven EXCLUSIVELY by
  `AuthRepository.sessionChanges`** (a broadcast stream). Every session
  mutation — login, refresh, restore, verify (`replaceSession`), logout
  (`null`) — flows through that one stream. `_onSessionChanged` projects
  it onto state.
- `_onSessionChanged(null)` must **not** clobber an error state set by a
  handler (the refresh-401 path emits `null` on the stream *and* throws a
  typed error; the handler's error wins, the queued `null` becomes a
  no-op).
- An **expired** session arriving on the stream is treated the same as
  `null` — it can never lift the Bloc to `authenticated`.

Routing is decoupled: `AuthBlocListenable` adapts `AuthBloc.stream` to the
framework-neutral `AuthStatusListenable` (`ChangeNotifier`) that
`go_router`'s `refreshListenable` consumes. Swapping Bloc → Riverpod later
touches only that adapter, not `core/router/`.

State machines: see `DATA.md` §6 (auth) and §7 (verification channels).

---

## 5. Auth flows (behavioral spec)

### 5.1 Cold start / session restore
1. `AuthBloc(AuthStarted)` → `restoreSession()` reads secure storage.
   **`restoreSession()` does NOT emit on the stream** (so the
   `ApiClient` token holder can't cache an expired bearer before the Bloc
   classifies it).
2. No session → `unauthenticated()`.
3. Fresh session → `authenticated` immediately, then *best-effort*
   `confirmIdentity()` (re-fetch `/auth/me` to replace JWT-decoded
   verified flags with BFF-confirmed ones — defends against a tampered
   on-device blob).
4. Expired session → `authenticating` + silent `refresh()`. Success emits
   on stream; `sessionExpired` failure emits `null` + typed error → back
   to login.

### 5.2 Login
`AuthLoginRequested` → `authenticating` → `flutter_appauth
.authorizeAndExchangeCode(...)` against BFF endpoints, 3-min hard timeout
(`kOauthLoginTimeout`). Response = `access_token` (internal JWT),
`expires_in`, and `session_id` via `tokenAdditionalParameters`. Persist,
enrich from `/auth/me`, emit on stream. Typed failures:
cancelled / timed-out / platform-error / missing-fields.

### 5.3 Refresh
`POST /auth/refresh` with `Bearer <jwt>` (accepted up to 24 h past expiry)
+ `{session_id}`. BFF rotates the Keycloak refresh_token in Redis and
mints a new internal JWT. **In-flight dedup at two layers** (repository
`_refreshing` Completer + `_RefreshInterceptor._refreshing`) because a
double rotation invalidates the loser's bearer. 401 / `invalid_session` →
wipe local + emit `null` + throw `sessionExpired`. Logout-race guard:
re-read storage before writing the refreshed session.

### 5.4 Logout
Run BFF `/auth/logout` and local `clear()` **in parallel** (the local
clear must not wait on a 15 s receive-timeout while the user sits in a
half-logged-out state). Remote call is best-effort, never re-throws;
failure logs a server-side zombie session (TODO: pending-logout retry
queue). Local always reaches a clean `unauthenticated`.

### 5.5 `/api/*` requests
`ApiClient` Dio: `_AuthInterceptor` always overwrites `Authorization`
from the session token holder (single source of truth — a caller-set
bearer is ignored). On one 401: deduped `refresh()`, retry the original
request once with the new bearer; a second 401 propagates and the Bloc
lands on `unauthenticated` via the stream.

### 5.6 Verification (OTP)
Scoped to a `ShellRoute` so `/verify`, `/verify/email`, `/verify/phone`
share one `VerificationBloc`. Per channel: `idle → sending →
awaitingCode → verifying → verified`. Send/verify carry a per-call
`Idempotency-Key`; verify endpoints are `noRetry` (retrying a late-success
burns an attempt). **No phone number ever travels on the wire** — the BFF
resolves it from the Keycloak profile and binds it to the OTP record. On
verify success the BFF re-mints the JWT; the verification repo pushes it
through `AuthRepository.replaceSession` so auth stays the single source of
truth. Soft gate only — a banner on home, never a redirect.

---

## 6. Security invariants (MUST port verbatim)

| # | Invariant | Where |
|---|-----------|-------|
| S1 | App never constructs Keycloak URLs; only BFF endpoints. | `AppConfig` getters |
| S2 | Only `(accessToken, sessionId, expiresAt)` persisted; refresh_token never on device. | `SecureStore` / `StoredSession` |
| S3 | Secure storage: Android `encryptedSharedPreferences`, iOS `first_unlock_this_device` (no iCloud sync of a citizen credential). | `SecureStore` |
| S4 | JWT decode is **fail-closed**: reject `alg:none` / missing alg; verified flags default `false` on any parse error. Signature is Kong's job, not the app's. | `JwtClaims` |
| S5 | Mock auth gated behind `kDebugMode && useMockAuth` — a re-signed release APK flipping `.env` cannot enable the in-memory mock. | `main.dart` |
| S6 | Release builds force `allowInsecureConnections=false` and `httpVerboseLog=false` via `kReleaseMode` compile-time dead-code elimination. | `AppConfig.fromEnv` |
| S7 | `.env` is **public data** (bundled asset). No secrets, ever. Per-env secrets → BFF; per-env non-secrets → `--dart-define`. | `AppConfig` doc header |
| S8 | Session expiry uses a 30 s skew (`kSessionExpirySkew`) so a backdated device clock can't keep a stale session "valid"; JWT `exp` is authoritative over wall-clock. | `AuthSession.isExpired` |
| S9 | Terse logger (`→/←/✗`) never logs bodies/headers/bearer; BFF-envelope logging is **discriminators-only** (`error` + `detail.attempts_left`), `error_description` deliberately omitted. The **pretty logger does NOT redact** — it prints bearer/OTP/phone verbatim; H-03 rests **entirely** on it being unreachable in release (`kDebugMode && httpVerboseLog`, with `kReleaseMode` forcing `httpVerboseLog=false`). `ErrorReporter` records only `runtimeType` in release. | `*_logging_interceptor`, `error_reporter` |
| S10 | `confirmIdentity()` re-confirms verified flags against `/auth/me` so a rooted device can't fake verification UI gates by editing the stored blob. | `BffAuthRepository` |
| S11 | No phone number on the OTP wire (send or verify) — closes the cross-number verification vector at the source. | `BffVerificationApi` |
| S12 | Boot failures mount `BootFailureApp` (actionable screen + Retry), never a black screen; global error sinks wired (zone, FlutterError, PlatformDispatcher, isolate). | `main.dart` |

---

## 7. Configuration contract

`.env` (bundled asset) parsed by `AppConfig.fromEnv()`:

| Key | Meaning | Prod value |
|-----|---------|-----------|
| `BFF_BASE_URL` | nginx origin (path-routed to BFF/Kong; never BFF/Kong/Keycloak directly) | `https://auth.pangkalpinangkota.go.id` |
| `OAUTH_CLIENT_ID` | logical client id the BFF allowlists | `super-app-eco` |
| `OAUTH_REDIRECT_URI` | deeplink scheme (matches Android `appAuthRedirectScheme`) | `id.go.pangkalpinangkota.<app>:/oauth2redirect` |
| `OAUTH_SCOPES` | space-separated | `openid profile email phone` (prod/local; `.env.example` still shows `openid profile email`) |
| `USE_MOCK_AUTH` | dev bypass; **MUST be false in prod** | `false` |
| `ALLOW_INSECURE_CONNECTIONS` | http allowed (dev only; forced false in release) | `false` |
| `HTTP_VERBOSE_LOG` | **non-redacting** pretty logger (forced false in release) | `false` ⚠️ see §10 |

Env files: `.env.local` (docker dev, `10.0.2.2:8080`, insecure ok),
`.env.prod` (`https://auth.pangkalpinangkota.go.id`), `.env.example`
(template). Switch via `cp .env.prod .env` + hot-restart. `.env` is the
bundled asset actually read at runtime.

`AppConfig.fromEnv()` throws `AppConfigException` (loudly, → boot failure
screen) if `USE_MOCK_AUTH=false` but BFF URL / client id / redirect are
missing or the URL is http without insecure opt-in. **Fail loud beats
silently falling back to mock against a real backend.**

---

## 8. Timing contract (`core/config/auth_timings.dart`)

Single audit point — tuning one without the BFF creates UI/server skew.

| Constant | Value | Role |
|----------|-------|------|
| `kOauthLoginTimeout` | 3 min | AppAuth round-trip hard cap |
| `kOtpDefaultTtl` | 300 s | OTP TTL when BFF omits `expires_in` |
| `kOtpResendCooldown` | 60 s | min interval between resend taps |
| `kSessionExpirySkew` | 30 s | refresh-early / anti-clock-backdate window |
| `kMockSessionLifetime` | 5 min | mock session lifetime (mirrors BFF token TTL) |
| `kHttpConnectTimeout` | 10 s | all HTTP |
| `kHttpReceiveTimeout` / `kHttpSendTimeout` | 15 s | all HTTP |
| `kHttpReceiveTimeoutSlow` | 30 s | send-OTP only (SMTP/Fonnte p99 > 20 s) |

---

## 9. What to replicate vs adapt in the main app

**Replicate verbatim (this is the point of the reference):**

- The whole `core/` kernel, `domain/` of auth + verification, the
  repository/datasource/DTO split, `bff_parse.dart`, the BFF API clients,
  the Bloc source-of-truth rule, the security invariants table (§6), the
  router's framework-neutral listenable, the composition root pattern,
  the global error wiring.

**Adapt (project-specific):**

- `.env` values (`OAUTH_CLIENT_ID`, redirect scheme, BFF host).
- All UI under `presentation/screens/` and `home/` — use the main app's
  design system. Keep the *state contract* (which Bloc state drives which
  screen), restyle freely. See `DESIGN.md`.
- Localization strings (`l10n/*.arb`) — keep the *codes*, swap the copy.
- `mock_*` repositories — keep for dev, but they are dev-only scaffolding.

**Do NOT change without a BFF-side change:**

- The timing constants (§8), the wire contracts (`DATA.md`), the
  redirect/state machine (`DESIGN.md`), the security invariants (§6).

---

## 10. Validation findings — discrepancies in the reference app

These specs were re-validated against the full source. The stack is
consistent except for three **in-repo discrepancies** to resolve in the
main app (none change runtime behavior of the reference, but each is a
latent footgun):

1. **JWT algorithm — RESOLVED.** The backend signs the internal JWT with
   **RS256** (confirmed authoritative). All source comments that
   previously said "HS256" (`bff_auth_repository.dart:33`,
   `mock_jwt.dart`, `secure_store.dart`, the two JWT test fixtures, audit
   doc 004) have been corrected to RS256. Remaining action for the main
   app: ensure **Kong is configured for RS256 public-key verification**
   (JWKS / public key), not an HS256 shared secret. (`mock_jwt.dart`
   mints an `alg:none` dev fake regardless — it never signs, so the mock
   is unaffected.)

2. **`.env.prod` ships `HTTP_VERBOSE_LOG=true`** while its own inline
   comment says "Must stay false for prod." Safe *only* because release
   builds dead-code-eliminate the logger — but `cp .env.prod .env` on a
   **debug/profile** build would dump bearers/OTP/phone to logcat (the
   pretty logger does **not** redact; see finding 3). Ship
   `HTTP_VERBOSE_LOG=false` in the main app's prod env.

3. **`.env.example` claims the pretty logger redacts** ("masked as
   «redacted»"); the actual `pretty_logging_interceptor.dart` header
   states it prints request/response/headers **verbatim with NO
   field-level redaction**. The accurate model: there is no redaction;
   the only defense is the `kDebugMode && httpVerboseLog` + release gate.
   Fix the `.env` comment in the main app so no one trusts a guarantee
   that doesn't exist. (S9 in §6 reflects the *correct* model.)

Everything else — layering, the Bloc source-of-truth rule, the dual-layer
refresh dedup, fail-closed JWT decode, expiry skew, the OTP no-phone-on-
wire rule, the 3-key storage, the global error sinks — matched the source
exactly.
