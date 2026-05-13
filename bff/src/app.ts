import cors from 'cors';
import express, { type Express, type RequestHandler } from 'express';
import helmet from 'helmet';
import type { Redis } from 'ioredis';
import { pinoHttp } from 'pino-http';
import { buildAuthRouter, type AuthRouterDeps } from './auth/router.js';
import type { Env } from './config/env.js';
import { buildHealthRouter } from './health/router.js';
import type { KeycloakClient } from './lib/keycloak.js';
import type { Logger } from './lib/logger.js';
import type { MetricsBundle } from './lib/metrics.js';
import { errorMiddleware } from './middleware/error.js';
import { metricsMiddleware } from './middleware/metrics.js';
import { requestIdMiddleware } from './middleware/requestId.js';
import { timeoutMiddleware } from './middleware/timeout.js';
import { requestContextMiddleware } from './lib/requestContext.js';
import { buildWellKnownRouter } from './wellKnown/router.js';

export interface AppDeps {
  env: Env;
  log: Logger;
  redis: Redis;
  authDeps: AuthRouterDeps;
  // Optional: tests don't need either of these.
  keycloak?: KeycloakClient;
  metrics?: MetricsBundle;
}

export const createApp = ({ env, log, redis, authDeps, keycloak, metrics }: AppDeps): Express => {
  const app = express();
  app.disable('x-powered-by');
  // AUDIT PR-9: JSON 200s don't benefit from etag; disabling keeps headers
  // predictable for the API contract and avoids accidental cache hits.
  app.disable('etag');
  // AUDIT S-3: env-driven trust-proxy so adding a second hop (Cloudflare,
  // mesh sidecar) doesn't silently make X-Forwarded-For spoofable.
  app.set('trust proxy', env.TRUST_PROXY);

  app.use(requestIdMiddleware);
  // AUDIT PR-3: pin req.id into AsyncLocalStorage so the KC HTTP client
  // can stamp outbound x-request-id without explicit threading.
  app.use(requestContextMiddleware);
  app.use(pinoHttp({ logger: log }) as unknown as RequestHandler);
  if (metrics) app.use(metricsMiddleware(metrics));
  app.use(helmet());
  if (env.CORS_ORIGINS.length > 0) {
    app.use(cors({ origin: env.CORS_ORIGINS, credentials: false }));
  }
  app.use(express.json({ limit: '64kb' }));
  // AUDIT PR-4: cap request handling time so a stalled KC upstream returns
  // a clean 504 instead of holding the inbound connection open.
  app.use(timeoutMiddleware(env.REQUEST_TIMEOUT_MS));

  app.use('/', buildHealthRouter({ redis, keycloak: keycloak ?? authDeps.keycloak, env }));
  app.use('/', buildWellKnownRouter(authDeps.internalJwtIssuer));

  // /metrics is gated by env.METRICS_ENABLED so dev/test don't expose it
  // by accident. Production deploys must additionally block the route at
  // the perimeter (nginx/Kong) — see IMPROVEMENT_PLAN §3.1.
  if (metrics && env.METRICS_ENABLED) {
    app.get('/metrics', (async (_req, res) => {
      res.set('Content-Type', metrics.registry.contentType);
      res.send(await metrics.registry.metrics());
    }) as RequestHandler);
  }

  app.use('/auth', buildAuthRouter({ ...authDeps, log: authDeps.log ?? log }));

  app.use((_req, res) => {
    res.status(404).json({ error: 'not_found', error_description: 'Route not found' });
  });

  app.use(errorMiddleware(log, metrics));

  return app;
};
