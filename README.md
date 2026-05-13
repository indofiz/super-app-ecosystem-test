# Pangkal Pinang Super App — Ecosystem

Back-end stack for the Pangkal Pinang citizen super-app. Authenticates users
against the city's Keycloak SSO (`sso.pangkalpinangkota.go.id`) via a
**Backend-for-Frontend** that mints short-lived RS256 internal JWTs;
**Kong** validates those JWTs at the gateway; downstream microservices trust
Kong's verdict via signed identity headers. The Flutter mobile app never
touches Keycloak directly.

For the full architectural rationale see [`docs/auth-architecture.md`](docs/auth-architecture.md).

## Components

| Dir | What | Trust boundary |
|---|---|---|
| [`bff/`](bff/) | Express + TypeScript. Owns the OAuth/PKCE ceremony, the Keycloak `client_secret`, the internal-JWT signing key, and the Redis-backed session store. The **auth boundary**. | Only thing that talks to Keycloak. |
| [`nginx/`](nginx/) | Edge reverse proxy. TLS termination (opt-in via env), per-IP rate limits, default-server sink, ACME webroot, security headers. The **edge boundary**. | Only thing exposed to the public internet. |
| [`kong/`](kong/) | DB-less Kong. Validates BFF-minted JWTs against the matching RSA public key by `kid` and injects identity headers for upstreams. The **data-plane gateway**. | Forwards to internal services only. |
| [`services/sample-service/`](services/sample-service/) | Tiny Express service behind Kong — the reference for how a microservice reads identity from `X-User-Id` / `X-Roles` headers without any auth code of its own. | Reads identity headers; never decodes JWT. |
| [`mobile/`](mobile/) | Flutter user app. Holds `internal_jwt` + `session_id` in `flutter_secure_storage` and nothing else. | Never sees a Keycloak token or refresh token. |
| [`docs/`](docs/) | Architecture + deployment docs. | — |

## Two-plane mental model

```
╔══════════════════ AUTH PLANE (rare) ══════════════════╗
║   mobile ──► nginx ──► BFF ──► Keycloak               ║
║                         │                              ║
║                         ▼                              ║
║                       Redis  (session → refresh_token) ║
║   used for: login, refresh, logout                     ║
╚════════════════════════════════════════════════════════╝

╔══════════════ DATA PLANE (every request) ═════════════╗
║   mobile ──► nginx ──► Kong ──► sample-service        ║
║                         │                              ║
║                         └─ validates internal JWT      ║
║                            (RS256, BFF holds key,      ║
║                            Kong holds public key)      ║
║   used for: every business request                     ║
╚════════════════════════════════════════════════════════╝
```

## Quickstart — local

Requires Docker, Node 20+ for the BFF dev loop, and (optionally) Flutter for
the mobile app.

```bash
cp .env.example .env
# Fill in KC_CLIENT_SECRET from Keycloak admin → Clients → super-app-bff → Credentials.
cd bff && npm install && npm run gen:keys
# The gen:keys script prints env-paste material for the workspace .env and
# the public PEM to paste under kong/kong.yml jwt_secrets.
cd ..

docker compose up -d --build
curl http://localhost:8080/nginx-health     # → {"status":"ok"}
curl http://localhost:8080/healthz          # → {"status":"ok"}  (proxied to BFF)
curl http://localhost:8080/readyz           # → {"status":"ok", checks: {...}}
```

Mobile app: `cd mobile && cp .env.example .env && flutter pub get && flutter run`.

## Deploying to a VPS

Single-VPS deployment guide (Ubuntu LTS, Docker Compose, Let's Encrypt TLS,
UFW firewall, ops checklist): **[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)**.

## Per-component docs

- [`bff/README.md`](bff/README.md) — endpoints, env, Redis keyspace, threat model, key rotation runbook
- [`nginx/README.md`](nginx/README.md) — routing, rate-limit zones, health probes, TLS overlay, metrics
- [`kong/README.md`](kong/README.md) — JWT validation, identity injection, plugin matrix, sandbox config
- [`services/sample-service/README.md`](services/sample-service/README.md) — reference microservice
- [`mobile/README.md`](mobile/README.md) — Flutter app

## Audit & improvement docs

- [`nginx/AUDIT.md`](nginx/AUDIT.md) — 24 findings; close-out summary at the top
- [`kong/AUDIT.md`](kong/AUDIT.md) — Kong configuration audit
- [`bff/docs/IMPROVEMENT_PLAN.md`](bff/docs/IMPROVEMENT_PLAN.md) — BFF roadmap (RS256 migration, rate-limit hardening, etc.)

## License

Unspecified. Internal use only until a license is added.
