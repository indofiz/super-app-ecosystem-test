# Smart App — Pangkal Pinang Super App (User App)

Flutter user app for the Pangkal Pinang super app ecosystem. Authenticates
via the BFF (which wraps Keycloak SSO) and carries a short-lived **internal
JWT** minted by the BFF as its bearer for every downstream API call.

The Flutter app **never** talks to Keycloak directly, never holds a
`client_secret`, and never stores a refresh token. See the workspace-level
`docs/auth-architecture.md` for the full picture.

## Architecture (auth)

```
 Flutter ──► nginx :8080 ──► BFF ──► Keycloak
   │                          │
   │                          ▼
   │                        Redis  (session_id → refresh_token)
   │
   └── stores: internal_jwt + session_id  (flutter_secure_storage)
```

1. App opens `flutter_appauth` against **nginx** at `/auth/authorize`. nginx routes the request to the BFF.
2. BFF runs the OAuth/PKCE dance against Keycloak with its `client_secret`.
3. BFF stores the Keycloak refresh_token in Redis under an opaque `session_id`.
4. BFF mints a short-lived **internal JWT (RS256, ~5 min)** and returns it
   alongside `expires_in` and `session_id` (via the deeplink callback).
   The BFF holds the signing key; Kong holds only the matching public key.
5. App stores `internal_jwt` + `session_id` in `flutter_secure_storage`.
6. Refresh: app POSTs `session_id` to `/auth/refresh` → new internal JWT.
7. Every `/api/*` call: app sends `Authorization: Bearer {internal_jwt}` →
   nginx → Kong (validates RS256 signature against the matching public key
   by `kid`) → upstream service.
8. Logout: BFF invalidates Redis + Keycloak; app wipes secure storage.

## Identifiers

| | |
|---|---|
| App identifier | `id.go.pangkalpinangkota.smart-app-test` |
| Android package / Flutter project | `id.go.pangkalpinangkota.smart_app_test` |
| Keycloak realm | `pangkalpinang` |
| Mobile `client_id` (BFF allowlist, NOT registered in Keycloak) | `super-app-eco` |
| Deeplink redirect URI | `id.go.pangkalpinangkota.smartapptest:/oauth2redirect` |

## Run locally

The default `.env` uses the **in-app mock auth repository** so the UI is
exercisable without the BFF stack running. To swap to the real BFF:

```dotenv
USE_MOCK_AUTH=false
BFF_BASE_URL=http://10.0.2.2:8080   # Android emulator → host's localhost:8080
ALLOW_INSECURE_CONNECTIONS=true     # local HTTP only; MUST be false in prod
```

Then bring up the workspace stack from the repo root:
```bash
docker compose up -d
```

…and run the app:
```bash
cp .env.example .env       # if you haven't already
flutter pub get
flutter run
```

### Reaching the BFF from each platform

| Platform | `BFF_BASE_URL` |
|---|---|
| Android emulator | `http://10.0.2.2:8080` |
| iOS simulator | `http://localhost:8080` |
| Physical device on the same Wi-Fi | `http://<your-laptop-LAN-ip>:8080` |
| Production | `https://<public-host>` (set `ALLOW_INSECURE_CONNECTIONS=false`) |

For a deployment walkthrough of the back-end this app talks to, see
[`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md) at the repo root.

## What the Home screen shows

After login, Home renders:

- A **verification banner** (top of screen) when either `email_verified` or
  `phone_number_verified` is false on the current JWT. Tapping it opens the
  `/verify` route — a hub with one card per channel + entry points to the
  email OTP and phone WA OTP screens. Soft gate: the rest of Home stays
  usable; specific features can hard-gate later per-feature.
- The decoded **internal JWT** (sub, sid, username, email, email_verified,
  phone_number, phone_number_verified, roles, exp, …)
- A `GET /auth/me` button — calls the **BFF** with the bearer; verifies the
  full auth boundary works and returns the cached profile snapshot.
- A `GET /api/profile` button — calls **Kong → sample-service** with the
  bearer; verifies Kong's bundled `jwt` plugin accepts the BFF-minted token
  and the upstream chain works end-to-end.

Both `/me` and `/api/profile` buttons fail if the workspace stack isn't up
or the bearer is expired (refresh via the toolbar's circular-arrow button).

In mock mode (`USE_MOCK_AUTH=true`), the verification flow is fully
exercisable: **`123456` is the magic accepted OTP for both channels.**
Any other 6-digit input yields an `OtpInvalidFailure` with `attemptsLeft=4`
so the "sisa percobaan" UX path is also testable.

## When you're ready for real auth

1. Register the Keycloak `super-app-bff` confidential client (see `bff/README.md`).
2. Put `KC_CLIENT_SECRET=…` in the workspace `.env`.
3. Set `USE_MOCK_AUTH=false` here.
4. `docker compose up -d --build` from the repo root.
5. `flutter run`.

No mobile-side code changes needed past the env edit.

## Project layout

```
lib/
  main.dart, app.dart
  core/
    config/    AppConfig (.env, including ALLOW_INSECURE_CONNECTIONS)
    storage/   SecureStore (flutter_secure_storage)
    router/    GoRouter + auth-driven redirects
  features/
    auth/
      domain/         AuthRepository, AuthSession, UserProfile, AuthFailure,
                      OtpInvalidFailure, OtpExpiredFailure, JwtClaims
      data/           BffAuthRepository, MockAuthRepository, BffAuthApi
      presentation/   AuthBloc, LoginScreen, SplashScreen
    home/
      presentation/   HomeScreen (banner + JWT preview + /me + /api/profile demos),
                      widgets/VerificationBanner
    verification/
      presentation/
        bloc/         VerificationBloc (two parallel channels: email + phone)
        screens/      VerificationScreen, EmailOtpScreen, PhoneOtpScreen
        widgets/      OtpInput (6-digit), ResendTimer
    sample/
      data/           SampleApi (calls /api/profile through Kong)
```

## Security guardrails

- The app never references Keycloak URLs in OAuth config — only the BFF.
- Refresh tokens never live on-device.
- Don't log `access_token` (the internal JWT), `session_id`, or any bearer.
- `ALLOW_INSECURE_CONNECTIONS=true` is for **local dev only**. Production
  builds must set it `false` and `BFF_BASE_URL` must be `https://`.
