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
  app.set('trust proxy', 1);

  app.use(requestIdMiddleware);
  app.use(pinoHttp({ logger: log }) as unknown as RequestHandler);
  if (metrics) app.use(metricsMiddleware(metrics));
  app.use(helmet());
  if (env.CORS_ORIGINS.length > 0) {
    app.use(cors({ origin: env.CORS_ORIGINS, credentials: false }));
  }
  app.use(express.json({ limit: '64kb' }));
  app.use(express.urlencoded({ extended: false, limit: '64kb' }));

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
