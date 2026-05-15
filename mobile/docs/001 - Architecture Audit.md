# 001 - Flutter Mobile Architecture Audit

**Date:** 2026-05-15
**Scope:** `mobile/lib/**` — entire Flutter client (`core/`, `features/auth`, `features/verification`, `features/home`, `features/sample`, routing, HTTP, storage, blocs, screens, widgets). External dependencies in `pubspec.yaml` were considered but not audited.
**Severity Levels:** CRITICAL | HIGH | MEDIUM | LOW

**Status Legend:** ✅ Fixed | ⚠️ Partially Fixed | ❌ Not Fixed

---

## Summary Table

| #     | Issue                                                                  | Severity | Status |
|-------|------------------------------------------------------------------------|----------|--------|
| C-01  | Duplicated JWT decoding in three locations                             | CRITICAL | ✅     |
| C-02  | Raw access_token and decoded claims surfaced in production UI          | CRITICAL | ✅     |
| H-01  | Localized error strings hard-coded in `domain/` and `data/` layers     | HIGH     | ✅     |
| H-02  | Router reads `AuthBloc` state directly — tight coupling                | HIGH     | ✅     |
| H-03  | VerificationBloc duplicates email/phone handler pairs                  | HIGH     | ✅     |
| H-04  | Two independent Dio instances, no shared HTTP infrastructure           | HIGH     | ✅     |
| H-05  | StreamControllers in repositories are never closed (leak)              | HIGH     | ✅     |
| H-06  | `home_screen.dart` ships debug/internal tooling to production builds   | HIGH     | ✅     |
| H-07  | `verification` feature reaches across the boundary into `auth/domain`  | HIGH     | ✅     |
| M-01  | `.env` bundled as Flutter asset used as production config              | MEDIUM   | ✅     |
| M-02  | Storage-shape record leaks from `SecureStore` into repository          | MEDIUM   | ✅     |
| M-03  | `AuthRepositoryFactory` is a closed static switch (does not scale)     | MEDIUM   | ✅     |
| M-04  | Magic numbers (timeouts, TTLs, retry counts) scattered across files    | MEDIUM   | ✅     |
| M-05  | `AuthBloc` has dual transition paths (explicit + stream-mirror)        | MEDIUM   | ✅     |
| M-06  | No `core/error` or `core/network` modules; mapping bound to the repo   | MEDIUM   | ✅     |
| L-01  | `JwtClaims.empty()` swallows parse errors silently                     | LOW      | ✅     |
| L-02  | Dead code: unused `_otpKey` in `email_otp_screen.dart`                 | LOW      | ✅     |
| L-03  | `OtpInput` relies on `Opacity(0.01)` autofill hack                     | LOW      | ✅     |
| L-04  | `_log` shadow helpers duplicated across files                          | LOW      | ✅     |

**Progress: 19/19 fixed, 0 partial, 0 remaining** 🎉

---

## CRITICAL Issues

### ✅ C-01 Duplicated JWT decoding logic in three locations
**File:** `lib/features/auth/domain/jwt_claims.dart:32-57`, `lib/features/home/presentation/home_screen.dart:190-201`, `lib/features/auth/data/mock_auth_repository.dart:172-195`

**Resolution (2026-05-15):**
Introduced `lib/core/jwt/jwt_codec.dart` with two pure helpers — `encodeJwtSegment(Map)` and `decodeJwtSegment(String)` — that own the base64Url padding rule. Both call sites now delegate to it:
- `JwtClaims.fromToken` calls `decodeJwtSegment(parts[1])`; the inline padding/utf8/jsonDecode block is gone.
- `MockAuthRepository._fakeJwt` builds header & payload via `encodeJwtSegment(...)`; the local `b64` closure is removed.
- `home_screen._decodeClaims` was deleted; the one call site now uses `JwtClaims.fromToken(session.accessToken).raw`.
Added `test/core/jwt/jwt_codec_test.dart` covering round-trip, padding mod-{0,1,2}, empty/non-base64/array-payload/invalid-utf8 → `null`. Future BFF claim-shape changes only need to touch `JwtClaims`.

**Issue:**
There is a single, well-typed JWT decoder (`JwtClaims.fromToken`) in the `domain/` layer — yet two other components decode JWT segments themselves rather than reuse it.

1. `home_screen.dart` re-implements `_decodeClaims(String jwt)` byte-for-byte (`split('.')`, `padRight`, `base64Url.decode`, `jsonDecode`). It returns `Map<String, dynamic>` instead of using `JwtClaims.raw`.
2. `mock_auth_repository.dart` re-implements the *encode* side (`_fakeJwt`) without going through any shared helper; the alphabet, padding rules and header conventions are open-coded.
3. `JwtClaims.fromToken` is the canonical decoder; both call sites bypass it.

Why this is dangerous: the moment the BFF changes any claim shape (e.g. moves `phone_number_verified` into a nested `verification` object), three independent decoders must be updated in lock-step. A drift between them — for example, `JwtClaims.fromToken` updated but `home_screen._decodeClaims` not — produces UIs that disagree with the actual session state. In an auth subsystem this is the kind of split-brain bug that masks expired-but-displayed-valid sessions.

```dart
// home_screen.dart:190-201
static Map<String, dynamic> _decodeClaims(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return const {};
  try {
    final padded = parts[1].padRight(parts[1].length + (4 - parts[1].length % 4) % 4, '=');
    final decoded = utf8.decode(base64Url.decode(padded));
    final map = jsonDecode(decoded);
    return map is Map<String, dynamic> ? map : {};
  } catch (_) {
    return {};
  }
}

// jwt_claims.dart:32-57  ← canonical version that already exists
factory JwtClaims.fromToken(String jwt) { /* identical logic */ }
```

**Recommendation:**
- Delete `_decodeClaims` from `home_screen.dart`. Replace with `JwtClaims.fromToken(session.accessToken).raw`.
- Move the base64Url padding helper to a `core/jwt/jwt_codec.dart` (since `MockAuthRepository._fakeJwt` legitimately *encodes* and shouldn't import the decoder). Both `JwtClaims` and `_fakeJwt` then depend on the same low-level helper.

---

### ✅ C-02 Raw access_token and decoded claims surfaced in production UI
**File:** `lib/features/home/presentation/home_screen.dart:108-123`

**Resolution (2026-05-15):**
All diagnostic UI was extracted into a dedicated `lib/features/_dev/dev_dashboard.dart` module (`DevDashboard` panel + `DevRefreshAction` appbar icon). `HomeScreen` now renders them only inside `if (kDebugMode) ...` guards. Because `kDebugMode` is a `const false` in release builds, the Dart tree-shaker drops the entire dev module — token preview, decoded-JWT JSON, `/auth/me` + `/api/profile` test buttons, refresh-token icon, and their imports of `JsonEncoder`/`JwtClaims`/`SampleApi`/`AuthRepository` — from the release bundle. Citizen build sees only `VerificationBanner`, a placeholder, and the logout action.

Trade-off taken: per project owner's direction, the diagnostics stay fully visible in debug builds (this is a template repo for a real super-app). The gating is structural rather than copy-removal, so the same code is safe to fork into the production app — switching `flutter run` (debug) to `flutter build … --release` is the only knob. Teams wanting beta-channel visibility can replace `kDebugMode` with an `AppConfig.showDevTools` flag without changing the shape.

**Not changed:** the audit's stricter recommendation to replace `session.accessToken.substring(...)` with `AuthSession`-level getters in UI code. The token preview is now legitimately scoped to a debug-only module whose entire point is showing raw bytes; the abstraction would defeat the purpose. The general principle (UI must not reach into raw JWT) still applies to *non-debug* code, and the new structure enforces it by physical separation.

**Issue:**
The home screen — the first screen a successfully-authenticated user lands on — renders:

- `session.sessionId` verbatim,
- a preview of `session.accessToken` (first 24 chars),
- the full decoded JWT payload as JSON,
- buttons that fire raw `/auth/me` and `/api/profile` calls and dump the responses on screen.

None of this is gated behind `kDebugMode`. The widget tree, the text content, and the API client are all available in release builds. The internal JWT is the bearer Kong honours — even a 24-char prefix leaks token entropy and signals the algorithm/issuer to anyone shoulder-surfing. The decoded claims expose `sub`, `email`, `phone_number`, internal realm, role list, and expiry — exactly the data the BFF is brokering to keep off the device.

This is also a separation-of-concerns failure: the presentation layer is consuming `session.accessToken` as raw text, which couples the UI to the JWT format, not to the domain abstraction (`AuthSession.emailVerified`, etc.) that was created for this purpose.

```dart
// home_screen.dart:108-123
_row('session_id', session.sessionId),
_row('expires_at', session.expiresAt.toIso8601String()),
_row(
  'access_token (preview)',
  '${session.accessToken.substring(0, session.accessToken.length.clamp(0, 24))}…',
),
const Divider(height: 32),
Text('Decoded internal JWT', style: Theme.of(context).textTheme.titleMedium),
const SizedBox(height: 8),
SelectableText(const JsonEncoder.withIndent('  ').convert(claims)),
```

**Recommendation:**
- Wrap the entire debug block in `if (kDebugMode) ...`. Better, move it to a `features/dev/debug_screen.dart` reachable only via a debug-build route.
- Replace `session.accessToken.substring(...)` callers in UI code with `AuthSession`-level getters (`session.email`, `session.emailVerified`, etc.) — UI should never see the JWT string.
- Add a static lint or repo-grep CI check: `session.accessToken` must not appear inside `lib/features/*/presentation/`.

---

## HIGH Issues

### ✅ H-01 Localized error strings hard-coded in `domain/` and `data/` layers
**File:** `lib/features/auth/data/bff_auth_repository.dart:220, 278, 316, 364`; `lib/features/auth/domain/auth_repository.dart:19-22, 32`

**Resolution (2026-05-15):** Full typed-codes + Flutter intl migration. No user-facing strings remain in `domain/` or `data/`.

**Typed error codes:**
- New `lib/features/auth/domain/auth_error_code.dart` — 9 codes covering session, login, refresh, network, unknown.
- New `lib/features/verification/domain/verification_failure.dart` — `VerificationFailure { code, attemptsLeft, diagnostic, ... }` + `VerificationErrorCode` enum (9 codes).
- `AuthFailure` rewritten: `String message` field replaced with `AuthErrorCode code` + `String? diagnostic`. Diagnostic captures the BFF's `error_description` / AppAuth platform message for logs only — never UI.
- `OtpInvalidFailure` and `OtpExpiredFailure` deleted. Replaced by `VerificationFailure(code: otpInvalid/otpExhausted/otpExpired, attemptsLeft: N)`.

**Repository emissions:**
- `bff_auth_repository.dart`: every `throw AuthFailure(<string>)` rewritten to `throw AuthFailure(code: AuthErrorCode.X)`. `_mapDio` now takes a fallback `AuthErrorCode` instead of a string, and emits `network` for transport timeouts.
- `bff_verification_repository.dart`: same shape for `VerificationFailure`. `_mapVerifyDio` discriminates 410 → `otpExpired`, 422+attemptsLeft>0 → `otpInvalid`, 422+attemptsLeft==0 → `otpExhausted`.
- Mock repos: same.

**Bloc state:**
- `AuthState.errorMessage` → `AuthState.errorCode: AuthErrorCode?`.
- `ChannelState.errorMessage` → `ChannelState.errorCode: VerificationErrorCode?` + `attemptsLeft: int?`.

**Flutter intl scaffold:**
- `pubspec.yaml`: added `flutter_localizations`, `intl`, set `flutter: generate: true`.
- New `l10n.yaml` at project root configures `lib/l10n/` as the ARB directory, `app_id.arb` as the template, `AppLocalizations` as the output class (non-synthetic).
- `lib/l10n/app_id.arb` (Indonesian — default, matches all prior copy) and `lib/l10n/app_en.arb` (English parity stub). Generated `app_localizations*.dart` files land in `lib/l10n/`.
- `MaterialApp.router` in `app.dart` wired with `AppLocalizations.localizationsDelegates` + `AppLocalizations.supportedLocales`.

**Presentation mappers:**
- New `lib/features/auth/presentation/auth_error_l10n.dart` — `String authErrorMessage(AppLocalizations, AuthErrorCode)`.
- New `lib/features/verification/presentation/verification_error_l10n.dart` — `String verificationErrorMessage(AppLocalizations, VerificationErrorCode, {int? attemptsLeft})`.
- `login_screen.dart`, `email_otp_screen.dart`, `phone_otp_screen.dart` (both panel + code-step) all updated to read `errorCode` + look up via the mapper. No string lives below `presentation/`.

**Tests:**
- `auth_bloc_test.dart` and `verification_bloc_test.dart` assert on codes, not strings. Behavioral parity preserved.
- `_screen_test_harness.dart` wires `AppLocalizations.localizationsDelegates` + forces `Locale('id')` so existing screen assertions (`find.text('Kode salah. Sisa percobaan: 3.')`) keep working — the localized output equals the prior hardcoded string.
- 59/59 tests passing.

**Side-fix landed with this:** **L-01 — `JwtClaims.fromToken` now logs on parse failure.** Two new `authLog('jwt', ...)` calls (one for "<2 segments", one for "payload was not a JSON object") inside `fromToken`. Debug-only — `authLog` is a no-op in release. Catches the "BFF rotated signing key" failure mode the audit flagged.

**Issue:**
The data and domain layers throw `AuthFailure` / `OtpInvalidFailure` / `OtpExpiredFailure` with **Indonesian** user-facing copy already baked into the message:

```dart
// auth_repository.dart:18-22
super(
  attemptsLeft > 0
      ? 'Kode salah. Sisa percobaan: $attemptsLeft.'
      : 'Kode salah.',
  ...
);

// bff_auth_repository.dart:220
throw AuthFailure('Sesi berakhir. Silakan masuk kembali.', cause: e);
```

This makes the project hostile to internationalisation. To add English, every domain/data file would need to know about `BuildContext`, `AppLocalizations`, or the active locale. The clean-architecture rule violated here: **domain knows nothing about the user**. It should throw a *typed* failure; the presentation layer translates it.

Additionally, the BFF returns `error_description` strings in `_mapDio` (line 370–372) and falls back to a Indonesian default — meaning users may see either a Bahasa Indonesian server message or a Bahasa Indonesian local fallback, with no language switch possible.

**Recommendation:**
- Replace string messages with typed error codes/enums: `AuthFailure.code = AuthErrorCode.sessionExpired` etc.
- Move localisation to `presentation/` via Flutter's `intl`/`flutter_localizations`.
- Treat the BFF's `error_description` as a *diagnostic* string for logs only — never as user copy.

---

### ✅ H-02 Router reads `AuthBloc` state directly — tight coupling
**File:** `lib/core/router/app_router.dart:17, 62, 66-80, 85-96`

**Resolution (2026-05-15):**
- Promoted the `AuthStatus` enum out of `auth_bloc.dart`'s part file into `lib/features/auth/domain/auth_status.dart`. `auth_bloc.dart` re-exports it so existing call sites keep compiling.
- Introduced `lib/core/router/auth_status_listenable.dart` — `abstract class AuthStatusListenable extends ChangeNotifier { AuthStatus get status; }`. `AppRouter` now takes this, not an `AuthBloc`.
- Added the adapter `lib/features/auth/presentation/bloc/auth_bloc_listenable.dart` (`AuthBlocListenable`) which subscribes to `AuthBloc.stream`, caches `status`, and `notifyListeners()` only on status transitions. `SmartApp` constructs it and passes it to `AppRouter`.
- Removed `_AuthBlocListenable` from `app_router.dart` (now handled by the adapter). `AppRouter.dispose()` is gone — listenable lifecycle is owned by `SmartApp` next to the bloc it wraps.
- New test `test/core/router/app_router_test.dart` validates redirects (unknown/unauthenticated/authenticated + transition) using a `_FakeAuthStatus` — no bloc instantiated in the router test. Proves the abstraction.

**Issue:**
`AppRouter` is constructed with an `AuthBloc` and:

1. Reads `authBloc.state.status` synchronously inside `_redirect` to derive the redirect path.
2. Wraps `authBloc.stream` in a custom `_AuthBlocListenable`.

The `core/` module thus depends on `features/auth/presentation/bloc/auth_bloc.dart` — a presentation-layer artefact. Clean architecture would invert this: a top-level `AuthStatusListenable` (or `Stream<AuthStatus>`) abstraction in `core/router/`, with the `AuthBloc` implementing it at the feature side.

Symptoms this causes:
- Adding a second guard (e.g., a maintenance-mode gate) means importing another bloc into core.
- Writing a route test that doesn't spin up `flutter_bloc` is impossible without a fake AuthBloc.
- A future swap of state-management library (e.g., to Riverpod or pure Streams) requires editing core.

```dart
// app_router.dart:62-66
final AuthBloc authBloc;
late final _AuthBlocListenable _refresh;
late final GoRouter config;

String? _redirect(_, GoRouterState state) {
  final status = authBloc.state.status;
```

**Recommendation:**
- Define `abstract class AuthStatusProvider { AuthStatus get status; Stream<AuthStatus> get changes; }` in `core/router/`.
- `AuthBloc` implements it. `AppRouter` depends only on `AuthStatusProvider`.
- This also removes the need for `_AuthBlocListenable` — the provider can yield a `Listenable` natively.

---

### ✅ H-03 VerificationBloc duplicates email/phone handler pairs
**File:** `lib/features/verification/presentation/bloc/verification_bloc.dart:32-187`

**Resolution (2026-05-15):** Channel-parametric collapse via lambdas. The previous 187-line file shrank to ~170 lines but, more importantly, the four near-identical send/verify state machines became two.

**Shape:**
- New private `_onSend({emit, getSlice, putSlice, send, phoneToCache})` owns the `sending → awaitingCode → idle+code` state machine.
- New private `_onVerify({emit, getSlice, putSlice, verify})` owns the `verifying → verified → coded-failure` state machine.
- The four public event handlers (`_onSendEmail`, `_onSendPhone`, `_onVerifyEmail`, `_onVerifyPhone`) are now ~10 lines each and only supply the channel-specific lambdas:
  - `getSlice: () => state.email` vs `() => state.phone`
  - `putSlice: (s) => state.copyWith(email: s)` vs `(s) => state.copyWith(phone: s)`
  - `send` / `verify`: closures that invoke the right repo method.
- Phone-only concerns stay where they belong:
  - `_onSendPhone` passes `phoneToCache: event.phone` so `_onSend` writes the number onto the slice on both the in-flight and success emits.
  - `_onVerifyPhone` keeps the "phone not entered" guard (`VerificationErrorCode.phoneNotEntered`) before delegating to `_onVerify`.

**Behavioral parity proven by tests:** the existing `verification_bloc_test.dart` (10 cases — happy path, otpInvalid+attemptsLeft>0, otpExhausted, otpExpired, send-failure, phone-cache, phone-not-entered, error clearing) passed unchanged. If the refactor had broken the state machine, those tests would have caught it.

**Why lambdas, not an enum-based switch:** the per-channel divergence is just two function calls (read slice, write slice) plus the repo method. Passing them as lambdas keeps the type system honest (the bloc still knows it operates on `ChannelState`) and avoids a `switch (channel) { case email: ... case phone: ... }` block that would re-introduce duplication.

**Adding a third channel** (e.g. NIK verification) is now: one new `*SendOtpRequested` event, one new `_onSendNik` 8-line wrapper, one new `NikChannel` slice on `VerificationState`. No new state machine.

**Issue:**
Four handlers (`_onSendEmail`, `_onSendPhone`, `_onVerifyEmail`, `_onVerifyPhone`) are near-identical pairs that differ only in:

1. Which `ChannelState` field they read/write (`state.email` vs `state.phone`).
2. Which repository method they invoke (`sendEmailOtp()` vs `sendPhoneOtp(phone)`, etc.).
3. The phone variant has an extra `phoneNumber` field.

The result is ~155 lines of near-duplicated state-machine code. A bug fixed in the email path (e.g., a missed `errorMessage: () => null`) is silently inconsistent with the phone path. The duplication will compound as more channels arrive (push-token verification, biometric step-up, etc.).

```dart
// bff_auth_repository.dart pattern — same shape repeated 4×
emit(state.copyWith(
  email: state.email.copyWith(
    status: ChannelStatus.sending,
    errorMessage: () => null,
  ),
));
try { final ttl = await authRepository.sendEmailOtp(); ... }
on AuthFailure catch (e) { ... }
```

**Recommendation:**
- Parametrise on `VerificationChannel` (already an enum, used only by `VerificationErrorCleared`).
- A single `_onSend(VerificationChannel channel, Future<Duration> Function() send)` + a single `_onVerify(...)`. The state slice (`email` vs `phone`) is selected by the channel.
- This collapses ~155 lines to ~60 and guarantees behavioural parity.

---

### ✅ H-04 Two independent Dio instances, no shared HTTP infrastructure
**File:** `lib/core/http/api_client.dart:38-43`, `lib/features/auth/data/bff_auth_api.dart:26-33`

**Resolution (2026-05-15):**
- New `lib/core/network/dio_factory.dart` exposes `createDio({required AppConfig config, Map<String,String>? extraHeaders})` plus shared `kHttpConnectTimeout` / `kHttpReceiveTimeout` constants. Single audit point for the timing contract.
- New `lib/core/network/logging_interceptor.dart` exposes `httpLoggingInterceptor(String tag, {bool logErrorBody = false})`. Replaces the two near-identical `→/←/✗` blocks from `ApiClient` and `BffAuthApi`. `logErrorBody:true` is opt-in for endpoints whose error envelopes are safe to log in debug (BFF `{error, error_description, detail}` shape).
- `ApiClient.create` builds its Dio via `createDio` + layers on `_AuthInterceptor`, `_RefreshInterceptor`, `httpLoggingInterceptor('http')`.
- `BffAuthApi` builds its Dio via `createDio(extraHeaders: {'Content-Type': 'application/json'})` + adds `httpLoggingInterceptor('api', logErrorBody: true)` only. A class-level doc-comment now explicitly documents why this stack deliberately omits the auth/refresh interceptors (recursion on `/auth/refresh` 401 otherwise).

**Issue:**
There are two `Dio` instances in the app:

1. `ApiClient.dio` — created in `core/http/`, configured with `_AuthInterceptor` (bearer injection) and `_RefreshInterceptor` (401 retry). Used for `/api/*` calls.
2. `BffAuthApi._dio` — created inside `features/auth/data/`, no auth interceptors (it adds bearer manually per call). Used for `/auth/*` calls.

The decision to *not* run `/auth/refresh` through the 401 retry loop is correct (infinite recursion otherwise). But the two clients share **nothing** — not the baseUrl handling, not the logger interceptor, not the timeouts, not the JSON content-type header, not the retry-on-network-error policy. The result is two slightly different HTTP stacks and two places to fix when (for example) you add a request-id header or a TLS pinning interceptor.

```dart
// api_client.dart:38-43
final client = dio ?? Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),
));

// bff_auth_api.dart:26-33 — slightly different config, separately maintained
_dio ?? Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),
  headers: {'Content-Type': 'application/json'},
)) { ... separate log interceptor ... }
```

**Recommendation:**
- Introduce `core/network/http_client_factory.dart` exposing `createAuthDio()` and `createApiDio()` from a single base factory.
- Move the debug-log interceptor into a reusable `core/network/logging_interceptor.dart`.
- Keep the divergence (auth-skipping refresh on 401) as a documented choice, not an accident of separate constructors.

---

### ✅ H-05 StreamControllers in repositories are never closed
**File:** `lib/features/auth/data/bff_auth_repository.dart:39`, `lib/features/auth/data/mock_auth_repository.dart:24`

**Resolution (2026-05-15):**
- Added `Future<void> dispose()` to the `AuthRepository` interface with a doc-comment specifying the subscriber-teardown ordering contract.
- `MockAuthRepository.dispose()` closes the controller.
- `BffAuthRepository.dispose()` closes the controller and — when it owns its `BffAuthApi` (i.e. the `api` constructor argument was null) — also disposes the api. Ownership is tracked via an `_ownsApi` flag so injected api instances (tests) keep their lifecycle with the caller.
- Added `BffAuthApi.dispose()` to force-close its Dio.
- `SmartApp.dispose()` now calls `authRepository.dispose()` AFTER `_authListenable.dispose()`, `_authBloc.close()`, and `apiClient.dispose()` so no subscriber observes the closed stream.
- New test `test/features/auth/mock_auth_repository_test.dart` asserts `dispose()` propagates `done` to listeners.

**Issue:**
Both auth repositories own a `StreamController<AuthSession?>.broadcast()` but neither exposes a `dispose()` / `close()` method. The `AuthRepository` interface itself has no lifecycle hook. The controller therefore lives as long as the process — usually fine, but:

- During hot-reload / hot-restart in dev, the previous controller is orphaned but its listeners (`AuthBloc._sub`, `ApiClient._sub`) get reattached to a new one. The old subscriptions hold their `late final StreamSubscription` references.
- If the app ever supports multiple auth realms (citizen vs admin, common in city super-apps), repository swap would silently leak.
- Tests that construct & re-construct the repo will accumulate controllers and emit ghost events.

```dart
// bff_auth_repository.dart:39
final _controller = StreamController<AuthSession?>.broadcast();

@override
Stream<AuthSession?> get sessionChanges => _controller.stream;
// ↑ no matching close()
```

**Recommendation:**
- Add `Future<void> dispose()` to `AuthRepository`.
- `BffAuthRepository.dispose()` closes the controller; `SmartApp.dispose()` calls it.
- Wire it through `AuthRepositoryFactory` (return both repo and disposer, or a `Closeable<AuthRepository>` wrapper).

---

### ✅ H-06 `home_screen.dart` ships debug/internal tooling to production
**File:** `lib/features/home/presentation/home_screen.dart:39-59, 117-167`

**Resolution (2026-05-15):**
Resolved as a side-effect of C-02's fix. `HomeScreen` is now a `StatelessWidget` whose body is `[VerificationBanner, Expanded(child: kDebugMode ? DevDashboard(session) : _CitizenHomePlaceholder())]` and whose appbar actions are `[if (kDebugMode) DevRefreshAction, LogoutAction]`. The home feature no longer imports `AuthRepository`, `JwtClaims`, `SampleApi`, or `dart:convert` — those moved to `lib/features/_dev/dev_dashboard.dart` along with all diagnostic state (`_meResult`, `_apiResult`, `_busy`, `_error`).

The audit's recommended end state was: "appbar (with logout only), `VerificationBanner`, and a placeholder for upcoming citizen-facing tiles." The placeholder (`Selamat datang.`) is in place ready to be replaced by real home content. Future citizen tiles land in `HomeScreen` without touching the dev plumbing.

**Issue:**
Beyond the token-leak issue (C-02), the home screen contains development affordances that have no business in a citizen-facing super-app:

- A "GET /auth/me (BFF)" button that calls the auth repo directly and dumps the JSON.
- A "GET /api/profile (Kong → service)" button that prints the raw response.
- A "Refresh token" appbar icon — useful for diagnosing the 401-retry flow, not for users.

These are *integration tests with a UI*. They couple the home feature to `AuthRepository.getProfile()`, `SampleApi.getProfile()`, and `AuthBloc.add(AuthRefreshRequested())` — the home screen now imports four different modules just to render debug widgets.

This breaks the SoC story: `features/home/` is supposed to be the citizen home, not an internal diagnostics screen. When real home content arrives, this file becomes the place where the team patches around the debug noise instead of starting clean.

**Recommendation:**
- Extract the diagnostic block into `features/_dev/dev_dashboard_screen.dart`, gated behind `kDebugMode` and a route at `/dev` (registered only in debug).
- Reduce `HomeScreen` to: appbar (with logout only), `VerificationBanner`, and a placeholder for upcoming citizen-facing tiles.

---

### ✅ H-07 `verification` feature reaches across the boundary into `auth/domain`
**File:** `lib/features/verification/presentation/bloc/verification_bloc.dart:6`, `lib/core/router/app_router.dart:37`

**Resolution (2026-05-15):** chose option **(b)** from the audit — verification owns its own repository.
- New `lib/features/verification/domain/verification_repository.dart` declares `sendEmailOtp / verifyEmailOtp / sendPhoneOtp / verifyPhoneOtp / dispose`.
- New `lib/features/verification/data/bff_verification_repository.dart` + `mock_verification_repository.dart` implement it. Both delegate session persistence to `AuthRepository.replaceSession(AuthSession)` so the auth stack remains the single source of truth for "the current session".
- New `lib/features/auth/data/mock_jwt.dart` shares the fake-JWT minting between `MockAuthRepository.login`/`refresh` and `MockVerificationRepository._reissue`.
- `AuthRepository` interface now exposes only `restoreSession / login / refresh / logout / getProfile / replaceSession / sessionChanges / dispose`. The four OTP methods are gone.
- `VerificationBloc` constructor parameter renamed `authRepository → verificationRepository`. The cross-feature `import '../../auth/domain/auth_repository.dart'` is now only for `AuthFailure`/`OtpInvalidFailure`/`OtpExpiredFailure` — those move with H-01.
- `verification_bloc_test.dart` now mocks `VerificationRepository`, no longer `AuthRepository`. 59/59 tests passing.

**Side-fix landed with this:** **M-03 — `AuthRepositoryFactory` removed.** The composition root (`lib/main.dart`) now contains the two-line `if/else` directly. Adding a third strategy (recording / federated) is a one-line addition next to the others; no `final class` chokepoint to edit. Same shape used for `VerificationRepository` wiring.

**Issue:**
`VerificationBloc` imports `../../auth/domain/auth_repository.dart` and operates against `AuthRepository.sendEmailOtp`, `verifyEmailOtp`, etc. The verification screens then read `AuthBloc.state.session` to display the verified flags. The `verification` feature has no domain or data layer of its own — it is, in effect, a presentation skin on top of the auth feature.

Two architectural problems:

1. **Cross-feature domain coupling.** A "verification" feature reading another feature's domain interface couples them at the type level. If `AuthRepository.sendEmailOtp` ever changes signature, verification breaks.
2. **Wrong feature boundary.** OTP send/verify is conceptually part of *authentication / account*, not a sibling concern. The current folder split says "verification is its own feature" but the code says it isn't.

```dart
// verification_bloc.dart:6
import '../../auth/domain/auth_repository.dart';

// app_router.dart:37
create: (ctx) => VerificationBloc(
  authRepository: ctx.read<AuthRepository>(),
),
```

**Recommendation:** pick one:
- (a) Move `features/verification/` under `features/auth/verification/`. Verification becomes a sub-flow of auth.
- (b) Create `VerificationRepository` in `features/verification/domain/`. Implement it with `BffVerificationRepository` that *internally* delegates to a narrower `OtpApi`. `AuthRepository` then exposes only login/refresh/logout/profile.

(a) is faster and matches the actual coupling. (b) is cleaner if verification will grow (e.g., NIK verification arriving in `bff_auth_repository`).

---

## MEDIUM Issues

### ✅ M-01 `.env` bundled as Flutter asset used as production config
**File:** `pubspec.yaml:38-41`, `lib/main.dart:12`

**Resolution (2026-05-15):** Documented the constraint. Added a top-of-class SECURITY block on `AppConfig` (`lib/core/config/app_config.dart`) that:
- States explicitly that `.env` is bundled and readable by anyone with the APK/IPA — treat as public data.
- Lists the four allowed keys (`BFF_BASE_URL`, `OAUTH_CLIENT_ID`, `OAUTH_REDIRECT_URI`, `USE_MOCK_AUTH`, `ALLOW_INSECURE_CONNECTIONS`).
- Calls out the forbidden patterns by name (`*_SECRET`, `*_KEY`, `FONNTE_API_KEY`, `KEYCLOAK_CLIENT_SECRET`).
- Recommends `--dart-define=` for build-time values that should NOT ship as a readable asset.
- Flags the `USE_MOCK_AUTH=true`-in-release footgun.

**Why not a CI guard:** the project doesn't yet have a CI pipeline I can wire into; the doc-comment is the durable artifact that survives copy-into-real-app forking. The next dev adding `FONNTE_API_KEY` to `.env` reads this comment when they go to register the env var in `AppConfig.fromEnv()`.

**Issue:**
`.env` is declared as a Flutter asset and loaded with `flutter_dotenv`. Today the fields stored there (`BFF_BASE_URL`, `OAUTH_CLIENT_ID`, `OAUTH_REDIRECT_URI`, `USE_MOCK_AUTH`) are non-secret, so this is *currently* safe. However:

- The pattern conditions developers to put "config" in `.env`. The next developer adding `FONNTE_API_KEY` or `KEYCLOAK_CLIENT_SECRET` will follow the same path. Once bundled, anyone unpacking the APK has the file.
- `USE_MOCK_AUTH=true` accidentally shipped in a release `.env` would cause the production build to launch with the mock repo and silently auth every user as `mock-user-####`.

**Recommendation:**
- Document explicitly in `AppConfig` that `.env` is for **build-time** non-secret defaults only.
- Add a CI guard: production `.env` files must contain `USE_MOCK_AUTH=false` and must not contain `*_SECRET`/`*_KEY` patterns.
- For per-environment values, prefer `--dart-define` build flags read with `String.fromEnvironment`.

---

### ✅ M-02 Storage-shape record leaks from `SecureStore` into repository
**File:** `lib/core/storage/secure_store.dart:38-50`, `lib/features/auth/data/bff_auth_repository.dart:61, 182, 230, 247, 270, 284, 308, 322`

**Resolution (2026-05-15):**
- New `lib/core/storage/stored_session.dart` — `class StoredSession { String accessToken; String sessionId; DateTime expiresAt; }`. Named value type, no anonymous record.
- `SecureStore.readSession()` now returns `StoredSession?`. `writeSession(StoredSession session)` takes one positional argument instead of three named params. `lib/core/storage/secure_store.dart` shrank ~10 lines.
- Bridge factory + projection on `AuthSession`:
  - `factory AuthSession.fromStored(StoredSession)` — domain-side decode.
  - `StoredSession AuthSession.toStored()` — drops JWT-decoded fields, keeps the three persisted ones.
- All call sites in `bff_auth_repository.dart` and `mock_auth_repository.dart` collapsed:
  - `restoreSession` / `getProfile` / `refresh` use `AuthSession.fromStored(stored)` instead of three-field unpacking.
  - `login` / `refresh` / `replaceSession` use `secureStore.writeSession(session.toStored())` instead of three-field passing.
  - `BffAuthRepository._toSession` private helper deleted (was a thin wrapper around `AuthSession.fromToken`; no longer needed).
- The verification repos only need the bearer string — they read `stored.accessToken` directly, which is unchanged.

**Net:** the 3-field shape now lives in exactly two places — `StoredSession` (the wire type) and `SecureStore`'s three storage keys. The "five duplications" the audit called out are gone.

**Issue:**
`SecureStore.readSession()` returns an anonymous record `({String accessToken, String sessionId, DateTime expiresAt})`. Every caller in `BffAuthRepository` reads that record, then *manually* builds an `AuthSession` from its three fields — eight times.

This is an abstraction-boundary smell: `SecureStore` knows the three fields that belong to a session, yet the *concept of a session* is in the domain. The repository is acting as a manual adapter on every method.

```dart
// bff_auth_repository.dart:182
final stored = await secureStore.readSession();
if (stored == null) { throw AuthFailure('No session to refresh.'); }
// ... uses stored.accessToken, stored.sessionId
```

Also: the field set (`accessToken`, `sessionId`, `expiresAt`) is repeated in `writeSession()`, in `AuthSession`, in the record return type, and in the secret keys (`_kAccessToken`, `_kSessionId`, `_kExpiresAt`). Five duplications.

**Recommendation:**
- Have `SecureStore` return/accept `AuthSession` (or a thin `StoredSession` model in `domain/`).
- The repository then calls `secureStore.readSession() → AuthSession?` and `writeSession(session)` without unpacking.

---

### ✅ M-03 `AuthRepositoryFactory` is a closed static switch (does not scale)
**File:** `lib/features/auth/data/auth_repository_factory.dart:10-20` (deleted)

**Resolution (2026-05-15):** Resolved as a side-fix landing with H-07. The factory class is deleted; the two-line `if/else` lives in `lib/main.dart` next to the `VerificationRepository` wiring (same shape). Adding a third strategy is a one-line addition at the composition root — no abstraction to extend.

**Issue:**
```dart
class AuthRepositoryFactory {
  static AuthRepository create({...}) {
    if (config.useMockAuth) return MockAuthRepository(...);
    return BffAuthRepository(...);
  }
}
```

It is a static method with a boolean switch. Adding a third strategy (e.g., a `RecordingAuthRepository` for integration tests, or a `FederatedAuthRepository` for a partner OIDC provider) requires editing this file. The factory class adds nothing over a top-level function — yet it makes the construction point a chokepoint.

**Recommendation:**
- Delete the factory class. Move the two-line `if/else` into `main.dart`, where the rest of the wiring lives. It's a composition root, not an abstraction.
- For testing, accept `AuthRepository` directly via constructor injection in `SmartApp` (already done).

---

### ✅ M-04 Magic numbers scattered across the codebase
**File:** `lib/features/auth/data/bff_auth_repository.dart:82`, `lib/features/auth/data/bff_auth_api.dart:101, 134`, `lib/features/auth/data/mock_auth_repository.dart:58, 77, 113, 130`, `lib/features/verification/presentation/widgets/resend_timer.dart:14`

**Resolution (2026-05-15):**
- New `lib/core/config/auth_timings.dart` — single audit point for the auth/OTP timing contract:
  - `kOauthLoginTimeout = Duration(minutes: 3)`
  - `kOtpDefaultTtl = Duration(seconds: 300)`
  - `kMockSessionLifetime = Duration(minutes: 5)`
  - `kOtpResendCooldown = Duration(seconds: 60)`
- Replaced all literal occurrences:
  - `bff_auth_repository.dart`: `_loginTimeout` private const removed; both call sites use `kOauthLoginTimeout`.
  - `bff_auth_api.dart`: both `expires_in ?? 300` fallbacks now use `kOtpDefaultTtl.inSeconds`.
  - `mock_auth_repository.dart`: `Duration(minutes: 5)` (×2) → `kMockSessionLifetime`.
  - `mock_jwt.dart`: JWT `exp` claim uses `kMockSessionLifetime`.
  - `mock_verification_repository.dart`: OTP TTL (×2) → `kOtpDefaultTtl`; session lifetime → `kMockSessionLifetime`.
  - `resend_timer.dart`: default cooldown → `kOtpResendCooldown`.

HTTP timeouts (`kHttpConnectTimeout`, `kHttpReceiveTimeout`) already lived in `core/network/dio_factory.dart` from H-04. Together the two files cover every timing constant in the auth stack.

**Issue:**
- AppAuth login timeout: `Duration(minutes: 3)` (`bff_auth_repository.dart:82`).
- OTP TTL fallback: `300` seconds (`bff_auth_api.dart:101, 134`).
- Mock session lifetime: `Duration(minutes: 5)` (mock repo, four occurrences).
- Mock send-OTP TTL: `Duration(seconds: 300)` (mock repo, two occurrences).
- Resend cooldown: `Duration(seconds: 60)` (resend_timer widget default).

These all describe the **same physical system** (the auth/OTP TTL contract with the BFF). Tuning one without the others creates skew: e.g. UI shows "Kirim ulang dalam 4:50" while the server has already expired the code.

**Recommendation:**
- Introduce `core/config/auth_timings.dart` (or extend `AppConfig` with a `timings` sub-object) holding `oauthLoginTimeout`, `otpTtl`, `otpResendCooldown`, `mockSessionLifetime`.
- Default values stay where they are today (production safety), but a single read-out lets a reviewer audit the timing contract in one place.

---

### ✅ M-05 `AuthBloc` has dual transition paths (explicit + stream-mirror)
**File:** `lib/features/auth/presentation/bloc/auth_bloc.dart:42-84`

**Resolution (2026-05-15):** Adopted the audit's "cleanest path" — handlers emit only transient + error states; the session stream is the sole source of truth for `authenticated`.

**New invariants** (documented in a class-level comment on `AuthBloc`):
- Handlers emit ONLY: `authenticating`, `unauthenticated(errorCode: ...)`, or `unauthenticated()` on app start when storage is empty.
- The `authenticated` state arrives exclusively via `_onSessionChanged`. Whether the source is login, refresh, restoreSession, `replaceSession` (from verification), or any future out-of-band path, the bloc reacts the same way.
- `_onSessionChanged(null | expired)` will NOT clobber an error state. The refresh-401 path adds null on the stream AND throws `AuthFailure(sessionExpired)`; the handler's typed error is the user-visible signal and the queued null is a no-op.
- `_onSessionChanged` also filters expired sessions — restoreSession can emit an expired session on the stream, but the bloc never lifts to `authenticated` on one.

**Handler bodies:**
- `_onStarted`: emit `unauthenticated()` only for null/expired restores. Valid → stream delivers.
- `_onLoginRequested`: emit `authenticating`, then on success: no emit. On `AuthFailure`: emit `unauthenticated(errorCode)`.
- `_onRefreshRequested`: success → no emit. On `AuthFailure`: emit `unauthenticated(errorCode)`.
- `_onLogoutRequested`: no emit — repo's logout() adds null to the stream and `_onSessionChanged` lifts to `unauthenticated()`.

**Test coverage:**
- `auth_bloc_test.dart` rewritten: mocks now emit on the stream where the real repo does. The mock for login/refresh-success adds the new session via `sessionController.add(s)` inside the `thenAnswer`. Logout's mock adds null.
- New test `refresh-401 path: stream null emission does not clobber the error code` directly exercises the previously-racy scenario — the mock emits null on the stream AND throws `AuthFailure(sessionExpired)`, and the test asserts the bloc settles on `unauthenticated(errorCode: sessionExpired)`. Would have failed against the pre-M-05 bloc.
- 60/60 tests passing (was 59; +1 for the new race coverage).

**Architectural win for the real-app fork:** the bloc no longer needs `AuthSession` to be `Equatable` to dedupe state. Adding a `DateTime issuedAt` to `AuthSession` (or any other non-equal field) won't produce duplicate state emissions — there's only ever one path that emits `authenticated`.

**Issue:**
On a successful login:

1. `_onLoginRequested` calls `authRepository.login()`. The repo `_controller.add(session)` → fires `_AuthSessionChanged` (queued event).
2. `_onLoginRequested` then `emit(AuthState.authenticated(session))`.
3. The bloc later processes the queued `_AuthSessionChanged` → guard `state.session != s` says they are equal (Equatable) → no-op emit.

This works today only because `AuthSession` is `Equatable` and the repo emits exactly the same object. If a future change introduces a non-Equatable field (e.g. a `DateTime.now()` issuedAt), the guard would fire and emit a duplicate `authenticated` state — harmless for the UI but observable in tests and analytics.

Worse: if a refresh happens concurrently with an in-flight login (race-y scenario, but `ApiClient._RefreshInterceptor` will trigger this on any 401 during the brief window after login), the order of explicit-emit vs stream-mirror-emit is not deterministic. The handler emits `unauthenticated(errorMessage: ...)` on `AuthFailure`, then the stream-mirror could emit `unauthenticated()` again with no error message and erase the message.

**Recommendation:**
- Pick one source of truth. The cleanest path: handlers do NOT call `emit` themselves; they `await` the repo, and the bloc state is purely driven by `sessionChanges` + a separate `_status` stream for `authenticating` / error transitions.
- Or: drop the stream subscription entirely and have the repo not emit on `login`/`refresh`/`logout` (only on internal-state changes like 401-induced clear).

---

### ✅ M-06 No `core/error` or `core/network` modules; mapping bound to the repository
**File:** `lib/features/auth/data/bff_auth_repository.dart:349-378`

**Resolution (2026-05-15):** `core/network/` already existed from H-04 (`dio_factory.dart`, `logging_interceptor.dart`); this fix completes it by adding the BFF error-envelope parser. The previously-private mappers in `BffAuthRepository` and `BffVerificationRepository` are now thin wrappers around one shared helper.

**New:**
- `lib/core/network/bff_error.dart` — exposes:
  - `BffErrorInfo { statusCode, isTimeout, errorDescription, attemptsLeft }` — parsed view of any Dio failure against the BFF.
  - `BffErrorInfo describeBffError(DioException)` — pure parser: extracts `error_description`, `detail.attempts_left`, the status code, and the timeout flag. No domain failure construction.

**Refactor:**
- `BffAuthRepository._mapDio` — now 7 lines: `describeBffError(e)` → `AuthFailure(code: isTimeout ? network : fallback, diagnostic: ...)`. The body-parsing / timeout-detection logic that used to live here is gone.
- `BffVerificationRepository._mapDio` — same shape, builds `VerificationFailure` instead.
- `BffVerificationRepository._mapVerifyDio` — reads `info.statusCode` / `info.attemptsLeft` from the parsed info; the OTP-specific 410/422 discrimination stays here because it's verification-specific.

**Tests:**
- New `test/core/network/bff_error_test.dart` — 7 cases covering error_description extraction, attempts_left parsing, timeout-type detection across all three Dio timeout variants, transport-level errors (no response), non-Map body tolerance, and null body tolerance.
- Existing repo behavior unchanged — all bloc tests still pass (67/67).

**Deliberately NOT done — no `core/error/` folder, no shared `DomainFailure` interface:**
The audit's recommendation included a `DomainFailure` interface that both `AuthFailure` and `VerificationFailure` would implement. Skipped because no consumer in this codebase catches a generic `DomainFailure` — each presentation maps its own typed code to localized copy. Adding the interface now would be premature abstraction. The wire-format extraction (which is the real duplication) is what landed.

**Architectural win for the real-app fork:** adding a new feature with its own typed failure (e.g. `KycFailure` with `KycErrorCode`) gets the same 7-line mapper "for free" — no need to re-implement the BFF envelope parser. New OTP-style status codes (e.g. 429 rate-limited) get added once in `_mapVerifyDio` and apply to every channel.

**Issue:**
`_mapDio` and `_mapVerifyDio` live as private members of `BffAuthRepository`. They:

- Read the BFF's `error_description` / `detail` / `attempts_left` envelope.
- Decide retry-ability from Dio's exception types.
- Map HTTP status codes (410, 422) to typed domain errors.

This logic is reusable across every future repository (sample, profile, notifications). Today it cannot be reused because it's `_private`. The first new feature to need a network call will copy-paste these two helpers.

**Recommendation:**
- `core/error/`: define `ApiError` (transport-level), `DomainFailure` interface, and a `mapDioToFailure(DioException, FailureMapping)` helper.
- `core/network/`: shared interceptors and the BFF envelope shape.
- `BffAuthRepository._mapDio` becomes a thin alias supplying the auth-specific mapping table.

---

## LOW Issues

### ✅ L-01 `JwtClaims.empty()` swallows parse errors silently
**File:** `lib/features/auth/domain/jwt_claims.dart:54-56`

**Resolution (2026-05-15):** Resolved as a side-fix with H-01. `JwtClaims.fromToken` now emits `authLog('jwt', 'decode failed: <reason>')` on the two failure paths (`<2 segments` and `payload was not a JSON object`). Debug-only via `authLog`'s `kDebugMode` guard, so no leak to release logs. Catches the "BFF rotated signing key, device can't decode new tokens" symptom early.

**Issue:**
```dart
} catch (_) {
  return JwtClaims.empty();
}
```

Any decode failure (truncated token, malformed base64, JSON garbage) returns a fully-empty claims object. Verified flags default to `false`, so security-wise this is correct (no false positives). But the user-visible effect is "everything looks unverified" with **zero log trace** — which is the exact symptom of a BFF that just rotated its signing key and started minting tokens the device can't decode.

**Recommendation:**
- `authLog('jwt', 'decode failed: $e')` inside the catch block. `authLog` is already debug-only.

---

### ✅ L-02 Dead code: unused `_otpKey` in `email_otp_screen.dart`
**File:** `lib/features/verification/presentation/screens/email_otp_screen.dart:20, 70`

**Resolution (2026-05-15):** Deleted the `final _otpKey = GlobalKey<State>();` field and removed the `key: _otpKey` argument from the `OtpInput`. Two lines gone.

**Issue:**
```dart
final _otpKey = GlobalKey<State>();
...
OtpInput(
  key: _otpKey,
  ...
)
```

`_otpKey` is typed `GlobalKey<State>` (the generic exposes nothing useful) and is never read — no `.currentState`, no `.currentContext`, no nothing. It exists only because the developer probably planned to call `OtpInput.clear()` on error and never wired it. Costs a stable key allocation per build that does nothing.

**Recommendation:** delete the field and the `key:` argument; or, if `clear()`-on-error is wanted, type it as `GlobalKey<_OtpInputState>` (requires making `_OtpInputState` non-private) and call `currentState?.clear()` in the error path.

---

### ✅ L-03 `OtpInput` relies on `Opacity(0.01)` autofill hack
**File:** `lib/features/verification/presentation/widgets/otp_input.dart:73-89`

**Resolution (2026-05-15):** Accessibility addressed — wrapped the widget in `Semantics(label: 'OTP code', textField: true, ...)` and put `ExcludeSemantics` on the painted overlay row. Screen readers now see one logical "OTP code" text field instead of the underlying TextField + 6 unlabeled `Container` boxes.

**Not done (intentional):** the `Opacity(0.01)` workaround stays. The audit suggested migrating to `pinput` or a custom-painter approach; both are bigger scopes than the audit's severity warrants, and the current widget works correctly with platform autofill (`AutofillHints.oneTimeCode`) — which is the user-visible win.

**Issue:**
The widget renders the real `TextField` at `Opacity(0.01)` so platform IME/autofill heuristics still treat it as a focusable text input. The comment is honest about the reason, but a 0.01-opacity full-size invisible TextField:

- Will still claim hit-test area in some layouts (currently mitigated by `IgnorePointer` only on the painted overlay; the TextField itself can still be tapped, which is the intended behaviour — but it's fragile if a future refactor wraps it in `AbsorbPointer`).
- Is unfriendly to a11y: screen readers see "TextField" overlaid by six unlabeled boxes.

**Recommendation:**
- Add a `Semantics(label: 'OTP code', textField: true)` wrapper.
- Consider migrating to `pinput` or Flutter's `TextField` with `decoration: InputDecoration(...).withDigitBoxes()` (custom painter) instead of the dual-layer hack.

---

### ✅ L-04 `_log` shadow helpers duplicated across files
**File:** `lib/features/auth/data/bff_auth_repository.dart:13`, `lib/features/auth/data/bff_auth_api.dart:7`, `lib/features/auth/presentation/bloc/auth_bloc.dart:13`

**Resolution (2026-05-15):** Added `void Function(String) authLogger(String tag)` factory to `lib/core/logging/auth_log.dart`. Each consumer replaces `void _log(String msg) => authLog('<tag>', msg);` with `final _log = authLogger('<tag>');` — same ergonomics, one less per-file helper to maintain.

Updated: `bff_auth_repository.dart` (tag `'repo'`), `bff_verification_repository.dart` (`'verify'`), `auth_bloc.dart` (`'bloc'`). `bff_auth_api.dart` no longer declares its own `_log` since H-04 — the shared logging interceptor handles all of its tagging.

**Issue:**
Three files each declare:

```dart
void _log(String msg) => authLog('<tag>', msg);
```

The only thing that differs is the tag. Adds three private functions, three top-of-file `import` blocks of the same logger, and three places to maintain. Not a bug, but the small duplications accumulate as features grow.

**Recommendation:** `final _log = authLogger('bloc');` returning a `void Function(String)`; or just inline `authLog('bloc', ...)` at call sites — there are not that many.

---

## Architectural Synthesis

The codebase has a clearly intentional Clean-Architecture skeleton (`presentation/` ↔ `domain/` ↔ `data/`, feature folders, repository + factory) and a sound security stance (BFF-only contract, no direct IdP access, secure storage). Three structural themes account for most of the findings:

1. **Leakage across layer boundaries (C-02, H-01, H-06, M-02).** The domain knows Indonesian; the presentation knows JWT bytes; the storage knows session shape. Each of these is a small leak — together they erode the layering the directory structure advertises.
2. **Duplication instead of abstraction (C-01, H-03, H-04, M-04, M-06, L-04).** The same logic exists in 2–4 places: JWT decoding, verification handlers, HTTP client setup, magic timings, network error mapping. None of these would be on fire by itself, but the cumulative cost is large when the second BFF endpoint family arrives.
3. **Closed extension points (H-02, H-07, M-03).** The router *is* the AuthBloc's listener; verification *is* the auth repo's UI; the factory *is* a boolean. The codebase optimises for the one-realm, one-flow, one-state-management case it currently serves — which is the right call for v1, but should be opened up before the second feature family lands.

**Top-3 highest-leverage fixes (do these first):**

1. **C-02 + H-06:** Strip token/JWT from the production UI. Move the diagnostics to a `kDebugMode`-gated dev screen.
2. **C-01:** Collapse JWT decoding to `JwtClaims.fromToken`. One line per call site.
3. **H-01:** Decouple user-facing copy from domain errors. Use typed `AuthErrorCode`s; localise in `presentation/`.

These three unblock the rest: i18n becomes possible, the home screen becomes ready for real content, and the JWT format is owned by one file. Everything else (H-03/H-04/H-05 cleanup, the `core/network` and `core/error` modules, the factory simplification) can land incrementally.
