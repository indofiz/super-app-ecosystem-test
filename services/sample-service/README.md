# sample-service

Tiny Express + TypeScript service whose only job is to prove the chain works:

```
mobile → nginx /api/* → Kong (validates BFF-minted RS256 JWT) → sample-service
```

> The chain used to validate Keycloak tokens via `jwt-keycloak`; we replaced
> that with Kong's bundled `jwt` plugin verifying a BFF-issued internal JWT
> (RS256) once `bff/docs/IMPROVEMENT_PLAN.md` §2.2 landed. See `kong/README.md`
> for details.

It exposes two endpoints, reads identity from the trusted headers Kong sets
(`X-User-Id`, `X-Session-Id`, `X-Roles`), and echoes the request id from
`X-Request-Id`. The service never sees the raw Bearer — Kong strips the
`Authorization` header after validating it (see `kong/AUDIT.md` S-3).

| Method | Path | Behaviour |
|---|---|---|
| `GET` | `/`        | JSON `{service, requestId, validatedBy, identity (from X-* headers), ts}` |
| `GET` | `/health`  | JSON `{status: "ok", service}` (used by Kong/nginx upstream checks) |

External URLs (via nginx + Kong, with `strip_path: true` on the Kong route):

- `http://localhost:8080/api/profile`        → this service's `GET /`
- `http://localhost:8080/api/profile/health` → this service's `GET /health`

## Run locally

```bash
npm install
npm run dev          # tsx watch on src/index.ts
curl http://localhost:3001/health
```

The service has no auth code of its own. Don't run it exposed — Kong is the
trust boundary.

## Adding real logic

Replace `GET /` with whatever the real `/profile` endpoint should do (DB lookup
keyed by `claims.sub`, etc.). Keep the assumption that Kong has already
validated the JWT, so you can trust `claims.sub` as identity.

For the workspace-level VPS deployment story (where this service runs as
a container behind Kong), see
[`../../docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md).
