# nginx Reverse Proxy — Audit Report

**Scope:** `nginx/Dockerfile`, `nginx/nginx.conf`, `nginx/conf.d/default.conf.template`,
`nginx/snippets/*.conf`, and nginx's contract with the BFF and Kong as wired in
the root `docker-compose.yml`.

**Audited at:** 2026-05-12
**nginx version under audit:** `nginx:1.27-alpine` (official image, env-template entrypoint)
**Role:** Edge reverse proxy. Terminates the public socket (currently HTTP-only),
routes `/auth/*` → BFF, `/api/*` → Kong, serves nginx-local health, and 404s
everything else.

Severity legend:

| Tag         | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| **CRITICAL**| Auth bypass, identity spoofing, or data exposure possible now. |
| **HIGH**    | Real production risk; fix before any internet exposure.        |
| **MEDIUM**  | Hardening / defense-in-depth; fix before scale.                |
| **LOW**     | Cleanup / nice-to-have; fix when convenient.                   |
| **INFO**    | Observation, no direct fix required.                           |

---

## 1. Executive Summary

The nginx layer is functionally correct for the documented edge role: routing
is clean, OAuth `code`/`state` query params are kept out of access logs, the
BFF and Kong are not exposed to the host, and per-IP rate limiting exists on
the auth endpoints as defense-in-depth on top of the BFF's own Redis-backed
limiter. The configuration is small, readable, and split sensibly between
`nginx.conf`, the env-substituted `default.conf.template`, and two snippet
files.

**However, the proxy is not production-ready as committed:**

- The TLS server block is commented out. There is no plan-of-record for how
  certs are mounted, no HTTP→HTTPS redirect, and the *example* TLS config in
  the comment block uses a weak cipher line (`HIGH:!aNULL:!MD5`) and skips
  OCSP stapling.
- Slow-client / connection-flood defenses are absent: `client_header_timeout`
  and `client_body_timeout` keep their 60 s defaults, and there is no
  `limit_conn` zone. A single IP can hold thousands of half-open connections.
- Rate limiting only covers `/auth/*`. `/api/*` (the data plane — every
  business request) is unbounded at the edge, and Kong has no rate-limit
  plugin either (per `kong/AUDIT.md`). The data plane has no DoS ceiling.
- The separate `auth-access.log` is written to a file inside the container.
  The alpine image only symlinks `access.log` and `error.log` to stdout/stderr,
  so this stream is invisible to `docker logs` and to any stdout-based log
  shipper. Across a container restart the file is lost.
- `set_real_ip_from` / `real_ip_header` are not configured. The BFF sets
  `trust proxy: 1`, which works for the single-hop dev topology but will
  silently break (or get spoofed) the moment a cloud LB / CDN is added.
- Service-name resolution for upstreams happens once at nginx start. If the
  `bff` or `kong` container is recreated with a new Docker DNS record, nginx
  will keep dialing the stale IP until reload.

There are **18 findings** below: 0 critical, 4 high, 8 medium, 5 low, 1
informational. None are exploitable as currently deployed (LAN-only, dev
host), but at least the four HIGH items must close before this proxy faces
the public internet.

---

## 1a. Fix Status — close-out 2026-05-13

Five phases of fixes have landed since this audit was written. Summary
below; per-finding details are inline in the sections that follow (search
for `**Status:**` under each heading).

| Finding | Severity | Phase | Status |
|---|---|---|---|
| §S-1  | HIGH    | 4 | DONE — TLS overlay opt-in via `NGINX_TLS_ENABLED`; Mozilla Intermediate, OCSP stapling, HSTS, h2, ACME-ready |
| §S-2  | HIGH    | 1 | DONE — slow-client timeouts + `limit_conn perip 32` |
| §S-3  | HIGH    | 1 | DONE — `api_default` zone applied to `/api/` |
| §S-4  | HIGH    | 1 | DONE — `default_server` 444 sink (both `:80` and `:443`) |
| §S-5  | MEDIUM  | 2 | DONE — `set_real_ip_from` + `real_ip_recursive` |
| §S-6  | MEDIUM  | 1 | DONE — `auth-access.log` symlinked to `/dev/stdout` |
| §S-7  | MEDIUM  | 1 | DONE — `X-Request-Id` echoed in response headers |
| §S-8  | MEDIUM  | 5 | DONE — `Permissions-Policy ()` + COOP + CORP |
| §S-9  | LOW     | 5 | DONE — 404 shape matches BFF |
| §S-10 | LOW     | 5 | DONE — global 4m, per-`/auth/*` 64k override |
| §P-1  | MEDIUM  | — | DEFERRED — explicit decision to commit to orchestrator-stable IPs (compose `container_name` today, k8s ClusterIP later); revisit when moving off compose |
| §P-2  | LOW     | 5 | DONE — `gzip_types` widened + `gzip_comp_level 5` |
| §P-3  | LOW     | 5 | DONE — `keepalive 64` + `keepalive_requests`/`keepalive_timeout` |
| §P-4  | LOW     | 5 | DONE — `proxy_next_upstream_tries 1` baked into `proxy_common.conf` |
| §M-1  | LOW     | — | DEFERRED — stylistic; the duplication is now mirrored into the TLS template too, where readability of each template in isolation is preferable |
| §M-2  | LOW     | — | DEFERRED — depends on §M-1 |
| §M-3  | LOW     | — | DEFERRED — until a second environment exists with different values |
| §M-4  | LOW     | — | DEFERRED — judgment call dependent on release cadence |
| §M-5  | LOW     | 5 | DONE — exact-match priority comment in both templates |
| §A-1  | MEDIUM  | 3 | DONE — compose healthcheck switched to `/readyz`, `/nginx-health` preserved for k8s liveness |
| §A-2  | MEDIUM  | 3 | DONE — `stub_status` on `:8081` + `nginx-prometheus-exporter:1.4.0` |
| §A-3  | MEDIUM  | 2 | DONE — BFF healthcheck + nginx `depends_on: bff: service_healthy` |
| §A-4  | LOW     | — | DEFERRED — until prod host shape is known |
| §A-5  | INFO    | 4 | ADDRESSED — `PUBLIC_BASE_URL → https` flip documented in `nginx/README.md` "Production TLS" section |

**Headline:** 4/4 HIGH closed, 3/4 remaining MEDIUM closed (§P-1 deferred),
6/11 LOW closed (5 deferred as stylistic / conditional), 1/1 INFO addressed.
Of the 24 distinct findings in this document, 18 are closed and 6 are
explicitly deferred with rationale above.

The recommended-fix-order in §7 has been annotated with each item's
close-out phase.

---

## 2. Findings — Security

### S-1 [HIGH] No TLS — `listen 443 ssl` block is commented out, no HTTP→HTTPS redirect plan

**Status:** DONE — Phase 4. Opt-in TLS overlay via `NGINX_TLS_ENABLED`; two-template approach selected at container start by `docker-entrypoint.d/15-select-tls.envsh`. TLS template (`nginx/conf.d-tls/default.conf.template`) implements ACME webroot, HTTP `/nginx-health` passthrough for kubelet, 301-redirect-everything-else, TLSv1.2/1.3 + Mozilla Intermediate ciphers, OCSP stapling with resolver, HSTS one-year (no preload), h2. Certs bind-mounted from `nginx/certs/` (gitignored); Let's Encrypt + certbot `--webroot` flow documented in `nginx/README.md`. Live-verified end-to-end with self-signed dev cert: `openssl s_client` confirmed `TLSv1.3 / TLS_AES_256_GCM_SHA384 / ALPN h2`.

**Files:** `nginx/conf.d/default.conf.template:70-80`

The only `listen` directive is `listen 80;`. The production TLS overlay is a
block-comment with placeholder paths. There is:

- no automation for mounting certs (no `certs/` volume in `docker-compose.yml`,
  no ACME companion, no documented manual flow beyond the README's
  "uncomment + configure"),
- no HTTP→HTTPS redirect — if and when TLS is enabled, `listen 80` will keep
  serving the API over cleartext,
- no `ssl_dhparam`, no `ssl_stapling`, no `ssl_stapling_verify`,
- the proposed `ssl_ciphers HIGH:!aNULL:!MD5` line is a 2012-era recipe that
  still allows weak ciphers (e.g. 3DES, plain CBC with SHA1) on TLSv1.2; it
  does not match Mozilla's current Intermediate profile,
- HSTS is `max-age=31536000; includeSubDomains` — fine in scope, but no
  `preload` and no documented submission to the HSTS preload list,
- no `ssl_session_tickets off;` justification or rotation strategy beyond
  the bare directive.

**Fix:** treat the TLS block as code, not a comment. Concretely:

1. Mount certs from `nginx/certs/` (already in `.gitignore`) via a compose
   volume and document the source (Let's Encrypt via `certbot --webroot`
   served from a dedicated `/.well-known/acme-challenge/` location, or
   pre-issued PKI).
2. Replace the TLS-config comment with a real `server` block, and add a
   second `server { listen 80; return 301 https://$host$request_uri; }`
   alongside it (keeping `/.well-known/acme-challenge/` excluded from the
   redirect when ACME is in use).
3. Use Mozilla Intermediate cipher list verbatim. Enable OCSP stapling.
   Generate or mount `ssl_dhparam` ≥ 2048 bits (or rely on the built-in
   ECDHE curves and drop dhparam entirely).
4. Enable `http2` (and consider `http3` / QUIC) on the 443 block.
5. Document cert renewal in `nginx/README.md` — currently the README ends
   at "uncomment the TLS block".

### S-2 [HIGH] No slow-client / slowloris defenses — `client_header_timeout` / `client_body_timeout` keep 60 s defaults; no `limit_conn`

**Status:** DONE — Phase 1. `nginx.conf` now sets `client_header_timeout 10s`, `client_body_timeout 10s`, `send_timeout 10s`, `reset_timedout_connection on`, and declares `limit_conn_zone $binary_remote_addr zone=perip:10m`. Server blocks (both HTTP and TLS templates) apply `limit_conn perip 32`.

**Files:** `nginx/nginx.conf` (missing), `nginx/conf.d/default.conf.template` (missing)

Neither `nginx.conf` nor the server block tightens the slow-client surface:

- `client_header_timeout` defaults to **60 s** — a single IP can hold a
  connection open for a full minute sending one byte of header at a time.
- `client_body_timeout` defaults to **60 s** — same trick on the body.
- `send_timeout` defaults to **60 s**.
- There is no `limit_conn_zone` / `limit_conn` directive. Per-IP connection
  count is unbounded.

`worker_connections 4096` × `worker_processes auto` is a lot of slots to
exhaust at 60-second cost per slot.

**Fix:** in `nginx.conf`:

```nginx
client_header_timeout 10s;
client_body_timeout   10s;
send_timeout          10s;
reset_timedout_connection on;

limit_conn_zone $binary_remote_addr zone=perip:10m;
```

…and in the `server` block: `limit_conn perip 32;` (tune to expected fan-out;
mobile typically opens 4–6 concurrent connections per host).

### S-3 [HIGH] `/api/*` has no edge rate limit — entire data plane is unbounded

**Status:** DONE — Phase 1. New `api_default` zone (`100r/s`) declared in `nginx.conf`; applied to `location /api/` as `limit_req zone=api_default burst=200 nodelay` in both HTTP and TLS templates. Kong-side per-route limits remain a separate defense-in-depth layer tracked in `kong/AUDIT.md` P-3.

**Files:** `nginx/conf.d/default.conf.template:59-62`

`limit_req` zones (`auth_token`, `auth_default`) are only applied to the
`/auth/*` block. The `/api/` proxy_pass to Kong has no `limit_req` at all,
and Kong itself runs without a rate-limiting plugin (see `kong/AUDIT.md`
P-3). Since the data plane is the high-volume path ("every business request"
per `docs/auth-architecture.md`), the actual DoS ceiling is Kong's worker
queue depth — not a numeric limit anyone has set on purpose.

**Fix:** add a third zone — global per-IP, generous — and apply it at the
`/api/` location:

```nginx
limit_req_zone $binary_remote_addr zone=api_default:10m rate=100r/s;
...
location /api/ {
    limit_req zone=api_default burst=200 nodelay;
    ...
}
```

Pair this with the §S-2 `limit_conn` zone so the two limits (connection
count and request rate) compose. Keep Kong-side per-route limits as a
later defense-in-depth layer (`kong/AUDIT.md` P-3).

### S-4 [HIGH] Wrong-Host requests are served by the first server block — no `default_server` sink

**Status:** DONE — Phase 1 (HTTP) + Phase 4 (TLS). Default-server `444` sink added at the top of both templates. In the TLS template the sink listens on both `:80 default_server` and `:443 ssl default_server` so a wrong-Host request over TLS also dies before any routing rule fires. Live-verified: `curl -H "Host: evil.example" https://localhost:8443/anything` returns connection-closed (code 000).

**Files:** `nginx/conf.d/default.conf.template:11-15`

Only one `server` exists, with `server_name ${NGINX_SERVER_NAME}`. nginx
treats the first/only server as the default for any Host that doesn't
match, so a request with `Host: attacker.example` is still routed through
this server, picks up `X-Forwarded-Host: attacker.example`, and reaches the
BFF where the OAuth callback URL is partially derived from request context.
The BFF defends itself via `PUBLIC_BASE_URL`, but the proxy should not
forward unauthorized hosts in the first place.

**Fix:** add a default-server sink that closes the connection without a
response (444 is nginx-only and emits no bytes):

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
```

(Mirror this for the TLS block when §S-1 lands.) The current "real" server
keeps its `server_name ${NGINX_SERVER_NAME}` so only requests with the
expected Host reach the routing rules.

### S-5 [MEDIUM] `set_real_ip_from` / `real_ip_header` not configured — client IP is whatever the client says it is the moment a layer is added in front of nginx

**Status:** DONE — Phase 2. `nginx.conf` declares `set_real_ip_from` for `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `127.0.0.1/32`; `real_ip_header X-Forwarded-For`; `real_ip_recursive on`. A note in the same block reminds future-us to bump `bff/src/app.ts` `trust proxy` to the number of trusted hops when an LB lands in front (BFF behind LB + nginx = 2).

**Files:** `nginx/nginx.conf` (missing), `nginx/snippets/proxy_common.conf:5`

`proxy_common.conf` sets `X-Forwarded-For` via `$proxy_add_x_forwarded_for`,
which **appends** `$remote_addr` to whatever the client sent. Today this is
fine because nginx is the only hop and the BFF's `trust proxy: 1` correctly
unwraps that one layer (`bff/src/app.ts:30`). The moment a cloud LB or CDN
is added in front, nginx's `$remote_addr` becomes the LB's IP and the
client-controlled XFF prefix is forwarded verbatim — and Express's
`trust proxy: 1` will trust the wrong entry.

It also means nginx's per-IP rate limit (`$binary_remote_addr`, the TCP
peer) collapses to the LB's IP and gives every external client the same
counter.

**Fix:** declare the trusted proxy CIDR(s) in `nginx.conf`:

```nginx
set_real_ip_from 10.0.0.0/8;   # adjust to your LB / VPC CIDR
set_real_ip_from 172.16.0.0/12;
real_ip_header   X-Forwarded-For;
real_ip_recursive on;
```

…and bump the BFF's `trust proxy` from `1` to the number of trusted hops
in production (BFF behind LB+nginx = `2`). Without this, both the nginx
rate limiter and the BFF's IP-based rate limiter become ineffective behind
any front-end.

### S-6 [MEDIUM] `auth-access.log` is written to a file inside the container — not on stdout, lost on restart, invisible to `docker logs`

**Status:** DONE — Phase 1. Dockerfile now runs `ln -sf /dev/stdout /var/log/nginx/auth-access.log` so the stream reaches `docker logs` and any stdout-based log shipper. The structural separation (`/auth/*` on its own access_log directive, with `$args` still excluded) is preserved.

**Files:** `nginx/conf.d/default.conf.template:28,36,42`

Three `/auth/*` locations write to `/var/log/nginx/auth-access.log`. The
official `nginx:alpine` image only symlinks `access.log` → `/dev/stdout`
and `error.log` → `/dev/stderr`. `auth-access.log` is a plain file in the
container's writable layer:

- not picked up by Docker / Kubernetes stdout collectors,
- lost on every container recreation,
- grows unbounded without log rotation,
- the README ("Logging" section) claims `/auth/*` is on a "separate stream"
  — technically true, but the stream sinks into `/dev/null` of operations.

The whole point of separating `/auth/*` logs (drop `$args` so OAuth `code`
never lands on disk) is undone by losing the stream entirely.

**Fix:** either (a) symlink the file to stdout in the Dockerfile
(`ln -sf /dev/stdout /var/log/nginx/auth-access.log`), or (b) drop the
separate log entirely and rely on a `map` to attach a `log_class=auth`
field to `main` while still filtering `$args`. Option (a) is one line in
the Dockerfile and keeps the structural separation:

```dockerfile
RUN ln -sf /dev/stdout /var/log/nginx/auth-access.log
```

### S-7 [MEDIUM] No `X-Request-Id` echoed back to the client — clients can't correlate

**Status:** DONE — Phase 1. `add_header X-Request-Id $request_id always;` added to `snippets/security_headers.conf`, so the header lands on 2xx/4xx/5xx responses alike. Verified live: `curl -i http://localhost:8080/nginx-health` shows `X-Request-Id: <16-byte hex>`.

**Files:** `nginx/snippets/proxy_common.conf:8`

nginx generates `$request_id` and forwards it upstream as `X-Request-Id`
(good — the BFF picks it up via pino-http). But it is not echoed back to
the client in the response, so a mobile client logging an error has no
correlation handle to give a backend engineer.

**Fix:** add to the server block (or a snippet):

```nginx
add_header X-Request-Id $request_id always;
```

(Also add `$request_id` to the BFF's response headers if it isn't there
already — check `bff/src/middleware/requestId.ts`.)

### S-8 [MEDIUM] Security-headers snippet is minimal; missing `Permissions-Policy`, `Cross-Origin-Opener-Policy`, no nosniff on error pages

**Status:** DONE — Phase 5. `security_headers.conf` extended with `Permissions-Policy` (full-feature deny list), `Cross-Origin-Opener-Policy: same-origin`, and `Cross-Origin-Resource-Policy: same-origin`. All headers use the `always` pattern so they reach 4xx/5xx responses too. HSTS still lives in the TLS server block only (added in Phase 4).

**Files:** `nginx/snippets/security_headers.conf`

Currently sets: `X-Content-Type-Options nosniff`, `X-Frame-Options DENY`,
`Referrer-Policy no-referrer`. Reasonable starting set for an API edge,
but for parity with `helmet()` in the BFF (`bff/src/app.ts:35`) and for
defense-in-depth on responses nginx itself emits (the 404 JSON, the
`/nginx-health` body), worth adding:

- `Permissions-Policy: ()`  — deny all powerful features by default.
- `Cross-Origin-Opener-Policy: same-origin` — irrelevant for an API
  consumed by mobile, but cheap.
- `Cross-Origin-Resource-Policy: same-origin` — blocks cross-site embedding
  of `/auth/me` etc.
- (Production-TLS only) `Strict-Transport-Security` is already in the
  TLS-overlay comment; carry that through to the real config in §S-1.

The current `add_header ... always;` ensures the headers reach 4xx/5xx
responses too — good. Keep that pattern for the new headers.

### S-9 [LOW] `proxy_intercept_errors off` lets upstream error bodies through verbatim — fine for a JSON API, but unify the 404 shape

**Status:** DONE — Phase 5. nginx's catch-all `location /` now returns `{"error":"not_found","error_description":"Route not found"}` in both HTTP and TLS templates — same envelope as the BFF.

**Files:** `nginx/snippets/proxy_common.conf:17`, `nginx/conf.d/default.conf.template:65-68`

The default 404 from nginx is `{"error":"not_found"}`. The BFF emits
`{"error":"not_found","error_description":"Route not found"}`. The shapes
differ by one field. Trivial, but if a contract test asserts on the BFF
shape and gets the nginx one for an unknown route, it will fail
mysteriously.

**Fix:** match the BFF shape in `default.conf.template:67`:

```nginx
return 404 '{"error":"not_found","error_description":"Route not found"}';
```

### S-10 [LOW] `client_max_body_size 64k` applies to `/api/*` too — any future file-upload route breaks at the edge

**Status:** DONE — Phase 5. `client_max_body_size` removed from `proxy_common.conf`. `nginx.conf` sets a generous `4m` global default; each `/auth/*` location overrides it back down to `64k` explicitly. Live-verified: 100 KB POST to `/auth/anything` → 413; same body to `/api/anything` → 200.

**Files:** `nginx/snippets/proxy_common.conf:15`

The 64 kB cap is right-sized for `/auth/*` (token payloads, profile JSON)
but `proxy_common.conf` is also included by `/api/`. The day Kong gets a
route that takes an upload (photo upload, document upload), nginx will
413 it before Kong sees it, and the error won't be obvious to whoever is
writing the upload service.

**Fix:** lift `client_max_body_size` out of the common snippet and set it
per-location: 64 k for the `/auth/*` locations, a larger value (e.g.
4 m) for `/api/`. Or set the global default to something generous and
tighten per-`/auth/*` location.

---

## 3. Findings — Performance

### P-1 [MEDIUM] Upstreams resolve once at startup — recreated `bff` / `kong` container = stale IP until nginx reload

**Status:** DEFERRED — explicit decision. Current deployment is docker-compose with `container_name`, where IPs stay stable across restarts; on the planned k8s migration, ClusterIP Service addresses are stable per-Service. The `resolver` + variable `proxy_pass` alternative loses upstream `keepalive`, so we'd rather pay the cost only if we actually move to a substrate where pod IPs churn (Nomad, raw k8s endpoints, ECS). Revisit when the deployment substrate is decided.

**Files:** `nginx/conf.d/default.conf.template:1-9`

`upstream bff { server bff:3000; }` resolves `bff` once when nginx starts.
If the BFF container is recreated (compose up after a `down`, k8s pod
restart with a new IP), nginx keeps the old IP cached and 502s until the
nginx container itself is restarted or reloaded. The same applies to Kong.

In Docker Compose with `container_name`, IPs tend to stay stable across
restarts — so this is mostly invisible in dev. In any orchestrator where
pod IPs change (k8s, Nomad, ECS) it is a real availability bug.

**Fix (open-source nginx, no plus):** drop the named `upstream` block for
upstreams that need DNS-resolved-per-request semantics and use a `resolver`
+ variable in `proxy_pass`:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;   # docker embedded DNS

location /auth/ {
    ...
    set $bff_upstream bff:3000;
    proxy_pass http://$bff_upstream;
}
```

Trade-off: this disables `keepalive` to the upstream (no `upstream {}` block
to hold pooled connections). For BFF traffic volume the latency hit is
small; if it matters, the orchestrator-stable-IP approach (k8s Service
ClusterIP) is the better answer.

### P-2 [LOW] `gzip_types` omits common JSON variants — `application/problem+json`, `application/vnd.api+json`, charset-suffixed types

**Status:** DONE — Phase 5. `gzip_types` in `nginx.conf` widened to include `application/problem+json` and `application/vnd.api+json` (plus the original set). `gzip_comp_level 5` added — negligible CPU at our traffic shape, real bandwidth saving on JSON.

**Files:** `nginx/nginx.conf:47`

`gzip_types application/json` matches the bare type. `Content-Type:
application/json; charset=utf-8` from Express **does** match (nginx
normalizes), but `application/problem+json` (RFC 7807, used by some error
responses) and `application/vnd.api+json` do not.

**Fix:** widen the list:

```nginx
gzip_types text/plain text/css text/xml
           application/json application/problem+json application/vnd.api+json
           application/javascript application/xml application/xml+rss;
```

Also consider `gzip_comp_level 5` (default 1) — JSON compresses well and
the CPU cost is negligible at this traffic shape.

### P-3 [LOW] `keepalive 16` to BFF/Kong may be undersized at sustained load

**Status:** DONE — Phase 5. Both upstream blocks (HTTP and TLS templates) now declare `keepalive 64; keepalive_requests 1000; keepalive_timeout 60s;`.

**Files:** `nginx/conf.d/default.conf.template:3,8`

16 pooled connections per worker × N workers = N×16 idle connections to
each upstream. Mobile traffic is bursty; the warm pool depletes quickly
under spike and nginx falls back to opening new TCP connections per
request. Not a correctness issue, just measurable p99 latency.

**Fix:** bump to `keepalive 64` (or 128) and consider `keepalive_requests
1000;` + `keepalive_timeout 60s;` inside each upstream block once you have
a sense of steady-state traffic.

### P-4 [LOW] No `proxy_next_upstream` policy — single-replica today but reads as a future foot-gun

**Status:** DONE — Phase 5. `proxy_common.conf` declares `proxy_next_upstream error timeout http_502 http_503 http_504` and `proxy_next_upstream_tries 1` as the safe default for every upstream-routed location. The day a second BFF replica lands, POST `/auth/token` won't double-execute. `/api/` can opt into a higher retry budget per-location later if idempotent reads dominate.

**Files:** `nginx/snippets/proxy_common.conf` (missing)

With one upstream server per pool, the default
`proxy_next_upstream error timeout` policy is a no-op (nothing to retry
to). The day someone adds a second `server bff:3000` line for HA, nginx
will silently retry POST `/auth/token`, POST `/auth/refresh`, POST
`/auth/logout` on the second replica when the first 5xxs — which can
double-execute non-idempotent auth ceremonies (e.g. mint two `bffcode`
records for one login).

**Fix:** be explicit now to lock in the safe default:

```nginx
proxy_next_upstream error timeout http_502 http_503 http_504;
proxy_next_upstream_tries 1;     # don't retry POSTs to /auth/*
```

For `/api/` (idempotent reads dominate) a higher `_tries` is fine — split
the snippet or override per-location.

---

## 4. Findings — Maintainability

### M-1 [LOW] Three near-identical `/auth/*` blocks differ only in rate-limit zone

**Status:** DEFERRED — judgment-call shift after Phase 4. The duplication is now mirrored into the TLS template (`conf.d-tls/default.conf.template`), and the explicit per-location `client_max_body_size` from §S-10 made each block slightly less uniform anyway. Each template is intentionally readable in isolation (no chasing snippets to understand what `/auth/token` does), which has become the more useful property. Revisit if a fourth `/auth/*` variant is added.

**Files:** `nginx/conf.d/default.conf.template:26-45`

```
location /auth/         { limit_req zone=auth_default ...; include proxy_common.conf; proxy_pass http://bff; }
location = /auth/token  { limit_req zone=auth_token  ...; include proxy_common.conf; proxy_pass http://bff; }
location = /auth/refresh{ limit_req zone=auth_token  ...; include proxy_common.conf; proxy_pass http://bff; }
```

Each block also repeats `access_log /var/log/nginx/auth-access.log main;`.
The duplication is mild today, but every reviewer has to read three
near-identical blocks and confirm the only difference is the zone name.

**Fix (optional):** extract the shared body into
`snippets/proxy_bff_auth.conf`:

```nginx
# snippets/proxy_bff_auth.conf
access_log /var/log/nginx/auth-access.log main;
include /etc/nginx/snippets/proxy_common.conf;
proxy_pass http://bff;
```

…then each location is two lines (`limit_req ...; include ...;`). Pure
readability — doesn't change behavior. If it makes the file harder to
search for `proxy_pass`, leave it alone.

### M-2 [LOW] Snippets directory contains two files, both small — folder may not earn its keep

**Status:** DEFERRED — depends on §M-1 (not adopted). The two snippets remain; both grew slightly in Phase 5 (security_headers gained three headers, proxy_common gained the retry policy), so the "folder doesn't earn its keep" argument has weakened a little.

**Files:** `nginx/snippets/proxy_common.conf`, `nginx/snippets/security_headers.conf`

This is a stylistic call. The two snippets together are < 20 lines and are
each used at exactly one place (`security_headers`) or 5 places
(`proxy_common`). Inlining `security_headers.conf` into the server block
removes one layer of indirection at the cost of three lines duplicated.

**Recommendation:** leave as-is *if* §M-1 adds a third snippet
(`proxy_bff_auth.conf`) — three snippets is enough to justify the folder.
If §M-1 isn't adopted, consider inlining `security_headers.conf`.

### M-3 [LOW] Only `NGINX_SERVER_NAME` is env-substituted — every other knob requires a config edit + rebuild

**Status:** PARTIAL / DEFERRED. Phase 4 added `NGINX_TLS_ENABLED`, `NGINX_TLS_CERT_PATH`, `NGINX_TLS_KEY_PATH`, `NGINX_TLS_TRUSTED_CHAIN_PATH` as env-controlled knobs for the TLS overlay. The remaining audit suggestion (rate-limit rates, upstream addresses, canary deploy hooks) is still deferred until a second environment exists with different values.

**Files:** `nginx/Dockerfile:8`, `nginx/conf.d/default.conf.template:14`

The template-driven config is set up for env substitution (the alpine image
runs `envsubst` over `*.template`), but only `${NGINX_SERVER_NAME}` uses it.
Rate-limit rates, upstream addresses, and the listen port are all hard-coded.

For a single deployment, hard-coding is fine. For an environment matrix
(dev / staging / prod with different rate limits, or for canary deploys
that route to a different `bff_canary:3000`), more `${}` placeholders pay
off. Defer until a second environment exists.

### M-4 [LOW] Dockerfile pins `nginx:1.27-alpine` by tag, not by digest

**Status:** DEFERRED — judgment call dependent on release cadence. Pin by digest when the project has a release / audit cadence that wants reproducible builds; leave on the floating tag for free CVE-patch absorption otherwise. Re-evaluate when the project moves out of active development.

**Files:** `nginx/Dockerfile:1`

`nginx:1.27-alpine` is a moving tag — the image behind it changes when
nginx ships a patch release (1.27.x → 1.27.y) or when the alpine base
upgrades. Most of the time this is desirable (free CVE patches); occasionally
it produces an unreproducible build.

**Recommendation:** if you have a release / audit cadence, pin by digest
(`FROM nginx:1.27-alpine@sha256:...`) and bump deliberately. Otherwise the
floating tag is fine.

### M-5 [LOW] No comment in `default.conf.template` explaining why `/auth/token` and `/auth/refresh` are `location =` exact matches

**Status:** DONE — Phase 5 (HTTP template) and Phase 4 (TLS template, which was written from scratch with the comment in place). Both templates now carry an explanatory comment that `location =` exact-match has higher priority than the `/auth/` prefix above.

**Files:** `nginx/conf.d/default.conf.template:34,40`

A future reader sees `/auth/` (prefix) and then two `location =` exact
matches and reasonably wonders whether the prefix rule should win first.
The answer (exact-match `=` has higher priority than prefix in nginx) is
obvious to anyone who knows nginx; a one-line comment makes it obvious to
everyone.

**Fix:** add a comment above the first `=` block: `# Tighter limit on the
high-cost auth endpoints. Exact-match wins over the /auth/ prefix above.`

---

## 5. Findings — Architecture / Production Readiness

### A-1 [MEDIUM] nginx healthcheck only proves nginx is up — readiness of upstreams is invisible to the orchestrator

**Status:** DONE — Phase 3. Compose `nginx` healthcheck switched from `/nginx-health` → `/readyz` so `service_healthy` reflects the full edge path (nginx → BFF → Redis + KC discovery). `/nginx-health` is preserved as the future k8s liveness endpoint; the split is documented in `nginx/README.md` "Health probes". The TLS template explicitly keeps `/nginx-health` on plain `:80` so the kubelet doesn't need a cert.

**Files:** `docker-compose.yml:14-18`, `nginx/conf.d/default.conf.template:19-23`

The compose healthcheck hits `/nginx-health`, which is a static `return 200`
inside nginx. It says nothing about the BFF or Kong being reachable. A
proper readiness probe should fail when the BFF is down, so the
orchestrator can stop sending traffic to that nginx instance (or restart
it).

The BFF has a real `/readyz` (checks Redis, KC discovery). nginx already
proxies it. The cheapest fix is to point the compose healthcheck at
`/readyz` for readiness, and keep `/nginx-health` as the liveness probe.

**Fix:** split the probes — liveness on `/nginx-health` (current),
readiness via a second container-level healthcheck or via the orchestrator
config that hits `/readyz`. In k8s these are two separate probes.

### A-2 [MEDIUM] No nginx-side metrics — `stub_status` is off, no Prometheus exporter

**Status:** DONE — Phase 3. Internal `server { listen 8081; }` exposes `/nginx-status` with `stub_status`, ACL-restricted to docker bridge (`172.16.0.0/12`) + loopback. The `nginx-exporter` service (image `nginx/nginx-prometheus-exporter:1.4.0`, pinned) was added to `docker-compose.yml` and scrapes via the docker network. Neither the stub_status listener nor the exporter publishes a host port. Live-verified: `nginx_up 1`, real `nginx_http_requests_total` counters scraped end-to-end.

**Files:** `nginx/nginx.conf` (missing)

The BFF exports `/metrics` via prom-client (gated by `METRICS_ENABLED`).
Kong has no metrics either (per `kong/AUDIT.md` M-1). nginx is the only
component that sees every request at the edge — connection counts, request
rates, 4xx/5xx breakdown, upstream latency — and it exports none of this.

For SRE alerting on edge issues (sudden 502 spike, slow-client flood,
TLS handshake errors once §S-1 lands) you need either:

- `stub_status` on a private listener (port 8081 bound to 127.0.0.1) +
  `nginx-prometheus-exporter` sidecar, or
- the `ngx_http_stub_status_module` + a scraping job, or
- switch the base image to `nginx-with-vts` for richer per-location stats.

**Fix:** the minimum viable change is `stub_status` on a private port:

```nginx
server {
    listen 127.0.0.1:8081;
    location = /nginx-status {
        stub_status;
        access_log off;
    }
}
```

…and add the prom exporter to compose. Block the listener from external
reach (it already is, by binding to loopback).

### A-3 [MEDIUM] `depends_on: bff: service_started` — nginx may accept traffic before BFF is ready

**Status:** DONE — Phase 2. BFF service now has a `wget -qO- http://localhost:3000/healthz` healthcheck (5s interval, 10s start_period). nginx's `depends_on.bff` flipped from `service_started` to `service_healthy`. Kong's healthcheck was already in place. Live-verified: `Container super-app-bff Healthy` before nginx starts.

**Files:** `docker-compose.yml:5-9`

`service_started` only waits for the BFF container to *exist*, not for the
BFF Express app to be listening on :3000. During the first second of a
compose-up, requests routed to `/auth/*` will 502. The BFF has no
healthcheck in compose, so there's nothing to wait on.

**Fix:** add a BFF healthcheck (it has `/healthz` and `/readyz` already):

```yaml
bff:
  ...
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:3000/healthz"]
    interval: 5s
    timeout: 3s
    retries: 5
nginx:
  depends_on:
    bff:
      condition: service_healthy   # was: service_started
    kong:
      condition: service_healthy
```

Kong needs its own healthcheck too (currently missing — `kong/AUDIT.md`
covers this).

### A-4 [LOW] `worker_rlimit_nofile 65535` × `worker_connections 4096` may exceed FD budget on small hosts

**Status:** DEFERRED — until prod host shape is known. The audit's recommendation depends on knowing the production CPU count, and the project hasn't decided between a small edge box and a larger orchestrator-managed pool. Re-tune when that decision lands.

**Files:** `nginx/nginx.conf:2,5`

`worker_processes auto` is "one per CPU". A 16-core host with 4096
connections/worker = 65k FDs needed, which matches `worker_rlimit_nofile`.
A 32-core host overflows — workers silently cap at the rlimit. Not a
correctness problem; the numbers should be calibrated to your real
deployment shape.

**Fix:** when the production host shape is known, set `worker_processes`
explicitly (`worker_processes 4;` or so) instead of `auto`. For a typical
2–4 vCPU edge box, 4096 connections × 4 workers = 16k — well within
65k FDs.

### A-5 [INFO] OAuth `code` over HTTP in dev (`PUBLIC_BASE_URL=http://...`)

**Status:** ADDRESSED — Phase 4. The `nginx/README.md` "Production TLS / Enable" section explicitly lists `PUBLIC_BASE_URL=https://...` and the Keycloak Valid Redirect URI update as part of the production flip. No code change in this audit's scope; the operational checklist is documented.

**Files:** `.env.example:16`, `docker-compose.yml:35`

`PUBLIC_BASE_URL` defaults to `http://10.0.2.2:8080` so the Keycloak
`code` lands at an HTTP URL during dev. This is a documented dev-only
choice — the README is clear that production needs `https://...` and a
matching Keycloak valid-redirect entry — and the `code` is single-use and
short-TTL anyway. **No fix; flagged for the §S-1 production checklist:
flipping nginx to TLS is *also* the moment to flip `PUBLIC_BASE_URL` to
HTTPS and update the Keycloak client.**

---

## 6. What's Already Good

Worth recording so the next refactor doesn't undo it:

- **`$args` deliberately excluded from `log_format main`** — keeps OAuth
  `code` and `state` query params off disk. The README explains it. Don't
  add `$args` back without a careful look.
- **`server_tokens off` + `app.disable('x-powered-by')`** — version
  fingerprinting suppressed on both layers.
- **Per-IP rate-limit zones distinct for `auth_token` (10 r/s) vs
  `auth_default` (30 r/s)** — token-mint endpoints are correctly identified
  as the high-cost path and limited more aggressively.
- **`X-Request-Id` from nginx's `$request_id` threaded into the BFF's
  pino logger** — log correlation works end-to-end. Carry this through
  Kong (§Kong P-2) for full coverage.
- **BFF and Kong are not exposed to the host** — only nginx publishes a
  port. The trust boundary in `docker-compose.yml` matches the auth
  architecture doc.
- **Snippet structure** — `proxy_common.conf` and `security_headers.conf`
  are short, single-purpose, and reused. Easy to audit at a glance.

---

## 7. Recommended Fix Order

If working through this audit, this ordering balances impact vs. risk of
breakage. Items already covered by the BFF / Kong audits are out of scope
here.

**Close-out annotation:** each step's actual landing phase is shown in `[…]`.

1. **§S-2** — slow-client timeouts + `limit_conn`. One-line wins, no
   behavioral change for well-behaved clients. **[Phase 1 — DONE]**
2. **§S-4** — `default_server` 444 sink. Defensive, no impact on real
   traffic. **[Phase 1 — DONE]**
3. **§S-3** — `/api/*` rate limit zone. Pick a generous initial number;
   tighten after observing real traffic. **[Phase 1 — DONE]**
4. **§S-6** — symlink `auth-access.log` to stdout. One Dockerfile line.
   **[Phase 1 — DONE]**
5. **§A-3** — BFF healthcheck + `condition: service_healthy`. Removes a
   class of "first-second-after-up" 502s. **[Phase 2 — DONE]**
6. **§S-7** — echo `X-Request-Id`. One line; pays for itself the first
   time mobile reports an error. **[Phase 1 — DONE]**
7. **§S-5** — `set_real_ip_from` / `real_ip_header`. Do this *before* the
   first time anything is fronted by an LB. **[Phase 2 — DONE]**
8. **§P-1** — `resolver` for upstreams *or* commit to orchestrator-stable
   IPs. Pick one explicitly. **[DEFERRED — committed to stable-IP path
   for compose / k8s ClusterIP; see §P-1 for rationale]**
9. **§A-2** — `stub_status` + prometheus exporter. Enables alerting before
   §S-1 (which adds new failure modes worth alerting on). **[Phase 3 — DONE]**
10. **§S-1** — full TLS production overlay. Largest change, should not
    happen until the prerequisites above are in. **[Phase 4 — DONE]**

**Phase 5** (cleanup-day) landed the remaining LOW items that don't gate
production but were cheap enough to close: §S-8, §S-9, §S-10, §P-2, §P-3,
§P-4, §M-5. The deferrals (§M-1/2/3/4 stylistic / conditional, §A-4
host-shape-dependent) are documented inline above.

---

## 8. Out of Scope

Filed elsewhere or not nginx's responsibility:

- TLS to the BFF / Kong (internal hop). Today everything inside the compose
  network is HTTP. Whether to add mTLS between nginx ↔ BFF / Kong is a
  trust-boundary decision; if the container network is trusted, leaving it
  HTTP is fine. Revisit if nginx and BFF end up on different hosts.
- WAF / ModSecurity. The vanilla nginx image has no ModSecurity. Adding it
  is a separate decision (operational cost vs. attack surface reduction).
- DDoS protection beyond `limit_req` / `limit_conn`. That layer belongs
  upstream of nginx (Cloudflare / cloud LB DDoS protection / fail2ban).
- BFF-side rate limiting (`bff/src/middleware/rateLimit.ts`) — already
  Redis-backed and audited as part of the BFF improvement plan §3.5.
- Kong's contribution to the data-plane rate limit — see `kong/AUDIT.md`
  P-3. Edge-side limit (§S-3 above) is the first layer; Kong's per-route
  plugin is the second.
