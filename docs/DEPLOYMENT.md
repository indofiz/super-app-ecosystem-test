# Single-VPS Deployment Guide

Step-by-step recipe for putting **BFF + nginx + Kong + Redis + sample-service**
on one VPS (a single virtual machine), with real TLS via Let's Encrypt and a
public hostname like `auth.pangkalpinangkota.go.id`. Keycloak is
**external** (it already lives at `sso.pangkalpinangkota.go.id`) and is not
deployed by this guide.

Read top-to-bottom on a fresh VPS — commands are runnable in order. Every
placeholder is in `<ANGLE_BRACKETS>`; substitute before pasting.

---

## 0. What you're deploying

```
              Internet  (:80, :443)
                 │
                 ▼  iptables PREROUTING 80→8080, 443→8443
        ┌─────────────────────────────────────────┐
        │  Single VPS  (Ubuntu LTS, Docker)       │
        │                                          │
        │   nginx  host :8080 → ctr :80           │
        │         host :8443 → ctr :443           │
        │     │                                    │
        │     ├─► bff:3000      ── auth boundary  │
        │     │     │                              │
        │     │     ├─► redis:6379                │
        │     │     ├─► sso.pangkalpinangkota...  │ ──► (external Keycloak)
        │     │     ├─► api.fonnte.com            │ ──► (WhatsApp OTP)
        │     │     └─► smtp.gmail.com:587        │ ──► (Email OTP)
        │     │                                    │
        │     └─► kong:8000      ── api gateway   │
        │           │                              │
        │           └─► sample-service:3001        │
        │                                          │
        │   nginx-exporter:9113  ── metrics       │
        └─────────────────────────────────────────┘
```

Six containers from the workspace-level `docker-compose.yml`:
`nginx`, `bff`, `redis`, `kong`, `sample-service`, `nginx-exporter`.
Only **nginx** publishes host ports (`:8080`, `:8443`). Everything else is
reachable only inside the Docker network. iptables PREROUTING rules
(§2) bridge the public `80`/`443` to nginx's host mapping so users (and
Let's Encrypt) hit the standard ports.

> **Dev vs prod compose layout.** The repo has two env templates —
> `.env.dev.example` (local) and `.env.prod.example` (this guide). It
> also has a dev-only overlay `docker-compose.override.yml` that exposes
> Redis/BFF/sample-service to the host for debugging. That overlay is
> **auto-merged in dev** but **skipped in prod** because
> `.env.prod.example` sets `COMPOSE_FILE=docker-compose.yml` (Compose
> reads only the listed files when that variable is set). Net effect:
> every `docker compose ...` command in this guide works as written
> without any `-f` flag, and host ports stay locked down on the VPS.

---

## 1. Sizing & prerequisites

| Item | Minimum | Recommended |
|---|---|---|
| vCPU         | 2     | 4 |
| RAM          | 2 GB  | 4 GB |
| Disk         | 20 GB | 40 GB SSD |
| OS           | Ubuntu 22.04 / 24.04 LTS (Debian 12 works the same) | — |
| Public IPv4  | required (for TLS / DNS A-record) | — |
| Outbound 443 | required (Keycloak, Let's Encrypt, Docker Hub, Fonnte) | — |
| Outbound 587 | required (Gmail SMTP for Email OTP) | — |

You also need:

- A **DNS A record** pointing your hostname (e.g.
  `auth.pangkalpinangkota.go.id`) at the VPS public IP. The TLS step
  cannot finish without this.
- **SSH access** as a user with `sudo`.
- **Keycloak admin access** to fetch `KC_CLIENT_SECRET` and update the
  client's `Valid Redirect URIs` later.
- **Fonnte device token** (https://md.fonnte.com) if WhatsApp OTP should
  send real messages. Without it, the BFF wires a stub that logs OTPs
  and returns 202 without contacting Fonnte.
- **Gmail App Password** (https://myaccount.google.com/apppasswords) if
  Email OTP should send real mail. Same stub-vs-live pattern as Fonnte.

---

## 2. Initial server hardening (one-time)

Log in as a `sudo`-capable user (do not run the stack as root).

```bash
# Update packages and reboot if a new kernel landed.
sudo apt-get update && sudo apt-get -y upgrade
[ -f /var/run/reboot-required ] && sudo reboot
```

After reconnecting:

```bash
# Create an unprivileged deploy user; we'll run docker as this user.
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG sudo deploy

# Lock root and password SSH later via /etc/ssh/sshd_config. Out of scope
# for this guide — use your existing org SSH hardening playbook.

# Time sync (matters: clock skew breaks JWT validation and TLS handshakes).
sudo timedatectl set-timezone Asia/Jakarta
sudo systemctl enable --now systemd-timesyncd

# Swap — strongly recommended on 2 GB hosts; Node + Kong can spike under load.
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# Firewall — allow SSH, HTTP, HTTPS only. Everything else (BFF, Redis,
# Kong status API, exporter) lives inside Docker's internal network.
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose

# fail2ban for SSH brute-force defense (optional but cheap).
sudo apt-get install -y fail2ban
sudo systemctl enable --now fail2ban
```

### 2.1 Bridge public 80/443 → nginx host ports 8080/8443

The committed `docker-compose.yml` maps nginx to host ports `8080` and
`8443` (so dev machines without root don't need privileged binds).
On the VPS we want clients (and Let's Encrypt's HTTP-01 challenge) to
reach the standard ports. Two options — pick one.

**A. iptables PREROUTING (recommended — leaves `docker-compose.yml`
untouched and survives image rebuilds):**

```bash
sudo apt-get install -y iptables-persistent

sudo iptables -t nat -A PREROUTING -p tcp --dport 80  -j REDIRECT --to-port 8080
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443

# Also allow connections that hit lo (e.g. curl from the VPS itself).
sudo iptables -t nat -A OUTPUT -p tcp -o lo --dport 80  -j REDIRECT --to-port 8080
sudo iptables -t nat -A OUTPUT -p tcp -o lo --dport 443 -j REDIRECT --to-port 8443

sudo netfilter-persistent save     # persists across reboot
```

**B. Edit `docker-compose.yml` ports** (one-line change — operators who
prefer keeping iptables clean):

```yaml
# In docker-compose.yml, under services.nginx.ports:
ports:
  - "80:80"
  - "443:443"
```

Then proceed as normal. Note: this is a local edit on the VPS only — do
not commit it back, since the dev compose still expects 8080/8443.

The rest of this guide assumes option **A**. If you took option B,
substitute `localhost:8080` → `localhost` and `localhost:8443` →
`localhost` in the smoke tests.

---

## 3. Install Docker Engine + Compose plugin

The Snap version of Docker has historically caused issues with Docker
Compose v2 on Ubuntu; use the upstream Docker apt repo.

```bash
# Remove any old engines.
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# Docker upstream repo.
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Run docker without sudo for the deploy user.
sudo usermod -aG docker deploy

# Log out and back in (or `newgrp docker`) for the group change to take effect.
docker --version
docker compose version
```

Cap Docker log size to stop containers filling the disk:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
sudo systemctl restart docker
```

---

## 4. Get the code onto the VPS

Switch to the `deploy` user. Two options — pick one.

**A. Git clone** (preferred — keeps `git pull` for updates):

```bash
sudo -iu deploy
cd ~
git clone <YOUR_REPO_URL> super-app
cd super-app
```

**B. SCP** (if the repo isn't reachable from the VPS):

```bash
# From your laptop:
rsync -av --exclude node_modules --exclude '.git' \
  --exclude '*/dist' --exclude '*/build' \
  ./super-app-ecosystem-test/ deploy@<VPS_IP>:/home/deploy/super-app/
```

The deploy user's home will then contain `~/super-app/` with `bff/`, `nginx/`,
`kong/`, `services/`, `docker-compose.yml`, etc.

---

## 5. Generate the production internal-JWT keypair

The dev keypair (committed under `bff/keys/internal-jwt-dev-v1*`) **must
not** be used in production. Mint a fresh `prod-v1` pair on the VPS, never
on a laptop, and let it live only on disk inside the deploy user's home.

The key-gen script (`bff/scripts/generate-dev-keys.mjs`) only uses
Node's built-in `node:crypto` — there are no external imports, so no
`npm install` is needed. Run it via a throwaway Node container so you
don't install Node on the host:

```bash
cd ~/super-app
docker run --rm -v "$(pwd)/bff:/work" -w /work node:20-alpine \
  node scripts/generate-dev-keys.mjs prod-v1
```

The script will:

- write `bff/keys/internal-jwt-prod-v1.private.pem`
- write `bff/keys/internal-jwt-prod-v1.public.pem`
- print three values to paste into `.env`:
  - `BFF_INTERNAL_JWT_ALG=RS256`
  - `BFF_INTERNAL_JWT_ACTIVE_KID=prod-v1`
  - `BFF_INTERNAL_JWT_PRIVATE_KEY=...` (base64 of the PKCS#8 PEM)
  - `BFF_INTERNAL_JWT_PUBLIC_KEYS=[{...}]` (JSON with the base64 SPKI PEM)
- print the public PEM to paste into `kong/kong.yml`

Copy the printed values somewhere you'll paste them in §7 and §8.

Lock the private PEM down:

```bash
chmod 600 ~/super-app/bff/keys/internal-jwt-prod-v1.private.pem
```

> The `prod-` prefix in the kid is a tripwire — if a `kid=dev-*` ever
> appears in a prod log, Kong has rejected the token before logging,
> and somebody put dev material in prod. Don't change the prefix.

---

## 6. Pre-flight — DNS and Keycloak

Before touching `.env`, confirm both:

### 6.1 DNS A record

```bash
# From the VPS itself:
curl -s ifconfig.me; echo                    # the IP your A record should target
dig +short auth.pangkalpinangkota.go.id A    # should return the same IP
```

Both lines should match. If they don't, fix DNS and wait for propagation
**before** continuing — Let's Encrypt cannot validate otherwise, and you'll
spend rate-limit quota chasing it.

### 6.2 Keycloak `super-app-bff` client secret

Visit the Keycloak admin console:

1. Select the `pangkalpinang` realm.
2. **Clients → super-app-bff → Credentials** → reveal `Client secret`.
   Copy this; you'll paste it as `KC_CLIENT_SECRET` in §7.
3. **Settings → Valid Redirect URIs** — note these. After deployment
   we'll add `https://<your-hostname>/auth/callback`. Don't do it yet —
   we'll wait until TLS is on so we don't add an HTTP entry that has to
   be cleaned up.
4. Confirm that the `phone` scope is in **Client scopes** for
   `super-app-bff` (default + optional both work). Without it, the
   access_token won't carry `phone_number` / `phone_number_verified`
   claims and the BFF's OTP-verify path can't see the user's current
   verification state.

---

## 7. Configure the production `.env`

```bash
cd ~/super-app
cp .env.prod.example .env
chmod 600 .env   # nobody else on the box can read it
nano .env        # or your editor of choice
```

`.env.prod.example` already sets `COMPOSE_FILE=docker-compose.yml` —
keep that line. It makes Compose ignore `docker-compose.override.yml`
(the dev-only overlay that publishes Redis/BFF/sample-service on the
host) without you needing a `-f` flag on every command.

Fill these. **Every value below has a `<PLACEHOLDER>`** — leaving a
placeholder will make the BFF fail at startup with a Zod validation error.

```dotenv
# ---- Compose ----
COMPOSE_FILE=docker-compose.yml

# ---- nginx ----
NGINX_SERVER_NAME=auth.pangkalpinangkota.go.id
# Keep this FALSE for §9 (first boot). Flip to TRUE in §11 after certs land.
NGINX_TLS_ENABLED=false

# ---- BFF public URL — the URL users' browsers see during OAuth ----
# Must match the Keycloak Valid Redirect URI we'll add in §12.
PUBLIC_BASE_URL=https://auth.pangkalpinangkota.go.id
NODE_ENV=production
LOG_LEVEL=info

# ---- Keycloak ----
KC_ISSUER=https://sso.pangkalpinangkota.go.id/realms/pangkalpinang
KC_CLIENT_ID=super-app-bff
KC_CLIENT_SECRET=<paste from Keycloak admin (§6.2)>
# `phone` scope is required for phone-OTP verification (see §6.2 step 4).
KC_SCOPES=openid profile email phone

# ---- BFF allowlists ----
ALLOWED_APP_CLIENTS=super-app-eco
ALLOWED_APP_REDIRECT_URIS=id.go.pangkalpinangkota.smartapptest:/oauth2redirect

# ---- TTLs (seconds) — defaults are fine ----
SESSION_TTL_SECONDS=2592000
AUTHSTATE_TTL_SECONDS=600
BFFCODE_TTL_SECONDS=300

CORS_ORIGINS=

# ---- Internal JWT (paste from §5 script output) ----
BFF_INTERNAL_JWT_ALG=RS256
BFF_INTERNAL_JWT_ACTIVE_KID=prod-v1
BFF_INTERNAL_JWT_PRIVATE_KEY=<from script>
BFF_INTERNAL_JWT_PUBLIC_KEYS=<from script>
BFF_INTERNAL_JWT_TTL_SECONDS=300
BFF_INTERNAL_JWT_ISSUER=super-app-bff
BFF_INTERNAL_JWT_AUDIENCE=super-app-services

# ---- WhatsApp OTP (Fonnte) ----
# Leave FONNTE_TOKEN blank to wire the stub sender (logs OTP, returns 202
# without contacting Fonnte). Set it to send real WhatsApp messages.
FONNTE_TOKEN=<paste-fonnte-device-token-or-leave-blank>
FONNTE_BASE_URL=https://api.fonnte.com

# ---- Email OTP (Gmail SMTP) ----
# Leave SMTP_USER / SMTP_PASS blank to wire the stub sender (logs OTP,
# returns 202 without sending). SMTP_PASS must be a Gmail App Password
# (https://myaccount.google.com/apppasswords), NOT the account password.
# Spaces in the App Password are accepted — keep them as Google displays.
# Do not wrap values in quotes; Compose's .env parser treats quotes
# as literal characters.
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=<gmail-address-or-leave-blank>
SMTP_PASS=<app-password-or-leave-blank>
SMTP_FROM=Pemkot Pangkal Pinang <noreply@pangkalpinangkota.go.id>

# ---- OTP behaviour ----
OTP_TTL_SECONDS=300
OTP_MAX_ATTEMPTS=5
```

> The current `.env.prod.example` ships without the OTP env vars
> filled in — they're new and not yet templated. The block above is the
> canonical shape; paste it into your `.env` and adjust.

---

## 8. Configure `kong.yml` for the prod kid

The committed `kong/kong.yml` ships with the **dev** kid (`dev-v1`) and
its public PEM inlined. For production, the kid must be `prod-v1` and
the prod public PEM must replace the dev one — Kong does not call out
to a secret manager for `consumers.jwt_secrets`; the value is read
straight out of `kong.yml` at startup. (Earlier revisions of this guide
used a `{vault://env/...}` indirection here; that pattern fails Kong
3.x's parse-time validator on the consumer credential — see
`kong/README.md` "Why not `{vault://env/...}`?".)

### 8.1 Update `kong.yml`

```bash
cd ~/super-app
nano kong/kong.yml
```

Find the `consumers[].jwt_secrets` block (search for `dev-v1`) and
replace the entry, inlining the prod public PEM directly:

```yaml
# Before
- key: dev-v1
  algorithm: RS256
  rsa_public_key: |
    -----BEGIN PUBLIC KEY-----
    ...dev public key (committed)...
    -----END PUBLIC KEY-----

# After (prod)
- key: prod-v1
  algorithm: RS256
  rsa_public_key: |
    -----BEGIN PUBLIC KEY-----
    <paste contents of bff/keys/internal-jwt-prod-v1.public.pem>
    -----END PUBLIC KEY-----
```

The dev entry must not survive in the prod `kong.yml`. Treat the prod
`kong.yml` as a deploy-time artifact: don't commit it back to the shared
repo (it's environment-specific now).

### 8.2 Confirm no leftover PEM env vars on the Kong service

The current `docker-compose.yml` no longer sets any
`INTERNAL_JWT_PUBKEY_*` env var on the `kong:` service. If you're
upgrading from an older revision, **delete** any leftover
`INTERNAL_JWT_PUBKEY_DEV_V1: |` (or `_PROD_V1: |`) block under
`kong.environment:` — the PEM lives in `kong.yml` now, and a stale env
var only confuses operators reading the file.

Then verify the kid configuration across all sources is consistent:

```bash
node kong/scripts/audit-kid-config.mjs
# Expected: kong.yml shows `prod-v1 → (inline pem)`, BFF env has
# active=prod-v1, and no leftover dev-v1 references anywhere.
```

Fix any divergence the script flags before proceeding.

---

## 9. First boot — HTTP-only, no TLS yet

We bring the stack up over plain HTTP first so Let's Encrypt's HTTP-01
challenge can reach nginx on `:80` (which iptables redirects to the
host's `:8080`, which Docker maps into nginx's container `:80`). TLS
gets flipped on in §11.

```bash
cd ~/super-app
docker compose up -d --build
docker compose ps
```

All six containers should reach state `Up (healthy)` within ~30 seconds.
Tail logs while you wait:

```bash
docker compose logs -f --tail 50 bff
# Look for: "BFF listening on :3000"
# 503s on /readyz briefly before Redis/KC come up are normal.
# Ctrl-C when steady.
```

Smoke test from the VPS itself (HTTP only at this point):

```bash
curl -s http://localhost/nginx-health   # → {"status":"ok"}
curl -s http://localhost/healthz        # → {"status":"ok", ...}
curl -s http://localhost/readyz         # → 200 with checks: { redis: ok, keycloak: ok }
```

`localhost` here means port 80, which iptables redirects to nginx on
`:8080`. If the redirect rule from §2.1 is missing, use
`http://localhost:8080/...` instead.

From a remote machine — verify the public hostname routes here:

```bash
curl -s http://auth.pangkalpinangkota.go.id/nginx-health   # same response
```

If `/readyz` reports a `keycloak: fail`, the BFF couldn't reach
`sso.pangkalpinangkota.go.id`. Check VPS outbound DNS / firewall / proxy.

---

## 10. Issue the initial TLS certificate

We use `certbot` in HTTP-01 webroot mode. nginx is already serving
`/.well-known/acme-challenge/` (it's present in both HTTP and TLS modes —
that's why §9 had to come first).

```bash
cd ~/super-app

# Run certbot in a one-shot container that shares the certbot-webroot
# volume with nginx (so its proofs land where nginx serves them) and
# writes the issued certs into ./nginx/certs/ on the host.
docker run --rm \
  -v "$(pwd)/nginx/certs:/etc/letsencrypt" \
  -v "super-app-ecosystem-test_certbot-webroot:/var/www/certbot" \
  certbot/certbot:latest \
  certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --email <ops-email@example.com> \
    --agree-tos \
    --no-eff-email \
    -d auth.pangkalpinangkota.go.id
```

Substitute your real email and hostname. Certbot will:

1. Write a challenge file under `/var/www/certbot/.well-known/acme-challenge/`.
2. Let's Encrypt fetches it from `http://auth.pangkalpinangkota.go.id/.well-known/...`
   (port 80, then iptables → 8080 → nginx).
3. On success, certbot writes the certs under
   `nginx/certs/live/auth.pangkalpinangkota.go.id/`.

The TLS template expects three flat filenames inside `/etc/nginx/certs/`,
so symlink them up one directory:

```bash
cd ~/super-app/nginx/certs
sudo ln -sf ./live/auth.pangkalpinangkota.go.id/fullchain.pem ./fullchain.pem
sudo ln -sf ./live/auth.pangkalpinangkota.go.id/privkey.pem   ./privkey.pem
sudo ln -sf ./live/auth.pangkalpinangkota.go.id/chain.pem     ./chain.pem
ls -la                  # should show three symlinks + the live/ dir
```

> If your compose project name is different (because you renamed the
> directory or set `COMPOSE_PROJECT_NAME`), find the actual volume name
> with `docker volume ls | grep certbot-webroot` and substitute it into
> the certbot command above.

---

## 11. Flip TLS on and recreate nginx

```bash
cd ~/super-app
sed -i 's/^NGINX_TLS_ENABLED=.*/NGINX_TLS_ENABLED=true/' .env

# Recreate ONLY nginx — the BFF, Kong, etc. don't need to restart.
docker compose up -d --force-recreate --no-deps nginx
docker compose logs --tail 20 nginx | grep "15-select-tls"
# Expected: "15-select-tls: NGINX_TLS_ENABLED=true — installing TLS template"
```

Smoke test:

```bash
# HTTP should now 301 to HTTPS (except /nginx-health and ACME).
curl -sI http://auth.pangkalpinangkota.go.id/readyz | head -1
# → HTTP/1.1 301 Moved Permanently

# HTTPS should work end-to-end with a real cert (no -k).
curl -s https://auth.pangkalpinangkota.go.id/nginx-health
# → {"status":"ok"}

curl -s https://auth.pangkalpinangkota.go.id/readyz
# → 200 with all checks ok

# Cipher / protocol / OCSP staple check:
echo | openssl s_client -connect auth.pangkalpinangkota.go.id:443 \
  -servername auth.pangkalpinangkota.go.id -status 2>/dev/null \
  | grep -E 'Protocol|Cipher|OCSP Response Status'
# Expected: TLSv1.3 + TLS_AES_256_GCM_SHA384 + "OCSP Response Status: successful"
```

If OCSP shows `no response sent` the first few seconds after nginx start,
it's a one-time fetch on first hit; retry the openssl probe in ~10 seconds.

---

## 12. Tell Keycloak about the prod redirect URI

In the Keycloak admin console, `pangkalpinang` realm → **Clients →
super-app-bff → Settings**:

1. Under **Valid Redirect URIs**, add the **prod** callback (the one that
   matches `PUBLIC_BASE_URL` in this guide's `.env`):
   ```
   https://auth.pangkalpinangkota.go.id/auth/callback
   ```
   This is the only entry prod traffic uses. **Do not** add any
   `10.0.2.2:8080` / `localhost:8080` entry to make prod work — those are
   purely Android-emulator / local-dev loopbacks and have no meaning on
   the VPS.
2. If you want this same Keycloak client to also serve local development
   (Android emulator pointed at the dev `docker compose` stack), keep
   the dev callback alongside the prod one:
   ```
   http://10.0.2.2:8080/auth/callback
   ```
   (The dev stack's `.env` has `PUBLIC_BASE_URL=http://10.0.2.2:8080`, so
   that's the URL the BFF generates when running locally. Use the iOS
   simulator's `http://localhost:8080/auth/callback` here too if you
   develop on iOS.) Otherwise, leave it out — splitting dev and prod
   into separate Keycloak clients is also fine.
3. Save.

Without the prod entry, the OAuth round-trip will fail with
`invalid_redirect_uri` when a real user logs in.

---

## 13. End-to-end smoke tests

From your laptop (not the VPS):

```bash
# 1. Edge is up.
curl -sI https://auth.pangkalpinangkota.go.id/nginx-health
# → HTTP/2 200, with HSTS + X-Request-Id headers

# 2. BFF is reachable through nginx.
curl -s https://auth.pangkalpinangkota.go.id/readyz | jq .
# → { "status": "ok", "checks": { "redis": "ok", "keycloak": "ok" }, ... }

# 3. Kong is reachable through nginx, and rejects unauthenticated calls.
curl -i https://auth.pangkalpinangkota.go.id/api/profile
# → HTTP/2 401 (jwt plugin: "Unauthorized")

# 4. Wrong Host doesn't reach the routing rules.
curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "Host: evil.example" https://auth.pangkalpinangkota.go.id/anything
# → 000 (connection closed by default_server 444)
```

Then run the mobile app pointed at this URL:

```dotenv
# mobile/.env on a build machine
USE_MOCK_AUTH=false
BFF_BASE_URL=https://auth.pangkalpinangkota.go.id
ALLOW_INSECURE_CONNECTIONS=false
```

Tap **Login**. You should land on Keycloak, sign in, get redirected back
to the app via the deeplink, and see the Home screen with a decoded
internal JWT. Then tap **GET /api/profile** — it should return JSON from
`sample-service` end-to-end.

### 13.1 OTP smoke (Email + WhatsApp)

If you set `SMTP_*` and/or `FONNTE_TOKEN` in §7, exercise the OTP
endpoints against the deployed BFF:

```bash
# Send an email OTP to yourself (must be a session the BFF accepts —
# normally the mobile app triggers this; here we just check the route exists).
curl -i https://auth.pangkalpinangkota.go.id/auth/send-email-otp \
  -H 'content-type: application/json' \
  --data '{}'
# → 401 or 400 with a clear error envelope (depending on session presence)

# With stub senders (no SMTP_USER/FONNTE_TOKEN), the BFF logs OTPs to
# stdout instead — look in `docker compose logs bff` for "[otp]" lines.
```

The full flow (registration, NIK + phone, WhatsApp verify, password
reset) lives in [`docs/registration-and-verification.md`](registration-and-verification.md).

---

## 14. Day-2 operations

### Tail logs

```bash
docker compose logs -f --tail 100 nginx       # edge requests
docker compose logs -f --tail 100 bff         # auth ceremonies + OTP sends
docker compose logs -f --tail 100 kong        # JWT validation / per-route
docker compose logs -f                        # everything together
```

Logs are auto-rotated at 10 MB × 5 files per container (configured in
`/etc/docker/daemon.json` in §3). To inspect old rotations:

```bash
ls /var/lib/docker/containers/<id>/
```

### Restart a single service

```bash
docker compose restart bff                    # apply a new .env value
docker compose up -d --force-recreate bff     # same but recreates the container
```

### Apply a code update

```bash
cd ~/super-app
git pull
docker compose build
docker compose up -d                          # only recreates services whose images changed
```

For a clean rebuild ignoring layer cache:

```bash
docker compose build --no-cache
docker compose up -d --force-recreate
```

### Back up

The only stateful thing on the box is **Redis** (sessions + OTP records)
and the **TLS certs**. Both live in named volumes / bind mounts under
the project directory.

```bash
# Redis snapshot — copy out a recent RDB.
docker compose exec redis sh -c 'redis-cli SAVE && cat /data/dump.rdb' \
  > ~/backups/redis-$(date +%F).rdb

# TLS certs — already on disk under nginx/certs/. Tar them up.
tar -czf ~/backups/certs-$(date +%F).tgz -C ~/super-app nginx/certs/
```

Keep at least 7 days; consider an off-box copy (rclone to S3 / GCS).

### Renew the TLS cert

Let's Encrypt certs expire after 90 days. The webroot is shared with
nginx, so renewals require no nginx downtime — just a reload.

Set up a weekly cron under the `deploy` user:

```bash
crontab -e
# Add:
17 3 * * * cd ~/super-app && docker run --rm \
  -v "$(pwd)/nginx/certs:/etc/letsencrypt" \
  -v "super-app-ecosystem-test_certbot-webroot:/var/www/certbot" \
  certbot/certbot:latest renew --quiet \
  && docker compose exec nginx nginx -s reload
```

Certbot's `renew` is a no-op until the cert is ≤30 days from expiry, so
running it weekly is safe.

### Rotate the Fonnte token or Gmail App Password

OTP credentials live in `.env`. To rotate:

```bash
cd ~/super-app
cp .env .env.$(date +%F)            # snapshot
nano .env                            # update FONNTE_TOKEN or SMTP_PASS
docker compose up -d --force-recreate bff
docker compose logs -f --tail 30 bff   # confirm clean startup
```

A bad SMTP password makes `/auth/send-email-otp` 502; a bad Fonnte
token makes `/auth/send-phone-otp` 502. Test both after rotation.

---

## 15. Internal-JWT key rotation in prod

When you need to roll `prod-v1` → `prod-v2` (suspected leak, yearly
rotation, etc.), follow the runbook in `bff/README.md` "Key rotation
runbook" and `kong/README.md` "Key rotation (zero-downtime)". Summarized:

1. Generate the new keypair on the VPS:
   ```bash
   cd ~/super-app
   docker run --rm -v "$(pwd)/bff:/work" -w /work node:20-alpine \
     node scripts/generate-dev-keys.mjs prod-v2
   ```
2. Append a `prod-v2` entry to `kong/kong.yml`'s `consumers[].jwt_secrets`
   (leave `prod-v1` in place), with the new public PEM inlined under
   `rsa_public_key: |`. Redeploy Kong only:
   `docker compose up -d --force-recreate kong`.
3. Update `.env`: `BFF_INTERNAL_JWT_ACTIVE_KID=prod-v2`, swap the
   private key, append v2's public to `BFF_INTERNAL_JWT_PUBLIC_KEYS`;
   redeploy BFF: `docker compose up -d --force-recreate bff`.
4. Wait `BFF_INTERNAL_JWT_TTL_SECONDS + 1m` (default 6 min) for v1
   tokens to age out.
5. Remove `prod-v1` from BFF env and from `kong.yml`'s `jwt_secrets`;
   redeploy.

`node kong/scripts/audit-kid-config.mjs` before and after each step
catches the most common rotation footgun (one file out of sync).

---

## 16. Rolling back

If a deploy goes wrong, the fastest recovery path is to redeploy the
previous image / commit:

```bash
cd ~/super-app
git log --oneline | head -5                  # find the previous good commit
git checkout <SHA>
docker compose up -d --build
```

If a `.env` change is the suspect, keep the previous `.env` somewhere
sane (`cp .env .env.$(date +%F)` before edits) so you can revert with
`cp .env.YYYY-MM-DD .env && docker compose up -d --force-recreate`.

If Redis got into a bad state and you have a recent dump:

```bash
docker compose stop redis
sudo cp ~/backups/redis-YYYY-MM-DD.rdb /var/lib/docker/volumes/super-app-ecosystem-test_redis-data/_data/dump.rdb
docker compose start redis
```

---

## 17. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose up` says `dependency failed to start: kong is unhealthy` | `kong.yml` syntax error, malformed inlined PEM, or kid mismatch with the BFF | `docker compose logs kong` — usually a Lua / config-parse error. Common: a `{vault://env/...}` reference under `consumers.jwt_secrets.rsa_public_key` (validates as `invalid key` at parse time — must be inlined). Run `node kong/scripts/validate.mjs`. |
| `/readyz` reports `keycloak: fail: ... timed out` | VPS can't reach `sso.pangkalpinangkota.go.id` | Check outbound 443. Check `dig sso.pangkalpinangkota.go.id` works inside the BFF container: `docker compose exec bff wget -qO- https://sso.pangkalpinangkota.go.id/.well-known/openid-configuration`. |
| nginx serves an old config after editing the template | Compose image cache | `docker compose up -d --build --force-recreate nginx`. Phase-3 footgun — bare `up -d` reuses the existing image. |
| Mobile login → "invalid_redirect_uri" from Keycloak | Forgot §12 — Keycloak doesn't have `https://<host>/auth/callback` in Valid Redirect URIs | Add it; no code change needed. |
| 401 on `/api/profile` with a known-good bearer | Kid mismatch — Kong doesn't have the public key for the kid in the token | `node kong/scripts/audit-kid-config.mjs` will tell you which file is out of sync. |
| Cert renewal fails with `no valid IP address for ...` | DNS A record changed or hostname doesn't resolve from outside | Verify with `dig +short <hostname>` from a third-party host. |
| OCSP stapling shows `no response sent` indefinitely | nginx can't reach the issuer's OCSP responder (DNS or egress firewall) | Confirm DNS resolves inside the nginx container; check egress firewall doesn't block UDP/53 or TCP/80 to OCSP responders. |
| Public `https://auth.pangkalpinangkota.go.id` times out but `https://<vps-ip>:8443` works | iptables PREROUTING rule from §2.1 missing or not persisted | `sudo iptables -t nat -L PREROUTING -n` should show both 80→8080 and 443→8443. Re-add and `sudo netfilter-persistent save`. |
| Let's Encrypt HTTP-01 fails with `Timeout during connect` | Port 80 not reaching nginx — usually iptables rule missing | Check `curl -v http://auth.pangkalpinangkota.go.id/.well-known/acme-challenge/test` from a third-party host. Should return 404 from nginx, not time out. |
| `/auth/send-email-otp` 502 | Wrong Gmail App Password, account 2FA disabled, or Gmail blocked the IP | Check `docker compose logs bff` for the nodemailer error. Regenerate App Password at `myaccount.google.com/apppasswords`; ensure 2-Step Verification is on. |
| `/auth/send-phone-otp` 502 | Fonnte session disconnected, token revoked, or out of credits | Visit `md.fonnte.com` — re-pair the WhatsApp number if the session dropped. |
| OTP arrives by neither WA nor email in dev | `FONNTE_TOKEN` / `SMTP_USER` blank → stub sender writes to stdout | Tail `docker compose logs bff` for `[otp]` log lines; that IS the OTP in stub mode. Set the real credentials for live delivery. |
| Stack OOMs intermittently on a 2 GB host | Node + Kong + Redis tipping over | Add swap if not yet done (§2). Consider a 4 GB host. |

---

## 18. What this guide does **not** cover

- **Keycloak hosting / hardening.** Keycloak is external to this stack
  and was deployed separately. If you're standing up Keycloak too, that's
  a parallel runbook — see [`docs/realm-setup.md`](realm-setup.md) for
  the realm/client/user-attribute configuration the BFF expects.
- **Off-VPS secret management.** `.env` on disk with `chmod 600` is the
  pragmatic answer for a single-VPS deployment in a city government
  context. Production-grade alternatives (HashiCorp Vault, AWS Secrets
  Manager, GCP Secret Manager, sealed-secrets in k8s) require migrating
  off compose.
- **Database for the sample-service.** The reference microservice has no
  database; real services need their own persistence story (Postgres /
  MariaDB / etc.) added as additional compose services. See
  [`docs/adding-a-service.md`](adding-a-service.md).
- **Production-grade OTP transports.** Fonnte is unofficial and Gmail
  SMTP caps at ~500 sends/day. Replace with Meta WhatsApp Cloud API and
  a real SMTP relay (Workspace SMTP, AWS SES, SendGrid, Mailgun) before
  any significant launch — both adapters in `bff/src/lib/waOtp.ts` and
  `bff/src/lib/emailOtp.ts` are single files to swap.
- **Multi-VPS / HA.** Single-VPS deployments have a single point of
  failure. The architecture supports HA (BFF replicas, Redis cluster /
  Sentinel, multiple Kong nodes), but that's a different deployment
  shape.
- **Cloud-LB fronting / CDN / WAF.** Cloudflare or a cloud LB in front
  of this VPS would change `set_real_ip_from` (see `nginx/AUDIT.md` §S-5)
  and the BFF's `trust proxy` setting. Document the LB CIDR ranges before
  enabling, and bump `app.set('trust proxy', N)` in `bff/src/app.ts` to
  the number of trusted hops.
- **Application-level monitoring / alerting.** Prometheus metrics are
  exposed by nginx-exporter (`:9113` inside the docker network), Kong
  (`:8100/metrics` inside), and BFF (`/metrics` proxied through nginx);
  scraping and alerting is downstream of this guide. See
  `nginx/AUDIT.md` §A-2.

---

## Appendix A — DNS records

| Type | Host | Value |
|---|---|---|
| A    | `auth.pangkalpinangkota.go.id` | `<VPS_PUBLIC_IPV4>` |
| AAAA | `auth.pangkalpinangkota.go.id` | (omit unless the VPS has IPv6) |
| CAA  | `auth.pangkalpinangkota.go.id` | `0 issue "letsencrypt.org"` (optional but recommended) |

## Appendix B — Container port matrix

| Container | Internal ports | Host port mapping (committed compose) | Reachable from public internet |
|---|---|---|---|
| nginx          | 80, 443, 8081 | `8080:80`, `8443:443` (+ iptables 80→8080, 443→8443) | yes (80, 443 via redirect) |
| bff            | 3000          | none                                                 | no |
| redis          | 6379          | none                                                 | no |
| kong           | 8000, 8100    | none                                                 | no |
| sample-service | 3001          | none                                                 | no |
| nginx-exporter | 9113          | none                                                 | no |

Everything except nginx is internal-network-only by design — that's the
trust boundary the architecture relies on. The 8080/8443 host ports
exist because the committed `docker-compose.yml` chooses them for dev
ergonomics (no root needed); §2.1's iptables rules bridge them to the
public 80/443 on the VPS.

## Appendix C — External egress required

The BFF needs outbound network access to:

| Host                                    | Port | Purpose                              |
|---|---|---|
| `sso.pangkalpinangkota.go.id`           | 443  | Keycloak OIDC + Admin REST           |
| `api.fonnte.com`                        | 443  | WhatsApp OTP delivery                |
| `smtp.gmail.com`                        | 587  | Email OTP delivery (STARTTLS)        |
| Let's Encrypt OCSP / ACME endpoints     | 80/443 | TLS cert issuance + OCSP stapling |
| Docker Hub / GHCR                        | 443  | Image pulls during `docker compose build` |

Lock egress further only if you've audited all five above resolve and
work from the VPS — silent failures here look like login or OTP outages.
