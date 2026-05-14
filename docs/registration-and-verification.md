# Registration, Verification & Account Lifecycle

How a citizen goes from "no account" to "fully verified `MASYARAKAT`" in
the Pangkal Pinang super-app — and the architectural reasoning behind
*where* each step runs (Keycloak hosted page vs. the mobile app).

This document is a companion to [`auth-architecture.md`](auth-architecture.md).
That doc covers the **token model** and the **steady-state login/refresh/logout**
loop. This doc covers everything *before* the first successful login:
account creation, email verification (OTP code), NIK collection, phone
capture, WhatsApp OTP verification, and password reset.

> **TL;DR.** Credential ceremonies (password set, password reset)
> run on the Keycloak hosted page opened via `flutter_appauth`.
> Registration also runs on the hosted page (the "Daftar" link).
> **Email verification** and **WhatsApp verification** are both
> attribute-verification (not credential) ceremonies and run in-app
> through the BFF — see §4.B and §4.D and the "Implementation status"
> box below.

> **Implementation status (as of 2026-05-14).** Phase 0.2, Phase 1, and
> Phase 2 of §5 have shipped:
>   - Mobile soft-gate: home shows a banner when `email_verified` or
>     `phone_number_verified` is false. Tap → verify screen.
>   - BFF endpoints `POST /auth/{email,phone}/{send,verify}-otp`,
>     OTP store with hashed codes + per-record attempts cap, Gmail
>     SMTP adapter (nodemailer, App Password), Fonnte WA adapter,
>     Keycloak Admin client with GET-then-PUT attribute merge.
>   - Internal JWT now carries `email_verified`, `phone_number`,
>     `phone_number_verified`; `/auth/me` returns them too.
>
> **Deviation from §4.B.** We shipped email as in-app OTP (the §4.B B2
> shape, but in the BFF instead of a KC Required Action SPI) rather
> than B1 (KC hosted magic link). Reasons:
>   - Same UX shape as WA OTP — one verify screen, two inputs.
>   - No Gmail-as-Keycloak-SMTP wiring required; the BFF's nodemailer
>     adapter owns the channel.
>   - Email is an *attribute* (no password in mobile), so the §3
>     "credentials must run on the IdP origin" argument doesn't apply
>     with the same force.
> When a second client (web/OPD portal) arrives that argument *does*
> apply again — migrating both ceremonies to KC Required Action SPIs
> (§4.B B2 + §4.D D1) becomes the right move at that point.

---

## 1. Why this is a decision worth writing down

The super-app has one mobile client today (`mobile/`) and one public web
client declared in the realm (`launcher-web`). A second mobile app or a
partner OPD portal will arrive eventually. The question — "do we collect
the password / OTP / NIK in our Flutter screens, or on Keycloak's hosted
page?" — locks in a posture for every future client.

Get it wrong in the direction of "do it in Flutter" and:

- Each new client re-implements forms, rate-limiting, lockout, password
  policy enforcement, breached-password checks, and i18n.
- The IdP cannot enforce ceremonies on bypass paths (a stolen refresh
  token, an admin-issued internal JWT, a future service-to-service tool)
  because the gate lives in the mobile app process.
- The mobile app moves into scope for credential storage, transit, and
  recovery under OWASP ASVS V6 — a much heavier security review surface.

Get it right ("do it on Keycloak") and:

- Every client — present and future — passes the same gate for free.
- New ceremonies (MFA, WebAuthn, terms-and-conditions) are turned on with
  a realm checkbox and zero mobile change.
- The mobile app stays a *viewer* of identity, not an *owner* of it,
  which is the same posture the project already commits to for login
  ([memory: BFF-only, no direct IdP access from clients]).

This doc lays out that decision once, with the research that backs it,
so future PRs don't relitigate it ceremony by ceremony.

---

## 2. Current realm state (Keycloak 24.0.5)

What [`docs/pangkalpinang-realm.json`](pangkalpinang-realm.json) actually
gives you today. Read this section before making any code change —
several of the gaps below block the flows in §4.

### 2.1 What's wired

| Realm setting | Value | Effect |
|---|---|---|
| `registrationAllowed` | `true` | Hosted **Daftar** page is reachable |
| `registrationEmailAsUsername` | `true` | Email *is* the username — no separate login id |
| `resetPasswordAllowed` | `true` | "Lupa password?" link renders on the login page |
| `loginWithEmailAllowed` | `true` | Login by email |
| `duplicateEmailsAllowed` | `false` | Single account per email |
| `defaultSignatureAlgorithm` | `RS256` | Matches our internal-JWT alg |
| `otpPolicyType` | `totp` | TOTP authenticator only (no email/SMS HOTP) |

Required Actions enabled in the realm:

| Action | Provider id | Purpose |
|---|---|---|
| Configure OTP | `CONFIGURE_TOTP` | TOTP enrolment for MFA |
| Update Password | `UPDATE_PASSWORD` | Forced password change |
| Update Profile | `UPDATE_PROFILE` | Re-collect profile attributes |
| Verify Email | `VERIFY_EMAIL` | Stock magic-link verification |
| Verify Profile | `VERIFY_PROFILE` | Re-validate existing profile against current rules |
| Webauthn Register | `webauthn-register` | Passkey enrolment |
| Webauthn Register Passwordless | `webauthn-register-passwordless` | Passkey, passwordless variant |
| Delete Credential | `delete_credential` | Self-service credential removal |
| Update User Locale | `update_user_locale` | i18n switcher |

Already declared on the user model:

- `nik` user attribute, mapped to the `nik` claim in `access_token` + userinfo via `oidc-usermodel-attribute-mapper`.
- Built-in OIDC `phone` scope with `phone_number` and `phone_number_verified` claims (sources: `phone_number` and `phoneNumberVerified` user attributes).
- Realm roles `MASYARAKAT` (citizen, default), `ASN`, `ADMIN_OPD`, `SUPER_ADMIN`.

Clients:

- `super-app-bff` (confidential, `serviceAccountsEnabled: true` — the BFF can call the Admin API).
- `launcher-web` (public, standard flow).

### 2.2 Gaps that must be closed before shipping registration

| Gap | Why it blocks | Fix |
|---|---|---|
| `smtpServer: {}` | **Verify Email** and **Forgot Password** both depend on outbound email; without SMTP they are no-ops. | Configure Realm → Email with a reliable transactional provider (e.g. Gov-tenant SES, a regional MTA). |
| `bruteForceProtected: false` | A registration/reset endpoint without lockout is an enumeration + credential-stuffing surface. | Turn on, set `failureFactor=10`, `waitIncrementSeconds=60`, `maxFailureWaitSeconds=900`. |
| `verifyEmail: false` (global flag) | Even though `VERIFY_EMAIL` is enabled as a required action, the realm-level flag is what forces it on new registrations. | Set to `true` once SMTP works. |
| `super-app-bff` client **secret is committed** in the realm export (plaintext) | Anyone with repo read access has the secret. | Rotate the secret in KC admin; remove the value from the committed JSON or re-export with `--users skip --realm-only`. |
| No declarative User Profile policy | `nik` exists as a free-form attribute with no validators; KC won't render a registration form field for it without User Profile enabled. | Realm Settings → User Profile → Enable, then declare `nik`, `phoneNumber`, `phoneNumberVerified` (see [Appendix A](#appendix-a-declarative-user-profile-snippet)). |
| No `MASYARAKAT_VERIFIED` role (or equivalent gate) | The downstream services have no way to require "phone verified" beyond reading the `phone_number_verified` claim. | Either add the role, or have services check `phone_number_verified === "true"` from the internal JWT. Recommend the claim approach. |

### 2.3 What's missing entirely

- **WhatsApp OTP authenticator** — no Keycloak SPI ships for this. §4.D covers the build-vs-buy options.
- **NIK validity check against Dukcapil** — out of scope for this doc; for the MVP, validate length + checksum locally and store the value. A separate `nik-verification-service` can hit Dukcapil later.
- **Indonesian theme** — the Keycloak login/register/reset pages render in English with the stock theme. A custom theme (FreeMarker + CSS) in `id-ID` is high-impact and not difficult; tracked separately.

---

## 3. The big architectural decision: hosted page vs native mobile

### 3.1 What standards and vendors say

| Source | Position | Citation |
|---|---|---|
| **IETF RFC 8252** — *OAuth 2.0 for Native Apps* (BCP 212) | Native apps **MUST** use an external user-agent (Custom Tab on Android, ASWebAuthenticationSession on iOS). Embedded WebViews and native credential forms are **prohibited**. | §8.12 — [datatracker.ietf.org/doc/html/rfc8252](https://datatracker.ietf.org/doc/html/rfc8252) |
| **IETF draft-ietf-oauth-v2-1** — *OAuth 2.1* | The Resource Owner Password Credentials grant (the closest spec match for "collect password in app") is **removed**. | §1.3.2 — [oauth.net/2.1/](https://oauth.net/2.1/) |
| **OpenID Connect Core 1.0** | The authentication request is browser-mediated; credentials are collected at the OP's authorization endpoint, not the RP. | §3.1 — [openid.net/specs/openid-connect-core-1_0.html](https://openid.net/specs/openid-connect-core-1_0.html) |
| **NIST SP 800-63C** — *Digital Identity Guidelines, Federation* | Authenticator binding and credential management belong to the **CSP** (Credential Service Provider). In federated flows, RPs do not enrol or recover authenticators. | §5.1 — [pages.nist.gov/800-63-3/sp800-63c.html](https://pages.nist.gov/800-63-3/sp800-63c.html) |
| **OWASP ASVS 4.0** | V6.1.3 — authentication on a single, server-controlled origin; V6.2 — credential storage, transit, recovery, rate-limiting are server-side responsibilities. | [owasp.org/ASVS](https://owasp.org/www-project-application-security-verification-standard/) |
| **OWASP MASVS-AUTH-2** | "The app uses standard authentication flows" — interpreted by the verification spec as Authorization Code + PKCE through the system browser. | [mas.owasp.org](https://mas.owasp.org/MASVS/) |
| **Auth0** — *Universal Login vs Embedded Login* | Universal Login is recommended for all credential ceremonies; embedded is offered with explicit security warnings. | [auth0.com/docs/authenticate/login/universal-vs-embedded-login](https://auth0.com/docs/authenticate/login/universal-vs-embedded-login) |
| **AWS Cognito** | Hosted UI is the recommended path for register, sign-in, and forgot-password; Amplify routes through the system browser. | [docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-app-integration.html](https://docs.aws.amazon.com/cognito/) |
| **Microsoft Entra ID** | Native registration and reset are gated to hosted pages; the MSAL SDK opens the system browser. | [learn.microsoft.com/entra/identity-platform/](https://learn.microsoft.com/en-us/entra/identity-platform/) |

The consensus is uniform: **credential ceremonies run on the IdP's
origin**, opened by a system browser. The project already implements
exactly this shape for login via `flutter_appauth`; extending it to
register / reset / verify is the natural and cheapest move.

### 3.2 Tradeoff table — concrete for this project

| Concern | Hosted SSO page | Native mobile form |
|---|---|---|
| OAuth/OIDC conformance | ✅ RFC 8252 + OIDC Core | ❌ ROPC-style; removed in OAuth 2.1 |
| Brute force / lockout | ✅ `bruteForceProtected` (one realm checkbox) | ❌ Reimplement per ceremony in BFF |
| Password leak detection | ✅ KC password policies + community HIBP SPI | ❌ Custom code in BFF |
| MFA / passkey escalation | ✅ Add as Required Action — zero mobile change | ❌ New screen, new mobile build |
| i18n + accessibility | ✅ Themes ship ID + EN strings via `messages_*.properties` | ❌ Maintain in Flutter |
| CAPTCHA / bot defence | ✅ reCAPTCHA / hCaptcha authenticators bundled | ❌ Custom |
| Web client reuse (`launcher-web`) | ✅ Same page serves both | ❌ Re-implement in each web app |
| Enforcement on bypass paths | ✅ Anyone reaching Kong has cleared every Required Action | ❌ A direct-API caller never sees the mobile gate |
| Audit trail | ✅ KC events stream | ❌ BFF logs only |
| Threat model surface for mobile | ✅ Mobile process never sees a password | ❌ Keylogger / accessibility-service capture possible |
| In-app UX cohesion | ⚠️ Custom Tab swap (normal, accepted) | ✅ Stays in-app |
| Visual customization | ⚠️ FreeMarker theme (learning curve, one-time cost) | ✅ Full Flutter freedom |
| WA OTP delivery | ❌ No KC support; needs SPI | ✅ BFF + provider SDK is straightforward |

The hosted page loses on exactly two axes: *visual freedom* and
*WhatsApp delivery effort*. Both are addressable — a custom KC theme
solves the first; §4.D covers the second.

### 3.3 Why this matters in the Indonesian gov-tech context

- The Pangkal Pinang Keycloak is shared across OPDs (other apps will
  onboard against the same realm). A native register form in *this*
  app does nothing for those other apps; a hosted page does.
- Citizens may register on a kiosk, a web client, or the mobile app —
  the journey must look the same regardless. Hosted pages give this for
  free.
- Bahasa Indonesia compliance + Pemkot branding live in **one** theme,
  not in N mobile apps.

---

## 4. Per-ceremony flows

All flows below assume the mobile app uses the existing
`flutter_appauth` integration (see
[`mobile/lib/features/auth/data/bff_auth_repository.dart`](../mobile/lib/features/auth/data/bff_auth_repository.dart))
and routes through `/auth/authorize` on the BFF. Only ceremony D adds
new BFF endpoints; everything else is realm config + theme + a CTA in
mobile.

### A. Registration

**Where:** Keycloak hosted page. **New code in mobile:** ~10 lines (a new CTA + the same AppAuth call with `prompt=login`).

```
mobile (Flutter)         Custom Tab                  BFF                  Keycloak
   │                          │                       │                      │
   │ user taps "Daftar"       │                       │                      │
   │ AppAuth.authorize(       │                       │                      │
   │   prompt=login)          │                       │                      │
   │ ──────────────────────► /auth/authorize          │                      │
   │                          │ ────────────────────► │                      │
   │                          │                       │ 302 to KC /auth      │
   │                          │ ◄──────────────────── │                      │
   │                          │ ───────────────────────────────────────────► │
   │                          │       KC login page renders                  │
   │                          │       ↓ user clicks "Daftar"                 │
   │                          │       ↓ registration form (KC theme)         │
   │                          │       ↓ fields: email, password×2, nik,      │
   │                          │              phoneNumber, fullName            │
   │                          │       ↓ User Profile validators run          │
   │                          │ ◄───────────────────────────────────────────│
   │                          │       Required-action chain runs:            │
   │                          │         1. VERIFY_EMAIL  (OTP code page)     │
   │                          │         2. VERIFY_PHONE  (custom; see §4.D)  │
   │                          │ ◄────── 302 /auth/callback?code=… ──────────│
   │                          │ ────────────────────► │                      │
   │                          │                       │ KC token exchange    │
   │                          │                       │ ──────────────────► │
   │                          │                       │ ◄─── tokens ────────│
   │                          │ ◄── 302 deeplink ──── │                      │
   │ POST /auth/token ─────────────────────────────► │                      │
   │ ◄── internal JWT + session_id ────────────────  │                      │
```

**Why the same `authorize` works:** Keycloak's login page contains the
"Daftar" link by default when `registrationAllowed=true`. The user
clicks it, completes the form, and Keycloak then runs the standard
required-action chain before redirecting back to the BFF callback. The
mobile app and BFF code paths are **byte-identical** to a login.

### B. Email verification — OTP code on the hosted page

Stock Keycloak emails a **magic link** (URL with action token); the user
clicks it in their inbox, lands on a "Your email is verified" page, and
the flow continues. For the Indonesian citizen UX where users often
bounce between inbox apps and the super-app, a **6-digit OTP code typed
into the KC page** reads as more familiar.

Two options:

**B1 — Stock magic link (zero code; ship first).**

```
KC                                User mail client            User
 │ runs VERIFY_EMAIL RA            │                            │
 │ generate action token (5 min)   │                            │
 │ email link ───────────────────► │                            │
 │ render holding page on theme    │ ──► inbox                  │
 │                                 │ ◄── click link  ◄────────  │
 │ KC verifies token, sets         │                            │
 │ emailVerified=true              │                            │
 │ continues required-action chain                              │
```

**B2 — OTP code via Required Action SPI (when B1 isn't enough).**

```
KC                                SMTP / OTP delivery
 │ runs VERIFY_EMAIL_OTP RA          │
 │ generate 6-digit code             │
 │ stash in user session note        │
 │ send via SMTP ──────────────────► │
 │ render "Masukkan kode" form       │
 │ ◄── user types code ─             │
 │ constant-time compare             │
 │   ok → emailVerified=true → next required action
 │   nok → increment attempts, lock after N
```

Ship B1 first. Only build B2 if delivery telemetry shows users dropping
off on the magic-link step. The SPI is ~200 lines of Java + a
FreeMarker template; community examples exist (e.g.
[`dasniko/keycloak-2fa-email-authenticator`](https://github.com/dasniko/keycloak-2fa-email-authenticator)
adapted to a Required Action instead of an authenticator).

### C. NIK and phone capture

**Where:** Keycloak hosted page (declarative User Profile).

NIK is already a user attribute with a protocol mapper; phone is already
wired through the OIDC `phone` scope. What's missing is the **declarative
User Profile** policy that tells Keycloak to render those fields in the
registration form and validate them.

Once User Profile is on (Realm Settings → User Profile → Enable), drop
the JSON in [Appendix A](#appendix-a-declarative-user-profile-snippet).
Keycloak then:

1. Renders `nik` and `phoneNumber` as required fields on the registration
   page automatically — no theme change.
2. Runs the regex validators server-side (a `\d{16}` NIK that doesn't
   parse comes back as a `400` with a translated error message).
3. Surfaces the same form during the `UPDATE_PROFILE` and
   `VERIFY_PROFILE` required actions, so existing users without an NIK
   are forced to add one on their next login — no migration script.

**NIK structure (for the regex + later Dukcapil validation):**

```
Position  1-2   Province code
Position  3-4   Kabupaten/Kota code
Position  5-6   Kecamatan code
Position  7-12  DDMMYY (date of birth; women have DD + 40)
Position 13-16  Sequential number
                Total: 16 digits, all numeric
```

A regex of `^\d{16}$` is sufficient for v1; a separate
`nik-verification-service` behind Kong can call Dukcapil's
`pembanding-data` API for real verification once contracts are in place.

### D. Phone verification via WhatsApp OTP

This is the only ceremony Keycloak does not ship support for. Three
implementation paths, ranked by long-term fit:

| Path | Gate location | Effort | When to pick |
|---|---|---|---|
| **D1** — Keycloak Required Action SPI (custom Java) calling WA Business API | Inside Keycloak's required-action chain | High (build + deploy a JAR, learn Quarkus build) | Long term, multi-client, defence-in-depth |
| **D2** — Adapt a community SMS/WA Keycloak plugin | Inside Keycloak | Medium (fork + Indonesian provider integration) | If a maintainable upstream exists |
| **D3** — BFF post-login flow + Admin API write-back | Inside the BFF (with native mobile screens) | Low (~2 days) | MVP today — mobile is the only client |

**Recommendation:** ship D3 now; migrate to D1 in v2 once stable.

#### D3 — MVP flow (BFF + native mobile)

```
Mobile (Bloc)        BFF                   WA provider           KC Admin API
  │                   │                          │                     │
  │ user submits      │                          │                     │
  │ phoneNumber       │                          │                     │
  │                   │                          │                     │
  │ POST /auth/phone/send-otp                    │                     │
  │   { phone }       │                          │                     │
  │ ─────────────────►│                          │                     │
  │                   │ rate-limit by sub + IP   │                     │
  │                   │   (Redis token-bucket)   │                     │
  │                   │ generate 6-digit code    │                     │
  │                   │ SET otp:<sub>:phone =    │                     │
  │                   │   {code, attempts:0}     │                     │
  │                   │   EX 300                 │                     │
  │                   │ ────────────────────────►│                     │
  │                   │ ◄── delivered ───────────│                     │
  │ ◄── 202 ──────────│                          │                     │
  │                   │                          │                     │
  │ user types code   │                          │                     │
  │ POST /auth/phone/verify-otp                  │                     │
  │   { phone, code } │                          │                     │
  │ ─────────────────►│                          │                     │
  │                   │ GETDEL otp:<sub>:phone   │                     │
  │                   │ constant-time compare    │                     │
  │                   │ ok →                     │                     │
  │                   │   PUT /admin/realms/pangkalpinang/users/<sub>  │
  │                   │     { attributes:{                             │
  │                   │       phoneNumber:[…],                         │
  │                   │       phoneNumberVerified:["true"] }}          │
  │                   │ ──────────────────────────────────────────────►│
  │                   │ ◄── 204 ───────────────────────────────────────│
  │                   │                                                │
  │                   │ internally trigger refresh: mint a new        │
  │                   │ internal JWT whose `phone_number_verified=true`│
  │ ◄── { verified:true, access_token, expires_in } ──────             │
```

**Rate limits to set (matches existing patterns in `bff/src/auth/middleware/rateLimit.ts`):**

| Endpoint | Key | Limit |
|---|---|---|
| `POST /auth/phone/send-otp` | `sub`  | 3 / 10 min |
| `POST /auth/phone/send-otp` | client IP | 10 / 10 min |
| `POST /auth/phone/verify-otp` | `sub` + `phone` | 5 attempts / OTP record (then `GETDEL` and force resend) |

**Provider considerations (Indonesian market):**

| Provider | Channel | Notes |
|---|---|---|
| **Meta WhatsApp Cloud API** | Official | Cheapest at scale; requires WABA + verified business; template approval needed for OTP messages |
| **Fonnte** | Reseller | Quick to onboard, suitable for pilots; unofficial — sessions can break |
| **Wablas** | Reseller | Similar shape to Fonnte; HTTP API; cheap per-message |
| **Twilio WhatsApp** | Official reseller | Highest reliability + cost; good if Twilio is already in use |

For a city pilot, Fonnte/Wablas → migrate to Meta Cloud API as soon as
volume justifies WABA verification. Behind a thin adapter
(`bff/src/lib/waOtp.ts`) the provider swap is one file.

#### D1 — Long-term shape (Keycloak SPI)

Once D3 is stable and the provider integration is hardened, fold it into
a Keycloak Required Action SPI so the gate moves into the IdP. The SPI's
contract:

```
public class WaPhoneVerifyRequiredAction implements RequiredActionProvider {
    public void requiredActionChallenge(RequiredActionContext context) {
        // render the "input WA OTP" page (FreeMarker template)
    }
    public void processAction(RequiredActionContext context) {
        // read code, compare, set phoneNumberVerified user attr
        // and remove this required action from the user
    }
}
```

Deployed as a JAR in `/opt/keycloak/providers/`. The downstream effect:
every client (mobile, launcher-web, future OPD portals) inherits the
gate, and the BFF endpoints from D3 can be deleted.

### E. Password reset

**Where:** Keycloak hosted page — already supported.

```
mobile           Custom Tab              BFF              Keycloak
  │  user taps "Lupa password"                                │
  │  AppAuth.authorize(                                       │
  │    prompt=login,                                          │
  │    kc_action=reset-credentials)                           │
  │ ───────────────► /auth/authorize ───► │                   │
  │                          │            │ 302 → KC reset    │
  │                          │            │   credentials flow│
  │                          │ ──────────────────────────────►│
  │                          │  KC renders "Reset password"   │
  │                          │  user types email              │
  │                          │  KC sends reset link via SMTP  │
  │                          │  user opens link → KC page     │
  │                          │  sets new password             │
  │                          │  continues to login normally   │
  │                          │ ◄── 302 callback?code=… ──────│
  │ ◄── deeplink with code ───────────────────────────────── │
```

Two small changes to enable this:

1. **BFF (`bff/src/auth/handlers/authorize.ts`):** the `QuerySchema`
   currently allowlists `prompt`, `max_age`, `login_hint`, `ui_locales`.
   Add `kc_action` to the allowed set and pass it through to the
   upstream `authorization_endpoint` URL. `kc_action` is a Keycloak
   extension that triggers a specific required-action flow without a
   pre-existing session.
2. **Mobile (`mobile/lib/features/auth/`):** add a "Lupa password" CTA
   on the login screen that calls `login()` with an additional
   `additionalParameters: {'kc_action': 'reset-credentials'}` on the
   AuthorizationTokenRequest. Same flow, same callback handling, same
   token endpoint.

### F. MFA — for the record

Realm already has `CONFIGURE_TOTP` and `webauthn-register*` enabled as
required actions. To turn on MFA for citizens later: bind those required
actions to a conditional sub-flow under the `browser` authentication
flow ("Conditional OTP" — KC ships this), zero mobile change. Out of
scope for this doc; mentioned so the architectural decision in §3 is
seen as future-proof.

---

## 5. Implementation plan (phased)

### Phase 0 — realm hygiene (half a day, blocks everything else)

See [`realm-setup.md`](./realm-setup.md) for the click-by-click admin
walkthrough. Summary:

1. Rotate `super-app-bff` client secret in KC admin; remove the value from
   the committed realm export (re-export or hand-edit). Put the new secret
   in `bff/.env` as `KC_CLIENT_SECRET`.
2. **Add `phone` to `super-app-bff`'s default client scopes** — required
   so `phone_number_verified` lands on access tokens.
3. **Grant `manage-users` + `view-users` (from `realm-management`) to the
   `super-app-bff` service account** — required so the BFF can call
   `PUT /admin/realms/.../users/{id}` to flip verification flags.
4. **Enable User Profile** + paste the JSON from
   [Appendix A](#appendix-a-declarative-user-profile-snippet) — declares
   `nik`, `phoneNumber`, and `phoneNumberVerified` (admin-edit-only).
5. (Recommended) Configure `smtpServer` (Realm Settings → Email) for
   future Forgot-Password / hosted email-verify flows. The BFF's own OTP
   email goes via the BFF's nodemailer adapter, not KC SMTP.
6. (Recommended) Set `bruteForceProtected=true`.
7. Run `node kong/scripts/audit-kid-config.mjs` to confirm no other
   config drift snuck in.

### Phase 1 — registration on the hosted page (1 day)

1. Add a "Daftar" CTA in mobile that calls `login()` (yes, the same
   method) so AppAuth opens the Custom Tab. The user clicks "Daftar" on
   the KC page.
2. Verify the realm registration form renders `nik` and `phoneNumber`
   with validators. Translate the labels via a custom theme (Phase 4) or
   override `messages_id.properties` in the default theme.
3. End-to-end test: create a new account → verify email link → log in.

### Phase 2 — password reset wiring (half a day)

1. Allowlist `kc_action` in `bff/src/auth/handlers/authorize.ts`.
2. Add "Lupa password" CTA in mobile, passing
   `additionalParameters: {'kc_action': 'reset-credentials'}`.
3. End-to-end test on a known account.

### Phase 3 — WA OTP via BFF (2 days)

1. Provider integration: pick Fonnte or Wablas, build
   `bff/src/lib/waOtp.ts` with the `sendOtp(phone, code)` adapter
   contract.
2. New endpoints in `bff/src/auth/router.ts`:
   - `POST /auth/phone/send-otp`
   - `POST /auth/phone/verify-otp`
   Both require `bearerStrict` (already defined in router.ts).
3. New Redis store `bff/src/auth/stores/otp.store.ts` with
   `put / takeAndCompare / delete` and an attempts counter.
4. KC Admin API client in `bff/src/lib/keycloakAdmin.ts` using the
   `super-app-bff` service account (client credentials grant — already
   enabled). One method needed:
   `setUserAttributes(sub, { phoneNumber, phoneNumberVerified })`.
5. Add `phone_number_verified` claim to the internal JWT mint path in
   `bff/src/auth/handlers/token.ts` and `refresh.ts`. Source it from the
   `phone_number_verified` claim on the KC access token (already
   available via the OIDC `phone` scope, which `super-app-bff` must
   request — confirm `KC_SCOPES` includes `phone` and update the realm
   scope if needed).
6. Mobile: new Bloc state `phoneVerificationRequired` triggered after
   login when the JWT lacks `phone_number_verified=true`; screen at
   `mobile/lib/features/auth/presentation/screens/phone_verify_screen.dart`
   collecting phone → send OTP → enter code → verify → call
   `/auth/refresh` to roll the JWT forward.

### Phase 4 — Indonesian theme (1-2 days)

Fork the `keycloak.v2` base theme; replace the Pemkot logo; override
`messages_id.properties` and switch `defaultLocale` to `id`. Drop the
theme JAR or directory under `/opt/keycloak/themes/` in the deployment.

### Phase 5 — WA OTP as a Keycloak SPI (later, when justified)

When (a) provider integration is stable, (b) a second client (web,
partner app) needs phone verification, or (c) downstream services need
to fail-closed on `phone_number_verified` independent of the BFF —
implement D1 and delete the BFF endpoints from Phase 3.

---

## 6. Data model — what lives where after these changes

### 6.1 Keycloak user model

| Attribute | Source | Required | Verified flag |
|---|---|---|---|
| `email` | registration form | yes (username) | `emailVerified` (KC built-in) |
| `fullName` | registration form (declarative UP) | yes | n/a — surfaced as the OIDC `name` claim via the `fullName` protocol mapper on `super-app-bff` |
| `nik` | registration form (declarative UP) | yes | not separately verified in v1 |
| `phoneNumber` | registration form or post-login screen | yes (eventually) | `phoneNumberVerified` (set by BFF after WA OTP) |
| `phoneNumberVerified` | BFF Admin API write after OTP | n/a | this *is* the flag |
| `emailVerifiedAt` | BFF Admin API write after email OTP verify | n/a | ISO-8601 audit timestamp; admin-edit-only |
| `phoneVerifiedAt` | BFF Admin API write after phone OTP verify | n/a | ISO-8601 audit timestamp; admin-edit-only |
| `nikVerifiedAt` | reserved (future Dukcapil flow) | n/a | declared admin-edit-only; no code writes it yet |

### 6.2 Internal JWT claims (after Phase 3)

The BFF-minted internal JWT picks up the new claims:

```json
{
  "iss": "super-app-bff",
  "aud": "super-app-services",
  "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "sid": "opaque-session-id",
  "username": "andi@example.id",
  "email": "andi@example.id",
  "email_verified": true,
  "phone_number": "+6281234567890",
  "phone_number_verified": true,
  "nik": "1971010101010001",
  "roles": ["MASYARAKAT"],
  "iat": 1746788400,
  "nbf": 1746788400,
  "exp": 1746788700,
  "jti": "uuid",
  "kid": "dev-v1"
}
```

Downstream services that need to gate on verification read the claim
from the trusted Kong-injected headers (Kong's `pre-function` plugin
already decodes the payload; extend it to surface
`X-Phone-Number-Verified` if you want per-route checks, or read
`X-Roles` if you opted into the `MASYARAKAT_VERIFIED` role pattern
instead).

### 6.3 BFF Redis keyspace additions (Phase 3)

| Key | Value | TTL | Purpose |
|---|---|---|---|
| `otp:<sub>:phone` | `{code: "123456", attempts: 0, phone: "+62..."}` | 300 s | One in-flight OTP per user. Single-use via `GETDEL` on success. |
| `otpsend:<sub>` | counter | 600 s | Send rate limit (3/10min per sub). |
| `otpsend:ip:<ip>` | counter | 600 s | Send rate limit (10/10min per IP). |

Sits alongside the existing `session:`, `authstate:`, `bffcode:`,
`userSessions:` families documented in
[`auth-architecture.md`](auth-architecture.md).

---

## 7. BFF endpoint contracts (Phase 3)

Mirrors the existing patterns in `bff/src/auth/handlers/` — Zod validation
on the body, `bearerStrict` middleware, Redis-backed state, metrics
labels matching `bff/src/lib/metrics.ts`.

### 7.1 `POST /auth/phone/send-otp`

```
Authorization: Bearer <internal-jwt>
Content-Type: application/json

{ "phone": "+6281234567890" }
```

**Validation:**

- `phone` matches `^\+62\d{8,12}$`.
- Bearer's `sub` is used to scope the OTP record; the body phone is
  what's actually verified (a user can change their phone before the
  OTP arrives).

**Response — 202 Accepted:**

```json
{ "delivery": "wa", "expires_in": 300 }
```

**Rate limits:** see §4.D, table.

**Errors:** 400 invalid phone; 401 missing/expired bearer; 429 rate
limited; 503 provider unreachable (after one retry).

### 7.2 `POST /auth/phone/verify-otp`

```
Authorization: Bearer <internal-jwt>
Content-Type: application/json

{ "phone": "+6281234567890", "code": "123456" }
```

**Validation:** `code` is exactly 6 digits; constant-time compare against
the Redis record (`GETDEL` on success or final-attempt failure).

**Response — 200 OK:**

```json
{
  "verified": true,
  "access_token": "<new-internal-jwt>",
  "expires_in": 300,
  "session_id": "<unchanged>"
}
```

The new JWT carries `phone_number_verified=true` and (optionally) the
`MASYARAKAT_VERIFIED` role.

**Errors:** 400 missing/invalid fields; 401 missing/expired bearer; 410
no OTP outstanding or expired; 422 code mismatch (with `attempts_left`
in the body until 0, then 410).

---

## 8. Mobile changes (Phase 3)

Concrete files to add/touch under `mobile/lib/`, in line with the Bloc
state-management preference already established
([memory: Bloc for Flutter state mgmt]):

- `features/auth/data/bff_auth_api.dart` — add `sendPhoneOtp` and
  `verifyPhoneOtp` methods (Dio, same pattern as `refresh` / `logout`).
- `features/auth/data/bff_auth_repository.dart` — methods on the
  repository, emit a `PhoneVerificationRequired` state through
  `sessionChanges` (or a sibling stream).
- `features/auth/presentation/bloc/auth_bloc.dart` — new states
  `PhoneVerificationRequired`, `PhoneOtpSending`, `PhoneOtpSent`,
  `PhoneOtpVerifying`.
- `features/auth/presentation/screens/phone_verify_screen.dart` — the
  UI: phone field, send-OTP button, 6-digit code input, resend timer.
- `core/router/` — route guard: if the JWT lacks
  `phone_number_verified=true`, redirect to
  `/onboarding/phone-verify`.

The JWT-claim read can be done by adding `phone_number_verified` to the
profile snapshot returned by `/auth/me` (the BFF already returns
`expiresAt`; extending the JSON costs one line).

---

## 9. Threat model — what each control buys

| Threat | Mitigation in this design |
|---|---|
| Credential capture on device (keylogger, accessibility service) | Password never enters the mobile process; entered on Custom Tab origin. |
| Phishing via in-app webview spoofing the IdP | RFC 8252 prohibits embedded WebViews; Custom Tab shows the real URL bar. |
| Email enumeration on registration | Realm `bruteForceProtected` + KC's "Generic" registration error message ("Invalid input"). |
| Email-link interception (man-in-the-mailbox) | Action token TTL 5 min (realm default `actionTokenGeneratedByUserLifespan: 300`); single-use; bound to user `id`. |
| OTP brute force | 5 attempts per OTP record; `GETDEL` on exhaustion; send rate-limited. |
| SIM swap / WA hijack | Inherent to phone-based OTP. Mitigated by short window (300 s), low send rate, and *not* using phone as the only authenticator — it's an attribute verification, not a login factor. |
| Replay of a leaked internal JWT | Existing TTL ≤ 5 min + Kong's `maximum_expiration: 600` + bearer-bound `sid` (see [`auth-architecture.md`](auth-architecture.md) §C). |
| Privilege escalation by setting `phoneNumberVerified=true` from the client | Attribute write goes through the **BFF**, never the mobile app. BFF uses the `super-app-bff` service-account token; mobile has no path to the Admin API. |
| Header spoofing (`X-Phone-Number-Verified` from the client) | Kong's `pre-function` plugin strips inbound identity headers before decoding and injecting trusted ones — same pattern as `X-User-Id` today. |
| Admin-API endpoint exposure | The Admin API lives on Keycloak, reachable only from the Docker network; BFF is the only container with the service-account credentials. |

---

## 10. Reference

- [`auth-architecture.md`](auth-architecture.md) — token model, login/refresh/logout, key rotation.
- [`adding-a-service.md`](adding-a-service.md) — how downstream services read identity from Kong-injected headers (relevant once `phone_number_verified` becomes a per-route gate).
- [`pangkalpinang-realm.json`](pangkalpinang-realm.json) — the current realm export (read alongside §2).
- [`bff/src/auth/handlers/authorize.ts`](../bff/src/auth/handlers/authorize.ts) — the OAuth entry point the registration/reset CTAs reuse.
- [`mobile/lib/features/auth/data/bff_auth_repository.dart`](../mobile/lib/features/auth/data/bff_auth_repository.dart) — where the new CTAs and the phone-verify screen plug in.

---

## Appendix A — Declarative User Profile snippet

The canonical User Profile JSON lives at
[`keycloak/user-profile.json`](../keycloak/user-profile.json) — single
source of truth, intentionally not duplicated here so the file and this
doc cannot drift. Paste its full contents under Realm Settings → User
Profile (JSON editor); the click-through is documented in
[`realm-setup.md` §Step 3](./realm-setup.md#step-3--declare-phonenumber--phonenumberverified-in-user-profile--2-min).

Naming uses **camelCase** (`phoneNumber`, `phoneNumberVerified`,
`fullName`) deliberately:

- KC's built-in `phone` client scope reads `phoneNumber` /
  `phoneNumberVerified` directly — no custom protocol mapper needed for
  the phone claims.
- `fullName` replaces the built-in `firstName` / `lastName` pair so the
  hosted registration form renders one "Nama Lengkap" field. It is
  projected onto the OIDC `name` claim by the `fullName` protocol mapper
  on `super-app-bff` (configured in
  [`realm-setup.md` §Step 3b](./realm-setup.md#step-3b--add-the-fullname--name-protocol-mapper-on-super-app-bff--1-min)).
  Without that mapper the BFF reads `fullName` as `null`.
- The BFF Admin client (`bff/src/lib/keycloakAdmin.ts`) writes
  `phoneNumber` / `phoneNumberVerified=true` after a successful WA OTP,
  so the OIDC `phone` scope ships a fresh `phone_number_verified: true`
  claim on the next access_token round-trip without any extra wiring.

`phoneNumberVerified` is **admin-edit-only** so a malicious user cannot
PATCH their own profile to set it to `true`. The BFF writes it via its
service account (`super-app-bff` with `manage-users` from
`realm-management`); end users see it as read-only.

---

## Appendix B — Required Actions cheat sheet

Already enabled in the realm; the table is just a map of when each one
fires during the flows in §4.

| Required Action | When it fires | Notes |
|---|---|---|
| `VERIFY_EMAIL` | After registration if `verifyEmail=true`, or on any user whose `emailVerified=false` | Built-in magic link; needs SMTP |
| `UPDATE_PROFILE` | When a user's profile is missing required attributes (e.g. NIK) | Used to backfill existing accounts |
| `VERIFY_PROFILE` | When existing user data fails current User Profile validators | Used after adding new validators |
| `UPDATE_PASSWORD` | Triggered by admin or by `kc_action=reset-credentials` | The "Lupa password" path |
| `CONFIGURE_TOTP` | When TOTP becomes required by realm policy | Future MFA rollout |
| `webauthn-register` / `webauthn-register-passwordless` | Future passkey rollout | Already enabled but not yet bound to a flow |

---

## Appendix C — Research citations (quick links)

- RFC 8252 (OAuth 2.0 for Native Apps): https://datatracker.ietf.org/doc/html/rfc8252
- OAuth 2.1 draft: https://oauth.net/2.1/
- OIDC Core 1.0: https://openid.net/specs/openid-connect-core-1_0.html
- NIST SP 800-63C (Federation): https://pages.nist.gov/800-63-3/sp800-63c.html
- OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/
- OWASP MASVS: https://mas.owasp.org/MASVS/
- Auth0 Universal vs Embedded: https://auth0.com/docs/authenticate/login/universal-vs-embedded-login
- Keycloak Required Actions SPI: https://www.keycloak.org/docs/latest/server_development/#_required_actions
- Keycloak User Profile: https://www.keycloak.org/docs/latest/server_admin/#user-profile
- Keycloak `kc_action` parameter: https://www.keycloak.org/docs/latest/server_admin/#con-actions_server_administration_guide
