# nginx — edge reverse proxy

Sits in front of the BFF and (eventually) Kong. The BFF is **not** exposed to
the host directly; it's only reachable through nginx.

## Routing

| Path | Upstream | Notes |
|---|---|---|
| `/auth/*` | `bff:3000` | All Keycloak-mediated auth flows |
| `/api/*` | `kong:?` | Currently stubbed by `traefik/whoami` in dev |
| `/healthz`, `/readyz` | `bff:3000` | Proxied; reports BFF + Redis state |
| `/nginx-health` | nginx itself | Liveness without touching upstreams |
| anything else | `404` | This is an API edge, not a web host |

## Files

```
nginx.conf                          # main process config + log_format + rate-limit zones
conf.d/
  default.conf.template             # HTTP-only server block (default)
conf.d-tls/
  default.conf.template             # TLS-enabled variant (selected by entrypoint)
snippets/
  proxy_common.conf                 # shared proxy_set_header / timeouts / buffering
  security_headers.conf             # X-Content-Type-Options, X-Frame-Options, X-Request-Id, ...
docker-entrypoint.d/
  15-select-tls.envsh               # swaps in the TLS template when NGINX_TLS_ENABLED=true
certs/                              # bind-mount target for fullchain/privkey/chain PEMs (gitignored)
Dockerfile                          # FROM nginx:1.27-alpine, drops in our config
```

The official `nginx:alpine` image's entrypoint runs `envsubst` on every
`*.template` in `/etc/nginx/templates/` at container start. We use that to
inject `${NGINX_SERVER_NAME}` (and the `${NGINX_TLS_*}` paths when TLS is on).

## Build / run

Use the workspace-level `docker-compose.yml` at the repo root — it brings up
nginx + bff + redis + the kong stub together. Don't run nginx alone.

```bash
# from the repo root
docker compose up -d
curl http://localhost:8080/nginx-health   # → {"status":"ok"}
curl http://localhost:8080/healthz        # → {"status":"ok"} (proxied to BFF)
```

For the **single-VPS production deployment** flow — including the TLS opt-in,
certbot integration, firewall rules, and ops checklist — see
[`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md).

## Production TLS

TLS is **opt-in** via the `NGINX_TLS_ENABLED` env var. When off (the dev
default), nginx serves `http://localhost:8080` and ignores everything under
`nginx/certs/`. When on, `15-select-tls.envsh` swaps in the TLS template
before envsubst runs, and nginx serves:

- `:80` — `/.well-known/acme-challenge/*` (webroot) and `/nginx-health`
  (liveness). Everything else 301-redirects to HTTPS.
- `:443` — full routing, TLSv1.2/1.3 (Mozilla Intermediate ciphers), OCSP
  stapling, HSTS one year (no `preload`).

### Enable

1. Mount your certs at the host path `nginx/certs/` (bind-mounted into the
   container at `/etc/nginx/certs/`). The directory is gitignored.

   ```
   nginx/certs/
     fullchain.pem    # leaf + intermediates (what nginx serves to clients)
     privkey.pem      # private key (chmod 600)
     chain.pem        # issuer chain only — for OCSP stapling verification
   ```

2. Set in `.env`:

   ```
   NGINX_TLS_ENABLED=true
   NGINX_SERVER_NAME=api.pangkalpinangkota.go.id
   PUBLIC_BASE_URL=https://api.pangkalpinangkota.go.id
   ```

3. Add `https://<host>/auth/callback` to the Keycloak super-app-bff client's
   **Valid Redirect URIs**.

4. `docker compose up -d --build nginx`. Verify the cert chain:

   ```
   curl -vk https://localhost:8443/nginx-health 2>&1 | grep -E 'issuer|subject|TLS'
   openssl s_client -connect <host>:443 -status -servername <host> </dev/null
   # ↑ look for "OCSP Response Status: successful"
   ```

### Issue / renew certs — Let's Encrypt + certbot --webroot

The TLS template exposes `/.well-known/acme-challenge/` as a webroot under
`/var/www/certbot` (an empty directory inside the nginx container by
default). To use the standard certbot flow:

1. Add a `certbot-webroot` named volume to `docker-compose.yml` mounted into
   the nginx container at `/var/www/certbot`.
2. Run certbot in a separate container (one-shot or scheduled) mounting:
   - the same `certbot-webroot` volume at `/var/www/certbot` (writes proofs)
   - the host `./nginx/certs` directory at `/etc/letsencrypt/live/<host>`
     (or run certbot with `--cert-path` / `--key-path` overrides so it
     writes `fullchain.pem` / `privkey.pem` / `chain.pem` directly to the
     bind-mount nginx reads from).
3. After renewal, `docker compose exec nginx nginx -s reload` to pick up
   the new cert without dropping connections.

A working certbot sidecar is intentionally **not** committed here — every
deployment will want a different schedule (cron / systemd / k8s CronJob)
and email address. The nginx side is ready for it.

## Logging

- Access log is JSON to stdout (the alpine image symlinks
  `/var/log/nginx/access.log` to stdout).
- `/auth/*` is logged to a separate `auth-access.log` stream — same format,
  but the log directives intentionally omit `$args` so OAuth `code` / `state`
  values never land in logs. (Dockerfile symlinks this file to stdout too,
  so it reaches `docker logs`.)
- Every proxied request includes an `X-Request-Id` header generated by nginx
  (`$request_id`) — the BFF picks this up and threads it through pino, and
  it's also echoed back to the client so mobile can quote it when reporting
  errors.

## Health probes

Three orthogonal endpoints exist; pick the right one for the orchestrator
phase you're configuring:

| Endpoint        | What it proves                              | Use as                      |
|-----------------|---------------------------------------------|-----------------------------|
| `/nginx-health` | nginx process is up, accepting connections  | k8s **liveness** probe      |
| `/healthz`      | BFF Express app is reachable through nginx  | (intermediate)              |
| `/readyz`       | Full edge path: nginx → BFF → Redis + KC OK | k8s **readiness** probe; compose `service_healthy` |

The compose-level healthcheck on the `nginx` service hits `/readyz` so
dependents (`nginx-exporter`) only start once traffic can actually flow.
When migrating to k8s, configure liveness on `/nginx-health` and readiness
on `/readyz` as separate probes.

## Metrics

`stub_status` is exposed on `:8081` inside the nginx container with an ACL
that only permits docker-network and loopback addresses. `:8081` is **not**
mapped to a host port. The `nginx-exporter` container (image
`nginx/nginx-prometheus-exporter`) scrapes `http://nginx:8081/nginx-status`
over the docker network and exports Prometheus-format metrics on its own
`:9113`. Wire your Prometheus job to scrape the exporter (also internal —
no host port).
