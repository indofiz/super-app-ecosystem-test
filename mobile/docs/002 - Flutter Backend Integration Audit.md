# 002 - Flutter Backend Integration Audit

**Date:** 2026-05-15
**Scope:** `mobile/lib/**` — API integration and data-flow layer of the Flutter client. Specifically: `core/http/api_client.dart`, `core/storage/secure_store.dart`, `core/config/app_config.dart`, `features/auth/data/bff_auth_api.dart`, `features/auth/data/bff_auth_repository.dart`, `features/auth/data/mock_auth_repository.dart`, `features/auth/data/auth_repository_factory.dart`, `features/auth/domain/{auth_repository,auth_session,jwt_claims}.dart`, `features/sample/data/sample_api.dart`, `features/auth/presentation/bloc/auth_bloc.dart`, `features/verification/presentation/bloc/verification_bloc.dart`, `features/home/presentation/home_screen.dart`. Cross-cutting concerns evaluated: API integration structure (datasource vs repository), JSON parsing & mapping safety, error handling, retry/timeout/cancellation, API↔UI model coupling, caching, and client↔server data consistency.
**Severity Levels:** CRITICAL | HIGH | MEDIUM | LOW

**Status Legend:** ✅ Fixed | ⚠️ Partially Fixed | ❌ Not Fixed

---

## Summary Table

| #     | Issue                                                                       | Severity | Status |
|-------|-----------------------------------------------------------------------------|----------|--------|
| C-01  | Unchecked JSON casts in `BffAuthApi` — TypeError on any BFF contract drift  | CRITICAL | ✅     |
| C-02  | `SampleApi` has zero error handling — `DioException` leaks raw to the UI    | CRITICAL | ✅     |
| C-03  | Session `expiresAt` computed from `DateTime.now() + expires_in` (clock skew)| CRITICAL | ✅     |
| H-01  | No DataSource layer — repository fuses HTTP + storage + mapping             | HIGH     | ❌     |
| H-02  | No request cancellation — in-flight calls outlive widget/bloc lifecycle     | HIGH     | ⚠️     |
| H-03  | API responses are raw `Map<String, dynamic>` — no DTO / no compile safety   | HIGH     | ❌     |
| H-04  | Retry only on HTTP 401 — transient 5xx and network errors surface as errors | HIGH     | ❌     |
| H-05  | `restoreSession` emits expired session and never revalidates with `/auth/me`| HIGH     | ❌     |
| H-06  | `logout()` swallows BFF errors silently → server-side zombie session        | HIGH     | ❌     |
| H-07  | Verify-OTP rebinds phone from bloc state — diverges from server-side binding| HIGH     | ❌     |
| M-01  | Two Dio instances configured by hand — no shared timeouts/headers/interceptors | MEDIUM   | ❌     |
| M-02  | Field-naming contract drift — `email_verified` (JWT) vs `emailVerified` (REST) | MEDIUM   | ❌     |
| M-03  | No send-timeout configured — only `connectTimeout` / `receiveTimeout`       | MEDIUM   | ❌     |
| M-04  | No correlation / request-id header — mobile↔BFF errors are not traceable    | MEDIUM   | ❌     |
| M-05  | No HTTP-level caching strategy — `/auth/me` round-trips for data already in JWT | MEDIUM   | ❌     |
| M-06  | Error mapping inspects only `error_description` — loses `error`/`error_code`/`detail` | MEDIUM   | ❌     |
| M-07  | `connectionError` is not flagged retryable in `_mapDio`                     | MEDIUM   | ⚠️     |
| L-01  | Anonymous record return types leak HTTP shape into call sites               | LOW      | ❌     |
| L-02  | `getMe` defaults to `const {}` on null body — emits silent empty profile    | LOW      | ✅     |
| L-03  | Mock vs Real session lifetime mismatch (5 min fixed vs server `expires_in`) | LOW      | ✅     |
| L-04  | `.cast<String>()` on `roles` is lazy — failures surface far from parse site | LOW      | ✅     |

**Progress: 6/21 fixed, 2 partial, 13 remaining** _(updated 2026-05-15 — C-01/C-02/C-03 + collateral fixes for L-02/L-03/L-04 and partial mitigations for H-02 scenario 3, M-07 on `/api/*`.)_

---

## CRITICAL Issues

### ✅ C-01 Unchecked JSON casts in `BffAuthApi` — TypeError on any BFF contract drift
**File:** `lib/features/auth/data/bff_auth_api.dart:65-70, 81-87, 91-103, 107-119, 124-136, 140-152`

**Issue:**
Every BFF response is parsed by direct cast against `Map<String, dynamic>` keys, with no guard:

```dart
// bff_auth_api.dart:65-70
final body = res.data ?? const {};
return (
  accessToken: body['access_token'] as String,       // throws if null
  sessionId:   (body['session_id'] as String?) ?? sessionId,
  expiresIn:   (body['expires_in'] as num).toInt(),  // throws if null OR if string
);
```

There are six such call sites — `refresh`, `getMe`, `sendEmailOtp`, `verifyEmailOtp`, `sendPhoneOtp`, `verifyPhoneOtp` — and they all share the same pattern: hard cast first, optional defaults second. The hard casts are the issue.

Why this is dangerous in real-world scenarios:
1. The BFF currently returns `access_token`. The instant a backend change renames it to `accessToken`, or omits it on a 200 with `verified:true` (the documented "already verified" path is documented for `send-otp` but the same shape risk exists for `verify-otp` once retries land), the cast throws a `_TypeError` — not an `AuthFailure`. The repository's `catch (DioException)` doesn't fire; the bloc's `catch (AuthFailure)` doesn't fire. The error reaches `runZonedGuarded`-territory and the user sees an empty error state.
2. `body['expires_in'] as num` throws if the value is missing OR is a JSON `String` (e.g. `"3600"`). The cast yields a `CastError` with a non-localised stack trace inside the data layer.
3. The "fall back to default" branch (`(body['session_id'] as String?) ?? sessionId`) implies care was taken to handle nulls — but the line above (`access_token`) and the line below (`expires_in`) do not. The inconsistency itself signals a contract not understood uniformly.
4. None of these errors are caught and re-thrown as `AuthFailure`. `BffAuthRepository.refresh` wraps in `on DioException` only — a `TypeError` from the parser is uncaught and propagates as a plain Dart error.

This is the single highest-risk file in the integration layer: the BFF is the only source of truth for session state, and the only barrier between "the BFF response" and "the rest of the app" is six lines of unchecked casts.

```dart
// bff_auth_api.dart:107-119  ← verifyEmailOtp; identical pattern
final res = await _dio.post<Map<String, dynamic>>(
  '/auth/email/verify-otp',
  data: {'code': code},
  options: Options(headers: {'Authorization': 'Bearer $bearer'}),
);
final body = res.data ?? const {};
return (
  accessToken: body['access_token'] as String,         // ← unguarded
  sessionId:   body['session_id'] as String,            // ← unguarded
  expiresIn:   (body['expires_in'] as num).toInt(),     // ← unguarded
);
```

**Recommendation:**
- Introduce a `parseSessionResponse(Map body) → ParsedSession` helper that validates each required field and throws a typed `BffParseFailure(field, actualType)`.
- Wrap `BffAuthApi` calls inside `BffAuthRepository` in `try { ... } on TypeError catch (e) { throw AuthFailure('BFF contract mismatch', cause: e); } on BffParseFailure ...` — keep the failure typed all the way to the bloc.
- Better: replace the anonymous records with typed DTOs (see H-03) and parse via a single validating constructor.

**Fix landed (2026-05-15):**
- Added `lib/core/network/bff_parse.dart` with `BffParseFailure(field, reason)` and validating helpers: `requireBody`, `requireString`, `optionalString`, `requireInt`, `optionalInt`, `optionalBool`. `requireInt` tolerates numeric strings (`"3600"`), so the audit's case 2 produces an `expires_in: 3600` instead of throwing.
- Rewrote all six parse sites in `bff_auth_api.dart` to use the helpers — no raw cast remains in the file. `getMe` now uses `requireBody` (closes L-02 too).
- Added `on BffParseFailure` and `on TypeError` arms to every call site in `bff_auth_repository.dart` (`refresh`, `getProfile`) and `bff_verification_repository.dart` (all four send/verify methods). Contract drift now reaches the bloc as a typed `AuthFailure(refreshFailed | unknown)` or `VerificationFailure(sendOtpFailed | verifyOtpFailed)`, never as a raw `_TypeError`.
- `getProfile` also eagerly materializes `roles` via `List<String>.from(...)` instead of `.cast<String>()` (closes L-04).
- Tests: `test/core/network/bff_parse_test.dart` covers each helper's missing / wrong-type / numeric-coercion paths.

DTO migration (H-03) and a single nominal `ParsedSession` constructor are deliberately kept as a follow-up — the helpers are sufficient to close the cast-throws-untyped path.

---

### ✅ C-02 `SampleApi` has zero error handling — `DioException` leaks raw to the UI
**File:** `lib/features/sample/data/sample_api.dart:15-18`, `lib/features/home/presentation/home_screen.dart:53-59`

**Issue:**
`SampleApi.getProfile()` is the entire body of the Kong-side integration:

```dart
// sample_api.dart:15-18
Future<Map<String, dynamic>> getProfile() async {
  final res = await _dio.get<Map<String, dynamic>>('/api/profile');
  return res.data ?? const {};
}
```

It has no try/catch, no DioException mapping, no domain failure type. Whatever Dio throws — `DioExceptionType.connectionTimeout`, a 5xx, a 401 that survives the refresh-interceptor (i.e. refresh itself failed), a TLS handshake error — propagates verbatim to the caller. The caller is `home_screen._fetchApiProfile`:

```dart
// home_screen.dart:53-59
Future<void> _fetchApiProfile() => _run(() async {
      final api = context.read<SampleApi>();
      final body = await api.getProfile();   // ← raw DioException from here
      setState(() => _apiResult = const JsonEncoder.withIndent('  ').convert(body));
    });

// home_screen.dart:32-34
} catch (e) {
  setState(() => _error = '$e');             // ← "DioException [bad response]: …"
}
```

The UI ends up rendering a stringified `DioException` — including the request URL, headers, status, response body — to the user. This is both a UX failure (the message is incomprehensible) and a leak surface (the raw error includes the bearer header value if you ever flip Dio's `printError` on, and includes server-side error envelopes that should not reach a citizen device's screen).

Beyond UX: `SampleApi` is the **template** for every future `/api/*` integration in the super-app (notifications, payments, citizen profile, etc.). If the first one shipped without error mapping, every next one will follow. The cost compounds: by the time the second Kong-side service ships, you have two unmapped APIs and the project has accidentally chosen "raw Dio exceptions are fine" as policy.

Comparison with the auth side: `BffAuthRepository._mapDio` exists and does most of the mapping correctly (extracting `error_description`, marking timeouts retryable). It is `_private` — invisible to `SampleApi`.

**Recommendation:**
- Create `core/error/api_failure.dart` with `ApiFailure(message, code, cause, retryable)`.
- Create `core/network/dio_error_mapper.dart` exposing `mapDioToFailure(DioException e, {String fallback}) → ApiFailure` — move the contents of `BffAuthRepository._mapDio` here.
- `SampleApi.getProfile` wraps the `_dio.get` in `try { ... } on DioException catch (e) { throw mapDioToFailure(e, fallback: '...'); }`.
- The UI catches `ApiFailure` and renders `failure.message`. The repository can keep `cause` for logs.

**Fix landed (2026-05-15):**
- Added `lib/core/network/api_failure.dart` with `ApiErrorCode { network, server, unauthorized, forbidden, notFound, badRequest, parse, unknown }`, `ApiFailure(code, diagnostic, cause, retryable)`, and `mapDioToApiFailure(...)` / `mapParseToApiFailure(...)`. `mapDioToApiFailure` reuses `describeBffError` (no envelope-parsing duplication) and treats `connectionError` plus all three timeouts as retryable — picks up M-07 on the `/api/*` side as a side benefit.
- Wrapped `SampleApi.getProfile` with `on DioException` → `mapDioToApiFailure` and `on BffParseFailure` → `mapParseToApiFailure`. The raw `Map` default (`?? const {}`) is gone — `requireBody` is used, so an empty Kong response surfaces as `ApiFailure(parse)` instead of a phantom empty profile.
- Updated the only current call site (`lib/features/_dev/dev_dashboard.dart`) to catch `ApiFailure` and render the typed code; the stringified-`DioException` leak the audit flagged no longer reaches `setState(_error = '$e')`.
- Tests: `test/core/network/api_failure_test.dart` covers every status-code and `DioExceptionType` branch.

When future citizen-facing `/api/*` repositories ship, they inherit `ApiFailure` for free — presentation localizes off `ApiErrorCode`, the same way `AuthErrorCode` / `VerificationErrorCode` are resolved today.

---

### ✅ C-03 Session `expiresAt` computed from `DateTime.now() + expires_in` — clock skew creates split-brain sessions
**File:** `lib/features/auth/data/bff_auth_repository.dart:196, 291, 329`, `lib/features/auth/data/mock_auth_repository.dart:58, 77, 113, 130, 156`

**Issue:**
Every place mobile mints a session lifetime, it does this:

```dart
// bff_auth_repository.dart:196 (refresh)
expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),

// bff_auth_repository.dart:291 (verifyEmailOtp)
expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),

// bff_auth_repository.dart:329 (verifyPhoneOtp)
expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
```

The internal JWT itself contains an authoritative `exp` claim (`JwtClaims.fromToken` decodes everything *except* expiry). Mobile is throwing away the server-stamped truth and substituting a value computed from the **device's wall clock** plus a duration. Three concrete failure modes:

1. **Backwards-set device clock (most common).** Citizen rolls their phone back two hours to "extend" something else (a free trial, a game cool-down). `DateTime.now() + 3600s` becomes 2h earlier than the JWT's `exp`. Mobile thinks the session is still valid for 2h longer than the BFF does. Every `/api/*` call 401s; the refresh interceptor fires; the refresh succeeds (BFF accepts up to 24h-expired bearer per §2.1 of the BFF plan); but the new session expiry is *also* computed from the wrong clock. The user sits in an authenticated state that the BFF will not honour.
2. **Forward-set device clock.** Phone clock is 10 minutes ahead. `AuthSession.isExpired` (`DateTime.now().isAfter(expiresAt)`) flips to true 10 minutes before the BFF actually rotates. The user is silently force-logged-out every session.
3. **Network latency.** Mobile takes the timestamp at receive time. If the BFF mints the JWT, then nginx adds 800ms latency, then the mobile parses 200ms later — that's 1 second of session lifetime the client never sees.

In a super-app where the user's clock is **not** under your control, the only authoritative session expiry is the JWT's `exp` claim. `JwtClaims` already decodes the payload — `exp` simply isn't read.

The mock repo doubles down on the issue: it hard-codes `Duration(minutes: 5)` for its session lifetime, decoupling completely from what the JWT's `exp` says (it stamps `exp` itself but then ignores it on read). Tests written against the mock will not surface the bug.

```dart
// mock_auth_repository.dart:58
expiresAt: DateTime.now().add(const Duration(minutes: 5)),  // ← fixed, not from token

// mock_auth_repository.dart:192-193 — token has exp, but
'exp': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
// ← never read back
```

**Recommendation:**
- Add `int? exp` to `JwtClaims`; have `JwtClaims.fromToken` populate it from `raw['exp']`.
- Compute `AuthSession.expiresAt` from `JwtClaims.exp` when present, falling back to `DateTime.now() + expires_in` only on parse failure.
- For sanity (when device clock is wildly off), still expose `expires_in` to the UI for "session valid for ~N more minutes" cosmetic countdowns. Auth decisions stay tied to `exp`.
- Mock repo: derive `expiresAt` from the `exp` claim it itself stamps. Drift between mock and real is then impossible by construction.

**Fix landed (2026-05-15):**
- Added `DateTime? exp` to `JwtClaims`. `JwtClaims.fromToken` reads `raw['exp']` via a tolerant `_decodeExp` (accepts `num` and numeric `String`, returns UTC). Missing or unparseable → null.
- `AuthSession.fromToken` now prefers `claims.exp` over the passed `expiresAt`: `expiresAt: claims.exp ?? expiresAt`. The `expiresAt` parameter is now a fallback only, used when the token has no `exp` claim (a BFF contract violation).
- Callers (`bff_auth_repository.refresh`, `bff_verification_repository.verifyEmailOtp` / `verifyPhoneOtp`, `mock_auth_repository.login` / `refresh`) are unchanged on the call side — the wall-clock fallback they pass is now only used on parse failure. Closes L-03 too: the mock JWT already stamps `exp` from `kMockSessionLifetime`, so the session's `expiresAt` now derives from that same source by construction; the hard-coded 5-min lifetime in mock-repo bodies is dead code (still passed as fallback, never used).
- Logout-during-refresh race (C-03 scenario 3) mitigated: `bff_auth_repository.refresh` now re-reads `secureStore` between the API response and the local write. If storage was cleared mid-flight (concurrent `logout()`), the refresh aborts with `AuthFailure(notAuthenticated)` instead of resurrecting the session. Full request-cancellation (H-02) is still a follow-up.
- Tests: `test/features/auth/jwt_claims_test.dart` (numeric / numeric-string / missing / non-numeric / unparseable token) and `test/features/auth/auth_session_test.dart` (prefers JWT exp; falls back when claim missing; falls back on garbage token).

---

## HIGH Issues

### ❌ H-01 No DataSource layer — repository fuses HTTP + storage + mapping
**File:** `lib/features/auth/data/bff_auth_repository.dart` (entire file)

**Issue:**
The codebase advertises a clean-architecture split (`domain/` ↔ `data/`), but inside `data/` there is no distinction between **remote data source**, **local data source**, and **repository**. `BffAuthRepository` does all three jobs in one class:

- Calls `BffAuthApi` (the remote source).
- Calls `SecureStore` (the local source).
- Maps the HTTP-shaped responses to domain types.
- Houses error-mapping logic (`_mapDio`, `_mapVerifyDio`).
- Owns the `StreamController` that broadcasts session changes.

This is the same anti-pattern as making one God class do everything called "repository". A canonical clean-arch repository has a tighter contract: it orchestrates one *remote* and one *local* data source, both injected. The current shape conflates the three.

Concrete consequences:
1. **Unit testing is awkward.** To test "refresh succeeds → secure storage updated → stream emits", you must fake `FlutterAppAuth` *and* `BffAuthApi` *and* `SecureStore` — three constructors, three contracts. A repository talking to two data sources would mock two.
2. **`SecureStore` shape leaks into eight call sites.** `final stored = await secureStore.readSession()` followed by `stored.accessToken` repeats verbatim in `restoreSession`, `refresh`, `logout`, `getProfile`, `sendEmailOtp`, `verifyEmailOtp`, `sendPhoneOtp`, `verifyPhoneOtp`. A `LocalSessionDataSource` exposing `Future<AuthSession?> read()` and `Future<void> write(AuthSession)` would erase eight repetitions.
3. **No reuse for `SampleApi` integrations.** When the next feature (notifications, payments) ships, its repository will copy the same "ask remote, persist locally, map errors" boilerplate.

```dart
// bff_auth_repository.dart:269-280 — pattern repeated 6×
Future<Duration> sendEmailOtp() async {
  final stored = await secureStore.readSession();          // ← local source
  if (stored == null) throw AuthFailure('Not authenticated');
  try {
    final res = await _api.sendEmailOtp(stored.accessToken); // ← remote source
    _log('sendEmailOtp: delivery=${res.delivery} alreadyVerified=${res.alreadyVerified}');
    return Duration(seconds: res.expiresIn);
  } on DioException catch (e) {
    throw _mapDio(e, fallback: 'Gagal mengirim OTP email.'); // ← mapping
  }
}
```

The "session-aware" mediation between `_api` and `secureStore` (six methods, each loads token then calls API) is the load-bearing weight that a missing data-source layer would absorb.

**Recommendation:**
- Add `features/auth/data/datasources/auth_remote_datasource.dart` (re-exports `BffAuthApi`'s methods, but accepts a `SessionTokenProvider` so callers don't pass `bearer` manually).
- Add `features/auth/data/datasources/auth_local_datasource.dart` (returns/accepts `AuthSession`, hiding the storage record shape — also resolves the audit-001 M-02 finding).
- `BffAuthRepository` shrinks to orchestration: ~10 lines per method.

---

### ⚠️ H-02 No request cancellation — in-flight calls outlive widget/bloc lifecycle
**File:** `lib/core/http/api_client.dart` (no `CancelToken` plumbing), `lib/features/auth/data/bff_auth_api.dart` (no `CancelToken` parameter on any method), `lib/features/home/presentation/home_screen.dart:25-37`, `lib/features/verification/presentation/bloc/verification_bloc.dart` (entire file)

**Issue:**
Dio supports per-request `CancelToken`. The codebase uses none.

The chain `UI → Bloc → Repository → BffAuthApi → Dio.post` has zero cancellation plumbing. Concrete scenarios this enables:

1. **User taps "Verify OTP", then immediately taps the back button.** The OTP-verify request is in flight. The verification screen is gone. The widget is disposed. The bloc is still alive (it's a feature-scoped bloc), and the future will eventually complete — but by then the bloc may have processed `VerificationErrorCleared`, the channel state may have moved on, and `emit(state.copyWith(...))` is called after the user has navigated elsewhere. Each in-flight verify becomes a race against the bloc's state machine.
2. **User triggers `_fetchApiProfile` on the home screen, then logs out before the response arrives.** The `await api.getProfile()` continues running. When the response arrives, `setState(() => _apiResult = ...)` fires on an unmounted widget — the `if (mounted)` guard on line 35 catches `_busy`, but `setState(() => _apiResult = ...)` on line 56 has no such guard, so a "Widget no longer in the tree" warning fires in debug.
3. **Token refresh runs after logout starts.** `_RefreshInterceptor._refreshOnce` (api_client.dart:161) calls `authRepository.refresh()`. If the user logs out while a refresh is in flight, `secureStore.clear()` runs (logout) — then the refresh completes with a successful response and `secureStore.writeSession(...)` writes a fresh session **after logout**. The user is suddenly authenticated again.
4. **Login timeout doesn't propagate cancel.** `bff_auth_repository.dart:96-110` wraps `authorizeAndExchangeCode` in `.timeout(_loginTimeout)`. When the timeout fires, the underlying AppAuth round-trip is *not* cancelled — it eventually completes (or fails) in the background. The next login attempt may interleave with a stale callback.

Scenario 3 is the most damaging because the refresh-after-logout interleave is silent: no UI feedback, no error, just a new session quietly persisted to disk. The race window is small (refresh takes <1s) but the impact is "the user thought they logged out but the device still holds a valid session".

**Recommendation:**
- Add an optional `CancelToken? cancel` parameter to every `BffAuthApi` method. Wire it through.
- `VerificationBloc` should hold a per-channel `CancelToken`. On `close()` / on `VerificationErrorCleared`, cancel the previous token.
- `AuthBloc.logout()` should cancel any in-flight refresh before clearing storage.
- `home_screen._fetchApiProfile`: hold a `CancelToken` in state; cancel on `dispose`.
- For AppAuth login timeouts, the right fix is upstream (the plugin needs `dispose()`); document it and accept the leak.

**Partial fix landed (2026-05-15):** scenario 3 only — the "refresh writes after logout cleared storage" race. `bff_auth_repository.refresh` re-reads `secureStore` between the API response and `writeSession`; if storage is empty (concurrent `logout()` won the race), the refresh aborts with `AuthFailure(notAuthenticated)` instead of resurrecting the session. Scenarios 1, 2, 4 (widget-lifecycle cancellation, full `CancelToken` plumbing, AppAuth dispose) remain open.

---

### ❌ H-03 API responses are raw `Map<String, dynamic>` — no DTO / no compile safety
**File:** `lib/features/auth/data/bff_auth_api.dart:60, 81, 91, 107, 124, 140`, `lib/features/sample/data/sample_api.dart:15`, `lib/features/auth/data/bff_auth_repository.dart:251-265`

**Issue:**
Every HTTP method in `BffAuthApi` and `SampleApi` returns either an anonymous record (auth side) or a raw `Map<String, dynamic>` (sample side and `/auth/me`). There is no DTO layer.

```dart
// bff_auth_api.dart:81-87  (the /auth/me path)
Future<Map<String, dynamic>> getMe(String bearer) async {
  final res = await _dio.get<Map<String, dynamic>>(
    '/auth/me',
    options: Options(headers: {'Authorization': 'Bearer $bearer'}),
  );
  return res.data ?? const {};      // ← raw map returned to repo
}
```

```dart
// bff_auth_repository.dart:251-265  (the consumer)
final body = await _api.getMe(stored.accessToken);
final roles = (body['roles'] as List?)?.cast<String>() ?? const [];
final expiresAt = body['expiresAt'] is String
    ? DateTime.tryParse(body['expiresAt'] as String)
    : null;
return UserProfile(
  sub: (body['sub'] as String?) ?? '',
  username: body['username'] as String?,
  email: body['email'] as String?,
  emailVerified: body['emailVerified'] == true,
  phoneNumber: body['phoneNumber'] as String?,
  phoneNumberVerified: body['phoneNumberVerified'] == true,
  roles: roles,
  expiresAt: expiresAt,
);
```

Cascading issues this causes:

1. **No compile-time check on key names.** A backend rename of `emailVerified` → `email_verified` (audit-002 M-02 is *exactly* this drift) compiles fine on mobile; the field silently goes false.
2. **Mapping logic lives in the repository.** `getMe`'s body shape is decoded across 14 lines of `bff_auth_repository.dart`. The next reader of "what does /auth/me return" must read both files.
3. **No reuse of validation.** The repository decides `body['emailVerified'] == true` is the right boolean check (not `== "true"`, not `?? false`). Every consumer of the same response — none today, but inevitable — gets to re-decide.
4. **`SampleApi` returns `Map<String, dynamic>`** to the UI directly (`home_screen.dart:55` then `JsonEncoder.withIndent('  ').convert(body)`). The UI is now coupled to the Kong-side response shape. The first time `/api/profile` returns nested objects, the UI's "convert to JSON and print" logic survives — but the moment any real consumption begins (display `profile.fullName`), the UI breaks open with `body['fullName'] as String?`.
5. **No null-safety on field-level.** Records like `(accessToken: body['access_token'] as String, ...)` will pass `null!` if Dio's JSON parser yields a missing key as `null`. No nullable-aware tooling can catch this — the cast is the contract.

**Recommendation:**
- Define DTOs alongside the API class: `RefreshResponseDto`, `MeResponseDto`, `SendOtpResponseDto`, `VerifyOtpResponseDto`. Use `freezed` + `json_serializable`, or hand-written `fromJson` factories with `MapValidator` helpers.
- `BffAuthApi.getMe` returns `MeResponseDto`. The repository maps the DTO → `UserProfile` (domain).
- `SampleApi.getProfile` returns `ProfileResponseDto` — the home screen consumes that.
- For DTO-to-domain mapping, keep it in the repository (one place, one direction).

---

### ❌ H-04 Retry only on HTTP 401 — transient 5xx and network errors surface as errors
**File:** `lib/core/http/api_client.dart:102-178`

**Issue:**
`_RefreshInterceptor` retries exactly one error class: HTTP 401 (and only once). Every other transient error — `DioExceptionType.connectionTimeout`, `receiveTimeout`, `sendTimeout`, `connectionError` (DNS, TCP reset), HTTP 502/503/504 from nginx or Kong during a deploy — is propagated to the caller, which surfaces it as a failure to the UI.

```dart
// api_client.dart:124-130
final status = err.response?.statusCode;
if (status != 401 || alreadyRetried) {
  handler.next(err);    // ← every non-401 propagates immediately
  return;
}
```

In a city super-app that runs on patchy 4G + occasional public Wi-Fi captive portals, transient errors are the **majority** of failures, not the exception. The current strategy means:

- A 503 from nginx during the BFF's daily reload → the user sees "Error 503" with no retry.
- A TCP reset because the user's phone moved between cell towers → the same.
- A `receiveTimeout` because the BFF's `/auth/refresh` took 16 seconds (1s past the 15s `receiveTimeout`) → no retry, immediate failure.

`BffAuthRepository._mapDio` marks `connectionTimeout` / `receiveTimeout` / `sendTimeout` as `retryable: true` — but **nothing in the codebase reads `AuthFailure.retryable`**. The flag is set, then ignored. A grep for `\.retryable` shows zero call sites that act on it. So the retry intent exists in the data layer but never reaches a retry decision.

This combines badly with H-02 (no cancellation): a 60-second-hung request can't be cancelled, but it also won't be retried, so the user is locked into watching a spinner until the timeout fires, then sees an error.

```dart
// bff_auth_repository.dart:373-377 — retryable is set …
final retryable =
    e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout;
return AuthFailure(desc ?? fallback, cause: e, retryable: retryable);

// … grep for `.retryable` across the codebase → only set sites, no read sites
```

**Recommendation:**
- Add a `_RetryInterceptor` to the shared HTTP factory (see audit-001 H-04). Retry on 5xx + timeouts with exponential backoff, max 2 retries, with jitter. Cap total time at 10s so a hung user-facing request fails fast.
- Honor `AuthFailure.retryable` somewhere — either auto-retry at the bloc level, or expose a "Try again" UI affordance.
- Do NOT retry on 4xx (other than 401 with refresh).
- Do NOT retry POST /auth/verify-otp or any mutating endpoint without an idempotency-key header.

---

### ❌ H-05 `restoreSession` emits expired session and never revalidates with `/auth/me`
**File:** `lib/features/auth/data/bff_auth_repository.dart:58-75`, `lib/features/auth/data/mock_auth_repository.dart:35-45`, `lib/features/auth/presentation/bloc/auth_bloc.dart:30-40`

**Issue:**
The app-start sequence is:

1. `AuthBloc._onStarted` → `authRepository.restoreSession()`.
2. `BffAuthRepository.restoreSession` reads `secureStore`, builds `AuthSession.fromToken(...)`, **adds it to `_controller` regardless of expiry**, and returns it.
3. `AuthBloc._onStarted` then checks `session.isExpired`. If expired, emits `unauthenticated`. If not, emits `authenticated`.

Two problems with this:

**Problem A — expired session leaks to the API client.** Between step 2 (`_controller.add(session)`) and step 3 (the bloc decides "expired"), the `ApiClient`'s `_TokenHolder` listener has *already received* the expired token and cached it as the bearer. If any `/api/*` call fires before the bloc lands on `unauthenticated` — which is plausible during a fast cold-start where another screen builds in parallel — that call uses an expired bearer. The 401-refresh dance then runs unnecessarily, and on a real expired session the refresh also fails (BFF rejects bearers older than 24h), so the user lands on `unauthenticated` anyway — but with a wasted refresh attempt and a 401 in logs.

```dart
// bff_auth_repository.dart:73-74
_controller.add(session);    // ← emitted even if expired
return session;
```

**Problem B — no server-side validation on restore.** The stored session may decode locally as valid (JWT not yet at `exp`) but have been wiped on the server (Redis cleared, BFF restarted without sticky state, user revoked the session from a different device). Mobile happily emits `authenticated` and renders the home screen. The first `/api/*` call 401s. The refresh fires. The refresh fails because the server-side session is gone. The user lands on `unauthenticated` — but only after seeing the home screen flash for ~1 second.

The right behaviour for restore: silently call `/auth/refresh` on app start. A successful refresh confirms the session is alive server-side; a failed refresh clears storage and lands on login without ever flashing the home screen.

The mock repo mirrors the same shape (line 43: `_controller.add(session)` before any expiry check), so tests built on the mock won't surface either issue.

**Recommendation:**
- `restoreSession` should not emit to the stream until validity is confirmed.
- Either:
  - (a) Have `restoreSession` perform a `/auth/refresh` round-trip; only emit on success.
  - (b) Have the bloc, not the repository, decide when to emit — repo returns `AuthSession?`, the bloc decides `expired? then unauthenticated : authenticated` and either emits via the repo or the bloc state itself.
- Add a "session probe" mode to the splash screen that gates the router until the refresh has resolved.

---

### ❌ H-06 `logout()` swallows BFF errors silently → server-side zombie session
**File:** `lib/features/auth/data/bff_auth_repository.dart:228-243`

**Issue:**
```dart
@override
Future<void> logout() async {
  final stored = await secureStore.readSession();
  if (stored != null) {
    try {
      await _api.logout(sessionId: stored.sessionId, bearer: stored.accessToken);
    } catch (_) {       // ← catches everything, logs nothing, surfaces nothing
      // Best-effort: still wipe local state if BFF is unreachable.
    }
  }
  await secureStore.clear();
  _controller.add(null);
}
```

The intent ("if the BFF is unreachable, still log the user out locally") is correct. The implementation is over-broad:

1. **No logging.** A failed server logout is silently dropped. There is no `authLog('repo', 'logout failed: $e')`, no metric, no breadcrumb. If 30% of logouts fail server-side because of a BFF auth bug, you would never know.
2. **No distinction between "network failed" and "BFF rejected the request".** A 401 (the bearer is no longer valid — fine, the server already considers this session dead) is treated the same as a 500 (BFF didn't actually delete anything in Redis — this is a zombie session).
3. **Server-side state may diverge silently.** The BFF holds the refresh_token in Redis, keyed by `session_id`. If `_api.logout` fails with a 500, the Redis entry remains. The Keycloak refresh_token is still valid. Mobile cleared its local copy, so there is no client-side capability to use it — but a parallel sign-in from the same user on a different device could in theory be told "session_id X is still alive". For a citizen-facing super-app where compliance may require session-id revocation on user-driven logout, this is a real audit gap.
4. **`SecureStore.clear()` is `await`ed *after* the BFF call regardless of outcome.** If the user has poor connectivity and the BFF call hangs for 15s (the `receiveTimeout`), local storage is not cleared for 15 seconds. During that window, the app is in an inconsistent state: the user thinks they tapped Logout, but every page still sees a valid session in storage.

```dart
} catch (_) {
  // Best-effort: still wipe local state if BFF is unreachable.
}
```

The `_` discards the exception entirely; even debug builds can't see which call shape is failing.

**Recommendation:**
- Log every failed logout: `authLog('repo', 'logout BFF failed: $e — proceeding with local clear')`.
- Differentiate at minimum two cases: (a) network/timeout — local clear proceeds; (b) 4xx/5xx with a body — treat as best-effort but record. Emit a soft-warning to a metrics sink if one exists.
- Run `secureStore.clear()` and `_api.logout` in **parallel** (not sequence) — the local clear should not be blocked by a hanging server call. Document that the BFF call is fire-and-forget once started.
- Consider a background queue: failed server logouts can be retried on next launch from a "pending logouts" file.

---

### ❌ H-07 Verify-OTP rebinds phone from bloc state — diverges from server-side binding
**File:** `lib/features/verification/presentation/bloc/verification_bloc.dart:135-187`, `lib/features/auth/data/bff_auth_api.dart:124-153`

**Issue:**
The phone OTP flow has a subtle data-flow inconsistency. Reconstruction:

1. User taps "Send" with phone `+62-A`. `VerificationBloc._onSendPhone` calls `authRepository.sendPhoneOtp('+62-A')`. The BFF stores an OTP record keyed by `(user_id, phone='+62-A')`.
2. User edits the phone field to `+62-B` before the OTP arrives. The `state.phone.phoneNumber` is updated to `+62-B` (the new value, written at send time in the bloc) — but only because the bloc *itself* writes `phoneNumber: () => event.phone` on `PhoneSendOtpRequested`. If the UI emits a different event flow (e.g. `PhoneNumberChanged`, which would also write to state), the field could diverge.
3. User receives an OTP, types it, taps Verify. `_onVerifyPhone` reads `phone = state.phone.phoneNumber` (line 139) — the **latest** value, which may not match the value sent to the BFF. It then calls `authRepository.verifyPhoneOtp(phone, code)`.
4. The BFF compares the OTP against its stored record keyed by `(user, '+62-A')`. The phone on the verify call is `+62-B`. The match fails — but the **failure mode** depends on BFF implementation:
   - If the BFF keys OTP by user+phone, the verify returns 410 otp_expired (no record matches).
   - If the BFF keys OTP by user only (and re-issues on each send), `+62-B` is accepted but the JWT's `phone_number` claim is set to `+62-B`, when the user actually proved ownership of `+62-A`.

Reading `bff_auth_api.dart:140-152`, the verify call sends `{'phone': phone, 'code': code}` to the BFF — so the BFF *can* sanity-check. But mobile does not enforce that the phone sent to verify equals the phone sent to send. The bloc trusts current state.

A second source of the same problem: `VerificationBloc._onVerifyPhone` uses `state.phone.phoneNumber`, but there's a race where the user could send OTP with `+62-A`, edit to `+62-B`, send OTP with `+62-B`, *then* receive the first OTP (delivered earlier), type it into the box, and verify. Mobile sends `phone=+62-B` with the `+62-A` OTP code. Confusing failure.

```dart
// verification_bloc.dart:139-140
final phone = state.phone.phoneNumber;   // ← latest, not "what was sent"
if (phone == null) { ... }
```

```dart
// verification_bloc.dart:117  (the send call writes phone to state)
final ttl = await authRepository.sendPhoneOtp(event.phone);
...
phoneNumber: () => event.phone,   // ← overwritten on each send
```

**Recommendation:**
- Make the bloc store **two** phone values: `pendingPhone` (the latest value the user entered) and `verifyingPhone` (the value sent to the BFF — captured at `_onSendPhone` time, never overwritten until verify completes or expires).
- `_onVerifyPhone` reads `state.phone.verifyingPhone`. The UI shows `pendingPhone` in the input but verifies the active OTP record's bound phone.
- Alternative: omit `phone` from the verify call body and let the BFF look it up by `(user_id, latest_pending_otp)`. This pushes the contract enforcement to the BFF — safer but requires BFF coordination.

---

## MEDIUM Issues

### ❌ M-01 Two Dio instances configured by hand — no shared timeouts/headers/interceptors
**File:** `lib/core/http/api_client.dart:38-43`, `lib/features/auth/data/bff_auth_api.dart:26-50`

**Issue:**
The codebase has two `Dio` instances. They share zero infrastructure:

- `ApiClient.dio` (core/http) — `/api/*` calls. Has `_AuthInterceptor`, `_RefreshInterceptor`, debug log interceptor. No JSON content-type default.
- `BffAuthApi._dio` (features/auth/data) — `/auth/*` calls. Has its own debug log interceptor. Adds `Content-Type: application/json` default. No bearer interceptor (bearer is passed per call).

Both use `connectTimeout: 10s, receiveTimeout: 15s`, but the values are duplicated, not derived from a single config. Both add a debug log interceptor, but the wiring code is duplicated. Both compute `baseUrl: config.bffBaseUrl`.

When the next change lands — TLS pinning, a `User-Agent: SmartApp/1.2.3 (Android 14)` header, OpenTelemetry instrumentation — it must be done twice. If only one is updated, the two HTTP stacks diverge.

(This is also raised as H-04 in audit-001. Repeated here because the data-flow audit lens makes the consequence more concrete: every API surface in the app today is built on one of these two Dios; future surfaces will inherit the inconsistency.)

```dart
// bff_auth_api.dart:26-33
_dio ?? Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),
  headers: {'Content-Type': 'application/json'},   // ← only here
)) { ... }

// api_client.dart:38-43
final client = dio ?? Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,                       // ← same value
  connectTimeout: const Duration(seconds: 10),      // ← same value
  receiveTimeout: const Duration(seconds: 15),      // ← same value
));                                                  // ← no content-type
```

**Recommendation:**
- Add `core/network/dio_factory.dart` with `Dio createDio({required AppConfig config, bool withAuthInterceptor = true, bool skipRefreshOn401 = false})`.
- The auth-API client uses `skipRefreshOn401: true` (so refresh-on-401 doesn't recurse on the refresh call itself).
- A single source of truth for timeouts, content-type, debug logging, TLS pinning.

---

### ❌ M-02 Field-naming contract drift — `email_verified` (JWT) vs `emailVerified` (REST)
**File:** `lib/features/auth/domain/jwt_claims.dart:47, 49`, `lib/features/auth/data/bff_auth_repository.dart:260-262`

**Issue:**
The same logical fact ("is the user's email verified") is read from two different sources with two different key naming conventions:

```dart
// jwt_claims.dart:47, 49 — snake_case (from JWT payload, OIDC convention)
emailVerified:        raw['email_verified'] == true,
phoneNumberVerified:  raw['phone_number_verified'] == true,

// bff_auth_repository.dart:260, 262 — camelCase (from /auth/me REST)
emailVerified:        body['emailVerified'] == true,
phoneNumberVerified:  body['phoneNumberVerified'] == true,
```

This is intentional on the BFF side — JWT uses OIDC standard claims (snake_case), REST uses a normalised camelCase response — but it's a **fragile contract** for mobile:

1. If the BFF accidentally normalises the JWT claims to camelCase (a one-line change in the claim mapper), every mobile session will silently report `emailVerified=false` — the verification banner will reappear for already-verified users.
2. The fallback `== true` for both fields is correct (Dart's `null == true → false`), but masks the bug: the field becomes silently false instead of producing a typed parse error.
3. The repository's `getProfile` and `JwtClaims.fromToken` produce overlapping data (`emailVerified`, `phoneNumberVerified`). When they disagree — JWT says true, /auth/me says false (or vice versa) — neither layer reconciles. The session reflects whichever ran last.

This is a *small* divergence but it's exactly the kind of drift the audit can flag now, before it becomes the cause of a 4am "users see verification banner after verifying" support ticket.

**Recommendation:**
- Document the contract explicitly: "JWT claims use snake_case (OIDC standard); BFF REST endpoints use camelCase."
- Centralise the keys: `const _kEmailVerifiedJwt = 'email_verified'; const _kEmailVerifiedRest = 'emailVerified';` in one constants file.
- Add a debug-only assert: if `JwtClaims.fromToken(session.accessToken).emailVerified != response.emailVerified`, log a warning. Catches the drift on the first refresh after the BFF change.

---

### ❌ M-03 No send-timeout configured — only `connectTimeout` / `receiveTimeout`
**File:** `lib/core/http/api_client.dart:40-43`, `lib/features/auth/data/bff_auth_api.dart:28-33`

**Issue:**
Dio's `BaseOptions` exposes three timeouts: `connectTimeout`, `sendTimeout`, `receiveTimeout`. The codebase sets the first and the third but not the second.

`sendTimeout` caps the time the client spends uploading the request body. For the current endpoints — small JSON `POST` bodies — this is rarely an issue. But:

- `verifyEmailOtp` / `verifyPhoneOtp` send small bodies but on slow 2G+captive-portal networks, the upload phase can stall for 30+ seconds without ever triggering `receiveTimeout` (because nothing has been received).
- A future endpoint that uploads an image (citizen profile avatar, complaint attachment) will hang indefinitely without a `sendTimeout`.

Worse, `BffAuthRepository._mapDio` claims `sendTimeout` is a retryable error (line 376) — but the Dio config never sets a `sendTimeout`, so `DioExceptionType.sendTimeout` will never actually fire. The retry intent for upload-side hangs is dead code.

```dart
// bff_auth_repository.dart:373-376
final retryable =
    e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout;     // ← never fires
```

**Recommendation:**
- Set `sendTimeout: Duration(seconds: 15)` (matching receive).
- Tighten `connectTimeout` to 5–8s (mobile networks fail-fast better than waiting 10s for a TCP SYN).

---

### ❌ M-04 No correlation / request-id header — mobile↔BFF errors are not traceable
**File:** `lib/core/http/api_client.dart` (no `X-Request-Id` / `traceparent`), `lib/features/auth/data/bff_auth_api.dart` (same)

**Issue:**
When a user reports "login failed at 14:32 yesterday", the on-call engineer has no way to correlate that with a specific BFF request. There is no:

- `X-Request-Id` (UUID-per-request) attached on the mobile side.
- `traceparent` / W3C trace context.
- `X-Client-Version` header for the app version.
- `X-Platform` header for android/ios.

The BFF logs (presumably) include nginx's auto-generated `request_id` — but mobile has no mirror of it. The only way to find the request in BFF logs is by timestamp + user-id, both of which are imprecise.

This is a backend-integration audit, not an observability audit, so the scope is narrow — but the missing request-id is the single highest-leverage change for debugging integration issues. A 16-byte UUID in a request header costs nothing and unlocks log correlation forever.

```dart
// api_client.dart:38-43 — no X-Request-Id, no traceparent, no version header
final client = dio ?? Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),
));
```

**Recommendation:**
- Add a `_CorrelationInterceptor` to the shared HTTP factory (see M-01): on each request, generate a UUID, set `X-Request-Id: <uuid>`. Also stamp it on the in-flight log line.
- Add `X-Client-Version: <pubspec-version>` and `X-Platform: <android|ios>` from `PackageInfo.fromPlatform()` once at app start; cache and reuse.
- If the BFF supports OpenTelemetry already (which the commit log suggests — "bump OpenTelemetry packages"), add a `traceparent` header generated from a `Tracer` on the mobile side.

---

### ❌ M-05 No HTTP-level caching strategy — `/auth/me` round-trips for data already in JWT
**File:** `lib/features/auth/data/bff_auth_repository.dart:246-266`, `lib/features/home/presentation/home_screen.dart:39-51`

**Issue:**
The current `getProfile()` always hits the BFF, regardless of whether the JWT in hand already contains the same fields. Specifically:

- `sub`, `email`, `email_verified`, `phone_number`, `phone_number_verified`, `username` are **already in the JWT claims** (and `JwtClaims.fromToken` decodes them).
- The only fields `/auth/me` adds beyond the JWT are `roles` and `expiresAt`. `roles` is in the JWT too (under `realm_access.roles` per Keycloak convention).
- The home screen offers a "GET /auth/me (BFF)" button (line 131) that simply re-fetches the same data.

A cache strategy of *any* kind is absent:

- No in-memory cache (`Map<String, ProfileResponseDto>` keyed by session_id).
- No `Cache-Control` header honored.
- No "use JWT claims if present, fall back to /auth/me" prefer-local strategy.
- No `If-None-Match` / ETag handling for `200 → 304` short-circuits.

The cost today is small (one extra round-trip per profile view). The cost at scale is non-trivial: on a citizen super-app with 50k DAU and a profile-screen-on-launch, that's 50k unnecessary BFF requests/day.

More importantly, the **architecture** doesn't express the preference. There is no `ProfileSource` enum, no "prefer-cache" mode. The next developer who adds a citizen-data API will follow the same pattern.

```dart
// bff_auth_repository.dart:246-251 — always network
Future<UserProfile> getProfile() async {
  final stored = await secureStore.readSession();
  if (stored == null) throw AuthFailure('Not authenticated');
  final body = await _api.getMe(stored.accessToken);     // ← unconditional
  ...
}
```

**Recommendation:**
- Add a `UserProfile.fromJwt(JwtClaims)` factory. Have `restoreSession()` and `login()` populate a `_cachedProfile` field with it.
- `getProfile()` returns the cached profile if fresh (< 5 min), else network.
- For `roles`, decode from JWT `realm_access.roles` — `/auth/me` round-trip not needed.
- Document a "stale-while-revalidate" policy: serve cached, kick off background refresh, emit update when complete.

---

### ❌ M-06 Error mapping inspects only `error_description` — loses `error` / `error_code` / `detail`
**File:** `lib/features/auth/data/bff_auth_repository.dart:367-378, 349-365`

**Issue:**
The BFF error envelope (per the existing `_mapVerifyDio` comment on lines 344-348) is:

```json
{ "error": "otp_invalid", "error_description": "...", "detail": { "attempts_left": 3 } }
```

`_mapDio` reads only `error_description`:

```dart
// bff_auth_repository.dart:367-378
AuthFailure _mapDio(DioException e, {required String fallback}) {
  final body = e.response?.data;
  String? desc;
  if (body is Map && body['error_description'] is String) {
    desc = body['error_description'] as String;
  }
  ...
  return AuthFailure(desc ?? fallback, cause: e, retryable: retryable);
}
```

What's lost:

1. **`error` code is ignored.** `error: 'invalid_grant'`, `error: 'fonnte_rate_limited'`, `error: 'phone_already_taken'` — each is a typed failure the UI should handle differently. The current code lumps them into a generic `AuthFailure(error_description)`. The presentation layer sees only the localised string, not the machine-readable code.
2. **`detail.attempts_left` is read only by `_mapVerifyDio`.** Other endpoints may emit `detail.retry_after_seconds` for rate-limiting; nothing reads it.
3. **`error_description` is treated as user-facing copy** (it gets concatenated directly into the `AuthFailure.message`), which violates the H-01 finding from audit-001: domain errors should not carry localised strings.

Symptom for users: every BFF error looks the same on mobile. "Verifikasi gagal." with no actionable next step. If the BFF says `error: 'rate_limited', error_description: 'too many attempts, wait 60s'`, the mobile UI cannot extract "60s" — there is no field for it.

**Recommendation:**
- Define `BffErrorEnvelope { error, errorDescription, detail }` and parse it once.
- Map common `error` values to typed failures: `RateLimitedFailure(retryAfter)`, `InvalidGrantFailure`, `OtpInvalidFailure(attemptsLeft)`, etc.
- Keep `errorDescription` as a diagnostic for logs/telemetry — user-facing copy comes from the localised mapping of the typed failure.

---

### ⚠️ M-07 `connectionError` is not flagged retryable in `_mapDio`
**File:** `lib/features/auth/data/bff_auth_repository.dart:373-377`

**Issue:**
```dart
final retryable =
    e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout;
```

`DioExceptionType.connectionError` (DNS failure, TCP reset, ECONNREFUSED) is omitted. This is the most common transient failure on mobile networks — the device briefly loses connectivity between cell handoffs, or the captive portal intercepts a request — and the type is `connectionError`, not any of the timeouts.

The flag is set but no caller reads it today (per H-04), so the immediate impact is zero. But the moment a retry loop or a "Try again" affordance is added, `connectionError` will silently be classified as non-retryable, which is the opposite of correct.

**Recommendation:**
- Add `e.type == DioExceptionType.connectionError` to the list.
- Consider also classifying 5xx responses as retryable (currently the function never looks at status code).

**Partial fix landed (2026-05-15):** the new `mapDioToApiFailure` (C-02) treats `connectionError` + all three timeouts as `retryable: true`, and 5xx as `ApiErrorCode.server` with `retryable: true`. The `/auth/*` mapper (`BffAuthRepository._mapDio` via `describeBffError.isTimeout`) still excludes `connectionError` — it covers the three timeouts only. Fix on the auth side is a one-line addition to `describeBffError` but is left for a follow-up so the failure-classification policy can be aligned in one pass with H-04 (retry interceptor).

---

## LOW Issues

### ❌ L-01 Anonymous record return types leak HTTP shape into call sites
**File:** `lib/features/auth/data/bff_auth_api.dart:56, 91, 107, 124, 140`

**Issue:**
`BffAuthApi` returns Dart 3 records for every method:

```dart
Future<({String accessToken, String sessionId, int expiresIn})> refresh(...)
Future<({String delivery, int expiresIn, bool alreadyVerified})> sendEmailOtp(...)
```

The names and field order are part of the public contract — but anonymous records have no nominal type, so:

1. The repository at the other end (`bff_auth_repository.dart:189-197`) destructures by field name: `res.accessToken, res.sessionId, res.expiresIn`. Any rename of the record fields silently breaks the destructuring.
2. There is no way to add a method to the record (e.g. `res.expiresAt` derived from `expiresIn`). Every consumer reimplements the same derivation.
3. The record cannot be passed across feature boundaries without exposing its raw shape — which couples downstream callers to the on-wire format.

These are DTOs in everything but name; they should be nominal classes.

**Recommendation:**
- Replace each `Future<({...})>` with `Future<RefreshResponseDto>`, `Future<OtpSendResponseDto>`, etc.
- DTOs in a `dtos/` subfolder, kept side-by-side with `BffAuthApi`.

---

### ✅ L-02 `getMe` defaults to `const {}` on null body — emits silent empty profile
**File:** `lib/features/auth/data/bff_auth_api.dart:86`, `lib/features/auth/data/bff_auth_repository.dart:251-265`

**Issue:**
```dart
// bff_auth_api.dart:81-87
Future<Map<String, dynamic>> getMe(String bearer) async {
  final res = await _dio.get<Map<String, dynamic>>(...);
  return res.data ?? const {};   // ← null body → empty map
}
```

When the BFF returns 200 with no body (a misconfiguration, or a load-balancer cutting the body), `getMe` returns `{}`. The repository then constructs a `UserProfile(sub: '', email: null, emailVerified: false, ...)` — a perfectly-formed empty profile that the UI may render as "logged-in user with no name".

The right behaviour for an empty body on a profile fetch is an error (server contract violation), not a default. Defaults belong on optional fields, not on the whole response.

**Recommendation:**
- `getMe`: if `res.data == null` or `res.data!.isEmpty`, throw `BffParseFailure('empty /auth/me body')`. Let the repository decide whether to retry or surface.

**Fix landed (2026-05-15):** collateral fix from C-01. `getMe` now uses `requireBody(res, '/auth/me')` which throws `BffParseFailure('<body>', 'empty-body')` on null or empty bodies. The repository's `on BffParseFailure` arm translates this to `AuthFailure(unknown)` with the parse detail in `diagnostic`. The phantom-empty-profile path is gone.

---

### ✅ L-03 Mock vs Real session lifetime mismatch (5 min fixed vs server `expires_in`)
**File:** `lib/features/auth/data/mock_auth_repository.dart:58, 77, 113, 130, 156, 192`, `lib/features/auth/data/bff_auth_repository.dart:196, 291, 329`

**Issue:**
Real repo:
```dart
expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
```
Mock repo:
```dart
expiresAt: DateTime.now().add(const Duration(minutes: 5)),
```

The real BFF currently issues internal JWTs with `expires_in: 900` (15 min) per typical Keycloak config — the mock issues `5 min` and ignores the JWT's own `exp`. Tests built on the mock will not surface:

- Race conditions around the refresh-before-expiry threshold.
- The clock-skew issue (C-03) — because the mock's 5-min window is short enough to test inside, but the real 15-min window may hide the bug for longer.
- Refresh-token loops, since the mock's "refresh" just rotates a fake token without server interaction.

The right behaviour for the mock is to mirror the real repo's shape (`Duration(seconds: someConfigurableValue)`) so tests see the same timing contract.

**Recommendation:**
- Inject `Duration mockSessionLifetime` into `MockAuthRepository`. Default to 15 min (matches real BFF). Tests can override to 5s for fast-expiry testing.
- Have the mock's `_fakeJwt(exp: ...)` and the session's `expiresAt` derive from the same source.

**Fix landed (2026-05-15):** collateral fix from C-03. After `AuthSession.fromToken` started preferring `claims.exp`, the mock's `expiresAt: DateTime.now().add(kMockSessionLifetime)` argument became a fallback — never used because the mock JWT already stamps `exp` from the same `kMockSessionLifetime`. Mock and real now derive `AuthSession.expiresAt` from the same source (the JWT's `exp` claim) by construction; drift is impossible. The injectable-duration / 15-min-default ergonomics from the recommendation remain a follow-up.

---

### ✅ L-04 `.cast<String>()` on `roles` is lazy — failures surface far from parse site
**File:** `lib/features/auth/data/bff_auth_repository.dart:252`

**Issue:**
```dart
final roles = (body['roles'] as List?)?.cast<String>() ?? const [];
```

`.cast<String>()` returns a `CastList<String>` view, which **does not validate** the contents at cast time. The first non-String element trips a `_TypeError` on access — in some random later widget that does `roles.contains('admin')` or iterates the list.

This is a known Dart sharp edge: `cast` is lazy; `List<String>.from(list)` is eager. The latter throws at the parse site, where the error is debuggable.

The current shape means: a BFF accidentally emitting `{"roles": ["admin", 42]}` will not throw on parse; it will throw the first time the UI iterates roles, far from any HTTP context.

**Recommendation:**
- Replace with `List<String>.from(body['roles'] ?? const [])`.
- Add the eager-cast lint rule `cast_list_strictly` (if available) or a custom analyzer plugin.

**Fix landed (2026-05-15):** collateral fix from C-01. `bff_auth_repository.getProfile` now does `rolesRaw is List ? List<String>.from(rolesRaw) : const <String>[]`. A non-String element in `roles` now throws at the parse site (inside the repo's `try` block) and is translated to `AuthFailure(unknown)` with the cast detail in `diagnostic` — no more lazy CastError surfacing from a downstream `roles.contains(...)`. Adding the lint rule remains a follow-up.

---

## Architectural Synthesis

The integration layer of this mobile codebase reflects a well-intentioned "data → domain → presentation" skeleton, but the **data** half hasn't been built out: it stops at `Repository` + `ApiClass` + `SecureStore`, with no DataSource layer between them and no DTO layer between the wire format and the domain. That structural gap is the root cause of most findings in this audit:

1. **No DTO layer → unchecked casts (C-01), raw map leakage (H-03), anonymous-record contracts (L-01), field-name drift (M-02), lazy cast failures (L-04).** The codebase parses HTTP responses six times across two API classes, each in subtly different ways, and the result is six independent contracts with the BFF that must all be kept in sync by code review alone.

2. **No DataSource layer → repository fuses three jobs (H-01), error mapping is private and unreusable (C-02), storage-shape leaks into the repository (audit-001 M-02), and no shared retry/cancellation logic (H-02, H-04).** `SampleApi` is the canary: it ships with zero error handling because there is no `core/network` module to inherit from. Every next API will repeat the gap.

3. **Client-side time is treated as authoritative (C-03, H-05).** The JWT carries an `exp` claim — the only authoritative session expiry — and mobile ignores it in favour of `DateTime.now() + expires_in`. This compounds with the lack of cancellation (H-02) to create silent split-brain scenarios: device thinks it's authenticated, BFF disagrees, refresh fires after logout writes to the (cleared) storage.

4. **Best-effort error swallowing (H-06, L-02).** Logout failures, empty bodies, and lazy casts all "succeed" in the local sense while leaving the server, the user, or the runtime in an inconsistent state. The pattern is `try { ... } catch (_) {}` or `?? const {}` — defensible per-call, harmful in aggregate.

**Top-3 highest-leverage fixes (do these first):**

1. **C-01 + H-03 + L-01: Introduce a DTO layer.** One DTO per BFF endpoint, with validating `fromJson` factories, used by `BffAuthApi` and `SampleApi`. Eliminates raw-map leakage, kills unchecked casts, gives the contract a single home. Unblocks M-02 (field-name centralisation) and L-04 (eager casts).

2. **C-03 + H-05: Make the JWT's `exp` claim the source of truth for session expiry, and have `restoreSession()` validate against the server.** Compute `AuthSession.expiresAt` from `JwtClaims.exp`. Have `restoreSession` perform a silent `/auth/refresh` before emitting. This single change eliminates clock-skew failures and zombie-session UI flashes.

3. **H-01 + C-02 + H-04: Carve out `core/network/` and `core/error/`.** A shared `DioFactory`, a shared `mapDioToFailure`, a shared `_RetryInterceptor`. `SampleApi` then inherits all three without writing any error-handling code. New `/api/*` features land on a working stack instead of building one from scratch.

These three structural fixes unblock most of the remaining issues: the DTO layer enables the field-name centralisation and the lazy-cast removal; the shared error mapper lets `SampleApi` and every future API surface fail correctly; the JWT-driven expiry makes the mock and real repos consistent and prevents the "logged in but every call 401s" class of bug. The rest (cancellation tokens, correlation headers, send-timeout, caching) can land incrementally on top.

---

## Update 2026-05-15 — Fix wave 1: all CRITICAL closed

The three CRITICAL findings (C-01, C-02, C-03) are fixed and the work also closed three LOW findings as collateral (L-02, L-03, L-04) and partially mitigated two more (H-02 scenario 3, M-07 on `/api/*`).

What landed:

- **`core/network/bff_parse.dart` (new).** `BffParseFailure` + validating helpers (`requireBody`, `requireString`, `optionalString`, `requireInt`, `optionalInt`, `optionalBool`). Numeric coercion built into `requireInt` defangs the audit's `"3600"` case. Used by `BffAuthApi` and `SampleApi`.
- **`core/network/api_failure.dart` (new).** Closed `ApiErrorCode` enum + `ApiFailure` exception + `mapDioToApiFailure` (uses `describeBffError` for envelope decoding) + `mapParseToApiFailure`. Treats `connectionError` + all three timeouts as retryable, 5xx as `server, retryable: true` — picks up M-07 on the `/api/*` side.
- **`features/auth/domain/jwt_claims.dart`.** `DateTime? exp` field, populated from `raw['exp']` via a tolerant decoder (accepts `num` and numeric `String`, returns UTC).
- **`features/auth/domain/auth_session.dart`.** `AuthSession.fromToken` now prefers `claims.exp` over the wall-clock fallback.
- **`features/auth/data/bff_auth_api.dart`.** All six parse sites rewritten to use the validating helpers. Anonymous record shapes preserved (DTO migration deferred to H-03).
- **`features/auth/data/bff_auth_repository.dart`.** `refresh` and `getProfile` now catch `BffParseFailure` + `TypeError` and translate to `AuthFailure`. `refresh` also re-reads storage between API response and write (logout-race guard, mitigates H-02 scenario 3). `getProfile` materializes `roles` eagerly via `List<String>.from(...)` (closes L-04).
- **`features/verification/data/bff_verification_repository.dart`.** Symmetric `BffParseFailure` / `TypeError` arms on all four send/verify methods.
- **`features/sample/data/sample_api.dart`.** Wrapped with `mapDioToApiFailure` / `mapParseToApiFailure`. Raw map default (`?? const {}`) replaced by `requireBody` (closes L-02 for the `/api/*` side too).
- **`features/_dev/dev_dashboard.dart`.** `_run` now catches `ApiFailure` and renders the typed code instead of `'$e'`. Stringified-`DioException` leak gone.

What is deliberately *not* part of this slice:
- Full DTO migration (H-03) — the helpers + records cover the immediate cast-throws path; the typed DTOs are still the right structural follow-up.
- Full `CancelToken` plumbing (H-02 scenarios 1, 2, 4) — only the logout/refresh race is mitigated.
- The `/auth/*` `connectionError` retryable classification (the other half of M-07). Left to bundle with H-04 (shared retry interceptor) so the failure-classification policy lands in one pass.

Tests added: `test/core/network/bff_parse_test.dart`, `test/core/network/api_failure_test.dart`, `test/features/auth/jwt_claims_test.dart`, `test/features/auth/auth_session_test.dart`. `flutter analyze` clean, `flutter test` 103 / 103 passing.
