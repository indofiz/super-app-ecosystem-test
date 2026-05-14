# Menambahkan Service Baru di Balik Kong

Panduan langkah demi langkah untuk developer backend. Mengantar Anda dari
"saya ingin menambahkan microservice baru" sampai "service sudah
ter-deploy dan dapat dijangkau di `/api/<prefix-anda>`", baik untuk
service **ber-autentikasi** (kasus umum) maupun service **publik**
(jarang; tanpa bearer).

Jika Anda hanya perlu referensi cepat, lompat ke **[Checklist](#checklist)**
di bagian bawah. Jika tidak, baca dari atas ke bawah.

> **Gambaran besar.** Mobile dan klien lain memanggil nginx di `/api/*`.
> nginx meneruskan semua `/api/` ke Kong. Kong mencocokkan rute
> berdasarkan path, menjalankan plugin fase-access untuk rute tersebut,
> lalu meneruskan ke container upstream. Service Anda tidak pernah
> membuka host port — hanya Kong yang berbicara dengannya.
>
> Lihat [`diagrams/architecture-overview.svg`](diagrams/architecture-overview.svg)
> untuk gambaran lengkap dan
> [`diagrams/flow-data-plane-request.svg`](diagrams/flow-data-plane-request.svg)
> untuk alur satu request.

---

## 1. Tentukan dulu: apakah service ini perlu auth?

| Jika… | Maka Anda butuh… | Contoh kerja |
|---|---|---|
| Endpoint membaca atau menulis data spesifik user | **Service ber-autentikasi** (Path A) | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| Endpoint memerlukan role Keycloak | **Service ber-autentikasi** + role check per-route (Path A + §6) | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| Endpoint khusus admin | **Service ber-autentikasi** + role check | [§9.1 `e-ktp-service`](#91-e-ktp-service-path-a--role-check) |
| Endpoint menerima upload file lebih besar dari default 256 KB | **Service ber-autentikasi** + `request-size-limiting` per-service | [§9.2 `e-perizinan-service`](#92-e-perizinan-service-path-a--upload-pdf) |
| Endpoint adalah katalog publik, halaman status, atau open data | **Service publik** (Path B) | [§9.3 `status-service`](#93-status-service-path-b--proxy-cache) |
| Endpoint menerima callback dari pihak ketiga (webhook) yang punya **signature/secret-nya sendiri** yang akan Anda verifikasi di service | **Service publik** (Path B) | [§9.4 `wa-webhook-service`](#94-wa-webhook-service-path-b--hmac) |
| Service-nya sendiri berjalan di **VPS lain**, host LAN privat, atau shared hosting (WHM/cPanel — biasanya PHP) | **Upstream di luar VPS** (Path C) — kombinasikan dengan Path A atau B untuk rantai auth | [§9.5](#95-legacy-citizen-db-path-c1a-lan-privat) / [§9.6](#96-e-sampah-service-path-c1b--https-publik) / [§9.7](#97-citizen-api-path-c1c-cpanelwhm-php) |

**Default ke Path A.** Stack ini didesain agar gateway yang menegakkan
auth dan service downstream-nya "bodoh". Memilih Path B berarti
melepaskan rate limit per-user dan injeksi identitas Kong — lakukan ini
hanya jika memang tidak ada user untuk diidentifikasi. Path C ortogonal —
yaitu *di mana* upstream berada, bukan *apakah* perlu auth; Anda tetap
memilih A atau B untuk plugin chain.

Satu service dapat menampung kedua jenis rute; cukup pisahkan path
prefix-nya (mis. `/api/ktp` ber-autentikasi, `/api/ktp/public` tidak).

---

## 2. Konvensi penamaan

| Hal | Konvensi | Contoh |
|---|---|---|
| Direktori service | `services/<name>-service/` | `services/ktp-service/` |
| Nama container | `super-app-<name>-service` | `super-app-ktp-service` |
| Port internal | Pilih port 3xxx yang bebas; dokumentasikan | `3002` |
| Path prefix (Kong) | `/api/<name>` (auth) atau `/api/public/<name>` (publik) | `/api/ktp` |
| Nama service Kong | `<name>-service` (sama dengan direktori) | `ktp-service` |

Konvensi `/api/public/` untuk rute tanpa auth bersifat **krusial** untuk
code review — `grep -r '/api/public' kong/kong.yml` adalah cara reviewer
memastikan rute mana yang sengaja melewati auth.

---

## 3. Path A — Service ber-autentikasi (kasus umum)

Kita akan menambahkan `ktp-service` (pencarian KTP) pada port `3002`,
dapat dijangkau di `/api/ktp`.

### 3.1 Bootstrap kode service

Salin skeleton `sample-service`. Skeleton tersebut sudah memiliki bentuk
yang tepat (tanpa kode auth, membaca identitas dari trusted headers,
mengembalikan request id):

```bash
cp -r services/sample-service services/ktp-service
cd services/ktp-service
```

Lalu:

- Rename package: edit `package.json` — set `"name": "ktp-service"`.
- Ubah port yang didengarkan — edit `src/index.ts`:
  ```ts
  const PORT = Number(process.env['PORT'] ?? 3002);
  ```
- Update baris `EXPOSE` di `Dockerfile` agar cocok (`EXPOSE 3002`).
- Tulis handler bisnis Anda (lookup DB, logika bisnis). **Jangan
  tambahkan library auth.** Kong adalah batas auth.

### 3.2 Baca identitas dari trusted headers — jangan dari JWT

Plugin `pre-function` Kong memverifikasi JWT, lalu menetapkan ulang
header-header ini dari klaim **yang sudah terverifikasi**, dan strip
header `Authorization` sebelum forward. Pola referensi (sudah ada di
`sample-service/src/index.ts`):

```ts
import express, { type Request } from 'express';

const identityFromHeaders = (req: Request) => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',')
               .map((r) => r.trim())
               .filter(Boolean),
});

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'ktp-service' });
});

app.get('/lookup/:nik', (req, res) => {
  const { userId, roles } = identityFromHeaders(req);
  if (!userId) {
    // Seharusnya tidak terjadi — Kong hanya forward jika jwt + pre-function lolos.
    // 401 di sini untuk kasus "Kong entah bagaimana ter-bypass"; perlakukan sebagai bug.
    return res.status(401).json({ error: 'unauthenticated' });
  }
  // …lakukan lookup sebenarnya…
  res.json({ nik: req.params.nik, requestedBy: userId, roles });
});

app.listen(Number(process.env['PORT'] ?? 3002));
```

**Hal yang tidak boleh dilakukan:**

- Jangan baca `req.headers.authorization`. Kong strip header itu sebelum forward
  ([diagram: kong-identity-injection.svg](diagrams/kong-identity-injection.svg)).
- Jangan decode JWT sendiri. Plugin sudah melakukannya.
- Jangan percayai `X-User-Id` jika Anda bypass Kong (mis. sidecar yang
  langsung hit service). Service hanya boleh dijangkau melalui Kong.

### 3.3 Daftarkan service ke Kong

Edit `kong/kong.yml`. Di bawah array `services:` top-level, append blok
baru. Plugin chain-nya **sama** dengan `sample-service` — itu memang
intinya. Jangan hilangkan satu plugin pun.

```yaml
services:
  # ─── blok sample-service yang sudah ada tetap apa adanya ───
  - name: sample-service
    # ...

  # ─── service baru ───
  - name: ktp-service
    url: http://ktp-service:3002         # DNS docker = container_name

    routes:
      - name: ktp-lookup
        paths:
          - /api/ktp
        strip_path: true
        # GET /api/ktp/lookup/123  →  upstream melihat GET /lookup/123

    plugins:
      # Mint dan reuse id per-request. Sama dengan sample-service.
      - name: correlation-id
        config:
          header_name: X-Request-Id
          generator: uuid
          echo_downstream: true

      # Verifikasi JWT internal RS256 yang di-mint BFF. JANGAN PERNAH
      # hilangkan ini di service ber-autentikasi. Ceiling maximum_expiration
      # membatasi TTL maksimum 10 menit tanpa peduli apa yang BFF tanda-tangani (AUDIT S-4).
      - name: jwt
        config:
          key_claim_name: kid
          claims_to_verify: [exp, nbf]
          maximum_expiration: 600
          header_names: [authorization]       # carrier dikunci (AUDIT S-2)
          cookie_names: []
          uri_param_names: []

      # Penegakan iss/aud + injeksi identitas + strip Authorization.
      # SALIN PERSIS dari blok sample-service. Body Lua harus cocok
      # dengan kong/lua/identity_inject.lua — script check-lua-sync
      # menegakkan ini untuk salinan sample-service; jika Anda mengubahnya
      # untuk ktp-service, Anda mem-fork kontraknya.
      - name: pre-function
        config:
          access:
            - |
              -- Lua yang sama dengan sample-service — paste dari kong.yml
              -- (atau ekstrak — lihat §5 jika butuh auth per-route)

      # Rate limit per-user. Di-key oleh X-User-Id yang baru saja Kong inject.
      # 600/menit adalah default proyek; tune per service jika perlu.
      - name: rate-limiting
        config:
          minute: 600
          policy: local
          fault_tolerant: true
          limit_by: header
          header_name: X-User-Id
```

**Penting:** Anda **tidak** menambahkan consumer baru. Single consumer
`super-app-bff` yang sudah dideklarasikan di `kong.yml` merepresentasikan
issuer (BFF), bukan user. Kong melakukan lookup `jwt_secrets` consumer
berdasarkan klaim `kid` — itu lookup yang sama untuk setiap service.

### 3.4 Hubungkan container

Edit `docker-compose.yml` level workspace:

```yaml
services:
  # ─── service yang sudah ada tetap apa adanya ───

  ktp-service:
    build: ./services/ktp-service
    container_name: super-app-ktp-service
    environment:
      NODE_ENV: production
      PORT: 3002
    # Tidak ada host port mapping — hanya Kong yang berbicara dengannya.
    # Opsional: tambahkan healthcheck jika Anda ingin depends_on Kong
    # menunggu `service_healthy` alih-alih `service_started`.
    # healthcheck:
    #   test: ["CMD", "wget", "-qO-", "http://localhost:3002/health"]
    #   interval: 10s
    #   timeout: 3s
    #   retries: 5
```

Lalu, buat Kong menunggu service ini saat startup. Edit `depends_on`
pada blok `kong:` agar include service baru:

```yaml
kong:
  # ...config yang sudah ada...
  depends_on:
    sample-service:
      condition: service_started
    ktp-service:                 # ← tambahkan ini
      condition: service_started
```

Lihat [`diagrams/compose-startup-order.svg`](diagrams/compose-startup-order.svg)
untuk DAG dependency lengkap.

### 3.5 Validasi sebelum boot

Tiga script menangkap kesalahan edit yang umum:

```bash
# Lint kong.yml terhadap schema Kong 3.8 sebenarnya (butuh Docker):
node kong/scripts/validate.mjs

# Pastikan mirror Lua utuh (body pre-function di kong.yml
# harus cocok persis dengan kong/lua/identity_inject.lua):
node kong/scripts/check-lua-sync.mjs

# Pastikan BFF + Kong + docker-compose sepakat soal kid yang aktif:
node kong/scripts/audit-kid-config.mjs
```

Ketiganya harus print OK. Jika ada yang gagal, perbaiki dulu sebelum lanjut.

### 3.6 Build dan smoke-test

```bash
docker compose up -d --build ktp-service kong
# Kong reload declarative config-nya saat container start, jadi Kong
# juga perlu di-rebuild/restart. --build untuk service baru.

# Tanpa bearer → 401 dari Kong (plugin jwt, tidak ada kredensial).
curl -i http://localhost:8080/api/ktp/lookup/123

# Mint token uji dari dev keypair dan panggil end-to-end.
TOKEN=$(node --input-type=module -e "
import { SignJWT, importPKCS8 } from 'jose';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
const pem = readFileSync('bff/keys/internal-jwt-dev-v1.private.pem', 'utf8');
const key = await importPKCS8(pem, 'RS256');
const t = await new SignJWT({ sid: 'sid-test', roles: ['citizen'], kid: 'dev-v1' })
  .setProtectedHeader({ alg: 'RS256', typ: 'JWT', kid: 'dev-v1' })
  .setIssuer('super-app-bff').setAudience('super-app-services').setSubject('user-test')
  .setIssuedAt().setNotBefore('0s').setExpirationTime('5m').setJti(randomUUID()).sign(key);
console.log(t);
")

curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/ktp/lookup/123 | jq .
# Diharapkan: 200 dengan { nik, requestedBy: "user-test", roles: ["citizen"] }
```

Konfirmasi pada response bahwa:

- `requestedBy` cocok dengan `sub` token (bukti bahwa Kong meng-inject
  `X-User-Id` dari klaim terverifikasi, bukan dari header yang dipasok caller).
- `roles` cocok dengan isi JWT (bukti injeksi `X-Roles`).
- Header `Authorization` TIDAK di-echo balik. Tambahkan debug log di
  service untuk memastikan ia melihat `req.headers.authorization === undefined`.

### 3.7 Hubungkan mobile (opsional)

Jika app mobile harus memanggil endpoint baru, path-nya melalui instance
`ApiClient` (Dio) yang sudah ada — tidak perlu kode auth di feature module:

```dart
// mobile/lib/features/ktp/data/ktp_api.dart
class KtpApi {
  KtpApi({required this.dio});
  final Dio dio;

  Future<Map<String, dynamic>> lookup(String nik) async {
    final res = await dio.get<Map<String, dynamic>>('/api/ktp/lookup/$nik');
    return res.data!;
  }
}
```

`_AuthInterceptor` melampirkan bearer; `_RefreshInterceptor` menangani
401 secara transparan. Lihat
[`diagrams/mobile-architecture.svg`](diagrams/mobile-architecture.svg).

---

## 4. Path B — Service publik (tanpa auth)

Gunakan ini hanya jika endpoint memang **secara alami** anonim: halaman
status layanan kota, feed gangguan publik, penerima webhook pihak ketiga.
**Tidak ada identitas per-user, jadi tidak ada rate limit per-user pula —
lindungi dengan rate-limiting IP dan terima keterbatasan ini.**

Kita akan menambahkan `status-service` pada port `3003`, dapat dijangkau
di `/api/public/status`.

### 4.1 Bootstrap service

Sama dengan 3.1 — salin `sample-service` sebagai starting point. Hapus
helper identity-from-headers jika tidak butuh. Service publik tidak boleh
mengasumsikan header `X-*` apapun ada.

### 4.2 Daftarkan service ke Kong — eksplisit no-auth

```yaml
services:
  - name: status-service
    url: http://status-service:3003

    routes:
      - name: status-public
        paths:
          - /api/public/status        # ← prefix /api/public/ adalah konvensi
        strip_path: true

    plugins:
      # Tetap mint / propagate request id — service publik juga butuh logging.
      - name: correlation-id
        config:
          header_name: X-Request-Id
          generator: uuid
          echo_downstream: true

      # TIDAK ADA plugin `jwt`.
      # TIDAK ADA plugin `pre-function` (tidak ada yang perlu di-inject).

      # Rate limit berbasis IP — tidak ada X-User-Id untuk dijadikan key.
      # Pilih angka yang sesuai profil endpoint publik; ini yang
      # melindungi Anda dari seseorang yang nge-burst path publik.
      - name: rate-limiting
        config:
          minute: 120                # tune per endpoint
          policy: local
          fault_tolerant: true
          limit_by: ip
```

**Hal yang perlu dipertimbangkan untuk service publik:**

| Kekhawatiran | Mitigasi |
|---|---|
| Cache poisoning lewat header | Service harus menolak input dari `X-User-Id` (perlakukan sebagai untrusted; abaikan). |
| Performa hot-path | Endpoint publik akan di-scrape bot; pakai header HTTP caching dan tune `minute:` ketat. |
| Eksposur data | Seluruh internet bisa membaca ini. Audit apa yang Anda kembalikan. |
| Autentisitas webhook | Jika menerima webhook pihak ketiga, verifikasi signature pihak ketiga **di dalam service Anda** (mis. HMAC body request dengan shared secret). Kong tidak membantu di sini. |
| Logging abuse | Pastikan `X-Request-Id` muncul di log service Anda meski tanpa user id. |

### 4.3 Container + smoke test

Wiring container identik dengan §3.4 — hanya beda port dan nama.

Smoke test:

```bash
docker compose up -d --build status-service kong

curl -s http://localhost:8080/api/public/status | jq .
# Diharapkan: 200 dengan payload publik apapun. Tidak butuh bearer.

# Konfirmasi rate limit aktif (berbasis IP):
for i in {1..200}; do curl -so /dev/null -w "%{http_code} " http://localhost:8080/api/public/status; done
# Di suatu titik Anda harus melihat 429 Too Many Requests.
```

---

## 5. Path C — Upstream remote / di luar VPS

Kontrak auth tidak berubah dari Path A. Yang berubah adalah jaringan,
TLS, header Host, dan bagaimana mencegah seseorang menabrak backend
langsung tanpa lewat Kong.

Tiga sub-case — pilih yang cocok dengan upstream Anda:

| Sub-case | Contoh URL upstream | Situasi tipikal | Contoh kerja |
|---|---|---|---|
| **C.1a LAN privat** | `http://10.0.5.20:3001` | VPS lain di VLAN provider yang sama | [§9.5 `legacy-citizen-db`](#95-legacy-citizen-db-path-c1a-lan-privat) |
| **C.1b HTTPS publik** | `https://sampah.pangkalpinangkota.go.id` | VPS lain dengan cert Let's Encrypt sendiri | [§9.6 `e-sampah-service`](#96-e-sampah-service-path-c1b--https-publik) |
| **C.1c WHM / cPanel PHP** | `https://services.pangkalpinangkota.go.id/citizen-api` | Shared hosting, Apache + PHP, AutoSSL | [§9.7 `citizen-api`](#97-citizen-api-path-c1c-cpanelwhm-php) |

Kita akan pakai contoh C.1c (`citizen-api`, service PHP di cPanel) karena
menyentuh semua kekhawatiran. C.1a dan C.1b adalah subset ketat — pakai
bagian TLS atau bagian virtual-host sesuai kebutuhan.

> **Path C mengharuskan Anda mengombinasikan dengan Path A atau B.**
> Sebagian besar waktu Anda akan butuh plugin chain Path A (jwt +
> pre-function + rate-limit per-user). Yang berbeda hanyalah `url:`,
> beberapa knob TLS / timeout, dan **lockdown direct-access** di §5.3.

### 5.1 Daftarkan service ke Kong

```yaml
services:
  - name: citizen-api
    url: https://services.pangkalpinangkota.go.id/citizen-api  # C.1c

    # HTTPS ke upstream — verifikasi cert terhadap CA sistem.
    # Default true; ditulis eksplisit demi kejelasan. Set false hanya
    # untuk CA internal yang tidak bisa Anda import, dan jangan di produksi.
    tls_verify: true

    # Ketatkan timeout. Lewat internet terbuka, default 60s Kong
    # terlalu longgar — budget mendekati p99 yang user rasakan.
    connect_timeout: 5000
    write_timeout: 10000
    read_timeout: 15000

    routes:
      - name: citizen
        paths: [/api/citizen]
        strip_path: true
        # KRITIS untuk backend virtual-hosted (cPanel, vhost nginx):
        # preserve_host: false mengirim `Host: services.pangkalpinangkota.go.id`
        # — host URL upstream — agar cPanel memilih site yang benar.
        # Set true akan mengirim edge host (api.pangkalpinangkota.go.id)
        # dan cPanel akan route ke vhost default (atau 404).
        preserve_host: false

    plugins:
      # Chain yang sama dengan Path A — salin persis dari sample-service.
      # Disingkat di sini; expand dari §3.3 untuk komentar inline.
      - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }
      - name: jwt
        config:
          key_claim_name: kid
          claims_to_verify: [exp, nbf]
          maximum_expiration: 600
          header_names: [authorization]
          cookie_names: []
          uri_param_names: []
      - name: pre-function
        config:
          access:
            - |
              -- Lua IDENTIK dengan sample-service. Jangan fork.
              -- (paste body penuh dari kong/kong.yml di sini)

      # BARU untuk Path C — inject shared secret yang akan diverifikasi backend.
      # Lihat §5.3 untuk alasan dan kode backend yang cocok.
      - name: request-transformer
        config:
          add:
            headers:
              - "X-Gateway-Secret:{vault://env/citizen-api-gateway-secret}"

      - name: rate-limiting
        config:
          minute: 600
          policy: local
          fault_tolerant: true
          limit_by: header
          header_name: X-User-Id

    # Passive health checks — Kong menarik upstream keluar dari rotation
    # setelah beberapa kegagalan berurutan alih-alih menunggu read_timeout
    # penuh setiap request. Active check butuh Admin API (off di stack ini);
    # passive sudah cukup.
    healthchecks:
      passive:
        healthy:
          successes: 5
        unhealthy:
          tcp_failures: 2
          http_failures: 5
          timeouts: 3
```

Untuk **C.1a (LAN privat)**: blok sama, tapi `url: http://10.0.5.20:3001`
dan hapus baris `tls_verify`. Lockdown shared-secret (§5.3) tetap dianjurkan.

Untuk **C.1b (HTTPS publik, tanpa kekhawatiran virtual-host)**: blok sama
dengan C.1c. `preserve_host: false` tetap benar.

Lalu set secret di `docker-compose.yml` di bawah env service `kong:`:

```yaml
kong:
  environment:
    # ...env vars yang sudah ada...
    CITIZEN_API_GATEWAY_SECRET: ${CITIZEN_API_GATEWAY_SECRET}
```

…dan nilai sebenarnya di workspace `.env` Anda (jangan pernah commit):

```bash
# .env
CITIZEN_API_GATEWAY_SECRET=<random panjang; rotate per kuartal>
```

Referensi `{vault://env/citizen-api-gateway-secret}` di `kong.yml`
me-resolve env var saat Kong startup, sehingga secret tidak pernah berada
di file yang di-commit.

### 5.2 Membaca identitas di backend (contoh PHP)

Model yang sama seperti Path A — baca `X-User-Id` / `X-Roles` /
`X-Session-Id`, jangan `Authorization` (Kong strip). Padanan PHP dari
`services/sample-service/src/index.ts`:

```php
<?php
// citizen-api/lookup.php
declare(strict_types=1);
require __DIR__ . '/_gateway_guard.php';   // §5.3 — verifikasi X-Gateway-Secret

$userId    = $_SERVER['HTTP_X_USER_ID']    ?? null;
$sessionId = $_SERVER['HTTP_X_SESSION_ID'] ?? null;
$rolesCsv  = $_SERVER['HTTP_X_ROLES']      ?? '';
$roles     = array_values(array_filter(array_map('trim', explode(',', $rolesCsv))));
$requestId = $_SERVER['HTTP_X_REQUEST_ID'] ?? null;

if ($userId === null) {
    http_response_code(401);
    echo json_encode(['error' => 'no identity from gateway']);
    exit;
}

// Log dengan X-Request-Id agar baris log berkorelasi dengan nginx / Kong / BFF.
error_log(sprintf('[%s] citizen-api lookup user=%s roles=%s',
    $requestId ?? '-', $userId, implode(',', $roles)));

// ...logika bisnis Anda...
header('Content-Type: application/json');
echo json_encode(['user' => $userId, 'roles' => $roles]);
```

**Hal yang TIDAK boleh dilakukan di sisi PHP** (larangan yang sama
seperti Path A, layak diulang karena shared hosting PHP cenderung
mengundang ini):

- Jangan baca `$_SERVER['HTTP_AUTHORIZATION']`. Kong strip.
- Jangan decode JWT apapun — Kong sudah memverifikasinya.
- Jangan mulai PHP session berdasarkan `X-User-Id`. Tidak ada browser
  session di flow ini; mobile adalah klien token-bearer.
- Jangan simpan `X-User-Id` di tempat persistent tanpa juga menyimpan
  `X-Request-Id` untuk korelasi audit.

### 5.3 Kunci akses langsung ke backend

URL backend yang bocor atau bisa ditebak sekarang adalah vektor
auth-bypass — backend mempercayai `X-User-Id`, dan siapapun yang
mencapainya secara langsung dapat memalsukan header tersebut. Pilih
satu pertahanan (atau keduanya):

**Pattern 1 — IP allowlist (paling murah, rusak jika IP Kong berpindah).**

Di cPanel: WHM → Security Center → Host Access Control → service `httpd`,
allow hanya IP egress VPS Kong, deny all.

Atau per-site lewat `.htaccess`:

```apache
# /home/<user>/public_html/citizen-api/.htaccess
<RequireAll>
  Require ip <KONG_VPS_PUBLIC_IP>
</RequireAll>
```

**Pattern 2 — Header shared secret (bertahan terhadap perubahan IP).**
Kong meng-inject `X-Gateway-Secret: <value>` (dikonfigurasi di §5.1);
backend memverifikasinya di setiap request:

```php
<?php
// citizen-api/_gateway_guard.php
declare(strict_types=1);

$expected  = getenv('GATEWAY_SECRET') ?: '';
$presented = $_SERVER['HTTP_X_GATEWAY_SECRET'] ?? '';

if ($expected === '' || $presented === '' || !hash_equals($expected, $presented)) {
    http_response_code(401);
    exit('not via gateway');
}
```

Set `GATEWAY_SECRET` di environment cPanel (tempat yang benar bervariasi
per host — `SetEnv` di `.htaccess`, file env per-akun, atau UI panel
hosting). Cocokkan dengan nilai yang Kong inject.

`hash_equals` (bukan `==`) wajib — perbandingan string biasa akan
membocorkan secret lewat timing.

**Direkomendasikan:** keduanya. Pattern 1 adalah pertahanan statis;
Pattern 2 menangkap saat Pattern 1 rusak (perubahan IP, kebocoran
routing, NAT egress baru). Rotate secret per kuartal — overlap dua
nilai valid selama deploy window dengan cara yang sama seperti meng-overlap
dua kid saat rotasi JWT.

### 5.4 Validasi + smoke test

```bash
node kong/scripts/validate.mjs           # schema-check yaml baru
docker compose up -d --force-recreate kong

# 1. Tanpa bearer → Kong 401.
curl -i http://localhost:8080/api/citizen/lookup.php

# 2. Dengan bearer → di-route ke backend, identitas dari klaim.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/citizen/lookup.php | jq .
# Diharapkan: 200 dengan { user: "<sub dari token>", roles: [...] }

# 3. KRITIS — coba mencapai backend LANGSUNG:
curl -i -H "X-User-Id: admin" -H "X-Roles: admin" \
  https://services.pangkalpinangkota.go.id/citizen-api/lookup.php
# Diharapkan: 401 (gateway secret kosong) atau 403 (IP tidak diizinkan).
# 200 di sini berarti §5.3 belum lengkap — siapa pun bisa menyamar jadi user apa pun.
```

Test §5.4 langkah 3 adalah yang membuktikan lockdown off-VPS bekerja.
Jika Anda bisa menabrak backend langsung dengan `X-User-Id` palsu,
seluruh model autentikasi ter-bypass tidak peduli sebagus apa konfigurasi
Kong. Jangan dilewatkan.

### 5.5 Kesalahan umum — spesifik Path C

| Gejala | Kemungkinan penyebab | Solusi |
|---|---|---|
| `502 Bad Gateway` langsung di setiap request | Container Kong tidak bisa resolve DNS upstream | `docker compose exec kong getent hosts services.pangkalpinangkota.go.id`. Jika kosong, cek `/etc/resolv.conf` di dalam container; di Docker Desktop resolver default biasanya aman, di VPS Docker Anda mungkin perlu `dns:` di blok compose service. |
| `502 Bad Gateway` setelah jeda | Verifikasi TLS gagal — chain cert upstream tidak lengkap atau issuer tidak dipercaya | `openssl s_client -connect <host>:443 -showcerts`. Chain cert harus include intermediate. Re-issue dengan `fullchain.pem`. Sebagai usaha terakhir `tls_verify: false` (JANGAN di prod). |
| WHM/cPanel mengembalikan HTML site yang salah, atau landing page default | `preserve_host: true` mengirim edge host; cPanel route ke vhost yang salah | Set `preserve_host: false` (pin eksplisit). |
| `Authorization: Bearer …` sampai ke script PHP | Plugin `pre-function` tidak ada, atau melekat di route bukan service, atau prioritasnya ter-override | Pastikan plugin ada di blok service, prioritas default. Jalankan `check-lua-sync.mjs`. |
| Backend menerima curl dengan `X-User-Id` pilihan sendiri | Lockdown §5.3 tidak diimplementasi (atau tidak ditegakkan di path/route ini) | Pattern 1 + Pattern 2 dari §5.3. Keduanya. |
| Spike latency hanya di rute Path C | Anda membayar RTT antar-VPS per request — Mobile melihat 401-then-refresh-then-retry = 3× RTT itu | Jika tidak terhindarkan, naikkan `BFF_INTERNAL_JWT_TTL_SECONDS` (di dalam cap 600s yang Kong tegakkan) agar refresh lebih jarang. Atau kembalikan rute latency-sensitif ke stack Docker lokal. |
| Rotasi secret butuh edit `kong.yml` | Anda inline literal secret-nya alih-alih pakai env-vault | Ganti ke `{vault://env/citizen-api-gateway-secret}` dan set env var di `docker-compose.yml`. |
| Healthcheck tidak menarik upstream keluar dari rotation saat backend down | Kong DB-less tidak menjalankan active healthcheck; passive hanya menghitung traffic nyata | Pastikan blok `passive` ada; di service yang nyaris idle butuh `tcp_failures: 2` upaya nyata sebelum Kong bereaksi. |
| Plugin `request-transformer` tidak menambahkan header | Scope plugin salah, atau env var `vault://` tidak ter-set saat Kong startup | Pastikan `CITIZEN_API_GATEWAY_SECRET` ada di `kong.environment:` di `docker-compose.yml` dan workspace `.env` punya nilainya. Restart Kong. |

---

## 6. Authorization per-route (role check)

Kedua path mendapatkan injeksi identitas secara gratis, tapi **penegakan
role** adalah keputusan Anda. Dua opsi:

### Opsi 1 — cek di service (paling sederhana)

Header `X-Roles` adalah CSV koma dari role user:

```ts
app.delete('/lookup/:nik', (req, res) => {
  const { roles } = identityFromHeaders(req);
  if (!roles.includes('admin')) {
    return res.status(403).json({ error: 'forbidden' });
  }
  // ...
});
```

Gampang. Kekurangannya policy ada di kode service, jadi mengubah "role
mana yang boleh delete" mengharuskan redeploy service.

### Opsi 2 — cek di Kong (tersentralisasi)

Tambahkan blok `pre-function` ekstra (atau perluas yang ada) di route
spesifik yang membutuhkan role:

```yaml
- name: ktp-service
  url: http://ktp-service:3002
  routes:
    - name: ktp-admin-only
      paths: [/api/ktp/admin]
      strip_path: true
      plugins:
        # plugin ekstra di-scope hanya ke route ini
        - name: pre-function
          config:
            _priority: 999            # eksplisit: di bawah jwt(1450), di atas limit(910)
            access:
              - |
                local roles = kong.request.get_header("X-Roles") or ""
                if not string.find("," .. roles .. ",", ",admin,", 1, true) then
                  return kong.response.exit(403, { message = "forbidden" })
                end
  plugins:
    # ...semua plugin level-service dari §3.3 tetap berlaku global...
```

Plugin route-scoped berjalan **setelah** plugin service-scoped. Saat Lua
ini berjalan, `pre-function` level-service sudah memverifikasi `iss`/`aud`
dan meng-inject `X-Roles` dari JWT — jadi membaca header di sini aman.

---

## 7. Cheatsheet validasi

| Command | Apa yang ditangkap |
|---|---|
| `node kong/scripts/validate.mjs` | Error YAML / schema di `kong.yml` (pakai Docker untuk menjalankan `kong config parse`) |
| `node kong/scripts/check-lua-sync.mjs` | Drift antara `kong/lua/identity_inject.lua` dan body `pre-function` inline di `kong.yml` |
| `node kong/scripts/audit-kid-config.mjs` | Sebuah kid dideklarasikan di satu file tapi hilang di file lain (BFF env / workspace `.env` / `kong.yml` / `docker-compose.yml`) |

Jalankan ketiganya sebelum setiap deploy. Tidak butuh dependency
eksternal selain Node dan (untuk `validate.mjs`) Docker.

---

## 8. Kesalahan umum

| Gejala | Kemungkinan penyebab | Solusi |
|---|---|---|
| Setiap request mengembalikan 401 meski dengan bearer yang valid | Blok service tidak punya plugin `jwt`, atau `key_claim_name` terlewat sehingga Kong lookup berdasarkan `iss` dan tidak menemukan apa-apa | Cek ulang §3.3 — salin **seluruh** plugin chain. |
| 401 dengan `"No credentials found for given 'kid'"` | `kid` token tidak ada di `consumers[0].jwt_secrets` — entah Kong masih pakai config lama atau Anda testing dengan token yang ditandatangani kid yang sudah dirotasi | `docker compose restart kong`; jalankan `audit-kid-config.mjs`. |
| 401 dengan `"invalid issuer"` atau `"invalid audience"` | Token uji Anda punya `iss`/`aud` berbeda dari hardcoded `super-app-bff` / `super-app-services` di Lua | Cocokkan nilai di `bff/src/lib/internalJwt.ts`. |
| Service tetap menerima header `Authorization` | Anda paste plugin `pre-function` tapi dengan prioritas berbeda, sehingga jalan **sebelum** `jwt` | Jangan override `_priority` di pre-function level service. |
| Service menerima `X-User-Id: admin` dari klien malicious | Anda lupa plugin `pre-function` — langkah strip-then-set tidak pernah jalan | Tambahkan plugin (§3.3). |
| Blok plugin di-parse tapi tidak berjalan | Indentasi YAML meleset dua space di bawah `config:` | `node kong/scripts/validate.mjs` menangkap ini. |
| Aplikasi mobile dapat 502 langsung setelah deploy | Kong restart tapi container upstream baru belum ready | Tambahkan `healthcheck` ke service dan `condition: service_healthy` ke `depends_on` Kong. |
| Test yang kemarin lolos hari ini 401 | Dev keypair di-regenerate tanpa redeploy Kong | PEM yang Kong miliki dan private key yang BFF pegang harus sepasang; regenerate bersamaan. |

---

## Checklist

Pakai ini sebagai ringkasan satu halaman saat menambahkan service.

### Untuk service ber-autentikasi (Path A)

- [ ] Salin `services/sample-service/` ke `services/<name>-service/`.
- [ ] Set port yang didengarkan dan update `EXPOSE` Dockerfile.
- [ ] Di kode service: baca identitas hanya dari `X-User-Id` / `X-Roles` / `X-Session-Id`. Jangan baca `Authorization`. Jangan decode JWT.
- [ ] Tambahkan entry `services:` di `kong/kong.yml` dengan plugin chain lengkap: `correlation-id`, `jwt`, `pre-function`, `rate-limiting`. Jaga body `pre-function` identik dengan `sample-service`.
- [ ] Set `strip_path: true` agar upstream melihat path yang ia miliki.
- [ ] Tambahkan service ke `docker-compose.yml` tanpa host port mapping.
- [ ] Tambahkan service ke `depends_on:` Kong.
- [ ] Jalankan `validate.mjs`, `check-lua-sync.mjs`, `audit-kid-config.mjs` — semua OK.
- [ ] `docker compose up -d --build`. Smoke-test dengan dan tanpa bearer.
- [ ] Konfirmasi di response bahwa `X-Authorization` hilang dan `X-User-Id` cocok dengan `sub` token.

### Untuk service publik (Path B)

- [ ] Pakai prefix path `/api/public/` agar reviewer langsung melihat bahwa auth sengaja dilewatkan.
- [ ] Blok service **tidak** punya plugin `jwt` dan **tidak** punya plugin `pre-function`.
- [ ] Blok service punya `rate-limiting` dengan `limit_by: ip` dan ceiling `minute:` yang masuk akal.
- [ ] Kode service tidak mempercayai header `X-*` apapun (tidak ada identitas user).
- [ ] Autentisitas pihak ketiga (signing webhook) diverifikasi **di dalam** service.
- [ ] Smoke-test bahwa endpoint bekerja tanpa bearer, dan bahwa `429` muncul saat burst.

### Untuk upstream di luar VPS (Path C — dikombinasikan dengan A atau B di atas)

- [ ] Pilih sub-case yang tepat: C.1a LAN privat / C.1b HTTPS publik / C.1c WHM-cPanel.
- [ ] Set `url:` yang benar — URL penuh termasuk skema, host, dan prefix path di sisi upstream.
- [ ] Untuk upstream HTTPS: `tls_verify: true` (default — pin). Konfirmasi chain cert lengkap dengan `openssl s_client`.
- [ ] Untuk backend virtual-hosted (cPanel, vhost nginx): `preserve_host: false` (default — pin).
- [ ] Ketatkan `connect_timeout` / `read_timeout` / `write_timeout` untuk RTT antar-VPS.
- [ ] **Kunci akses langsung:** IP allowlist (Pattern 1) + header shared-secret (Pattern 2) — keduanya, idealnya. Inject secret lewat `request-transformer` yang merujuk ke `{vault://env/...}`; jangan inline.
- [ ] Set nilai secret di `kong.environment:` `docker-compose.yml` dan workspace `.env`. Konfirmasi Kong melihatnya saat startup.
- [ ] Backend membaca identitas hanya dari `X-User-Id` / `X-Roles` / `X-Session-Id`; verifikasi gateway secret setiap request pakai `hash_equals` (atau ekuivalen constant-time compare).
- [ ] Tambahkan healthcheck `passive` agar upstream yang flaky ditarik dari rotation.
- [ ] **Smoke test langkah 3 (bypass langsung):** `curl` URL publik backend dengan `X-User-Id` palsu. Harus mengembalikan 401 atau 403. 200 di sini berarti lockdown belum lengkap.

---

## 9. Contoh kerja

Bagian-bagian di atas adalah referensi. Bagian ini adalah cookbook: tujuh
case lengkap yang dapat di-copy-paste — blok `kong.yml` penuh, diff
`docker-compose.yml` penuh, skeleton backend penuh, smoke test penuh.

| § | Service | Path | Apa yang berbeda |
|---|---|---|---|
| [9.1](#91-e-ktp-service-path-a--role-check) | `e-ktp-service` | A | Service local-auth referensi, dengan role check untuk endpoint write |
| [9.2](#92-e-perizinan-service-path-a--upload-pdf) | `e-perizinan-service` | A | Menaikkan batas body per-service untuk upload PDF permohonan izin |
| [9.3](#93-status-service-path-b--proxy-cache) | `status-service` | B | Halaman status layanan kota publik dengan proxy-cache dan rate limit IP |
| [9.4](#94-wa-webhook-service-path-b--hmac) | `wa-webhook-service` | B | Webhook inbound WhatsApp Business — HMAC diverifikasi di-service |
| [9.5](#95-legacy-citizen-db-path-c1a-lan-privat) | `legacy-citizen-db` | C.1a | VPS sibling lewat LAN privat, plain HTTP, hanya shared-secret |
| [9.6](#96-e-sampah-service-path-c1b--https-publik) | `e-sampah-service` | C.1b | **Case produksi nyata** — VPS terpisah, HTTPS publik, lockdown penuh |
| [9.7](#97-citizen-api-path-c1c-cpanelwhm-php) | `citizen-api` | C.1c | PHP di shared hosting cPanel/WHM, AutoSSL, lockdown .htaccess |

---

### 9.1 `e-ktp-service` (Path A + role check)

**Skenario.** Disdukcapil membuka API baca agar warga bisa cek record
NIK mereka sendiri, dan API tulis untuk pegawai (role
`pegawai-disdukcapil`) untuk memperbaiki record. Kedua endpoint berada
di service yang sama, di prefix yang sama; role check memisahkannya.

**Klasifikasi Path.** Path A — service Node lokal di stack Docker, penuh
di belakang Kong. Plugin chain-nya standar. Penegakan role memakai §6
Opsi 1 (in-service), karena policy spesifik per-endpoint dan tim lebih
suka mengedit TS daripada `kong.yml`.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: e-ktp-service
  url: http://e-ktp-service:3002

  routes:
    - name: e-ktp
      paths: [/api/ktp]
      strip_path: true
      # GET  /api/ktp/lookup/<nik>  → upstream melihat GET  /lookup/<nik>
      # POST /api/ktp/correct/<nik> → upstream melihat POST /correct/<nik>

  plugins:
    - name: correlation-id
      config:
        header_name: X-Request-Id
        generator: uuid
        echo_downstream: true

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- IDENTIK dengan sample-service. Paste body penuh dari
            -- kong/kong.yml di sini. check-lua-sync.mjs hanya menjaga
            -- salinan sample-service; yang ini adalah kontrak yang Anda jaga.

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id
```

#### `docker-compose.yml` — append di bawah `services:`

```yaml
e-ktp-service:
  build: ./services/e-ktp-service
  container_name: super-app-e-ktp-service
  environment:
    NODE_ENV: production
    PORT: 3002
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:3002/health"]
    interval: 10s
    timeout: 3s
    retries: 5
```

Dan tambahkan ke `depends_on:` `kong:`:

```yaml
kong:
  depends_on:
    sample-service: { condition: service_started }
    e-ktp-service:  { condition: service_healthy }   # ← baru
```

#### `services/e-ktp-service/src/index.ts`

```ts
import express, { type Request, type Response, type NextFunction } from 'express';

const PORT = Number(process.env['PORT'] ?? 3002);

type Identity = {
  userId: string | null;
  sessionId: string | null;
  roles: string[];
};

const identityFromHeaders = (req: Request): Identity => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',').map((r) => r.trim()).filter(Boolean),
});

const requireRole = (role: string) =>
  (req: Request, res: Response, next: NextFunction) => {
    const { roles } = identityFromHeaders(req);
    if (!roles.includes(role)) {
      return res.status(403).json({ error: 'forbidden', requires: role });
    }
    next();
  };

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'e-ktp-service' });
});

app.get('/lookup/:nik', (req, res) => {
  const { userId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...lookup DB, kembalikan hanya record warga itu sendiri...
  res.json({ nik: req.params.nik, requestedBy: userId });
});

app.post('/correct/:nik', requireRole('pegawai-disdukcapil'), (req, res) => {
  const { userId } = identityFromHeaders(req);
  // ...terapkan koreksi, audit log berdasarkan userId + X-Request-Id...
  res.json({ nik: req.params.nik, correctedBy: userId, body: req.body });
});

app.listen(PORT, () => console.log(`e-ktp-service on :${PORT}`));
```

#### Smoke test

```bash
docker compose up -d --build e-ktp-service kong

# Endpoint baca sebagai warga — harus berhasil.
TOKEN_CITIZEN=$(./scripts/mint-test-token.sh --roles citizen --sub user-123)
curl -s -H "Authorization: Bearer $TOKEN_CITIZEN" \
  http://localhost:8080/api/ktp/lookup/1271010101010001 | jq .
# Diharapkan: 200 { "nik": "...", "requestedBy": "user-123" }

# Endpoint tulis sebagai warga — 403.
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST -H "Authorization: Bearer $TOKEN_CITIZEN" \
  -H "Content-Type: application/json" -d '{"name":"x"}' \
  http://localhost:8080/api/ktp/correct/1271010101010001
# Diharapkan: 403

# Endpoint tulis sebagai pegawai — 200.
TOKEN_STAFF=$(./scripts/mint-test-token.sh --roles pegawai-disdukcapil --sub staff-7)
curl -s -X POST -H "Authorization: Bearer $TOKEN_STAFF" \
  -H "Content-Type: application/json" -d '{"name":"x"}' \
  http://localhost:8080/api/ktp/correct/1271010101010001 | jq .
# Diharapkan: 200 { "correctedBy": "staff-7", ... }
```

#### Jebakan khusus §9.1

| Gejala | Penyebab | Solusi |
|---|---|---|
| Role check tidak lolos untuk siapa pun | `X-Roles` `null` karena JWT tidak punya klaim `roles` | Pastikan BFF menyalin role-mapping Keycloak ke JWT internal — lihat `bff/src/lib/internalJwt.ts`. |
| Warga bisa membaca NIK warga lain | Anda lupa membatasi `lookup` ke NIK milik `userId` sendiri | Role gate tidak menggantikan authorization per-row. Filter query DB juga berdasarkan `userId`. |
| Role pegawai bekerja di dev, gagal di prod | Realm role di Keycloak prod tidak bernama `pegawai-disdukcapil` | Realm role spesifik per environment; cek console admin Keycloak cocok dengan string di `requireRole(...)`. |

---

### 9.2 `e-perizinan-service` (Path A + upload PDF)

**Skenario.** Service permohonan izin. Warga submit PDF dokumen pendukung
bersama form permohonan. Ceiling request-size default (256 KB di Kong,
64 KB di nginx) memblokir apapun yang berguna — keduanya perlu dinaikkan,
khusus rute ini saja.

**Klasifikasi Path.** Path A — service Node lokal. Satu-satunya deviasi
dari §9.1 adalah config `request-size-limiting` per-service dan kenaikan
client-body-size nginx di location yang cocok.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: e-perizinan-service
  url: http://e-perizinan-service:3004

  routes:
    - name: e-perizinan
      paths: [/api/perizinan]
      strip_path: true

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- Lua IDENTIK dengan sample-service.

    # ── OVERRIDE PER-SERVICE atas cap global 256 KB (AUDIT S-6). ──
    # Instance plugin yang di-scope ke service ini mengoverride
    # request-size-limiting global yang dideklarasikan di root kong.yml.
    # 5 MB cocok untuk ceiling praktis PDF multi-page hasil scan; menaikkan
    # lebih tinggi menambah cost-of-abuse upload jahat, jadi jangan
    # dinaikkan lagi tanpa jenis dokumen nyata yang membutuhkannya.
    - name: request-size-limiting
      config:
        allowed_payload_size: 5120
        size_unit: kilobytes
        require_content_length: true   # tolak upload chunked tanpa size

    - name: rate-limiting
      config:
        # lebih ketat dari default karena upload mahal
        minute: 60
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id
```

#### `nginx/conf.d/api.conf` — naikkan batas client body di prefix yang cocok

```nginx
# nginx terminate koneksi TLS client SEBELUM Kong melihat request,
# jadi cap body-size-nya (default 1m atau 64k proyek ini) clamp duluan.
# Naikkan hanya di /api/perizinan/ agar rute lain tetap pakai default ketat.
location /api/perizinan/ {
  client_max_body_size 5m;        # cocok dengan 5120 KB Kong
  client_body_timeout 30s;        # jangan biarkan upload lambat mengikat worker
  proxy_request_buffering off;    # stream langsung ke Kong, jangan buffer

  include /etc/nginx/snippets/proxy_common.conf;
  proxy_pass http://kong:8000;
}
```

#### `docker-compose.yml` — append di bawah `services:`

```yaml
e-perizinan-service:
  build: ./services/e-perizinan-service
  container_name: super-app-e-perizinan-service
  environment:
    NODE_ENV: production
    PORT: 3004
    # Di mana PDF upload mendarat. Pada deploy nyata ini adalah klien
    # object-store (MinIO S3-compatible, dsb.), bukan FS lokal.
    UPLOAD_DIR: /var/lib/perizinan/uploads
  volumes:
    - perizinan-uploads:/var/lib/perizinan/uploads
  restart: unless-stopped

volumes:
  perizinan-uploads:
```

#### `services/e-perizinan-service/src/index.ts`

```ts
import express, { type Request } from 'express';
import multer from 'multer';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3004);
const UPLOAD_DIR = process.env['UPLOAD_DIR'] ?? '/tmp';

const identityFromHeaders = (req: Request) => ({
  userId: (req.headers['x-user-id'] as string | undefined) ?? null,
  requestId: (req.headers['x-request-id'] as string | undefined) ?? null,
});

const upload = multer({
  dest: UPLOAD_DIR,
  limits: {
    // belt-and-braces: Kong sudah menegakkan 5 MB, tapi service tetap harus
    // menolak yang lebih besar agar memori tidak melonjak jika Kong di-bypass
    fileSize: 5 * 1024 * 1024,
    files: 1,
  },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype !== 'application/pdf') {
      return cb(new Error('only application/pdf accepted'));
    }
    cb(null, true);
  },
});

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/apply', upload.single('document'), (req, res) => {
  const { userId, requestId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  if (!req.file) return res.status(400).json({ error: 'document required' });

  const applicationId = randomUUID();
  // ...persist row permohonan dengan key applicationId, userId, req.file.path...

  res.status(202).json({
    applicationId,
    appliedBy: userId,
    requestId,
    fileSize: req.file.size,
  });
});

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build e-perizinan-service kong nginx

# File kecil — diterima.
echo "%PDF-1.4 small" > /tmp/small.pdf
curl -s -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/small.pdf;type=application/pdf" \
  http://localhost:8080/api/perizinan/apply | jq .
# Diharapkan: 202 dengan applicationId

# File 6 MB — plugin request-size-limiting Kong menolak di 413.
dd if=/dev/zero of=/tmp/big.pdf bs=1M count=6 status=none
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/big.pdf;type=application/pdf" \
  http://localhost:8080/api/perizinan/apply
# Diharapkan: 413 Request Entity Too Large

# Content type salah — service menolak di 400 (Kong tidak filter MIME).
echo "not a pdf" > /tmp/notpdf.txt
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -F "document=@/tmp/notpdf.txt;type=text/plain" \
  http://localhost:8080/api/perizinan/apply
# Diharapkan: 400
```

#### Jebakan khusus §9.2

| Gejala | Penyebab | Solusi |
|---|---|---|
| `413` bahkan untuk upload 1 MB | `client_max_body_size` nginx masih default 1m | Naikkan di blok `location` yang cocok (lihat `api.conf` di atas). |
| Upload hang lalu timeout | `proxy_request_buffering on` + klien lambat = nginx buffer seluruh file sebelum Kong melihat satu byte pun | Set `proxy_request_buffering off` di route upload. |
| Disk penuh di dev | Test upload lalu crash sebelum cleanup | Mount volume ke `tmpfs` di compose dev, atau wire cron untuk drop file lebih lama dari N hari. |
| Service OOM untuk PDF 5 MB yang valid | `multer` mem-buffer di memori alih-alih stream ke disk | Pakai `multer({ dest, ... })` bukan `multer.memoryStorage()`. |
| File parts tiba tapi `req.file` undefined | Nama form field di klien tidak cocok dengan `upload.single('document')` | Rename form field atau ubah pemanggilan multer. |

---

### 9.3 `status-service` (Path B + proxy-cache)

**Skenario.** Halaman status publik yang mencantumkan layanan kota mana
yang sedang up. Diakses scraper, embed di homepage kota, tidak pernah ada
identitas user. Banyak baca — caching di Kong menyimpan upstream
sepenuhnya saat hit.

**Klasifikasi Path.** Path B. Tidak ada `jwt`, tidak ada `pre-function`.
Rate limit IP + plugin `proxy-cache` agar burst request identik dijawab
dari RAM.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: status-service
  url: http://status-service:3005

  routes:
    - name: status-public
      paths: [/api/public/status]
      strip_path: true
      # Prefix /api/public/ krusial untuk code review:
      # grep -r '/api/public' kong/kong.yml mengonfirmasi rute mana
      # yang sengaja melewati auth. Lihat §2.

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    # TIDAK ada plugin jwt. TIDAK ada plugin pre-function.

    # Cache GET selama 30s. Upstream re-compute status dengan polling
    # internal service tiap 60s; 30s di edge memotong setengah beban
    # upstream dengan staleness terburuk 30s.
    - name: proxy-cache
      config:
        response_code: [200]
        request_method: [GET, HEAD]
        content_type: ["application/json", "application/json; charset=utf-8"]
        cache_ttl: 30
        strategy: memory
        memory:
          dictionary_name: kong_db_cache   # dict in-memory default

    # Rate limit IP — tidak ada X-User-Id untuk dijadikan key.
    # 120/menit/IP adalah default proyek untuk endpoint publik; tune
    # untuk pola scraping yang legal (poll homepage kota = ~1/menit).
    - name: rate-limiting
      config:
        minute: 120
        policy: local
        fault_tolerant: true
        limit_by: ip
```

#### `docker-compose.yml`

```yaml
status-service:
  build: ./services/status-service
  container_name: super-app-status-service
  environment:
    NODE_ENV: production
    PORT: 3005
  restart: unless-stopped
```

Tambahkan `status-service: { condition: service_started }` ke
`depends_on:` `kong:`.

#### `services/status-service/src/index.ts`

```ts
import express from 'express';

const PORT = Number(process.env['PORT'] ?? 3005);

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// Pada kenyataannya ini di-poll di background dan di-cache in-process,
// bukan dihitung per request.
app.get('/', (_req, res) => {
  res.setHeader('Cache-Control', 'public, max-age=30');
  res.json({
    asOf: new Date().toISOString(),
    services: [
      { name: 'e-ktp',     status: 'up'   },
      { name: 'e-sampah',  status: 'up'   },
      { name: 'perizinan', status: 'degraded', note: 'PDF render slow' },
    ],
  });
});

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build status-service kong

# Akses anonim bekerja.
curl -s http://localhost:8080/api/public/status | jq .

# Cache hit di request ke-2 — cari X-Cache-Status: Hit.
curl -sI http://localhost:8080/api/public/status | grep -i x-cache-status
curl -sI http://localhost:8080/api/public/status | grep -i x-cache-status
# 1st: X-Cache-Status: Miss
# 2nd: X-Cache-Status: Hit

# Rate limit aktif sekitar request ke-121 dari IP yang sama.
for i in {1..200}; do
  curl -so /dev/null -w "%{http_code} " http://localhost:8080/api/public/status
done | tr ' ' '\n' | sort | uniq -c
# Diharapkan: ~120 baris "200", sisanya "429"
```

#### Jebakan khusus §9.3

| Gejala | Penyebab | Solusi |
|---|---|---|
| `proxy-cache` tidak pernah hit | Upstream menset `Cache-Control: no-store` atau `private` | Plugin menghormati header cache upstream. Ubah response service atau set `cache_control: false` di plugin untuk force-cache. |
| Cache di-key salah — setiap IP dapat miss baru | Default `proxy-cache` include `Host`/`URI`/`query` request tapi bukan `X-Forwarded-For` | Default key cocok untuk endpoint anonim. Jika Anda vary by query string, pastikan `vary_query_params:` cocok dengan yang caller kirim. |
| `429` muncul di 5 req/detik padahal `minute: 120` | Bot menggunakan satu IP yang sebenarnya NAT di depan kantor kota | `limit_by: ip` dengan `fault_tolerant: true` adalah setup yang benar; naikkan `minute:` untuk IP NAT via plugin instance per-route, atau terima saja. |
| Service bisa dijangkau langsung dari host | Anda menambahkan mapping `ports:` karena refleks | Hilangkan. Service publik tetap hanya boleh dijangkau via Kong. |

---

### 9.4 `wa-webhook-service` (Path B + HMAC)

**Skenario.** WhatsApp Business API mengirim pesan inbound dengan POST
ke URL publik. Pihak ketiga menandatangani setiap POST dengan HMAC-SHA256
dari body, memakai shared secret yang hanya Meta dan service kita ketahui.
Kong tidak bisa memverifikasi ini — secret-nya bukan milik kita dan
mekanisme signature-nya provider-specific. Jadi rute-nya Path B di Kong
(tanpa JWT), dan verifikasi HMAC terjadi di dalam service di setiap request.

**Klasifikasi Path.** Path B + verifikasi HMAC in-service. Spesifiknya
penerima webhook: anonim ke Kong, ter-autentikasi oleh signature Meta di
dalam service.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: wa-webhook-service
  url: http://wa-webhook-service:3006

  routes:
    - name: wa-webhook
      paths: [/api/public/webhooks/whatsapp]
      strip_path: true
      methods: [GET, POST]
      # GET = handshake verifikasi Meta; POST = pesan inbound.

  plugins:
    - name: correlation-id
      config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true }

    # TIDAK ada jwt. TIDAK ada pre-function. Auth = HMAC check upstream.

    # Rate limit IP. Meta post dari range IP yang dikenal — set cukup
    # longgar agar burst saat kampanye tidak drop, tapi cukup ketat agar
    # URL bocor tidak kewalahan.
    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: ip
```

> **Alternatif lebih ketat:** Plugin `ip-restriction` bawaan Kong bisa
> meng-allowlist range IP egress Meta langsung di gateway. Meta
> mempublikasikan daftarnya dan rotate sesekali — otomatisasi sinkron
> itu adalah orkestrasi yang berlebihan untuk satu webhook. Serahkan IP
> filter ke service atau terima bahwa HMAC check adalah satu-satunya
> gate autentisitas.

#### `docker-compose.yml`

```yaml
wa-webhook-service:
  build: ./services/wa-webhook-service
  container_name: super-app-wa-webhook-service
  environment:
    NODE_ENV: production
    PORT: 3006
    # Shared secret yang Meta konfigurasikan untuk webhook ini. Diisi
    # dari ${WA_APP_SECRET} di workspace .env Anda (jangan pernah commit).
    WA_APP_SECRET: ${WA_APP_SECRET}
    # Verify-token yang Meta kirim pada handshake GET.
    WA_VERIFY_TOKEN: ${WA_VERIFY_TOKEN}
  restart: unless-stopped
```

#### `services/wa-webhook-service/src/index.ts`

```ts
import express, { type Request, type Response, type NextFunction } from 'express';
import { createHmac, timingSafeEqual } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3006);
const APP_SECRET = process.env['WA_APP_SECRET'] ?? '';
const VERIFY_TOKEN = process.env['WA_VERIFY_TOKEN'] ?? '';

const app = express();
app.disable('x-powered-by');

// Tangkap body request MENTAH — kita butuh byte persis untuk re-compute HMAC.
// express.json() akan re-serialize dan signature tidak akan pernah cocok.
app.use(express.raw({ type: 'application/json', limit: '256kb' }));

const verifyMetaSignature = (req: Request, res: Response, next: NextFunction) => {
  const sigHeader = req.header('x-hub-signature-256') ?? '';
  // Meta kirim "sha256=<hex>"
  if (!sigHeader.startsWith('sha256=')) {
    return res.status(401).json({ error: 'missing signature' });
  }
  const presented = Buffer.from(sigHeader.slice('sha256='.length), 'hex');
  const expected = createHmac('sha256', APP_SECRET)
    .update(req.body as Buffer)
    .digest();

  // Constant-time compare. Mismatch panjang harus short-circuit aman.
  if (presented.length !== expected.length ||
      !timingSafeEqual(presented, expected)) {
    return res.status(401).json({ error: 'bad signature' });
  }
  next();
};

// Handshake verifikasi Meta: GET dengan hub.mode / hub.challenge / hub.verify_token.
app.get('/', (req, res) => {
  const mode = req.query['hub.mode'];
  const token = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];
  if (mode === 'subscribe' && token === VERIFY_TOKEN) {
    return res.status(200).send(String(challenge ?? ''));
  }
  res.sendStatus(403);
});

// POST pesan inbound.
app.post('/', verifyMetaSignature, (req, res) => {
  const payload = JSON.parse((req.body as Buffer).toString('utf8'));
  // ...enqueue payload untuk pemrosesan async; ack dalam 200ms atau Meta retry...
  res.sendStatus(200);
});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.listen(PORT);
```

#### Smoke test

```bash
docker compose up -d --build wa-webhook-service kong

# 1) Handshake GET — cocokkan verify token.
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://localhost:8080/api/public/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=$WA_VERIFY_TOKEN&hub.challenge=test"
# Diharapkan: 200

# 2) Handshake GET — token salah.
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://localhost:8080/api/public/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test"
# Diharapkan: 403

# 3) POST tanpa signature → 401 dari service.
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  -H "Content-Type: application/json" -d '{"messages":[]}' \
  http://localhost:8080/api/public/webhooks/whatsapp
# Diharapkan: 401

# 4) POST dengan signature benar → 200.
BODY='{"object":"whatsapp_business_account","entry":[]}'
SIG="sha256=$(printf %s "$BODY" | openssl dgst -sha256 -hmac "$WA_APP_SECRET" -binary | xxd -p -c 256)"
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$BODY" \
  http://localhost:8080/api/public/webhooks/whatsapp
# Diharapkan: 200
```

#### Jebakan khusus §9.4

| Gejala | Penyebab | Solusi |
|---|---|---|
| HMAC tidak pernah cocok | `express.json()` re-parse body, verifier hash JSON yang sudah di-re-serialize | Pakai `express.raw({ type: 'application/json' })` dan hash `req.body` (Buffer). |
| HMAC cocok di dev, gagal di prod | Prod punya `WA_APP_SECRET` berbeda; Anda menyalin yang dev | Sinkronkan secret dengan dashboard Meta per environment. |
| Constant-time compare crash karena beda panjang | `timingSafeEqual` melempar saat buffer beda panjang | Cek `presented.length === expected.length` sebelum memanggilnya. |
| Meta retry pesan yang sama selamanya | Service mengembalikan non-2xx, atau butuh > ~20s untuk ack | Ack dalam 200ms; kerjakan tugas async (queue). |
| URL webhook bocor → spam ke endpoint | URL memang publik by design | Andalkan HMAC check — tanpa secret, penyerang hanya menyebabkan noise 401 yang di-rate-limit per IP. |

---

### 9.5 `legacy-citizen-db` (Path C.1a LAN privat)

**Skenario.** Service Java yang sudah ada berjalan di VPS sibling di
VLAN provider yang sama. Dapat dijangkau dari Kong di
`http://10.0.5.20:8080`. Tanpa TLS (LAN privat), tanpa virtual host.
Anda tidak punya codebase-nya dan menambahkan middleware gateway-guard
butuh deploy terkoordinasi dengan tim lain.

**Klasifikasi Path.** Path C.1a — HTTP plain lewat LAN privat. Plugin
chain auth sama dengan Path A; perbedaannya `url:`, tidak ada knob TLS,
tidak ada urusan `preserve_host`, dan lockdown direct-access lebih minim
(hanya Pattern 2 shared-secret yang portable; IP LAN sudah merupakan
allowlist parsial).

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: legacy-citizen-db
  url: http://10.0.5.20:8080
  # Tanpa tls_verify — HTTP plain. Dapat diterima HANYA karena path
  # ini privat di VLAN provider. Jika VPS ini pindah ke segmen jaringan
  # lain, switch ke https:// dan re-add tls_verify: true.

  connect_timeout: 3000
  read_timeout: 10000
  write_timeout: 10000

  routes:
    - name: legacy-citizen
      paths: [/api/legacy/citizen]
      strip_path: true
      # Tidak perlu preserve_host — upstream single-vhost.

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }
    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []
    - name: pre-function
      config:
        access:
          - |
            -- Lua IDENTIK dengan sample-service.

    # Header shared-secret — lihat §5.3 Pattern 2. Satu-satunya gate
    # auth service legacy ini adalah header ini; verifikasi setiap inbound.
    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/legacy-citizen-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — env Kong

```yaml
kong:
  environment:
    LEGACY_CITIZEN_GATEWAY_SECRET: ${LEGACY_CITIZEN_GATEWAY_SECRET}
```

…dan `.env` (jangan pernah commit):

```bash
LEGACY_CITIZEN_GATEWAY_SECRET=<32+ byte random; rotate per kuartal>
```

#### Snippet backend (servlet filter Java/Spring)

```java
// LegacyCitizenDB — tambahkan filter ini di path inbound.
public class GatewayGuardFilter implements Filter {
  private final byte[] expected;

  public GatewayGuardFilter() {
    String env = System.getenv("GATEWAY_SECRET");
    if (env == null || env.isEmpty()) {
      throw new IllegalStateException("GATEWAY_SECRET unset");
    }
    this.expected = env.getBytes(StandardCharsets.UTF_8);
  }

  @Override
  public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
      throws IOException, ServletException {
    HttpServletRequest http = (HttpServletRequest) req;
    String presentedStr = http.getHeader("X-Gateway-Secret");
    if (presentedStr == null) { deny((HttpServletResponse) res); return; }
    byte[] presented = presentedStr.getBytes(StandardCharsets.UTF_8);
    // Constant-time compare; mismatch panjang fail dengan aman.
    if (presented.length != expected.length
        || !MessageDigest.isEqual(presented, expected)) {
      deny((HttpServletResponse) res);
      return;
    }
    // Dari sini, percayai X-User-Id / X-Roles / X-Session-Id.
    chain.doFilter(req, res);
  }

  private void deny(HttpServletResponse res) throws IOException {
    res.setStatus(401);
    res.getWriter().write("not via gateway");
  }
}
```

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Tanpa bearer → Kong 401 (plugin jwt).
curl -i http://localhost:8080/api/legacy/citizen/lookup

# 2) Dengan bearer → di-route ke service legacy, identitas ter-inject.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/legacy/citizen/lookup | jq .

# 3) KRITIS — coba backend langsung dari box lain di VLAN yang sama.
ssh ops@10.0.5.21 'curl -i -H "X-User-Id: admin" http://10.0.5.20:8080/lookup'
# Diharapkan: 401 dari service legacy (gateway secret tidak ada).
# 200 berarti GatewayGuardFilter belum ter-wire — perbaiki SEBELUM
# roll rute ini ke produksi.
```

#### Jebakan khusus §9.5

| Gejala | Penyebab | Solusi |
|---|---|---|
| 502 langsung, padahal box legacy ping baik | Docker di host Kong tidak bisa melihat VLAN | Pastikan Docker tidak pakai mode NAT yang memblokir 10.0.0.0/8. `docker compose exec kong ping 10.0.5.20`. |
| Curl langsung dari laptop admin sampai ke service legacy | "LAN privat" terjangkau dari VPN kantor | LAN bukan batas keamanan — pengecekan shared-secret-lah yang penting. Percayai guard, bukan jaringan. |
| Filter menolak semua di prod | Nama env var backend tidak cocok dengan yang Kong inject | Filter membaca `GATEWAY_SECRET`; Kong inject `X-Gateway-Secret`. Nilainya harus cocok; nama env-var di backend bebas. |
| Spike p99 latency sekitar 60s | Box legacy diam-diam drop koneksi; Kong menunggu `read_timeout` default penuh | `read_timeout` 10s di atas membatasi ini. Turunkan lagi jika box legacy konsisten lebih cepat. |

---

### 9.6 `e-sampah-service` (Path C.1b — HTTPS publik)

> **Ini adalah case produksi nyata Anda.** Service e-sampah adalah
> aplikasi Node/Express yang berjalan di VPS terpisah, dapat dijangkau
> di `https://sampah.pangkalpinangkota.go.id` dengan sertifikat Let's
> Encrypt sendiri. Kontrak auth identik dengan service lokal — yang
> berubah adalah jaringan, TLS, dan lockdown.

**Skenario.** Warga melaporkan lokasi pembuangan ilegal dan melihat
laporan mereka sendiri. Pegawai Disdamkar (`pegawai-disdamkar`) review
dan menutup laporan. Service berjalan di VPS sendiri (terpisah dari
VPS Kong) untuk isolasi tim/deployment.

**Klasifikasi Path.** Path C.1b — HTTPS publik ke backend single-vhost.
Tidak ada urusan cPanel. Lockdown penuh: IP allowlist *dan* header
shared-secret. Plugin chain cocok dengan Path A.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: e-sampah-service
  url: https://sampah.pangkalpinangkota.go.id

  # Verifikasi cert upstream terhadap CA sistem. Default true; di-pin
  # di sini agar edit di masa depan tidak diam-diam menonaktifkan
  # verifikasi TLS.
  tls_verify: true

  # RTT antar-VPS di region yang sama adalah single-digit ms; budget p99
  # mobile ~2s end-to-end. Tiga cap ini menjaga upstream lambat agar
  # tidak menahan worker Kong selama satu menit penuh.
  connect_timeout: 5000
  write_timeout: 10000
  read_timeout: 15000

  routes:
    - name: e-sampah
      paths: [/api/sampah]
      strip_path: true
      # Backend single-vhost, tapi pin preserve_host: false eksplisit
      # agar nginx upstream route ke blok server{} yang benar. Default
      # adalah false; ini belt-and-braces terhadap edit di masa depan.
      preserve_host: false

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- Lua IDENTIK dengan sample-service. Jangan fork body.

    # Lockdown direct-access — Pattern 2 (shared secret). Pattern 1 (IP
    # allowlist) dikonfigurasi di firewall VPS e-sampah, lihat §9.6
    # "Firewall VPS-side" di bawah.
    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/e-sampah-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — env Kong

```yaml
kong:
  environment:
    # ...env vars yang sudah ada...
    E_SAMPAH_GATEWAY_SECRET: ${E_SAMPAH_GATEWAY_SECRET}
```

Dan di workspace `.env` (jangan pernah commit):

```bash
E_SAMPAH_GATEWAY_SECRET=<32+ byte random; rotate per kuartal>
```

Nilai yang sama harus di-set di env VPS e-sampah sendiri agar middleware
guard-nya dapat memverifikasi header.

#### VPS e-sampah — backend (`server.ts`)

```ts
import express, { type Request, type Response, type NextFunction } from 'express';
import { timingSafeEqual } from 'node:crypto';

const PORT = Number(process.env['PORT'] ?? 3000);
const GATEWAY_SECRET = process.env['GATEWAY_SECRET'] ?? '';
if (!GATEWAY_SECRET) {
  throw new Error('GATEWAY_SECRET unset — refusing to start');
}
const expectedBuf = Buffer.from(GATEWAY_SECRET, 'utf8');

// Tolak setiap request yang tidak datang via gateway Kong. Berjalan
// SEBELUM route apa pun — jadi /health dan /metrics juga butuh header
// (atau pindahkan guard di bawahnya jika Anda expose mereka publik).
const gatewayGuard = (req: Request, res: Response, next: NextFunction) => {
  const presented = req.header('x-gateway-secret') ?? '';
  if (!presented) return res.status(401).end('not via gateway');
  const presentedBuf = Buffer.from(presented, 'utf8');
  if (presentedBuf.length !== expectedBuf.length ||
      !timingSafeEqual(presentedBuf, expectedBuf)) {
    return res.status(401).end('not via gateway');
  }
  next();
};

type Identity = {
  userId: string | null;
  sessionId: string | null;
  roles: string[];
  requestId: string | null;
};

const identityFromHeaders = (req: Request): Identity => ({
  userId:    (req.headers['x-user-id']    as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles:     ((req.headers['x-roles'] as string | undefined) ?? '')
               .split(',').map((r) => r.trim()).filter(Boolean),
  requestId: (req.headers['x-request-id'] as string | undefined) ?? null,
});

const requireRole = (role: string) =>
  (req: Request, res: Response, next: NextFunction) => {
    const { roles } = identityFromHeaders(req);
    if (!roles.includes(role)) {
      return res.status(403).json({ error: 'forbidden', requires: role });
    }
    next();
  };

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));
app.use(gatewayGuard);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.post('/reports', (req, res) => {
  const { userId, requestId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...persist row laporan dengan key userId + requestId untuk korelasi audit...
  res.status(201).json({ reportedBy: userId, requestId, body: req.body });
});

app.get('/reports/mine', (req, res) => {
  const { userId } = identityFromHeaders(req);
  if (!userId) return res.status(401).json({ error: 'unauthenticated' });
  // ...kembalikan laporan WHERE reporter_user_id = userId saja...
  res.json({ user: userId, reports: [] });
});

app.post('/reports/:id/close', requireRole('pegawai-disdamkar'), (req, res) => {
  const { userId } = identityFromHeaders(req);
  res.json({ closedBy: userId, reportId: req.params.id });
});

app.listen(PORT, () => console.log(`e-sampah on :${PORT}`));
```

#### VPS e-sampah — firewall (Pattern 1 IP allowlist)

VPS Kong punya IP egress stabil — sebut saja `203.0.113.10`. Kunci VPS
e-sampah agar hanya menerima inbound HTTPS dari IP tersebut:

```bash
# Di VPS e-sampah, sebagai root.
ufw default deny incoming
ufw default allow outgoing
ufw allow from <admin-bastion-ip> to any port 22 proto tcp     # SSH hanya dari bastion
ufw allow from 203.0.113.10       to any port 443 proto tcp    # HTTPS hanya dari Kong
ufw enable
ufw status verbose
```

Jika Kong berada di belakang load balancer managed dengan egress yang
rotasi, pakai range egress stabil dari provider LB, atau lewati Pattern 1
dan andalkan Pattern 2 saja (shared secret). Dokumentasikan pilihan
Anda di runbook VPS e-sampah.

#### VPS e-sampah — TLS

VPS terminate TLS dengan cert Let's Encrypt sendiri (terpisah dari cert
VPS Kong). Stack Kong tidak perlu berubah untuk itu — `tls_verify: true`
di sisi Kong hanya butuh chain cert yang lengkap:

```bash
# Dari box manapun, konfirmasi chain valid (intermediate include):
openssl s_client -connect sampah.pangkalpinangkota.go.id:443 -showcerts </dev/null
# Cari "Verify return code: 0 (ok)" di akhir.
```

Jika Anda lihat `unable to get local issuer certificate`, VPS hanya
serve leaf cert tanpa intermediate Let's Encrypt — reissue dengan
`fullchain.pem`, bukan `cert.pem` saja. Jika tidak, Kong akan 502 setiap
request.

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Tanpa bearer → Kong 401.
curl -i http://localhost:8080/api/sampah/reports/mine
# Diharapkan: 401 dari plugin jwt Kong.

# 2) Dengan bearer warga → identitas ter-inject, list laporan kembali.
TOKEN=$(./scripts/mint-test-token.sh --roles citizen --sub user-42)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/sampah/reports/mine | jq .
# Diharapkan: 200 { "user": "user-42", "reports": [] }

# 3) Warga mencoba close laporan → 403 dari role gate.
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/sampah/reports/r-1/close
# Diharapkan: 403

# 4) Bearer pegawai dapat close.
TOKEN_STAFF=$(./scripts/mint-test-token.sh --roles pegawai-disdamkar --sub staff-3)
curl -s -X POST -H "Authorization: Bearer $TOKEN_STAFF" \
  http://localhost:8080/api/sampah/reports/r-1/close | jq .
# Diharapkan: 200 { "closedBy": "staff-3", "reportId": "r-1" }

# 5) KRITIS — hit URL PUBLIK backend langsung dengan identitas palsu.
curl -i -H "X-User-Id: admin" -H "X-Roles: pegawai-disdamkar" \
  https://sampah.pangkalpinangkota.go.id/reports/mine
# Diharapkan: 401 ("not via gateway") jika Pattern 2 ter-wire, ATAU
#             connection refused / timeout jika firewall Pattern 1 aktif.
# 200 di sini berarti KEDUA lockdown hilang. JANGAN roll out sebelum diperbaiki.
```

Test langkah 5 adalah yang membuktikan chain-nya sehat. Jika curl
spoofed-header dari laptop Anda berhasil, seluruh model identitas
dapat di-bypass — baik chain JWT maupun role gate tidak ada artinya.

#### Jebakan khusus §9.6

| Gejala | Penyebab | Solusi |
|---|---|---|
| `502 Bad Gateway` langsung di setiap request | DNS tidak resolve di dalam container Kong | `docker compose exec kong getent hosts sampah.pangkalpinangkota.go.id`. Jika kosong, tambahkan `dns: [1.1.1.1, 8.8.8.8]` ke blok compose `kong:`. |
| `502 Bad Gateway` setelah jeda | Chain TLS tidak lengkap di VPS e-sampah | `openssl s_client -showcerts` dan konfirmasi chain penuh. Reissue dengan `fullchain.pem`. |
| Semua request 401 "not via gateway" | `E_SAMPAH_GATEWAY_SECRET` mismatch antara env Kong dan env VPS e-sampah | Re-sync. Secret harus byte-identical; quote hati-hati di shell script (tidak ada trailing newline). |
| p99 antar-VPS > 200ms | Host Kong dan host e-sampah di region berbeda | Pindahkan ke region/AZ yang sama, atau terima cost-nya dan tune `BFF_INTERNAL_JWT_TTL_SECONDS` naik (di dalam cap `maximum_expiration` 600s Kong) untuk mengurangi frekuensi refresh. |
| Test direct-bypass (langkah 5) kembali 200 | Entah firewall Pattern 1 tidak menegakkan atau `gatewayGuard` tidak ter-install pertama di middleware chain | Pastikan `app.use(gatewayGuard)` berjalan sebelum route handler apapun. Pastikan `ufw status` menunjukkan `Status: active`. |
| `kong reload` tidak memuat YAML baru | DB-less Kong hanya re-read `kong.yml` saat container start | `docker compose restart kong`. |
| Rotasi secret butuh restart Kong | Ya — `{vault://env/...}` di-resolve saat startup, bukan per request | Rencanakan rotasi: dual-accept di sisi e-sampah dulu (terima lama DAN baru), flip env Kong, restart Kong, lalu drop secret lama di e-sampah. Mirror runbook rotasi key JWT di `kong/README.md`. |

---

### 9.7 `citizen-api` (Path C.1c cPanel/WHM PHP)

**Skenario.** Service PHP yang sudah ada di shared hosting cPanel di
`https://services.pangkalpinangkota.go.id/citizen-api`. AutoSSL menangani
TLS. Akun hosting dibagi dengan tenant lain; Anda dapat mengedit
`.htaccess`, `.env`, dan source PHP, tapi tidak config Apache atau
mod_security.

**Klasifikasi Path.** Path C.1c — HTTPS publik ke backend
virtual-hosted. Dua kekhawatiran ekstra dibanding §9.6:
`preserve_host: false` krusial (Apache upstream route by Host header),
dan lockdown ada di `.htaccess` alih-alih `ufw`.

#### `kong/kong.yml` — append di bawah `services:`

```yaml
- name: citizen-api
  url: https://services.pangkalpinangkota.go.id/citizen-api

  tls_verify: true
  connect_timeout: 5000
  write_timeout: 10000
  read_timeout: 15000

  routes:
    - name: citizen
      paths: [/api/citizen]
      strip_path: true
      # KRUSIAL untuk cPanel: false mengirim `Host: services.pangkalpinangkota.go.id`
      # (host URL upstream), agar Apache memilih vhost yang benar.
      # true akan mengirim edge host dan cPanel akan 404 atau route ke
      # vhost default. Default adalah false; di-pin untuk pembaca berikutnya.
      preserve_host: false

  plugins:
    - { name: correlation-id, config: { header_name: X-Request-Id, generator: uuid, echo_downstream: true } }

    - name: jwt
      config:
        key_claim_name: kid
        claims_to_verify: [exp, nbf]
        maximum_expiration: 600
        header_names: [authorization]
        cookie_names: []
        uri_param_names: []

    - name: pre-function
      config:
        access:
          - |
            -- Lua IDENTIK dengan sample-service.

    - name: request-transformer
      config:
        add:
          headers:
            - "X-Gateway-Secret:{vault://env/citizen-api-gateway-secret}"

    - name: rate-limiting
      config:
        minute: 600
        policy: local
        fault_tolerant: true
        limit_by: header
        header_name: X-User-Id

  healthchecks:
    passive:
      healthy:   { successes: 5 }
      unhealthy: { tcp_failures: 2, http_failures: 5, timeouts: 3 }
```

#### `docker-compose.yml` — env Kong

```yaml
kong:
  environment:
    CITIZEN_API_GATEWAY_SECRET: ${CITIZEN_API_GATEWAY_SECRET}
```

…dan workspace `.env`:

```bash
CITIZEN_API_GATEWAY_SECRET=<32+ byte random; rotate per kuartal>
```

#### cPanel `.htaccess` — Pattern 1 IP allowlist

Letakkan file ini di document root `citizen-api/`. Apache evaluasinya
sebelum PHP berjalan:

```apache
# /home/<user>/public_html/citizen-api/.htaccess
<RequireAll>
  Require ip <KONG_VPS_PUBLIC_IP>
  # Baris kedua opsional jika Kong punya beberapa IP egress:
  # Require ip <KONG_VPS_PUBLIC_IP_BACKUP>
</RequireAll>

# Juga nonaktifkan listing direktori, terlepas dari allowlist.
Options -Indexes

# Belt-and-braces: tolak request tanpa header gateway secret.
# RewriteCond Apache bisa short-circuit sebelum PHP load.
RewriteEngine On
RewriteCond %{HTTP:X-Gateway-Secret} ^$
RewriteRule .* - [F,L]
```

`RewriteCond` level Apache hanya cek header itu *ada* — tidak bisa
memverifikasi nilainya (tidak ada constant-time compare di rewrite rule
Apache). Guard PHP di bawah yang melakukan verifikasi sebenarnya.

#### cPanel — `.env` dan PHP guard

`.env` (di luar document root; tidak pernah web-accessible):

```bash
# /home/<user>/citizen-api-config/.env
GATEWAY_SECRET=<nilai sama dengan CITIZEN_API_GATEWAY_SECRET di workspace .env>
```

`_gateway_guard.php` — diperlukan dari setiap endpoint:

```php
<?php
// /home/<user>/public_html/citizen-api/_gateway_guard.php
declare(strict_types=1);

// Load GATEWAY_SECRET dari file env di luar docroot. getenv() PHP hanya
// mewarisi env shell di mod_php Apache jika Anda set SetEnv di .htaccess;
// pendekatan env-file di bawah lebih portable.
$envPath = '/home/<user>/citizen-api-config/.env';
$expected = '';
if (is_readable($envPath)) {
    foreach (file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match('/^GATEWAY_SECRET=(.*)$/', $line, $m)) {
            $expected = $m[1];
            break;
        }
    }
}

$presented = $_SERVER['HTTP_X_GATEWAY_SECRET'] ?? '';

if ($expected === '' || $presented === '' || !hash_equals($expected, $presented)) {
    http_response_code(401);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'not via gateway']);
    exit;
}
```

`lookup.php` — contoh endpoint:

```php
<?php
// /home/<user>/public_html/citizen-api/lookup.php
declare(strict_types=1);
require __DIR__ . '/_gateway_guard.php';

$userId    = $_SERVER['HTTP_X_USER_ID']    ?? null;
$sessionId = $_SERVER['HTTP_X_SESSION_ID'] ?? null;
$rolesCsv  = $_SERVER['HTTP_X_ROLES']      ?? '';
$roles     = array_values(array_filter(array_map('trim', explode(',', $rolesCsv))));
$requestId = $_SERVER['HTTP_X_REQUEST_ID'] ?? null;

if ($userId === null) {
    http_response_code(401);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'no identity from gateway']);
    exit;
}

// Korelasi ke log nginx/Kong/BFF.
error_log(sprintf('[%s] citizen-api lookup user=%s roles=%s',
    $requestId ?? '-', $userId, implode(',', $roles)));

header('Content-Type: application/json');
echo json_encode([
    'user'      => $userId,
    'roles'     => $roles,
    'requestId' => $requestId,
]);
```

#### Smoke test

```bash
node kong/scripts/validate.mjs
docker compose up -d --force-recreate kong

# 1) Tanpa bearer → Kong 401.
curl -i http://localhost:8080/api/citizen/lookup.php
# Diharapkan: 401 dari plugin jwt Kong.

# 2) Dengan bearer → identitas ter-inject, PHP mengembalikan user.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/api/citizen/lookup.php | jq .
# Diharapkan: 200 { "user": "<sub dari token>", "roles": [...] }

# 3) KRITIS — hit URL PUBLIK backend langsung dengan identitas palsu.
curl -i -H "X-User-Id: admin" -H "X-Roles: admin" \
  https://services.pangkalpinangkota.go.id/citizen-api/lookup.php
# Diharapkan: 401 (gateway secret hilang) atau 403 (IP tidak di allowlist).
# 200 di sini berarti KEDUA lockdown gagal. Jangan roll out.

# 4) Dari host VPS Kong (yang DIIZINKAN), tapi TANPA header secret:
ssh ops@<KONG_VPS> 'curl -i https://services.pangkalpinangkota.go.id/citizen-api/lookup.php'
# Diharapkan: 401 (RewriteCond di .htaccess menangkap X-Gateway-Secret hilang).
# Mengonfirmasi Pattern 2 tetap bekerja meski dari dalam allowlist Pattern 1.
```

#### Jebakan khusus §9.7

| Gejala | Penyebab | Solusi |
|---|---|---|
| cPanel mengembalikan HTML site yang salah | `preserve_host: true` mengirim edge host; Apache route ke vhost default | Set `preserve_host: false` (default; pin eksplisit). |
| 500 tanpa entry di log PHP | mod_security di shared hosting memblokir request | Cek log mod_security cPanel (Security → ModSecurity). Whitelist rule ID jika false positive. |
| `.htaccess` diabaikan | `AllowOverride None` di-set oleh host | Buka tiket dengan provider cPanel untuk enable `AllowOverride All` di docroot. |
| PHP tidak bisa baca file env `_gateway_guard.php` | Path salah, atau permission file menolak user PHP | `ls -la /home/<user>/citizen-api-config/.env` harus readable oleh user cPanel. `chmod 600` dan owner sama. |
| `RewriteCond` Apache tidak menangkap header yang hilang | mod_rewrite tidak enable atau rule `.htaccess` tidak loading | `a2enmod rewrite` di sisi server (host harus melakukannya); konfirmasi dengan tes wrap `<IfModule mod_rewrite.c>`. |
| `hash_equals` tidak terdefinisi | PHP < 5.6 di shared host | Minta host menaikkan versi PHP akun, atau pakai `password_verify` dengan nilai expected ter-hash sebagai workaround. |
| Test direct-bypass (langkah 3) kembali 200 | `.htaccess` ada tapi `RequireAll` tidak ditegakkan (mismatch syntax Apache 2.2 vs 2.4) | Apache 2.4 pakai `Require ip`; 2.2 pakai `Allow from`. Konfirmasi versi Apache dengan provider cPanel dan cocokkan syntax. |
| Rotasi secret butuh edit `.htaccess` | Anda inline secret di `.htaccess` | Jangan. Secret hanya ada di `.env` cPanel dan env compose Kong. `.htaccess` hanya cek presence. |

---

## Lihat juga

- [`kong/README.md`](../kong/README.md) — referensi plugin lengkap, runbook rotasi kid.
- [`docs/auth-architecture.md`](auth-architecture.md) — mengapa gateway split terlihat seperti sekarang.
- [`docs/DEPLOYMENT.md`](DEPLOYMENT.md) — deploy VPS tunggal dan TLS bootstrap.
- [`docs/diagrams/flow-data-plane-request.svg`](diagrams/flow-data-plane-request.svg) — sequence apa yang terjadi pada `/api/*`.
- [`docs/diagrams/kong-identity-injection.svg`](diagrams/kong-identity-injection.svg) — bentuk request sebelum vs setelah plugin `pre-function`.
