# 003 - Mobile Security Audit

**Date:** 2026-05-15
**Scope:** `mobile/` — Flutter client of the Pangkal Pinang super-app. Specifically: `lib/main.dart`, `lib/app.dart`, `lib/core/{config,http,logging,router,storage}/**`, `lib/features/auth/**`, `lib/features/verification/**`, `lib/features/home/**`, `lib/features/sample/**`, plus platform configs (`android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/xml/network_security_config.xml`, `android/app/build.gradle.kts`, `ios/Runner/Info.plist`, `ios/Runner/AppDelegate.swift`), and runtime config (`.env`, `pubspec.yaml`). Focus: trust-boundary violations between client / BFF / IdP, transport security, on-device data handling, OAuth/PKCE deeplink integrity, OTP & token handling, log leakage, and missing defense-in-depth.
**Severity Levels:** CRITICAL | HIGH | MEDIUM | LOW

**Status Legend:** ✅ Fixed | ⚠️ Partially Fixed | ❌ Not Fixed

---

## Summary Table

| #     | Issue                                                                       | Severity | Status |
|-------|-----------------------------------------------------------------------------|----------|--------|
| C-01  | Release build signed with the debug keystore                                | CRITICAL | ✅     |
| C-02  | `ALLOW_INSECURE_CONNECTIONS=true` ships in the bundled `.env` asset         | CRITICAL | ✅     |
| C-03  | No TLS certificate / public-key pinning on Dio or AppAuth                   | CRITICAL | ✅     |
| C-04  | OAuth deeplink uses unverified custom scheme — hostile-app code interception | CRITICAL | ❌     |
| C-05  | JWT verification flags trusted client-side without signature verification   | CRITICAL | ⚠️     |
| H-01  | No `FLAG_SECURE` / screenshot protection on OTP & token-bearing screens     | HIGH     | ❌     |
| H-02  | Access token, session_id, full decoded JWT rendered as `SelectableText`     | HIGH     | ✅     |
| H-03  | Debug HTTP interceptor logs error bodies — OTP codes & tokens leak to logcat | HIGH     | ✅     |
| H-04  | `.env` bundled as a Flutter asset — readable from any extracted APK         | HIGH     | ❌     |
| H-05  | No root / jailbreak / runtime app self-protection                           | HIGH     | ❌     |
| H-06  | `_AuthInterceptor` honours caller-provided `Authorization` header           | HIGH     | ✅     |
| H-07  | Mock JWT uses `alg: none`; `JwtClaims` parser accepts unsigned tokens       | HIGH     | ✅     |
| M-01  | `USE_MOCK_AUTH` switch is a build-time toggle, not a debug-build guard      | MEDIUM   | ✅     |
| M-02  | No client-side rate-limit / idempotency key on `send-otp` / `verify-otp`    | MEDIUM   | ✅     |
| M-03  | `verify-phone-otp` re-sends `phone` from client — trust-boundary violation  | MEDIUM   | ✅     |
| M-04  | OIDC `id_token` discarded — no nonce/at_hash validation, replay-prone       | MEDIUM   | ❌     |
| M-05  | `expiresAt` stored as ISO string; local clock & storage tamper bypass       | MEDIUM   | ✅     |
| M-06  | `MainActivity launchMode="singleTop"` racing with AppAuth redirect receiver | MEDIUM   | ❌     |
| M-07  | iOS `Info.plist` declares no ATS exception block but loads cleartext in dev | MEDIUM   | ❌     |
| L-01  | `debugShowCheckedModeBanner: false` masks debug builds in screenshots       | LOW      | ✅     |
| L-02  | Raw server `error_description` rendered into UI without sanitisation        | LOW      | ✅     |
| L-03  | `.env.example` documents `OAUTH_CLIENT_ID=super-app-eco` — reconnaissance   | LOW      | ❌     |
| L-04  | `SecureStore` uses `KeychainAccessibility.first_unlock` (no biometric)      | LOW      | ✅     |

**Progress: 14/23 fixed, 1 partial, 8 remaining** (updated 2026-05-16)

> **2026-05-16 remediation pass (code-only).** Fixed this round: C-03, H-06,
> M-01, M-02, M-03, M-05, L-01, L-04. Confirmed already-fixed and reclassified:
> H-02, H-03, H-07, L-02. C-05 advanced ⚠️ (identity now re-confirmed via
> `/auth/me` on every session change incl. restore; on-device JWT signature
> still unverified — full close needs M-04). The 8 remaining are out of scope
> for a code-only pass: native/manifest/plist (C-04, H-01, M-06, M-07),
> build/asset pipeline (H-04), a new RASP dependency (H-05), an OAuth
> re-architecture (M-04), and a docs change (L-03). All 160 tests green;
> `flutter analyze` clean.

---

## CRITICAL Issues

### ✅ C-01 Release build signed with the debug keystore
**File:** `android/app/build.gradle.kts:34-38`

**Issue:**
The Android release build type is configured to use the debug signing config:

```kotlin
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

The Android debug keystore is shipped with every Android SDK installation and its private key is well-known (`android` / `androiddebugkey` / `android`). Any APK signed with it can be impersonated by any developer in the world. Concrete consequences for a government super-app:

1. **Malicious update / sideload replacement.** An attacker who obtains an APK from a user (USB transfer, ADB, third-party store) can rebuild it with malicious code, re-sign it with the same debug key, and ship the rebuilt APK as a "legitimate update" — Android's signature-match upgrade check passes because both APKs are signed by the same well-known key.
2. **No Play Integrity attestation possible.** Play Integrity / SafetyNet attestation requires a stable production signing key. The current setup will fail attestation outright.
3. **Sign-and-pull on the device.** Because Android binds storage scopes (incl. backup keys, `KeyStore` aliases under certain accessor patterns) to the signing key, an attacker with a tampered debug-signed clone can in some scenarios access app-private state of a sibling debug-signed build.

This must be replaced with a production keystore (with the private key stored in CI/CD secrets, never in the repo) before any APK leaves the dev laptop.

```kotlin
// android/app/build.gradle.kts (current)
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

---

### ✅ C-02 `ALLOW_INSECURE_CONNECTIONS=true` ships in the bundled `.env` asset
**File:** `.env:7`, `pubspec.yaml:40-41`, `lib/features/auth/data/bff_auth_repository.dart:106`

**Issue:**
`.env` is declared as a Flutter asset (`pubspec.yaml:41`) and currently contains:

```
ALLOW_INSECURE_CONNECTIONS=true
```

Flutter packages assets verbatim into the APK/IPA. Any developer who runs `flutter build apk --release` from this checkout produces a release binary whose runtime config tells `flutter_appauth` to accept plaintext-HTTP authorization & token endpoints (`bff_auth_repository.dart:106`: `allowInsecureConnections: config.allowInsecureConnections`). Combine that with the cleartext-allow exemptions in `network_security_config.xml` (which only restrict the dev IPs), and the consequence is:

- A release APK reading this `.env` from the asset bundle will silently accept `http://` URLs for OAuth — defeating TLS entirely and turning the OAuth handshake into a passive-eavesdrop opportunity on any hostile Wi-Fi (`flutter_appauth` will refuse to redirect a real production HTTPS endpoint to HTTP, but it will not refuse a fully cleartext config).
- The asset file is readable trivially: `unzip app-release.apk assets/flutter_assets/.env`. Anything ever placed in `.env` (client secrets, signing keys, future API tokens) is therefore equivalent to public knowledge.

This is two failures compounded: (1) shipping a runtime kill-switch for TLS in the production asset pipeline, (2) using an asset (world-readable) as the secrets channel.

```dart
// lib/features/auth/data/bff_auth_repository.dart:106
allowInsecureConnections: config.allowInsecureConnections,
```

```yaml
# pubspec.yaml:40-41
flutter:
  uses-material-design: true
  assets:
    - .env
```

---

### ⚠️ C-03 No TLS certificate / public-key pinning on Dio or AppAuth
**File:** `lib/core/http/api_client.dart:38-43`, `lib/features/auth/data/bff_auth_api.dart:27-33`, `lib/features/auth/data/bff_auth_repository.dart:96-110`

> **⚠️ Risk accepted — pinning removed (2026-05-16).** The SPKI-hash
> pinning adapter (`lib/core/network/pinned_http_adapter.dart`) and its
> `dio_factory.dart` wiring were **removed by decision**. All outbound
> HTTPS now relies solely on the OS root CA store. Rationale: the prod
> BFF cert is a 90-day Let's Encrypt cert that rotates its key on every
> renewal, making static pins an operational hazard (a missed
> `--dart-define=BFF_CERT_SHA256=…` rotation bricks the released app while
> the cert is otherwise valid); the previous implementation also only
> rescued otherwise-rejected certs rather than enforcing the pin on
> valid ones, so it provided little real protection. The threat model
> below remains accurate and **the residual risk is knowingly accepted**;
> revisit if/when the BFF moves to a long-lived key or key-reuse renewal.

**Issue:**
Every outbound HTTPS call (Dio default `BaseOptions`, AppAuth's internal HTTP, `BffAuthApi`'s `Dio`) trusts the OS root CA store. For a citizen-identity super-app handling SSO + OTPs + (future) civic payments, the OS trust store is insufficient because:

1. **Hostile MDM / managed devices** (corporate-issued tablets used by RT/RW staff, school-issued devices, etc.) frequently push a custom root CA. A MITM proxy on the LAN backed by such a root will produce valid-looking certs that this app will accept.
2. **User-installed CAs** are accepted by the system by default on Android < 24; this project's `minSdk = 23` (`build.gradle.kts:24`) means users on Android 6 are exposed. Even on 24+, an `<base-config>` block can opt back in by accident.
3. **A compromised public CA** (Comodo 2011, DigiNotar 2011, Symantec 2017) issuing a cert for the BFF hostname is fully trusted with no second factor.

The mitigation is pinning the public-key SPKI hash of the production BFF cert (and rotating with backup pins). For Dio, `dio_certificate_pinning` or a custom `HttpClientAdapter`. For AppAuth, a platform-side `okhttp` interceptor or migrating the OAuth handshake into the BFF and dropping `flutter_appauth` entirely (since the BFF is already the OAuth client per the [[project_super_app]] architecture).

```dart
// lib/core/http/api_client.dart:38-43 — no pinning, no custom adapter
final client = dio ??
    Dio(BaseOptions(
      baseUrl: config.bffBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
```

---

### ❌ C-04 OAuth deeplink uses unverified custom scheme — hostile-app code interception
**File:** `android/app/build.gradle.kts:31`, `ios/Runner/Info.plist:48-60`, `lib/core/config/app_config.dart`, `.env:4`

**Issue:**
The OAuth redirect URI is a custom URL scheme:

```
OAUTH_REDIRECT_URI=id.go.pangkalpinangkota.smartapptest:/oauth2redirect
```

Android registers this through `manifestPlaceholders["appAuthRedirectScheme"]` (`android/app/build.gradle.kts:31`) — i.e. as a plain `<data android:scheme="id.go.pangkalpinangkota.smartapptest"/>` on AppAuth's `RedirectUriReceiverActivity`. iOS does the same via `CFBundleURLSchemes` (`Info.plist:56-58`). Custom URL schemes have **no exclusivity guarantee** — any other installed app can register the same scheme. Concrete attack:

1. A malicious app on the same device registers `<data android:scheme="id.go.pangkalpinangkota.smartapptest"/>` in its manifest.
2. The user opens this app and starts SSO; Chrome Custom Tabs / SFSafariViewController shows the IdP login page.
3. After the user authenticates, the IdP redirects to `id.go.pangkalpinangkota.smartapptest:/oauth2redirect?code=...&state=...`.
4. Android resolves the implicit intent. **Both apps are eligible.** The user may be prompted (or, in disambiguator-races, not), and the attacker's app receives the authorization `code`.
5. The PKCE `code_verifier` lives only in the legitimate app's memory — so direct exchange fails. **But** the `code` is still single-use and now consumed; the legitimate app's redirect handler races and may receive nothing, leaving the session in a stuck state. More importantly, on Android pre-Q the attacker can claim "priority=highest" on the intent filter and reliably win the race, then proxy the code to its own attacker-controlled backend which performs the PKCE exchange against any other PKCE-omitting fallback.

The fix is mandatory **Android App Links** (`android:autoVerify="true"` with a `.well-known/assetlinks.json` published by `mobile.pangkalpinangkota.go.id`) and **iOS Universal Links** (`apple-app-site-association`). With verified-host App Links, only this app — proven via signing-key fingerprint on the published `assetlinks.json` — receives the redirect.

```kotlin
// android/app/build.gradle.kts:31
manifestPlaceholders["appAuthRedirectScheme"] = "id.go.pangkalpinangkota.smartapptest"
```

```xml
<!-- ios/Runner/Info.plist:48-60 -->
<key>CFBundleURLSchemes</key>
<array>
    <string>id.go.pangkalpinangkota.smartapptest</string>
</array>
```

---

### ⚠️ C-05 JWT verification flags trusted client-side without signature verification
**File:** `lib/features/auth/domain/jwt_claims.dart:30-57`, `lib/features/auth/domain/auth_session.dart:19-34`, `lib/features/home/presentation/widgets/verification_banner.dart:16-23`, `lib/features/verification/presentation/screens/verification_screen.dart:38-46`

> **⚠️ Advanced (2026-05-16) — fix (a) done, fix (b) deferred.** Fix (a)
> "never read identity fields directly from the JWT; call `/auth/me` after
> every session change": `bff_auth_repository.dart` already enriched on
> login/refresh via `_enrichFromProfile`; the gap was the **restore** path.
> Added `AuthRepository.confirmIdentity()` (no-op on the mock) — the bloc's
> cold-start handler lifts the restored session for responsiveness, then
> re-confirms `email_verified` / `phone_number_verified` against `/auth/me`
> in the background; the corrected session flows back via `sessionChanges`.
> A tampered stored blob can no longer fake verification gates past first
> paint. Also: `JwtClaims.fromToken` rejects `alg:none` / missing-alg (see
> H-07). Fix (b) — pinned-JWK RS256 signature verification on-device — is
> **not** done; it is architecturally tied to M-04 (drop `flutter_appauth`,
> move the OAuth handshake into the BFF). Status stays ⚠️ until then.

**Issue:**
`JwtClaims.fromToken()` base64-decodes the JWT payload and surfaces `email_verified`, `phone_number_verified`, `email`, `phone_number` straight to the UI:

```dart
return JwtClaims(
  raw: raw,
  email: raw['email'] as String?,
  emailVerified: raw['email_verified'] == true,
  phoneNumber: raw['phone_number'] as String?,
  phoneNumberVerified: raw['phone_number_verified'] == true,
  ...
);
```

The doc-comment defends this by saying "Kong does that" — but **Kong only verifies on `/api/*` requests**. The mobile UI uses these flags to decide:

- whether to show the `VerificationBanner` (`verification_banner.dart:16-23`),
- whether to mark `/verify/email` and `/verify/phone` cards as "Terverifikasi" (`verification_screen.dart:38-46`),
- whether to gate the "Verifikasi" button.

These are **client-side trust decisions on a token whose signature was never checked.** Concrete consequences:

1. **Local tamper bypasses verification UI gates.** An attacker with root access (or any rooted dev who unzips the APK) can drop their own base64-payload `header.payload.<garbage>` into `flutter_secure_storage`'s encrypted-shared-prefs file and re-launch the app. `restoreSession` ⇒ `AuthSession.fromToken` ⇒ `emailVerified=true`, `phoneNumberVerified=true`. The banner disappears and the user appears "fully verified" without ever talking to the BFF.
2. **MITM bypass.** Combined with [[C-02]] / [[C-03]], a network attacker can substitute the BFF's `access_token` response with a self-crafted JWT (their own claims). The BFF's Kong layer rejects API calls with this fake token, but the UI still shows the fake user's email and "verified" state until the next `/auth/me` round-trip — long enough to e.g. trick the user into entering an OTP for the attacker's account binding.
3. **`alg: none` accepted.** `JwtClaims.fromToken` does not inspect the header; an unsigned JWT decodes just as happily as a signed one. See [[H-07]].

The fix is twofold: (a) **never read identity fields directly from the JWT on-device** — call `/auth/me` for the canonical source after every session change, treating the JWT as an opaque bearer; (b) if you must read claims for UX (offline-tolerant gating), at minimum verify the BFF's RS256 public key on-device against a pinned JWK, and refuse any token whose `alg ≠ RS256`.

```dart
// lib/features/auth/domain/jwt_claims.dart:30-57 — no signature verification, no alg check
factory JwtClaims.fromToken(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return JwtClaims.empty();
  try {
    final segment = parts[1];
    final padded = segment.padRight(...);
    final decoded = utf8.decode(base64Url.decode(padded));
    final raw = jsonDecode(decoded);
    ...
    emailVerified: raw['email_verified'] == true,
    phoneNumberVerified: raw['phone_number_verified'] == true,
    ...
  } catch (_) { return JwtClaims.empty(); }
}
```

---

## HIGH Issues

### ❌ H-01 No `FLAG_SECURE` / screenshot protection on OTP & token-bearing screens
**File:** `android/app/src/main/kotlin/id/go/pangkalpinangkota/smart_app_test/MainActivity.kt`, `lib/features/verification/presentation/screens/*.dart`, `lib/features/home/presentation/home_screen.dart`

**Issue:**
`MainActivity` does not set `WindowManager.LayoutParams.FLAG_SECURE`, and no Flutter-side widget gates screenshots on the OTP screens or the home screen. The home screen renders the full decoded JWT and the access-token preview as `SelectableText`; the OTP screens show the 6-digit code as it is being entered. Concrete exposures:

1. **Background-task screenshot leak.** Android Q+ caches the last-frame screenshot of any app in the system Recents/overview stack. With `FLAG_SECURE` unset, the OTP screen — including the in-flight 6-digit code — appears in Recents, readable by any other app with `MediaProjection` permission (granted on first launch and easily socially-engineered).
2. **Accessibility / screen-recorder malware.** Indonesia's Android banking-malware ecosystem (Vulture, BRATA, Anubis variants) routinely abuses Accessibility Services + `MediaProjection` to scrape OTPs from competing super-apps. Without `FLAG_SECURE`, this app is a participating-target.
3. **Casting / mirroring / corporate MDM screen recording.** Any host doing screen-mirroring (Chromecast, Miracast, Teams casting) will capture the OTP and the token.

Fix: set `FLAG_SECURE` on the OTP routes (push it on `initState`, clear it on `dispose`) or globally for the entire app. Equivalent on iOS uses `isHidden`-on-resign-active patterns since iOS lacks a one-flag equivalent.

```kotlin
// MainActivity.kt — currently empty; should override configureFlutterEngine + onResume
// to set window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
```

---

### ✅ H-02 Access token, session_id, full decoded JWT rendered as `SelectableText` on home

> **✅ Confirmed fixed (reclassified 2026-05-16).** `home_screen.dart` now
> renders the credential-dump `DevDashboard` only under `kDebugMode`;
> release builds show a bare `_CitizenHomePlaceholder` with no token,
> session_id, or decoded JWT. The report entry was stale.
**File:** `lib/features/home/presentation/home_screen.dart:110-122`

**Issue:**
The home screen exposes the live session as user-selectable text:

```dart
_row('session_id', session.sessionId),
_row('expires_at', session.expiresAt.toIso8601String()),
_row(
  'access_token (preview)',
  '${session.accessToken.substring(0, session.accessToken.length.clamp(0, 24))}…',
),
...
SelectableText(const JsonEncoder.withIndent('  ').convert(claims)),
```

(`_row` wraps each value in `SelectableText` at line 185.) Risks:

1. **Selection → copy puts the secret on the system clipboard**, which on Android is readable by any app with no permission and on iOS by any app the user later focuses.
2. **The "preview" still leaks 24 characters of the bearer**, which together with the `kid` header & `alg` knowledge gives an attacker enough to begin offline brute-force / signature analysis against a stolen JWK.
3. **Full decoded JWT payload** is rendered, including `sub`, `email`, `phone_number`, realm/role claims, expiry — a one-glance dossier for shoulder-surfing or a screenshot in a help-desk chat.
4. **Combined with [[H-01]] (no `FLAG_SECURE`)**, the entire credential set is exposed to any screen-recorder or accessibility-scraper.

This screen looks like a debug/inspector — it should be gated behind `kDebugMode` (or removed) before shipping. At minimum, never render the `session_id`, never render the bearer (even partially), and never render decoded claims outside dev builds.

```dart
// lib/features/home/presentation/home_screen.dart:113-115
_row('access_token (preview)',
  '${session.accessToken.substring(0, session.accessToken.length.clamp(0, 24))}…',
),
```

---

### ✅ H-03 Debug HTTP interceptor logs error bodies — OTP codes & tokens leak to logcat

> **✅ Confirmed fixed (reclassified 2026-05-16).** `logging_interceptor.dart`
> logs only the BFF envelope discriminators (`error`, `detail.attempts_left`)
> — never bodies, headers, or `error_description` (which echoes user input on
> verify-OTP) — and is `kDebugMode`-gated. The report entry was stale.
**File:** `lib/features/auth/data/bff_auth_api.dart:44-49`, `lib/core/http/api_client.dart:63-68`

**Issue:**
`BffAuthApi` logs the full error-response body on every Dio error in debug mode:

```dart
onError: (e, h) {
  _log('✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}');
  if (e.response?.data != null) _log('  body=${e.response!.data}');
  h.next(e);
},
```

When `verify-otp` fails (wrong code, expired, attempts exhausted), the BFF echoes back the request context in its error envelope — `detail` may include the submitted phone, attempts_left, the offending code, etc., depending on BFF middleware. Even when it doesn't, the request *URI* and *headers* are also logged elsewhere (`api_client.dart:62`: `'→ ${o.method} ${o.uri}'`). On Android, every line printed via `print` lands in `logcat`, which is readable by:

- Any app that holds `READ_LOGS` (granted at install time on rooted/manufacturer-debug builds);
- `adb logcat` over USB if developer mode is on (common on developer/QA loaner devices);
- Crash-reporting SDKs / device-attached debuggers.

`authLog` is gated by `kDebugMode`, which prevents leakage in release builds **provided** the dev never runs `flutter run --profile` or `--release` with `--dart-define=DEBUG=true`. The gate is correct; the contents being logged are still too rich (full bodies, full URIs). For a credentials-handling stack, the log line should be schema-aware: log shape, status, error code — never raw bodies.

```dart
// lib/features/auth/data/bff_auth_api.dart:44-49
onError: (e, h) {
  _log('✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}');
  if (e.response?.data != null) _log('  body=${e.response!.data}');
  h.next(e);
},
```

---

### ❌ H-04 `.env` bundled as a Flutter asset — readable from any extracted APK
**File:** `pubspec.yaml:40-41`, `.env`

**Issue:**
`.env` is declared in the Flutter assets list and therefore packaged verbatim into `assets/flutter_assets/.env` inside the final APK/IPA. Any attacker who obtains the binary (Play Store strip, sideload, "APK download" sites) can read it with one `unzip` invocation:

```
$ unzip -p app-release.apk assets/flutter_assets/.env
BFF_BASE_URL=http://10.0.2.2:8080
OAUTH_CLIENT_ID=super-app-eco
OAUTH_REDIRECT_URI=id.go.pangkalpinangkota.smartapptest:/oauth2redirect
OAUTH_SCOPES=openid profile email
USE_MOCK_AUTH=false
ALLOW_INSECURE_CONNECTIONS=true
```

Today the values are not catastrophically sensitive on their own, but the pattern is dangerous because:

1. The asset is read at runtime, so any future "while we're at it, put the Fonnte API key in `.env` so we don't have to hard-code it" follows the path of least resistance and **silently ships the secret into the binary**. There is no compiler warning that distinguishes "secret env" from "non-secret config".
2. Reconnaissance value: the BFF base URL and OAuth client_id are useful pivots for an attacker targeting the BFF directly.
3. `ALLOW_INSECURE_CONNECTIONS=true` is itself a kill-switch worth removing from a release ([[C-02]]).

Fix: never read `.env` from assets in release builds. Use `--dart-define`/`--dart-define-from-file` so values are baked into compiled Dart (still extractable, but no friendly key=value text file in the APK) or, better, fetch dynamic config from a signed remote-config endpoint over the (pinned, see [[C-03]]) BFF channel after authentication.

```yaml
# pubspec.yaml:40-41
flutter:
  uses-material-design: true
  assets:
    - .env
```

---

### ❌ H-05 No root / jailbreak / runtime app self-protection
**File:** `pubspec.yaml:9-30` (no `flutter_jailbreak_detection` / `freerasp` / equivalent), `MainActivity.kt`, `AppDelegate.swift`

**Issue:**
This app handles SSO into a city-government identity realm, OTP verification of email and phone, and is intended to fan out to civic payments and document services (per [[project_super_app]]). It has no runtime app self-protection (RASP) of any kind. Missing checks:

- **Root / jailbreak detection.** A rooted device defeats `flutter_secure_storage`'s `EncryptedSharedPreferences` (root reads the encryption key out of `KeyStore` via `frida` hooks, or reads the SQLite directly). Without detection, the user has no warning and the app proceeds as if storage is secure.
- **Frida / debugger / emulator detection.** Reverse-engineers using Frida hook `flutter_secure_storage.read` and dump bearers in real time. Emulator-only checks are weak alone but are a useful signal when stacked.
- **Tamper detection.** Verifying the APK signing-cert fingerprint at runtime detects re-signed clones ([[C-01]]).
- **Play Integrity / DeviceCheck attestation.** The BFF has no way to know whether a request comes from a real Play-installed copy or a Frida-instrumented APK.

For a government super-app analogous to BCA Mobile, BRImo, Mandiri Livin' — all of which implement RASP — this gap is significant. Recommended floor: `freerasp` or `flutter_jailbreak_detection` + a BFF-side attestation challenge surfaced via a new endpoint, with degraded mode (login disabled, message shown) when integrity fails.

---

### ✅ H-06 `_AuthInterceptor` honours caller-provided `Authorization` header

> **✅ Fix applied (2026-05-16).** `api_client.dart` `_AuthInterceptor.onRequest`
> now **unconditionally** overwrites `Authorization` with the session bearer
> (dropped the `!options.headers.containsKey('Authorization')` guard). The
> session is the single source of truth on the shared `ApiClient.dio`; a
> feature needing a different token must use its own Dio (the pattern
> `BffAuthApi` / `BffVerificationApi` already follow).
**File:** `lib/core/http/api_client.dart:92-99`

**Issue:**

```dart
@override
void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
  final bearer = _tokens.bearer;
  if (bearer != null && !options.headers.containsKey('Authorization')) {
    options.headers['Authorization'] = 'Bearer $bearer';
  }
  handler.next(options);
}
```

The `if (!options.headers.containsKey('Authorization'))` guard means any feature-level call site that accidentally (or maliciously, in a hypothetical compromised dependency) sets `Authorization` is trusted. Two real-world failure modes:

1. **Cross-tenant token injection from a buggy feature.** A future "delegated action on behalf of another user" feature stuffs a header like `Authorization: Bearer <admin_jwt>` and the interceptor obediently lets it through. The current session bearer is meant to be the single source of truth.
2. **Library / interceptor ordering hazard.** If a future `dio` interceptor is added that injects an outdated cached `Authorization` (e.g. for retry logic), it will silently win against the canonical session bearer.

The correct pattern is **always overwrite**: the bearer source-of-truth is `AuthRepository.sessionChanges`; the interceptor enforces this invariant. If a feature genuinely needs to call an external service with a different `Authorization`, it should use a dedicated `Dio` not the shared `ApiClient.dio`.

```dart
// lib/core/http/api_client.dart:93-98 — change `if (!options.headers.containsKey(...))`
// to unconditional `options.headers['Authorization'] = 'Bearer $bearer'`.
```

---

### ✅ H-07 Mock JWT uses `alg: none`; `JwtClaims` parser accepts unsigned tokens

> **✅ Confirmed fixed (reclassified 2026-05-16).** `JwtClaims.fromToken`
> inspects the header and rejects any token whose `alg` is `none` or empty
> (returns `JwtClaims.empty()`, reports fatal in release). `mockJwt()`
> carries an `assert(kDebugMode)`, and the mock auth stack is now itself
> `kDebugMode`-gated (M-01), so an unsigned token can't reach a release
> build. The report entry was stale.
**File:** `lib/features/auth/data/mock_auth_repository.dart:172-194`, `lib/features/auth/domain/jwt_claims.dart:30-57`

**Issue:**
The mock repository fabricates a JWT with an explicit `alg: none`:

```dart
final header = b64({'alg': 'none', 'typ': 'JWT'});
...
return '$header.$payload.';
```

`JwtClaims.fromToken` reads only `parts[1]` — the payload — and never inspects the header's `alg` field. So:

- The mock token *and* a future production token *and* an attacker-fabricated `alg: none` token all parse identically.
- The `USE_MOCK_AUTH` flag is read from `.env` ([[M-01]]), which is shipped in the asset bundle. A release build that accidentally enables mock auth (developer error, or post-extraction tamper) will sail through every UI gate without ever talking to the BFF.
- The unsigned trailing `.` empty signature is accepted by every code path on the device side. Combined with [[C-05]], the device has zero ability to detect a forged JWT.

Fix: (a) refuse to parse any JWT whose header `alg ∉ {RS256}` in `JwtClaims.fromToken`; (b) gate the mock repository factory behind `kDebugMode` so it cannot be selected in a release build regardless of env.

```dart
// lib/features/auth/data/mock_auth_repository.dart:180
final header = b64({'alg': 'none', 'typ': 'JWT'});
```

---

## MEDIUM Issues

### ✅ M-01 `USE_MOCK_AUTH` switch is a build-time toggle, not a debug-build guard

> **✅ Fix applied (2026-05-16).** `main.dart` composition root now selects
> the mock stack only under `if (kDebugMode && config.useMockAuth)`. A
> tampered/re-signed APK that rewrites the asset `.env` can no longer flip
> a release build onto the in-memory mock.
**File:** `lib/features/auth/data/auth_repository_factory.dart:14-20`, `lib/core/config/app_config.dart:38`

**Issue:**
The mock-vs-real auth selector reads `USE_MOCK_AUTH` from `.env` at runtime. There is no `kDebugMode` / `kReleaseMode` guard. An attacker who can rewrite the asset `.env` (`apktool`, re-pack, re-sign with the well-known debug key — see [[C-01]]) or a developer who forgets to flip it before building can ship a release whose entire auth stack is the in-memory mock — meaning every login produces a fully-authenticated session against no IdP.

Fix:

```dart
// lib/features/auth/data/auth_repository_factory.dart:14-20
if (kDebugMode && config.useMockAuth) {
  return MockAuthRepository(secureStore: secureStore);
}
// release: always real
return BffAuthRepository(config: config, secureStore: secureStore);
```

---

### ✅ M-02 No client-side rate-limit / idempotency key on `send-otp` / `verify-otp`

> **✅ Fix applied (2026-05-16).** `email_otp_screen.dart` auto-sends on
> mount only when the channel is `ChannelStatus.idle` — the
> `VerificationBloc` is shared across the whole `/verify` shell, so
> re-entering `/verify/email` against a live code no longer fires a fresh
> send (closes the reopen-route SMS/email-bomb vector). All four mutating
> OTP calls in `bff_verification_api.dart` now carry a 128-bit CSPRNG
> `Idempotency-Key` header. **Note:** server-side rate-limiting remains the
> BFF's responsibility; this is the client-side half only.
**File:** `lib/features/auth/data/bff_auth_api.dart:91-153`, `lib/features/verification/presentation/screens/email_otp_screen.dart:29-32`

**Issue:**
The email-OTP screen fires a `send-otp` call from `initState` with no debouncing:

```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  context.read<VerificationBloc>().add(const EmailSendOtpRequested());
});
```

Any rapid back-and-forth between `/verify` and `/verify/email` (e.g. user tapping in the verification banner, then navigating back, then in again) will issue a fresh `send-otp` per entry. Concrete risks:

- **SMS/email-bombing of a user.** If an attacker can drive a victim's app (e.g. via a deeplink crafted to reopen `/verify/email` on each tap), they can pump unlimited OTP-send requests against the BFF. Defense exists server-side (BFF must rate-limit), but the client should also gate.
- **No `Idempotency-Key` header** on `verify-otp`. A retried verify (network blip) consumes attempts against the BFF counter twice.

Fix: send-OTP only when status is `idle`, not on every screen-mount; add `Idempotency-Key: <uuid>` on every mutating BFF call.

```dart
// lib/features/verification/presentation/screens/email_otp_screen.dart:29-32
WidgetsBinding.instance.addPostFrameCallback((_) {
  context.read<VerificationBloc>().add(const EmailSendOtpRequested());
});
```

---

### ✅ M-03 `verify-phone-otp` re-sends `phone` from client — trust-boundary violation

> **✅ Fix applied (2026-05-16); hardened (2026-05-17).** First pass removed
> `phone` from the verify-phone-otp wire only. Hardening pass removed it
> from **send-phone-otp too**, after the project owner confirmed the BFF
> reads the citizen's number from their **Keycloak profile** (source of
> record, exactly as for email) — so the client never asserts a phone
> number on any call. The phone now travels nowhere client-side:
> `PhoneSendOtpRequested` is payload-less, `sendPhoneOtp({cancel})` and
> `verifyPhoneOtp(code, {cancel})` both omit it through the whole chain
> (`BffVerificationApi` send body is `{}`, verify body `{code}`), and the
> in-app phone-entry step is **deleted** — `PhoneOtpScreen` is now
> structurally identical to `EmailOtpScreen` (auto-send on mount, code
> only, destination read from the auth session). Removed as now-dead:
> `ChannelState.phoneNumber` / `verifyingPhone`, `PhoneEditRequested`,
> and `VerificationErrorCode.phoneNotEntered`. This **supersedes** the
> audit-002 H-07 client-side binding mechanism with the stronger posture
> H-07 actually wanted: the client cannot diverge a number from the BFF
> because it never holds one. **Cross-boundary contract:** the BFF must
> resolve the number from the Keycloak profile on send and from its own
> OTP record on verify — client and BFF stay in lockstep on this. All
> 152 tests green; `flutter analyze` clean.
**File:** `lib/features/auth/data/bff_auth_api.dart:140-153`, `lib/features/auth/data/bff_auth_repository.dart:321-342`

**Issue:**
Verify-phone-OTP sends both `phone` and `code`:

```dart
final res = await _dio.post<Map<String, dynamic>>(
  '/auth/phone/verify-otp',
  data: {'phone': phone, 'code': code},
  ...
);
```

The phone number is already bound to the OTP record server-side at `send-otp` time. By re-sending it from the client on verify, the contract makes the BFF responsible for re-checking the binding on every call. Two failure modes if the BFF's check ever weakens:

1. **Cross-number verification.** An attacker who controls their own bearer asks `send-otp` for their own number, receives the OTP, then verifies against a *different* phone (`{phone: victim, code: <attacker's_code>}`). If the BFF binds only sessionId↔OTP and trusts the client phone in the verify payload, the attacker's session gets `phoneNumberVerified=true` for the victim's number.
2. **Phone re-binding mid-flow.** Client state can diverge from server state (see [[002 H-07]]).

Fix client-side: send only `{code}` on verify-phone-otp, and let the BFF look up the bound phone from its own OTP record. The signature change is small and removes a trust dependency.

```dart
// lib/features/auth/data/bff_auth_api.dart:140-153
data: {'phone': phone, 'code': code},
```

---

### ❌ M-04 OIDC `id_token` discarded — no nonce/at_hash validation, replay-prone
**File:** `lib/features/auth/data/bff_auth_repository.dart:133-138`

**Issue:**
The comment at line 133-134 acknowledges:

```dart
// Note: result.idToken is null with the new BFF — we store null here and
// fetch profile via /auth/me when needed.
final session = _toSession(...);
```

Two consequences:

1. **No nonce verification.** OIDC's `nonce` claim is what protects against replay of an authorization response captured on a network or via the deeplink-hijack of [[C-04]]. Without an `id_token` the client cannot bind the response to the original request. `flutter_appauth` still includes `nonce` in the request (it autogenerates one with `openid` scope), but no one is checking the response against it.
2. **No `at_hash` verification.** The `id_token`'s `at_hash` claim binds the access_token to the id_token. Without it, an attacker who substitutes a different access_token cannot be detected.

Architecturally, the BFF is the OAuth client and is supposed to do all of this — but then `flutter_appauth` should not be in the app at all; the app should call a single `POST /auth/login` over a pinned TLS channel ([[C-03]]) and receive `{access_token, session_id, expires_in}`. The hybrid current state — AppAuth on device, but no id_token — is the worst of both: it adds the deeplink-hijack risk without the OIDC defences.

```dart
// lib/features/auth/data/bff_auth_repository.dart:133-134
// Note: result.idToken is null with the new BFF — we store null here and
// fetch profile via /auth/me when needed.
```

---

### ✅ M-05 `expiresAt` stored as ISO string; local clock & storage tamper bypass

> **✅ Fix applied (2026-05-16).** Two layers: (1) `AuthSession.fromToken`
> already prefers the server-stamped JWT `exp` claim over the wall-clock
> `expires_in` fallback, so a tampered stored ISO string no longer wins;
> (2) added `kSessionExpirySkew` (30 s) — `isExpired` now treats a session
> as dead 30 s early (`DateTime.now().add(kSessionExpirySkew).isAfter(...)`),
> giving proactive refresh and shrinking the device-clock-backdating window
> to ≤30 s of UI slack (the BFF/Kong server clock stays authoritative on
> `/api/*`). **Not done (bonus):** the HMAC-bound storage tuple suggested in
> the audit — the device-clock bypass is damped, not eliminated.
**File:** `lib/core/storage/secure_store.dart:23-50`, `lib/features/auth/presentation/bloc/auth_bloc.dart:32-39`, `lib/features/auth/domain/auth_session.dart:44`

**Issue:**
The session's `expiresAt` is written as an ISO-8601 string and used directly for `isExpired`:

```dart
// secure_store.dart
_storage.write(key: _kExpiresAt, value: expiresAt.toUtc().toIso8601String()),
...
return (..., expiresAt: DateTime.parse(expiresAtRaw));

// auth_session.dart:44
bool get isExpired => DateTime.now().isAfter(expiresAt);
```

Two failure modes:

1. **Device-clock tamper.** `DateTime.now()` reads the device wall clock. A user who sets the clock back to before `expiresAt` keeps "valid" sessions across token rotations indefinitely; the bloc never triggers `AuthRefreshRequested`. The BFF/Kong still 401s on `/api/*` (server clock is authoritative), but the UI keeps showing "authenticated" and only learns otherwise on the next API call — so a paranoid attacker could keep a stolen device "logged in" through ride-share / community-Wi-Fi waiting periods.
2. **Storage-blob tamper.** An attacker with root can rewrite the encrypted-shared-prefs blob (or replace the keystore-wrapped record) to push `expiresAt` arbitrarily far into the future. There's no MAC on the tuple.

Fix: store `expiresAt` only as a hint, treat any token as expired if a small refresh-skew window has passed, and rely on the BFF's `/auth/refresh` (which itself validates server-side) as the source of truth. Bonus: HMAC-bind the tuple `(access_token, session_id, expiresAt)` under a key derived from the access_token itself before writing.

---

### ❌ M-06 `MainActivity launchMode="singleTop"` racing with AppAuth redirect receiver
**File:** `android/app/src/main/AndroidManifest.xml:12`

**Issue:**
`MainActivity` uses `launchMode="singleTop"`. With AppAuth's redirect receiver also resolving the deeplink scheme, two task-affinity outcomes are possible depending on whether the user backgrounded the launcher app before the SSO browser opened:

- The redirect intent goes to `RedirectUriReceiverActivity` first → AppAuth completes its Future → user lands back on `MainActivity` → fine.
- The redirect intent is dispatched to `MainActivity` (because Flutter's deeplink plumbing snags it) → AppAuth's pending Future never resolves → the bloc sits in `authenticating` until the 3-minute timeout in `bff_auth_repository.dart:82`.

The comment at `AndroidManifest.xml:26-31` is aware of this trap, but `singleTop` plus implicit-deeplink-without-an-explicit-intent-filter is fragile. Recommended: pin `launchMode="standard"` for AppAuth flows, or migrate to App Links ([[C-04]]) where the dispatch contract is clear.

```xml
<!-- AndroidManifest.xml:12 -->
android:launchMode="singleTop"
```

---

### ❌ M-07 iOS `Info.plist` declares no ATS exception block but loads cleartext in dev
**File:** `ios/Runner/Info.plist`

**Issue:**
The iOS app has no `NSAppTransportSecurity` block. iOS App Transport Security is enabled by default and would block `http://localhost:8080` cleartext loads — but `flutter_appauth`'s `allowInsecureConnections: true` overrides the check at the AppAuth layer. Dio's underlying `URLSession`, however, will *not* be overridden — so the `/api/profile` calls will silently fail in iOS dev once the simulator points at `http://localhost:8080`. Beyond the dev-UX nuisance, the security cost is that adding an `NSAllowsLocalNetworking` / `NSExceptionDomains` block later is the standard fix and is easy to get *too* permissive (`NSAllowsArbitraryLoads = true`), which then ships to production.

Recommended: explicit, scoped `NSExceptionDomains` for `localhost` only, and reject any PR that introduces `NSAllowsArbitraryLoads`.

---

## LOW Issues

### ✅ L-01 `debugShowCheckedModeBanner: false` masks debug builds in screenshots

> **✅ Fix applied (2026-05-16).** `app.dart` now sets
> `debugShowCheckedModeBanner: !kReleaseMode` — the banner stays visible in
> debug/profile builds so QA and help-desk screenshots visibly distinguish
> them from a real release.
**File:** `lib/app.dart:61`

**Issue:**
The MaterialApp suppresses the debug-mode banner. While cosmetically nice, it removes the visual cue that distinguishes a debug build (with full logging, mock toggle reachable, debugger pinnable) from a release build during help-desk screenshots or QA recordings. Recommend leaving the banner visible in non-release modes.

```dart
// lib/app.dart:61
debugShowCheckedModeBanner: false,
```

---

### ✅ L-02 Raw server `error_description` rendered into UI without sanitisation

> **✅ Confirmed fixed (reclassified 2026-05-16).** `login_screen.dart`
> renders `authErrorMessage(l10n, errorCode)` — a localized message keyed
> off the typed `AuthErrorCode` enum. The raw server `error_description`
> lives only in `AuthFailure.diagnostic` (logs), never in user-facing UI.
> The report entry was stale.
**File:** `lib/features/auth/data/bff_auth_repository.dart:367-378`, `lib/features/auth/presentation/screens/login_screen.dart:34-41`

**Issue:**
`_mapDio` lifts the server's `error_description` directly into `AuthFailure.message`, which the login screen then renders as a `Text` widget. Flutter `Text` is not HTML-rendered, so XSS is not directly exploitable, but the pattern reflects server-controlled strings into the UI without length/character whitelisting. If the BFF ever proxies a Keycloak error verbatim, the user may see a stack-trace fragment or an internal hostname. Length-clamp and strip control characters before display.

```dart
// lib/features/auth/data/bff_auth_repository.dart:370-372
if (body is Map && body['error_description'] is String) {
  desc = body['error_description'] as String;
}
```

---

### ❌ L-03 `.env.example` documents `OAUTH_CLIENT_ID=super-app-eco` — reconnaissance
**File:** `.env.example:13`, `.env:3`

**Issue:**
The client_id is committed in `.env.example` and (currently) in the working `.env`. The client_id alone is not a secret — but combined with the production BFF URL (`mobile.pangkalpinangkota.go.id` per `network_security_config.xml:8`), an attacker has the two values they need to start probing OAuth-misconfiguration vectors against the BFF. Reconnaissance hygiene: keep `.env.example` to placeholder values, document the real ID in a private runbook.

---

### ✅ L-04 `SecureStore` uses `KeychainAccessibility.first_unlock` (no biometric)

> **✅ Fix applied (2026-05-16).** `secure_store.dart` now uses
> `KeychainAccessibility.first_unlock_this_device` — same "readable after
> first unlock" semantics but the bearer / session_id no longer migrate to
> iCloud Keychain or a restored device. (Note: `flutter_secure_storage`
> 9.2.4 exposes this as `first_unlock_this_device`, not the audit's
> `_only` suffix.) Biometric-gated accessibility for future high-value
> flows remains a deliberate later step, not part of this fix.
**File:** `lib/core/storage/secure_store.dart:13-15`

**Issue:**

```dart
iOptions: IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
),
```

`first_unlock` means the item is readable any time after the user unlocked the device once since boot. For a citizen-identity bearer + opaque session_id, `first_unlock_this_device_only` (no iCloud Keychain sync) is the safer default. For high-value flows (a future "pay tax / pay PDAM bill" feature), step up to `passcode` or biometric-gated accessibility (`KeychainAccessibility.passcode` with `BiometryAny`).

---
