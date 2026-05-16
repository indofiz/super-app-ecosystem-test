# TASKS.md — Implementation Checklist (port to main app)

Ordered to respect dependencies: build inner layers first
(`core/` → `domain/` → `data/` → `presentation/` → wiring). Each task is
checkable; security tasks are marked 🔒 and **must not be skipped or
simplified**. Cross-refs: [`SPEC.md`](SPEC.md), [`DATA.md`](DATA.md),
[`DESIGN.md`](DESIGN.md).

---

## Phase 0 — Project setup

- [ ] Add deps: `flutter_appauth`, `flutter_secure_storage`,
  `flutter_bloc`, `equatable`, `dio`, `go_router`, `flutter_dotenv`,
  `flutter_localizations`/`intl`, `pretty_dio_logger`. Dev: `bloc_test`,
  `mocktail`, `flutter_lints`.
- [ ] `pubspec.yaml`: `generate: true`, `assets: [ .env ]`.
- [ ] Create `.env`, `.env.example`; **gitignore** real `.env*`.
- [ ] Android: set `appAuthRedirectScheme` manifest placeholder to match
  `OAUTH_REDIRECT_URI` scheme. iOS: register the URL scheme.
- [ ] `l10n.yaml` + `lib/l10n/app_en.arb` + `app_id.arb`.

## Phase 1 — `core/` kernel

- [ ] `core/config/app_config.dart` — `AppConfig` + `fromEnv()` +
  `AppConfigException`. 🔒 release dead-code: force
  `allowInsecure=false` & `httpVerboseLog=false` under `kReleaseMode`;
  🔒 throw loudly if `USE_MOCK_AUTH=false` and BFF URL/clientId/redirect
  missing or http-without-optin. BFF-endpoint getters only (no Keycloak
  URLs).
- [ ] `core/config/auth_timings.dart` — all timing constants
  (`DATA.md`/`SPEC.md` §8). Single source.
- [ ] `core/storage/stored_session.dart` — 3-field record.
- [ ] `core/storage/secure_store.dart` — 🔒 Android
  `encryptedSharedPreferences`, iOS `first_unlock_this_device`; 🔒 16 KB
  access-token cap (reject + report); `write/read/clear`.
- [ ] `core/jwt/jwt_codec.dart` — base64url segment encode/decode (pad
  rule), header decode.
- [ ] `core/network/cancelled_exception.dart` +
  `withCancelTranslation` (Dio cancel → domain `CancelledException`).
- [ ] `core/network/bff_parse.dart` — `requireBody/String/Int`,
  `optional*`, `BffParseFailure`. (int accepts numeric string.)
- [ ] `core/network/bff_error.dart` — `describeBffError` (status,
  `error`, `error_description`, `attempts_left`, `isTimeout`).
- [ ] `core/network/retry_interceptor.dart` — exp backoff + jitter,
  retry only timeouts/connError/502/503/504, `kNoRetryExtra` opt-out,
  attempt counter in `extra`.
- [ ] `core/network/dio_factory.dart` — `createDio(config, extraHeaders,
  withRetry)`; shared timeouts; no auth/refresh interceptors here.
- [ ] `core/network/logging_interceptor.dart` +
  `pretty_logging_interceptor.dart` — terse logger logs no
  bodies/headers/bearer; BFF envelope = discriminators only
  (`error` + `detail.attempts_left`, `error_description` omitted).
  🔒 pretty logger does **NOT** redact (prints bearer/OTP/phone
  verbatim) — its *only* safety is the `kDebugMode && httpVerboseLog`
  attach gate (`kReleaseMode` forces `httpVerboseLog=false`). Do not add
  a "redaction" comment unless you actually implement redaction.
- [ ] `core/logging/auth_log.dart`, `error_reporter.dart` (singleton
  sink: `reportError/FlutterError/BootFailure`, `fatal` flag).
- [ ] `core/boot/boot_failure_app.dart` — actionable error screen +
  `onRetry`.
- [ ] `core/router/auth_status_listenable.dart` — abstract
  `ChangeNotifier` exposing `AuthStatus` (framework-neutral).
- [ ] `core/router/app_router.dart` — routes + ShellRoute + redirect
  table (`DESIGN.md` §1–2). Depends only on `AuthStatusListenable`.

## Phase 2 — auth `domain/`

- [ ] `auth_status.dart` enum.
- [ ] `auth_error_code.dart` enum + `isRetryable` extension.
- [ ] `jwt_claims.dart` — 🔒 fail-closed: reject `alg:none`/missing;
  release-fatal report; verified flags default false; `exp` parse.
- [ ] `auth_session.dart` — `fromToken`/`fromStored`/`toStored`,
  🔒 `isExpired` with `kSessionExpirySkew`, JWT `exp` authoritative.
- [ ] `auth_repository.dart` — abstract API + `AuthFailure` +
  `UserProfile`. Document the no-emit-on-restore + sessionChanges
  contract.

## Phase 3 — auth `data/`

- [ ] `dto/refresh_response_dto.dart`, `me_response_dto.dart`,
  `dto/send_otp_response_dto.dart`, `verify_otp_response_dto.dart` — all
  via `bff_parse`. (Verify DTO: sid required; refresh DTO: sid optional;
  `me`: camelCase + eager roles.)
- [ ] `bff_auth_api.dart` — own Dio (`withRetry`, NOT `ApiClient`);
  refresh/logout/me with `Bearer` header + `{session_id}` body.
- [ ] `datasources/auth_remote_datasource.dart`,
  `datasources/auth_local_datasource.dart` (wraps SecureStore↔AuthSession).
- [ ] `bff_auth_repository.dart` — orchestration:
  - login (AppAuth → BFF endpoints, `kOauthLoginTimeout`, parse
    sid/exp, persist, `_enrichFromProfile`, emit).
  - 🔒 refresh dedup (`_refreshing` Completer); 🔒 logout-race re-read
    guard; 401/invalid_session → clear+emit null+`sessionExpired`.
  - logout: 🔒 parallel remote(best-effort, never throws) + local clear.
  - `getProfile`, `replaceSession` (persist+emit), 🔒 `confirmIdentity`
    (re-confirm flags vs `/auth/me`).
  - `_mapDio` → typed; catch DioException/BffParseFailure/TypeError.
- [ ] `mock_auth_repository.dart` + `mock_jwt.dart` — dev only
  (alg=none JWT, `kMockSessionLifetime`). Keep for local dev.

## Phase 4 — auth `presentation/`

- [ ] `bloc/auth_bloc.dart` + `auth_event.dart` + `auth_state.dart` —
  🔒 source-of-truth rule: handlers emit only transient/error;
  `authenticated` only via `_onSessionChanged`; null/expired guard
  preserves handler errors. `AuthStarted` classify
  (none/fresh/expired→refresh) + `unawaited(confirmIdentity())`.
- [ ] `bloc/auth_bloc_listenable.dart` — adapts bloc → router listenable.
- [ ] `screens/splash_screen.dart`, `screens/login_screen.dart` (states
  per `DESIGN.md` §3) — **restyle to main app**.
- [ ] `auth_error_l10n.dart` — code→string + retry/permanent hints.

## Phase 5 — verification feature

- [ ] `domain/verification_failure.dart` (code enum + failure +
  `attemptsLeft`), `domain/verification_repository.dart` (abstract;
  🔒 no phone param on send/verify).
- [ ] `data/bff_verification_api.dart` — own Dio; 🔒 per-call
  `Idempotency-Key`; 🔒 `noRetry` on all 4; 30 s timeout on send-otp;
  empty body on send, `{code}` on verify.
- [ ] `data/datasources/verification_remote_datasource.dart`.
- [ ] `data/bff_verification_repository.dart` — orchestrate; reuse
  `AuthLocalDataSource`; on verify success →
  `authRepository.replaceSession`; 🔒 map 410/422+attempts.
- [ ] `data/mock_verification_repository.dart` — accepts `"123456"`.
- [ ] `presentation/bloc/verification_bloc.dart` (+event/state) —
  2-channel, per-channel `CancelToken`, shared `_onSend`/`_onVerify`,
  cancel on `close()`.
- [ ] `presentation/screens/` verification + email_otp + phone_otp;
  `widgets/otp_input.dart`, `widgets/resend_timer.dart`;
  `home/widgets/verification_banner.dart`. 🔒 auto-send only when
  `status==idle`. **Restyle to main app.**
- [ ] `verification_error_l10n.dart`.

## Phase 6 — `/api/*` client

- [ ] `core/http/api_client.dart` — `_TokenHolder` subscribed to
  `sessionChanges`; 🔒 `_AuthInterceptor` always overwrites
  `Authorization`; `_RefreshInterceptor` 🔒 single-401 deduped refresh +
  retry-once (`_kRetriedExtra`), second 401 propagates.

## Phase 7 — composition root & wiring

- [ ] `app.dart` — `MultiRepositoryProvider` + `BlocProvider<AuthBloc>`
  (`..add(AuthStarted())`), `MaterialApp.router`, l10n delegates,
  🔒 release `ErrorWidget.builder` override, dispose order
  (listenable → bloc → apiClient → repos).
- [ ] `main.dart` — 🔒 `runZonedGuarded` + `FlutterError.onError` +
  `PlatformDispatcher.onError` + isolate listener; `_bootstrap` loads
  dotenv, builds config; 🔒 mock branch only under
  `kDebugMode && config.useMockAuth`; else BFF stack; on any boot error
  → `BootFailureApp(onRetry: _bootstrap)`.

## Phase 8 — tests (mirror `test/` layout)

- [ ] Unit: `jwt_codec`, `jwt_claims` (alg:none rejection),
  `auth_session` (expiry skew), `bff_parse`, `retry_interceptor`,
  all DTOs, `api_failure`/`bff_error`, `cancelled_exception`.
- [ ] Bloc: `auth_bloc` (source-of-truth/race), `verification_bloc`
  (per-channel), `mock_auth_repository`.
- [ ] Datasource: auth/verification remote + local.
- [ ] Widget: login/otp screens, `verification_banner`, `app_router`
  redirect table.

## Phase 9 — pre-ship security gate (🔒 all required)

- [ ] `.env` prod: `USE_MOCK_AUTH=false`, `ALLOW_INSECURE_CONNECTIONS=
  false`, `HTTP_VERBOSE_LOG=false`, `BFF_BASE_URL=https://…`.
- [ ] No secrets anywhere in `.env` / `--dart-define`-able strings.
- [ ] Confirm release build: mock unreachable, insecure HTTP rejected,
  pretty logger tree-shaken, alg:none → fatal report.
- [ ] Confirm refresh_token never written to device; only the 3 keys.
- [ ] Confirm logs carry no token/OTP/phone/`error_description`.
- [ ] Manual: cold-start (fresh/expired/none), login cancel/timeout,
  401-mid-call refresh, logout offline, OTP invalid/exhausted/expired,
  re-enter `/verify/email` does not re-send, tampered-blob →
  `confirmIdentity` corrects flags.

---

### Open TODO carried from the reference (decide in main app)
- Pending-logout retry queue (failed BFF logout currently logs a
  server-side zombie session; no retry-on-next-launch yet).
- Remaining in-repo discrepancies (`SPEC.md` §10): JWT algorithm
  comments are now fixed to RS256 (action: configure Kong for RS256
  public-key/JWKS verification). Still open: `.env.prod` ships
  `HTTP_VERBOSE_LOG=true` against its own comment; `.env.example` claims
  a redaction the pretty logger does not perform — ship the main app's
  prod env with `HTTP_VERBOSE_LOG=false` and an accurate comment.
