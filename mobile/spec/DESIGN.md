# DESIGN.md — Routes, Screen States, UX Gates

Companion to [`SPEC.md`](SPEC.md).

> **Scope note.** This reference app's UI is intentionally minimal — the
> real main app has its own, better design system. This doc describes the
> **structural UX contract** (routes, redirects, which Bloc state drives
> which screen, the soft-gate behavior) — *not* visual styling. When
> porting: keep the route map + state→screen contract, **restyle freely**.
>
> **Figma:** none for the reference app. Link the main app's Figma here
> when porting: `<add Figma URL>`.

---

## 1. Route map (`go_router`)

| Path | Screen | Notes |
|------|--------|-------|
| `/splash` | `SplashScreen` | initial; shown while `AuthStatus.unknown` |
| `/login` | `LoginScreen` | SSO entry point |
| `/home` | `HomeScreen` | authenticated landing |
| `/verify` | `VerificationScreen` | hub: email + phone status cards |
| `/verify/email` | `EmailOtpScreen` | inside `/verify` ShellRoute |
| `/verify/phone` | `PhoneOtpScreen` | inside `/verify` ShellRoute |

`/verify*` is a **`ShellRoute`** so all three share one
`VerificationBloc` (created on first entry, disposed on leaving the
subtree). `initialLocation: /splash`. Router rebuilds on
`refreshListenable: AuthStatusListenable`.

---

## 2. Redirect table (the auth gate)

Evaluated in `AppRouter._redirect` on every navigation + auth-status
change. `loc` = matched location.

| AuthStatus | Condition | Redirect → |
|------------|-----------|-----------|
| `unknown` | `loc != /splash` | `/splash` |
| `unknown` | `loc == /splash` | (stay) |
| `authenticated` | `loc ∈ {/splash, /login}` | `/home` |
| `authenticated` | else | (stay) |
| `authenticating` | `loc == /home` | `/login` (refresh in flight ⇒ anticipate logout) |
| `authenticating` | else (incl. `/splash`, `/login`) | (stay — don't flash login during cold-start silent refresh) |
| `unauthenticated` | `loc ∈ {/splash, /home}` | `/login` |
| `unauthenticated` | else | (stay) |

**Key UX subtlety to preserve:** during cold-start silent refresh the user
stays on `/splash` (no login flash); login is initiated from `/login`
itself which also stays put.

`/verify*` is **never** a redirect target — verification is a *soft gate*
(see §4).

---

## 3. Screen states

### SplashScreen
Single state: centered progress indicator. Pure visual placeholder while
`AuthStatus == unknown`. (Restyle: brand splash.)

### LoginScreen — driven by `BlocBuilder<AuthBloc, AuthState>`
| `state` | UI |
|---------|----|
| `status == authenticating` | button disabled, spinner, "Signing in…" |
| else | enabled "Sign in with SSO" button |
| `errorCode != null` | error text (localized via `authErrorMessage`) + retry-hint line: `errorCode.isRetryable ? authRetryHint : authPermanentHint` |

Action: button → `AuthBloc.add(AuthLoginRequested())`.

### HomeScreen — `BlocBuilder<AuthBloc, AuthState>`
- `session == null` → progress indicator (transient).
- else → `Column[ VerificationBanner, content ]`.
  - AppBar action: Logout → `AuthLogoutRequested()`. Debug build also
    shows a `DevRefreshAction` + `DevDashboard` (dev-only — drop or
    replace in the real app).
  - `_CitizenHomePlaceholder` is a stub — **replace with the real home**.

### VerificationBanner (soft gate, top of home)
`BlocBuilder<AuthBloc, AuthState>` (`buildWhen` on the two verified
flags):
- `session == null || fullyVerified` → `SizedBox.shrink()` (hidden).
- else → tappable banner; copy depends on what's missing
  ("Akun Anda belum diverifikasi." vs "Verifikasi {email|nomor WhatsApp}
  Anda…"). Tap → `context.push('/verify')`. **Never blocks home.**

### VerificationScreen (hub) — reads `AuthBloc` session
Two `_ChannelCard`s (Email / WhatsApp): icon, title, subtitle
(`session.email` / `session.phoneNumber` or "Belum terdaftar"),
verified badge ("Terverifikasi" / "Belum diverifikasi"), "Verifikasi"
button when not verified → `push('/verify/email'|'/verify/phone')`.
When `fullyVerified`: success block, no buttons. Status updates instantly
because it reads the JWT-decoded session (re-minted on verify).

### EmailOtpScreen / PhoneOtpScreen — `BlocConsumer<VerificationBloc>`
Auto-sends OTP on entry **only if `channel.status == idle`** (prevents an
OTP-bomb when re-entering the shared shell — manual resend stays via the
timer). Layout: destination line (from `AuthBloc` session) → `OtpInput`
(6-digit) → error text (`verificationErrorMessage`, with
`attemptsLeft`) → Verify button (disabled while busy / code≠6 digits,
spinner while `verifying`) → `ResendTimer` (gated by `expiresAt` /
`kOtpResendCooldown`).
- `listenWhen` status → `verified`: snackbar "… berhasil diverifikasi." +
  `Navigator.pop()` back to the hub.

| `ChannelStatus` | UI |
|-----------------|----|
| `idle` | (entry) auto-send fires; or error shown, resend available |
| `sending` | inputs disabled, busy |
| `awaitingCode` | OTP input active, resend timer running |
| `verifying` | verify button spinner, inputs disabled |
| `verified` | snackbar + pop |

---

## 4. Soft-gate principle (do not turn into a hard gate)

Verification is **never** enforced by the router. An unverified user has
full access to `/home`; the only prompts are the dismissable-by-completion
`VerificationBanner` and the hub cards. Individual *features* may
self-gate on `session.fullyVerified` later — that is a feature decision,
not a routing one. Keep this behavior in the port.

---

## 5. Localization

`AppLocalizations` (`l10n/app_en.arb`, `app_id.arb`; default UI copy is
Indonesian). The data/domain layers emit **error codes**; presentation
resolves them: `auth_error_l10n.dart` (`authErrorMessage`,
`authRetryHint`, `authPermanentHint`) and `verification_error_l10n.dart`
(`verificationErrorMessage(..., attemptsLeft:)`). When porting: keep the
code→string mapping function shape, swap the actual strings/tone to match
the main app.

---

## 6. Theming

Reference app: `ColorScheme.fromSeed(seedColor: 0xFF1F4E8C)`, Material 3,
debug banner shown in non-release builds (QA can distinguish a debug
build). **Replace entirely** with the main app's theme — nothing here is
prescriptive. Only keep: the non-release debug-banner convention and the
release `ErrorWidget.builder` override (friendly localized tile + reload,
instead of the red error box) for production resilience.
