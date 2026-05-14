# Keycloak realm setup — verification flow

Click-by-click operational checklist to make the verification flow
(`/auth/email/{send,verify}-otp`, `/auth/phone/{send,verify}-otp`) work
against the Pangkal Pinang Keycloak. Everything here is admin-UI work —
no code changes.

Companion to [`registration-and-verification.md`](./registration-and-verification.md);
that doc covers *why* the flow looks the way it does. This doc covers
*what to click*.

> **Target version:** Keycloak **24.0** admin console. Wording matches
> 24's UI; on 23.x the User Profile feature still has an explicit
> "Enable" toggle (re-enable in Realm settings → User profile → "Enable
> User Profile"). On 25.x the wording is essentially identical to 24.
>
> **Realm:** `pangkalpinang`
>
> **Client used by the BFF:** `super-app-bff` (confidential,
> `serviceAccountsEnabled=true`)

---

## What this walkthrough achieves

After completing the **required** steps, this becomes true:

- The BFF's `super-app-bff` access tokens carry the OIDC `phone` scope, so
  KC ships `phone_number` and `phone_number_verified` on the access_token
  → the BFF's session profile + internal JWT pick them up automatically.
- The BFF can call `PUT /admin/realms/pangkalpinang/users/{id}` to flip
  `emailVerified=true` and merge `phoneNumber` / `phoneNumberVerified`
  attributes (using the service account behind `super-app-bff`).
- The registration form on the KC hosted page renders `phoneNumber` as
  a required field with `^\+62\d{8,12}$` validation, and `phoneNumberVerified`
  exists as an **admin-edit-only** user attribute (so users can't set it
  themselves).

The **optional** steps (SMTP, brute-force) are hardening you'll want
before production but not strictly needed for the verification flow to
work in dev.

---

## Prerequisites

- Admin access to the `pangkalpinang` realm.
- `super-app-bff` client exists, is **confidential**, and has
  `serviceAccountsEnabled=true`. (Check: Clients → `super-app-bff` →
  Settings → "Service accounts roles" tab is visible.)
- The BFF's `KC_CLIENT_ID=super-app-bff` and `KC_CLIENT_SECRET=…` are set
  in `bff/.env` and match the realm's client.

If any of the above is not true, fix it first — the rest of this doc
assumes the client is wired correctly.

---

## Required steps

### Step 1 — Add the `phone` scope to `super-app-bff` (≈ 30 s)

The OIDC `phone` scope is a Keycloak built-in. It maps the user attributes
`phoneNumber` / `phoneNumberVerified` to the `phone_number` /
`phone_number_verified` claims on the access_token. Without it, the BFF
has no upstream view of phone-verification state.

1. Sidebar → **Clients** → click `super-app-bff`.
2. Top tabs → **Client scopes**.
3. Click **Add client scope** (top-right button).
4. In the dialog, check the row for `phone`.
5. Under the **Assigned type** dropdown (or the "Add" button's chevron in
   24.x), choose **Default** — *not* "Optional". Default scopes are
   granted to every token request without the client having to ask for
   them.
6. Click **Add**.
7. Confirm: the `phone` row now appears with **Default** under "Assigned
   type" in the table.

**Verify:** in the BFF logs after the next login, the upstream id_token
or access_token's decoded payload should contain `phone_number_verified`
(boolean) even if `phone_number` is absent for users without a phone yet.

---

### Step 2 — Grant Admin API roles to the `super-app-bff` service account (≈ 1 min)

The BFF's verify-OTP handlers call `PUT /admin/realms/.../users/{id}` to
flip the verification flag. That endpoint is gated by realm-management
roles. The `super-app-bff` service account currently has none — it must
get `manage-users` (write) and `view-users` (read for the GET-then-PUT
merge).

1. Sidebar → **Clients** → click `super-app-bff`.
2. Top tabs → **Service accounts roles** (only visible because
   `serviceAccountsEnabled=true`).
3. Click **Assign role**.
4. In the dialog's top **Filter by clients** dropdown, switch to
   **Filter by clients** (or "Filter by client roles" depending on KC
   version) and find `realm-management` in the table — these are the
   realm-management client's roles.
5. Check **`view-users`** and **`manage-users`**.
6. Click **Assign**.
7. Confirm: both roles now appear in the "Service accounts roles" table.

> **Why not just `realm-admin`?** That's the umbrella role that includes
> every realm-management permission. We grant only what's needed
> (least-privilege) — the BFF doesn't need to create users, manage
> clients, or read events.

**Verify:** from the BFF, call `POST /auth/email/send-otp` with a valid
bearer, then `POST /auth/email/verify-otp` with the correct code.
Check the BFF logs for `keycloak_admin_*` failures — there shouldn't be
any. If you see `403 Forbidden`, this step wasn't completed.

---

### Step 3 — Declare `phoneNumber` / `phoneNumberVerified` in User Profile (≈ 2 min)

Two reasons this is required:

- The registration form on the hosted page needs to render `phoneNumber`
  as a required field with `^\+62\d{8,12}$` validation. Without a
  User-Profile attribute declaration, KC has no way to render the field.
- The BFF writes `phoneNumberVerified=true` via Admin API. That attribute
  must exist on the user model AND be **admin-edit-only** so a malicious
  user can't PATCH their own profile to "verified".

> **KC 24 note.** Declarative User Profile is **always enabled** in
> Keycloak 24+ — the legacy "Enable user profile" toggle has been removed.
> Just go straight to the JSON editor below. If you don't see a **User
> profile** tab under Realm settings, you're either on a pre-24 build or
> looking at the wrong realm.

1. Sidebar → **Realm settings**.
2. Top tabs → **User profile**.
3. Top tabs (still on User profile) → **JSON editor**.
4. Replace the contents with the JSON below (it's the [Appendix A][appA]
   snippet from the verification doc, unchanged). It declares `email`,
   `firstName`, `lastName`, `nik`, `phoneNumber`, and
   `phoneNumberVerified`.

   ```json
   {
     "attributes": [
       {
         "name": "username",
         "displayName": "${username}",
         "permissions": { "view": ["admin", "user"], "edit": ["admin"] }
       },
       {
         "name": "email",
         "displayName": "${email}",
         "validations": { "email": {}, "length": { "max": 255 } },
         "required": { "roles": ["user"] },
         "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
       },
       {
         "name": "firstName",
         "displayName": "${firstName}",
         "validations": {
           "length": { "max": 255 },
           "person-name-prohibited-characters": {}
         },
         "required": { "roles": ["user"] },
         "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
       },
       {
         "name": "lastName",
         "displayName": "${lastName}",
         "validations": {
           "length": { "max": 255 },
           "person-name-prohibited-characters": {}
         },
         "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
       },
       {
         "name": "nik",
         "displayName": "NIK",
         "validations": {
           "length": { "min": 16, "max": 16 },
           "pattern": {
             "pattern": "^\\d{16}$",
             "error-message": "NIK harus 16 digit angka"
           }
         },
         "required": { "roles": ["user"] },
         "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
       },
       {
         "name": "phoneNumber",
         "displayName": "Nomor WhatsApp",
         "validations": {
           "pattern": {
             "pattern": "^\\+62\\d{8,12}$",
             "error-message": "Format: +62 diikuti 8-12 digit"
           }
         },
         "required": { "roles": ["user"] },
         "permissions": { "view": ["admin", "user"], "edit": ["admin", "user"] }
       },
       {
         "name": "phoneNumberVerified",
         "displayName": "Phone Number Verified",
         "permissions": { "view": ["admin"], "edit": ["admin"] }
       }
     ],
     "groups": [
       {
         "name": "user-metadata",
         "displayHeader": "User metadata",
         "displayDescription": "Attributes, which refer to user metadata"
       }
     ]
   }
   ```

5. Click **Save**. KC validates the JSON before saving — if it rejects,
   the error message points at the offending field; fix and retry.
6. (Optional but recommended) Switch to the **Attributes** tab and
   confirm each row shows up with the right validations.

> **Why `phoneNumberVerified` is admin-edit-only.** The `permissions`
> block scopes write access to the `admin` role only. The `super-app-bff`
> service account holds `manage-users` (which is granted by Step 2) and
> therefore counts as admin for User-Profile purposes. End users see the
> attribute as read-only — they can never set it to `"true"` themselves
> via a self-service `/account` PATCH.

> **Unmanaged-attribute policy (KC 24+).** Realm settings → General has a
> separate **Unmanaged Attributes** setting. Default is **Disabled** —
> meaning *only* attributes declared above can be written. If you have
> legacy attributes flowing through (e.g. set via an older import or by
> custom code), set this to **Admin can write** so the BFF service account
> can still touch them, while end-users still cannot. Don't set it to
> **Enabled**: that defeats the lockdown on `phoneNumberVerified`.

**Verify:** open the KC hosted registration page (just visit your
auth_endpoint with the standard OAuth params and click "Daftar"). You
should see `Nomor WhatsApp` and `NIK` rendered as required fields with
their validators.

---

## Optional / recommended (production hardening)

### Step 4 — SMTP on Keycloak (≈ 2 min) — only if you want KC-hosted email features

The verification flow we built sends email via the **BFF**'s Gmail SMTP
adapter, not Keycloak's. So you can skip this for the OTP flow itself.

But Keycloak's own "Forgot password" link and the `VERIFY_EMAIL` required
action (if you ever enable `verifyEmail=true`) **do** need KC-side SMTP.
Configure it once and both your password-reset and any future hosted
verify flows work.

1. Sidebar → **Realm settings** → top tabs → **Email**.
2. Fill in:
   - **From:** the From header, e.g. `noreply@pangkalpinangkota.go.id`
   - **From display name:** `Pemkot Pangkal Pinang`
   - **Reply to:** optional
   - **Host:** SMTP server hostname (e.g. `smtp.gmail.com`)
   - **Port:** `587` for STARTTLS, `465` for implicit TLS
   - **Encryption:** **Enable StartTLS** for port 587
   - **Authentication:** **Enabled**
   - **Username / Password:** the SMTP credentials. If using Gmail, this
     is the same App Password used by the BFF's `SMTP_PASS`.
3. Click **Test connection** to send yourself a test email.
4. Click **Save**.

> Same Gmail caveat as the BFF: the regular Gmail password is rejected.
> Use an App Password from
> [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
> (2-Step Verification must be on for the account).

### Step 5 — Brute-force protection (≈ 30 s) — strongly recommended

`bruteForceProtected=false` means registration / reset endpoints can be
enumerated and stuffed without any per-IP / per-user lockout. Flip it
on:

1. Sidebar → **Realm settings** → top tabs → **Security defenses**
   → sub-tab **Brute force detection**.
2. Toggle **Enabled** to On.
3. Reasonable defaults:
   - **Permanent lockout:** Off
   - **Max login failures:** `10`
   - **Wait increment:** `60 seconds`
   - **Max wait:** `900 seconds` (15 min)
   - **Failure reset time:** `12 hours`
   - **Quick login check (ms):** `1000`
4. Click **Save**.

### Step 6 — Realm-wide `verifyEmail` (only if you decide to enable hosted-page email verify later)

We **don't** need this for the BFF-mediated OTP flow we shipped. If you
later decide to migrate email verification to the KC hosted magic link
(the §4.B "B1" shape in the design doc), flip:

1. Sidebar → **Realm settings** → top tabs → **Login**.
2. Toggle **Verify email** to On.
3. Save.

Without SMTP (Step 4) this just blocks login indefinitely — make sure
SMTP works first.

---

## Smoke test after setup

Run the full registration → verify chain end-to-end. From a clean state:

1. Open the KC hosted registration page (visit your authorization URL,
   click "Daftar"). Register a test user with a real email you can reach.
2. Complete the existing KC required actions (email link if `verifyEmail`
   is on; otherwise nothing here).
3. Log into the mobile app with the new user → land on Home → orange
   banner appears: "Akun Anda belum diverifikasi."
4. Tap banner → Verifikasi Akun → tap **Verifikasi** on the Email card →
   `Kirim Kode` runs → check inbox → enter the 6-digit code → success
   snackbar → back to hub. Email card now shows ✓ Terverifikasi.
5. Tap **Verifikasi** on the WhatsApp card → enter `+6281…` → Kirim
   Kode → check WhatsApp → enter code → success → ✓.
6. Banner disappears on Home.

**If something fails, check (in order):**

- **`401 invalid_token` from `/auth/email/send-otp`** — bearer is expired
  (5 min TTL); pull refresh.
- **`403 Forbidden` in BFF logs from `keycloakAdmin.setEmailVerified`** —
  Step 2 wasn't completed (service account missing `manage-users` /
  `view-users`).
- **`/auth/me` shows `emailVerified: false` even after a successful verify
  call** — the BFF wrote it to KC but the BFF's session-profile snapshot
  is stale. Either call `/auth/refresh` or check that the verify
  endpoint's "update session profile" branch ran (it's in
  `bff/src/auth/handlers/verifyEmailOtp.ts`).
- **`phone_number_verified` missing from internal JWT** — Step 1 wasn't
  completed (the `phone` scope isn't on the client's Default Client
  Scopes).
- **Hosted registration form has no `Nomor WhatsApp` field** — Step 3
  wasn't completed (User Profile not enabled, or JSON not saved).

---

## CLI equivalents (optional — if you prefer scripting)

If your CI / IaC pipeline manages the realm and you'd rather express
this declaratively, the same changes via `kcadm.sh`:

```bash
# Step 1: add phone as a default client scope on super-app-bff
CID=$(kcadm.sh get clients -r pangkalpinang -q clientId=super-app-bff --fields id --format csv --noquotes | tail -n1)
PSID=$(kcadm.sh get client-scopes -r pangkalpinang -q name=phone --fields id --format csv --noquotes | tail -n1)
kcadm.sh update clients/$CID/default-client-scopes/$PSID -r pangkalpinang

# Step 2: assign realm-management roles to the service account
SA_USER=$(kcadm.sh get clients/$CID/service-account-user -r pangkalpinang --fields id --format csv --noquotes | tail -n1)
RM_CID=$(kcadm.sh get clients -r pangkalpinang -q clientId=realm-management --fields id --format csv --noquotes | tail -n1)
kcadm.sh add-roles -r pangkalpinang --uusername service-account-super-app-bff \
  --cclientid realm-management --rolename manage-users --rolename view-users

# Step 3: paste the User Profile JSON (save the Appendix A JSON to user-profile.json first)
kcadm.sh update users/profile -r pangkalpinang -f user-profile.json
```

Run these against any KC where `kcadm.sh` has been authenticated:

```bash
kcadm.sh config credentials --server https://sso.pangkalpinangkota.go.id \
  --realm master --user admin
```

---

[appA]: ./registration-and-verification.md#appendix-a-declarative-user-profile-snippet
