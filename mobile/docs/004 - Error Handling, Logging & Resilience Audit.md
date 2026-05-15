# 004 - Error Handling, Logging & Resilience Audit

**Date:** 2026-05-15
**Scope:** `mobile/` — Flutter client of the Pangkal Pinang super-app. Specifically the error/exception surface across `lib/main.dart`, `lib/app.dart`, `lib/core/{config,http,logging,storage,router}/**`, `lib/features/auth/**`, `lib/features/verification/**`, `lib/features/home/**`, `lib/features/sample/**`, plus the platform error boundaries (`ios/Runner/AppDelegate.swift`, `android/app/src/main/AndroidManifest.xml`) and the dependency manifest (`pubspec.yaml`). Focus: unhandled exceptions, global error strategy, layer-to-layer consistency, sensitive-data leakage through errors and logs, dev-vs-prod logging policy, crash-reporting integration, retry / fallback / timeout behaviour.
**Severity Levels:** CRITICAL | HIGH | MEDIUM | LOW

**Status Legend:** ✅ Fixed | ⚠️ Partially Fixed | ❌ Not Fixed

---

## Summary Table

| #     | Issue                                                                          | Severity | Status |
|-------|--------------------------------------------------------------------------------|----------|--------|
| C-01  | No global error handlers — uncaught exceptions disappear in release builds     | CRITICAL | ❌     |
| C-02  | No crash-reporting integration (Crashlytics / Sentry / Datadog / Bugsnag)      | CRITICAL | ❌     |
| C-03  | `main()` startup exceptions abort before `runApp()` — blank-screen failure mode | CRITICAL | ❌     |
| C-04  | `ErrorWidget.builder` not overridden — framework errors paint default red box  | CRITICAL | ❌     |
| H-01  | Raw exception objects stringified directly into user-facing UI (`'$e'`)        | HIGH     | ❌     |
| H-02  | `refresh()` lacks repository-level dedup — concurrent refresh rotates twice     | HIGH     | ❌     |
| H-03  | Debug interceptor dumps full response body — OTP / error payloads leak to logcat | HIGH     | ❌     |
| H-04  | `SampleApi.getProfile()` has zero error normalisation                          | HIGH     | ❌     |
| H-05  | `BffAuthRepository.logout()` swallows every error with `catch (_)`             | HIGH     | ❌     |
| H-06  | No retry / exponential backoff for transient 5xx / network failures            | HIGH     | ❌     |
| M-01  | `JwtClaims.fromToken` silently returns `empty()` on parse failure              | MEDIUM   | ❌     |
| M-02  | `AuthFailure.retryable` is produced but never consumed by the UI               | MEDIUM   | ❌     |
| M-03  | 15 s receive timeout on OTP-send misclassifies in-flight Fonnte delivery as failure | MEDIUM | ❌    |
| M-04  | `authLog` uses `print` — no severity, no observability hook, may miss flush on crash | MEDIUM | ❌  |
| M-05  | `ResendTimer` relies on the local device wall-clock with no fallback           | MEDIUM   | ❌     |
| M-06  | `MockAuthRepository` mints `alg: none` JWTs that the prod parser silently accepts | MEDIUM | ❌  |
| M-07  | `HomeScreen._error` retains only the most recent error — masks back-to-back failures | MEDIUM | ❌ |
| L-01  | `AuthFailure` is not `Equatable` — repeated identical errors retrigger rebuilds | LOW     | ❌     |
| L-02  | `Stopwatch` started but never stopped in `BffAuthRepository.login()`           | LOW      | ❌     |
| L-03  | `OtpInvalidFailure` message locked to Bahasa Indonesia at throw site           | LOW      | ❌     |
| L-04  | No structured logging — flat string prefix only, no machine-parseable fields   | LOW      | ❌     |
| L-05  | No sanity guard on access-token size before persisting to secure storage       | LOW      | ❌     |

**Progress: 0/22 fixed, 0 partial, 22 remaining**

---

## CRITICAL Issues

### ❌ C-01 No global error handlers — uncaught exceptions disappear in release builds
**File:** `lib/main.dart:10-33`

**Issue:**
`main()` calls `WidgetsFlutterBinding.ensureInitialized()` and `runApp()` with no error-collection scaffolding around them. Specifically, none of the four error pipes that a production Flutter app needs are wired up:

1. `FlutterError.onError` — framework errors (build / layout / paint, assertion failures inside `build()`)
2. `PlatformDispatcher.instance.onError` — uncaught async errors from any zone
3. `runZonedGuarded(...)` — uncaught errors raised inside the zone that runs `runApp`
4. `Isolate.current.addErrorListener(...)` — errors raised on any spawned isolate

This is dangerous in practice. The repository correctly converts BFF errors into `AuthFailure` and the verification bloc catches `AuthFailure`/`OtpInvalidFailure`/`OtpExpiredFailure` — but any path that throws something else (a `TypeError` from a malformed JSON shape, a `StateError` from a closed bloc, an out-of-bounds `substring` like the unguarded one at `home_screen.dart:114`, a Dio `DioException` from `SampleApi` which has no `try/catch`) is uncaught. In debug, the Flutter inspector surfaces it. In release, it is printed to stderr and lost. The user sees a frozen UI or a blank screen, the team has no telemetry, and reproduction is impossible.

```dart
// lib/main.dart — current state
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  // …
  runApp(SmartApp(/* … */));
}
```

What it should look like (sketch):

```dart
Future<void> main() async {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      // → forward to crash reporter, structured log
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      // → forward to crash reporter
      return true;
    };
    // … rest of startup
    runApp(SmartApp(/* … */));
  }, (error, stack) {
    // → final catch-all
  });
}
```

Pair with C-02 (crash reporting) — handlers without a sink are still better than nothing because they at least let you render a controlled error screen.

---

### ❌ C-02 No crash-reporting integration (Crashlytics / Sentry / Datadog / Bugsnag)
**File:** `pubspec.yaml:9-30`

**Issue:**
`pubspec.yaml` declares no crash-reporting dependency. There is no `firebase_crashlytics`, `sentry_flutter`, `datadog_flutter_plugin`, `bugsnag_flutter`, or equivalent. Combined with C-01, this means the team is completely blind to production failures:

- Field crashes from any of the > 30 `print(...)` log sites that funnel through `authLog` are lost the moment the OS reclaims the process.
- `DioException`s that escape `SampleApi.getProfile()` or unhandled rejections in `_run(...)` are stringified into `_error = '$e'` and shown to the user once — there is no server-side trail.
- The OAuth/PKCE round-trip swallows a lot of platform-specific failure modes (`FlutterAppAuthUserCancelledException` is widely known to fire for at least four distinct underlying causes — `bff_auth_repository.dart:156-166` comments this out loud). Without aggregate telemetry, distinguishing "user cancelled" from "Custom Tabs failed to launch" from "redirect lost on app-task kill" relies on individual users sending screenshots.
- `verifyEmailOtp` and `verifyPhoneOtp` map 422 → `OtpInvalidFailure` correctly, but any *other* failure shape (BFF returns 500 with HTML, BFF returns the new `error_code` field added later, Kong returns 502) collapses to a generic `'Verifikasi gagal.'` (`bff_auth_repository.dart:364`). The team has no way to discover regressions in error vocabulary.

This is the highest-leverage fix in the audit. Wire one provider, then iterate.

---

### ❌ C-03 `main()` startup exceptions abort before `runApp()` — blank-screen failure mode
**File:** `lib/main.dart:11-26`

**Issue:**
`main()` performs four operations *before* `runApp()` is reached, every one of which throws on a class of real failures:

1. `dotenv.load(fileName: '.env')` — throws `EmptyEnvFileError` if the asset is missing, malformed, or unreadable. `.env` is declared at `pubspec.yaml:41` as a bundled asset; an OEM that strips assets, a partial-install state on Android, or a parse error from a stray CRLF will tip this over.
2. `AppConfig.fromEnv()` — throws `AppConfigException` for any of: missing `BFF_BASE_URL`, malformed URL, http:// without `ALLOW_INSECURE_CONNECTIONS`, missing `OAUTH_CLIENT_ID`, missing `OAUTH_REDIRECT_URI` (`app_config.dart:45-70`). Each of these is a deployment misconfiguration, not a bug — but the user sees a blank screen because `runApp` never runs.
3. `SecureStore()` — `FlutterSecureStorage` itself does not throw at construction, but the constructor allocates the platform channel. A platform-channel error here would be surfaced on the first `read`/`write` attempt with a `PlatformException`. That is technically handled, but…
4. `ApiClient.create(...)` — pre-subscribes to `authRepository.sessionChanges`. If a future refactor synchronously emits on subscribe, an error there has the same blank-screen consequence.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');     // ← throws here = blank screen
  final config = AppConfig.fromEnv();       // ← throws here = blank screen
  // …
  runApp(SmartApp(/* … */));
}
```

The fix is to (a) wrap the prelude in `try/catch`, (b) on failure render a dedicated `runApp(BootFailureApp(error))` that explains the misconfiguration and offers a "retry" or "open settings" affordance. Today the user just sees a black phone screen and force-quits.

---

### ❌ C-04 `ErrorWidget.builder` not overridden — framework errors paint default red box
**File:** `lib/app.dart:50-70`

**Issue:**
`SmartApp.build()` constructs `MaterialApp.router(...)` without overriding `ErrorWidget.builder`. Flutter's default implementation renders the well-known red-bar-on-yellow `Error` widget in debug mode, and a grey container with no message in release mode. Any thrown exception inside `build()` of any descendant widget (e.g., a null deref on `session.email` if the BFF returns a partial JWT, a `RangeError` from the unguarded `substring(0, 24)` in `home_screen.dart:114`, a layout assertion in a nested widget) is caught by `FlutterError.reportError(...)` and silently replaced with this placeholder.

Three concrete consequences:

1. In debug, the screenshot the user sends back is the red error box — no context, no breadcrumbs.
2. In release, the user sees a grey rectangle in the middle of the screen and assumes the feature is broken. They cannot tell us *what* feature; only the part of the tree below the breaking widget is replaced.
3. Without C-01 wired up, `FlutterError.onError` does not forward the exception anywhere, so the error never reaches Crashlytics/Sentry. The only diagnostic surface is `flutter logs` on a tethered device.

```dart
// lib/app.dart — current state, no ErrorWidget.builder override
return MaterialApp.router(
  title: 'Smart App',
  debugShowCheckedModeBanner: false,
  // …
  routerConfig: _router.config,
);
```

What it should do: override `ErrorWidget.builder` in release to render a user-facing "Something went wrong" tile with a "Retry" / "Report" action, and forward the `FlutterErrorDetails` to the same crash reporter wired in C-02.

---

## HIGH Issues

### ❌ H-01 Raw exception objects stringified directly into user-facing UI (`'$e'`)
**File:** `lib/features/home/presentation/home_screen.dart:33` ; `lib/features/auth/presentation/bloc/auth_bloc.dart:55`

**Issue:**
Both code paths stringify any caught `Object` straight into a string that lands in the UI:

```dart
// home_screen.dart
} catch (e) {
  setState(() => _error = '$e');     // ← Dio exceptions render their internal toString() here
}

// auth_bloc.dart
} catch (e) {
  _log('onLoginRequested → unauthenticated (unexpected: $e)');
  emit(AuthState.unauthenticated(errorMessage: 'Login failed: $e'));  // ← bypasses _mapDio, leaks raw
}
```

The default `DioException.toString()` (Dio 5.x) embeds the request URL, method, status code, headers, and a truncated response body. So a failed `/api/profile` call against the Kong gateway can render something like:

```
DioException [bad response]: This exception was thrown because the response has a status code of 502 and RequestOptions.validateStatus was configured to throw for this status code.
The request options were: GET https://bff.example.id/api/profile
```

Concrete problems:

1. **Information disclosure to users.** The raw URL exposes the BFF/Kong topology to anyone who can screenshot the home screen — directly contradicts the architectural rule (CLAUDE.md, security audit) that mobile must never expose internal infrastructure.
2. **Mixed language.** The whole app is Bahasa Indonesia; users see English Dart exception messages mid-flow.
3. **Stable error vocabulary lost.** `_mapDio` exists in `bff_auth_repository.dart:367-378` specifically to translate Dio errors into safe, localised `AuthFailure` messages — but the bloc's outer `catch (e)` (line 53-56) skips it for any non-`AuthFailure` exception, defeating the purpose.

Fix: replace every `'$e'` with a sanitised message function (e.g., `errorToMessage(e)`) that produces a short Bahasa string for known error families and a generic "Terjadi kesalahan." otherwise.

---

### ❌ H-02 `refresh()` lacks repository-level dedup — concurrent refresh rotates twice
**File:** `lib/features/auth/data/bff_auth_repository.dart:181-226` ; `lib/core/http/api_client.dart:161-177`

**Issue:**
The `_RefreshInterceptor._refreshOnce()` deduplicates concurrent 401-driven refreshes *inside the interceptor*. But `BffAuthRepository.refresh()` itself has no in-flight guard. The bloc can call it directly via `AuthRefreshRequested` (`auth_bloc.dart:65`) — the home screen wires this to the `Icons.refresh` IconButton at `home_screen.dart:67-72`. If the user taps that button while a `/api/*` call is already retrying-on-401, two separate `/auth/refresh` requests fire in parallel.

Because the BFF rotates the underlying Keycloak refresh_token on each call (BFF spec §2.1: "rotate with Keycloak"), the second response invalidates the token issued to the first. Whichever response gets stored in `flutter_secure_storage` last wins; the other caller continues with a token whose Keycloak counterpart has been rotated out, and the next API call 401s. The interceptor will then try to refresh, fail (because the refresh_token in Redis is the newer one), wipe local state via `bff_auth_repository.dart:215-222`, and dump the user back to the login screen *while they thought they were logged in*.

```dart
// bff_auth_repository.dart:181 — no in-flight deduplication
Future<AuthSession> refresh() async {
  final stored = await secureStore.readSession();
  if (stored == null) throw AuthFailure('No session to refresh.');
  try {
    final res = await _api.refresh(/* … */);   // ← two concurrent callers each hit this
    // …
  }
}
```

Fix: move the `Completer`-based dedup currently in `_RefreshInterceptor._refreshOnce()` *into the repository*, or move it to a shared layer above both call sites. The interceptor's local dedup should then be a no-op because the repo handles it.

---

### ❌ H-03 Debug interceptor dumps full response body — OTP / error payloads leak to logcat
**File:** `lib/features/auth/data/bff_auth_api.dart:44-49` ; `lib/core/http/api_client.dart:64-68`

**Issue:**
The error interceptor in `BffAuthApi` prints the entire response body verbatim on any failure:

```dart
onError: (e, h) {
  _log('✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}');
  if (e.response?.data != null) _log('  body=${e.response!.data}');   // ← unbounded dump
  h.next(e);
},
```

`authLog` is gated on `kDebugMode` so this does not run in release. But during dev / staging, every failed OTP verify (422) prints the BFF's `{error, error_description, detail: {attempts_left}}` body — including, for a few error codes, the OTP code the user typed echoed back in `error_description`. Logcat on Android is accessible to *every* app with the (deprecated but still functional) `READ_LOGS` permission on rooted devices, and to anyone connected via `adb logcat` while the device is in developer mode (i.e., every QA tester's laptop).

This is also called out as **H-03** in the security audit (`docs/003`). The error-handling angle is that the interceptor is doing two jobs — request tracing *and* error diagnostic — and the error path is over-instrumented for what it actually needs. A safer pattern logs only the status code and `error` code (the discriminator) on failures, and never the full body:

```dart
onError: (e, h) {
  final body = e.response?.data;
  final code = (body is Map ? body['error'] : null) ?? '<no-error-code>';
  _log('✗ ${e.requestOptions.method} ${e.requestOptions.uri} — '
       '${e.response?.statusCode} [$code]');
  h.next(e);
},
```

The same applies to `api_client.dart:64-68` for the `/api/*` channel.

---

### ❌ H-04 `SampleApi.getProfile()` has zero error normalisation
**File:** `lib/features/sample/data/sample_api.dart:15-18`

**Issue:**
`SampleApi.getProfile()` is a one-liner with no `try/catch`:

```dart
Future<Map<String, dynamic>> getProfile() async {
  final res = await _dio.get<Map<String, dynamic>>('/api/profile');
  return res.data ?? const {};
}
```

Any `DioException` (network, 401-after-refresh-failed, 500, timeout) propagates up unchanged. The only catch site is `HomeScreen._run`, which stringifies it via the H-01 path. The repository has a dedicated `_mapDio` helper to produce safe failures — `SampleApi` does not.

Two practical consequences:

1. The home screen renders `DioException [bad response]: …` as user-facing copy on any failure of the demo "GET /api/profile" button.
2. There is no typed failure for callers — every other feature that consumes `SampleApi` (and the four-or-five more services that will be modelled the same way as the super-app grows) will have to defensively wrap every call with the same boilerplate, or they will inherit the same UX bug. Each layer that re-implements the wrap will get it slightly wrong.

Define an `ApiFailure` type analogous to `AuthFailure` (`auth_repository.dart:3-10`), wrap the call in a try/catch that maps `DioException` to it, and treat that as the contract that every `/api/*` client honours.

---

### ❌ H-05 `BffAuthRepository.logout()` swallows every error with `catch (_)`
**File:** `lib/features/auth/data/bff_auth_repository.dart:229-243`

**Issue:**
The logout flow is best-effort by design — local state must be cleared whether or not the BFF acknowledges. But the implementation throws away the underlying error entirely:

```dart
Future<void> logout() async {
  final stored = await secureStore.readSession();
  if (stored != null) {
    try {
      await _api.logout(sessionId: stored.sessionId, bearer: stored.accessToken);
    } catch (_) {                                       // ← every failure is identical to success
      // Best-effort: still wipe local state if BFF is unreachable.
    }
  }
  await secureStore.clear();
  _controller.add(null);
}
```

That's safe for the user, but operationally disastrous. The three failure modes that should each be visible are now indistinguishable in telemetry:

1. **401 from BFF** — bearer was already expired; this is benign and expected.
2. **5xx from BFF** — server-side Redis is dead or the BFF crashed; this should page someone but is silently masked.
3. **Network error** — no connectivity; useful for understanding flaky-region issues.

Fix: at minimum, log the error with severity + cause before discarding it. With C-02 in place, forward as a non-fatal breadcrumb. Do not change the user-facing behaviour (still clear local state) — just stop dropping the diagnostic.

---

### ❌ H-06 No retry / exponential backoff for transient 5xx / network failures
**File:** `lib/core/http/api_client.dart:120-159`

**Issue:**
`_RefreshInterceptor.onError` retries exactly one class of failure (HTTP 401) exactly once. Every other transient failure — connection reset, DNS hiccup, 502 Bad Gateway from Kong, 504 from an upstream service, the bog-standard "Kong restarted, give it 200 ms" — fails immediately with no automated recovery. The verification flow is especially exposed:

- `sendEmailOtp` / `sendPhoneOtp` make a single call that the BFF forwards to Fonnte. Fonnte's gateway has a documented 1-3 % transient-failure rate. A user who taps "Verifikasi" on a flaky 4G network and gets a 502 from Kong has no retry — they see "Gagal mengirim OTP" and tap again, which spends another OTP attempt against the BFF's per-IP rate limit.
- The 401 retry path *itself* has no backoff. If the refresh succeeds and the retry then hits a 502, the user sees the error as if the original request failed for an unrelated reason.

Combine with the hard 15 s receive timeout (M-03) and you get a UX where a flaky network produces a parade of false-negative errors that the user must manually retry, each of which competes with server-side rate limits.

Fix: introduce an exponential-backoff interceptor (e.g., `dio_smart_retry` or a hand-rolled one) for `DioExceptionType.connectionTimeout`, `connectionError`, and 5xx with a fixed cap (3 tries, 200 ms / 500 ms / 1 s with full jitter). Explicitly *do not* retry idempotency-violating operations (verify-otp consumes the OTP attempt; resend is fine).

---

## MEDIUM Issues

### ❌ M-01 `JwtClaims.fromToken` silently returns `empty()` on parse failure
**File:** `lib/features/auth/domain/jwt_claims.dart:32-57`

**Issue:**
The parser was written to "fail closed" — any decode error returns `JwtClaims.empty()` whose `emailVerified` and `phoneNumberVerified` are `false`. The security intent (never default to "verified") is correct. The error-handling defect is that the failure is *completely invisible*:

```dart
factory JwtClaims.fromToken(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return JwtClaims.empty();    // ← no log, no signal
  try {
    // …
  } catch (_) {
    return JwtClaims.empty();                         // ← no log, no signal
  }
}
```

Real-world failure pattern: BFF rolls out a new claim format, a stray field breaks `jsonDecode`, every mobile client drops `emailVerified` / `phoneNumberVerified` to false at the next refresh, the verification banner reappears across the entire user base, support gets flooded with "I already verified my email" tickets, and the team has no telemetry to triangulate because the parser silently returned `empty()` for every token. The session itself remains usable (the BFF/Kong still validates the signature), so only the UI banner mis-fires — which makes the bug subtle and high-impact.

Fix: keep the fail-closed behaviour, but emit a `developer.log(level: 1000, error: ...)` and a non-fatal breadcrumb when the catch fires. A real claim-shape change should be one log line per token until you push a new build, which is exactly the signal you want.

---

### ❌ M-02 `AuthFailure.retryable` is produced but never consumed by the UI
**File:** `lib/features/auth/domain/auth_repository.dart:3-10` ; `lib/features/auth/presentation/bloc/auth_bloc.dart:50-56`

**Issue:**
`AuthFailure` carries a `retryable` boolean that the repository sets meaningfully — true for timeouts and user-cancelled flows (`bff_auth_repository.dart:154,166`), false for "BFF response missing required fields", false for refresh-after-session-died. The bloc reads `e.retryable` only to log it (`auth_bloc.dart:51`) and never propagates it to state. The login screen has no concept of "this failure is retryable" — it just shows the error text and re-enables the same button:

```dart
} on AuthFailure catch (e) {
  _log('onLoginRequested → unauthenticated (AuthFailure: ${e.message}, retryable=${e.retryable})');
  emit(AuthState.unauthenticated(errorMessage: e.message));   // ← retryable discarded
}
```

The user sees identical UI for "tap retry, it'll probably work" (timeout) and "your session is permanently gone" (`AuthFailure('No session to refresh.')`), with no affordance distinguishing them. For retryable timeouts this is recoverable; for non-retryable failures the user retries forever and the team gets a wave of "the login button doesn't work" reports.

Fix: thread `retryable` through `AuthState.unauthenticated` (add a `bool retryable` field) and render either a "Coba lagi" button or a "Hubungi bantuan" hint depending on the value.

---

### ❌ M-03 15 s receive timeout on OTP-send misclassifies in-flight Fonnte delivery as failure
**File:** `lib/features/auth/data/bff_auth_api.dart:28-32` ; `lib/core/http/api_client.dart:39-43`

**Issue:**
Both Dio instances use the same hard-coded timeouts:

```dart
Dio(BaseOptions(
  baseUrl: config.bffBaseUrl,
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 15),       // ← applied to every endpoint
  // …
))
```

`/auth/email/send-otp` and `/auth/phone/send-otp` are not normal API calls — the BFF synchronously forwards to Fonnte (WhatsApp) or the email provider before returning. Fonnte's documented p95 is around 6-8 seconds and p99 can exceed 20 seconds during regional carrier saturation. A 15 s receive timeout means the user's `Dio` aborts mid-send, the BFF's request continues to completion server-side, Fonnte delivers the OTP, and the *user sees* "Gagal mengirim OTP" while their phone buzzes with the code.

The user reflex is to tap "Kirim ulang" — which now tries to issue a second OTP, but the per-phone OTP record on the BFF is still the first one, and depending on BFF semantics either (a) silently overwrites it with a new code that arrives moments later, confusing the user, or (b) returns a rate-limit error which the user reads as "the whole flow is broken".

Fix: per-endpoint timeout configuration. Long-running send-otp calls should allow ~30 s receive; routine `/auth/me` / `/api/*` keeps 15 s. Or, treat send-otp as fire-and-forget and rely on the 202 status's `expires_in` to drive the resend timer optimistically.

---

### ❌ M-04 `authLog` uses `print` — no severity, no observability hook, may miss flush on crash
**File:** `lib/core/logging/auth_log.dart:1-12`

**Issue:**
The logger is a single `print(...)` call:

```dart
void authLog(String tag, String msg) {
  if (!kDebugMode) return;
  // ignore: avoid_print
  print('[AUTH/$tag] $msg');
}
```

Three errors-and-logging problems:

1. **No severity.** Every line — `→ POST /auth/refresh`, `refresh: session gone server-side`, `login: UNEXPECTED ERROR` — has the same priority in logcat (`Info` on Android). Filtering for "actual error lines" requires grepping for emoji glyphs (`✗`, `FAIL`). A real logger (e.g., `developer.log` with `level: 1000` for errors) puts errors at `Error` priority where logcat highlights them.
2. **No `error` / `stackTrace` parameters.** The `developer.log(message, error: e, stackTrace: st)` signature integrates with the Dart DevTools logging view and with crash reporters (when wired). Building the message ourselves and dropping it through `print` ditches both.
3. **Flush semantics.** `print` is buffered through the Dart VM's stdout. On a hard crash (uncaught exception → process kill), the last few `print` calls may not flush before stderr is reaped by the OS. The very last log line before the crash — the one you most want — is the most likely to be missing. `developer.log` writes through the VM service which has different flush semantics, and a real crash reporter persists locally before forwarding.

Fix: replace `authLog` with a wrapper around `developer.log` that carries `level`, `error`, and `stackTrace` parameters; keep the `kDebugMode` gate.

---

### ❌ M-05 `ResendTimer` relies on the local device wall-clock with no fallback
**File:** `lib/features/verification/presentation/widgets/resend_timer.dart:36-49`

**Issue:**
The countdown is computed as `_target.difference(DateTime.now())`:

```dart
_target = widget.expiresAt ?? DateTime.now().add(widget.resendCooldown);
_ticker = Timer.periodic(const Duration(seconds: 1), (_) {
  if (mounted) setState(() {});
});
// …
final remaining = _target.difference(DateTime.now());
```

The BFF computes `expires_in` against the server clock; the client renders the countdown against the *device* clock. Two failure modes:

1. **Skewed device clock** (NITZ disabled, traveller, automatic-time-off): the countdown is wrong. If the device clock is fast by 5 minutes, the timer hits zero immediately and the user thinks they can resend, but the BFF still has the old OTP record locked and returns "rate limited". If the device clock is slow, the countdown runs past the BFF's actual OTP TTL — the user types the code at second 250 of an apparent 300 s window, gets `OtpExpiredFailure`, and is confused.
2. **System clock changes mid-countdown** (user manually adjusts time, daylight-saving rollover): `setState` fires every second and recomputes — the next tick can jump backward or forward by an arbitrary amount with no continuity guarantee.

Fix: drive the timer off a monotonic clock (start `Stopwatch` on `initState`, decrement a known TTL) and use the server-issued `expires_in` *as a duration*, not an absolute timestamp. Treat `expiresAt` as a hint, not authority.

---

### ❌ M-06 `MockAuthRepository` mints `alg: none` JWTs that the prod parser silently accepts
**File:** `lib/features/auth/data/mock_auth_repository.dart:172-195` ; `lib/features/auth/domain/jwt_claims.dart:32-57`

**Issue:**
The mock repository fabricates JWTs whose header is `{"alg":"none"}` and which have an empty signature segment:

```dart
final header = b64({'alg': 'none', 'typ': 'JWT'});
// …
return '$header.$payload.';                            // ← trailing dot, no signature
```

`JwtClaims.fromToken` only looks at the payload segment and returns whatever flags it finds. The same parser runs against the real BFF-issued RS256 tokens *and* against these mock tokens. The mock is gated by `USE_MOCK_AUTH=true` and the factory correctly picks the BFF repo when the flag is false (`auth_repository_factory.dart:15-19`).

But `USE_MOCK_AUTH` is read from a bundled `.env` asset (`pubspec.yaml:41`, `app_config.dart:38`) which is shipped *inside the APK*. If a misconfigured release build keeps `USE_MOCK_AUTH=true` in `.env`, the mock path activates in production. Combined with the fact that the parser blindly trusts `email_verified` / `phone_number_verified` from the payload and that the BFF/Kong has nothing to verify (because nothing is being sent to them), every mock user gets full verified status and bypasses the verification banner. Error-handling angle: there is no defensive check anywhere that rejects unsigned tokens, so the failure is silent.

Already flagged as **H-07** in the security audit; the error-handling angle here is that no exception is ever raised — the failure mode is "everything works, but wrong". That is the worst kind of bug for ops to diagnose without telemetry.

Fix: have `JwtClaims.fromToken` refuse to parse tokens whose header `alg` is `none`, and have the BFF repository throw `AuthFailure` if the access token presented at `restoreSession` has no signature segment.

---

### ❌ M-07 `HomeScreen._error` retains only the most recent error — masks back-to-back failures
**File:** `lib/features/home/presentation/home_screen.dart:20-37`

**Issue:**
`HomeScreen` has a single `_error` field shared between `_fetchMe` and `_fetchApiProfile`:

```dart
String? _error;
// …
Future<void> _run(Future<void> Function() task) async {
  setState(() {
    _busy = true;
    _error = null;                                  // ← clears any prior error before running
  });
  try {
    await task();
  } catch (e) {
    setState(() => _error = '$e');                  // ← overwrites any prior error
  } finally {
    if (mounted) setState(() => _busy = false);
  }
}
```

If the user taps "GET /auth/me" and it fails, then taps "GET /api/profile" before reading the first error, the `_error = null` reset wipes the first failure. The second call's success-or-failure is the only thing the user sees. Two real consequences:

1. User reports "the /auth/me button is broken" but by the time they reach support they have re-tapped `/api/profile` and the error message visible is for the second call entirely. Support chases the wrong endpoint.
2. The home screen is the team's smoke-test surface (per the `// Useful for proving the chain …` comment in `sample_api.dart:14`). Diagnostic value drops as soon as more than one button has a failure mode.

Fix: per-action error state (`_meError` / `_apiError`), or keep an error list and render each. Either way, do not silently overwrite.

---

## LOW Issues

### ❌ L-01 `AuthFailure` is not `Equatable` — repeated identical errors retrigger rebuilds
**File:** `lib/features/auth/domain/auth_repository.dart:3-36`

**Issue:**
`AuthFailure`, `OtpInvalidFailure`, and `OtpExpiredFailure` use the default `Object.==`, which is reference equality. The bloc emits `AuthState.unauthenticated(errorMessage: e.message)` (`auth_bloc.dart:73`); the state itself is `Equatable` and compares `errorMessage` by value, so identical strings are deduplicated correctly *at the state level*. The defect is downstream: if a feature ever surfaces `AuthFailure` instances directly (e.g., a future `errorObject` field, or a comparison in a test), two failures with identical message + retryable + cause are not `==`. The verification bloc already side-steps this by extracting `.message` into the channel state, so the bug is latent rather than active. Worth tidying when next touching the file.

---

### ❌ L-02 `Stopwatch` started but never stopped in `BffAuthRepository.login()`
**File:** `lib/features/auth/data/bff_auth_repository.dart:93-178`

**Issue:**
`login()` creates `final stopwatch = Stopwatch()..start();` at line 93 and reads `stopwatch.elapsedMilliseconds` at six log sites, but never calls `.stop()`. `Stopwatch` does not leak resources, but the pattern is misleading — `elapsedMilliseconds` keeps ticking past the `return` while the closure is still in scope. The success-path log line at line 146 reads timing correctly; the catch-block reads at 150/157/168/174 read after a thrown exception. Not a bug, just a code-smell that suggests the author wanted scoped timing and got something different. Replace with `final start = DateTime.now(); … DateTime.now().difference(start)` if scoped timing matters, or call `.stop()` at every exit.

---

### ❌ L-03 `OtpInvalidFailure` message locked to Bahasa Indonesia at throw site
**File:** `lib/features/auth/domain/auth_repository.dart:15-36`

**Issue:**
The failure types build their user-facing message in their constructors:

```dart
class OtpInvalidFailure extends AuthFailure {
  OtpInvalidFailure({required this.attemptsLeft, Object? cause})
      : super(
          attemptsLeft > 0
              ? 'Kode salah. Sisa percobaan: $attemptsLeft.'
              : 'Kode salah.',
          cause: cause,
          retryable: attemptsLeft > 0,
        );
  final int attemptsLeft;
}
```

The Bahasa strings are baked in at throw time. If the app later adds i18n (English for non-Bahasa speakers, or even just minor copy tweaks), every error message must be re-mapped at the bloc or UI boundary. The pattern that scales is: failure objects carry a discriminator + structured fields (`OtpInvalidFailure(attemptsLeft: ...)`), and a `localize(failure, l10n)` helper at the UI boundary produces the string.

---

### ❌ L-04 No structured logging — flat string prefix only, no machine-parseable fields
**File:** `lib/core/logging/auth_log.dart:1-12` (and every caller)

**Issue:**
All log output is unstructured strings like `[AUTH/repo] login: SUCCESS in 1234ms` — readable to humans, opaque to tooling. There is no JSON output, no event/level/context shape. When the team eventually pipes mobile logs into a log aggregator (Datadog, Logtail, CloudWatch), the ingest will be a regex parse against ad-hoc prefixes. Worse, the prefix collides with substring matches — `[AUTH/api]` and `[AUTH/repo]` are siblings but logically the same channel; filtering is by free-form string match.

Light-touch fix: keep the human-readable line but `developer.log` it with `name: 'auth.repo'` / `name: 'auth.api'` / `name: 'auth.bloc'`. DevTools and any future crash reporter then have a real namespace to filter on.

---

### ❌ L-05 No sanity guard on access-token size before persisting to secure storage
**File:** `lib/core/storage/secure_store.dart:23-36`

**Issue:**
`writeSession` writes whatever `accessToken` string the caller passes:

```dart
Future<void> writeSession({
  required String accessToken,
  required String sessionId,
  required DateTime expiresAt,
}) async {
  await Future.wait([
    _storage.write(key: _kAccessToken, value: accessToken),     // ← no length check
    // …
  ]);
}
```

A pathological BFF response (a misrouted endpoint that returns a multi-MB HTML payload aliased into `access_token` by `bff_auth_api.dart:67`'s un-validated cast `body['access_token'] as String`) would be persisted forever. `flutter_secure_storage` on Android wraps `EncryptedSharedPreferences`, whose per-key size limit is undocumented but in practice fails non-deterministically above ~1 MB. The failure mode is then a stuck app that cannot read or clear its own credentials — the user has to uninstall to recover. A simple `assert(accessToken.length < 4096)` or a hard reject in the BFF repository would catch this. Belt-and-braces, but very cheap.
