import { loadEnv } from './config/env.js';
import { createLogger } from './lib/logger.js';
import { buildMetrics } from './lib/metrics.js';
import { createRedis } from './lib/redis.js';
import { startTracing, stopTracing } from './observability/tracing.js';

const main = async () => {
  const env = loadEnv();
  const log = createLogger(env);

  // §3.1: tracing must start BEFORE the app's modules are imported, so
  // auto-instrumentations can patch http/express/axios. The dynamic import
  // below is the rest of the bootstrap.
  startTracing(env);

  const { createApp } = await import('./app.js');
  const { AuthStateStore } = await import('./auth/stores/authState.store.js');
  const { BffCodeStore } = await import('./auth/stores/bffCode.store.js');
  const { SessionStore } = await import('./auth/stores/session.store.js');
  const { InternalJwtIssuer } = await import('./lib/internalJwt.js');
  const { KeycloakClient } = await import('./lib/keycloak.js');
  const { createKeycloakJwtVerifier } = await import('./lib/keycloakJwt.js');
  const redis = createRedis(env, log);
  // Metrics bundle is always built; the /metrics route is only mounted
  // when METRICS_ENABLED. Building it unconditionally keeps the KC client
  // and handlers wired the same way in every environment.
  const metrics = buildMetrics();
  const keycloak = new KeycloakClient({
    issuer: env.KC_ISSUER,
    clientId: env.KC_CLIENT_ID,
    clientSecret: env.KC_CLIENT_SECRET,
    log,
    metrics,
  });
  const keycloakJwtVerifier = createKeycloakJwtVerifier({
    keycloak,
    issuer: env.KC_ISSUER,
    clientId: env.KC_CLIENT_ID,
    metrics,
  });

  const internalJwtIssuer = await InternalJwtIssuer.create({
    alg: env.BFF_INTERNAL_JWT_ALG,
    activeKid: env.BFF_INTERNAL_JWT_ACTIVE_KID,
    privateKeyPem: env.BFF_INTERNAL_JWT_PRIVATE_KEY,
    publicKeys: env.BFF_INTERNAL_JWT_PUBLIC_KEYS,
    issuer: env.BFF_INTERNAL_JWT_ISSUER,
    audience: env.BFF_INTERNAL_JWT_AUDIENCE,
    ttlSeconds: env.BFF_INTERNAL_JWT_TTL_SECONDS,
  });

  const app = createApp({
    env,
    log,
    redis,
    keycloak,
    metrics,
    authDeps: {
      env,
      redis,
      keycloak,
      keycloakJwtVerifier,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      internalJwtIssuer,
      metrics,
      log,
    },
  });

  const server = app.listen(env.PORT, () => {
    log.info({ port: env.PORT, env: env.NODE_ENV }, 'bff listening');
  });

  const shutdown = async (signal: string) => {
    log.info({ signal }, 'shutting down');
    server.close(() => log.info('http server closed'));
    redis.disconnect();
    await stopTracing();
    setTimeout(() => process.exit(0), 1000).unref();
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));

  process.on('unhandledRejection', (reason) => {
    log.fatal({ err: reason }, 'unhandledRejection');
    process.exit(1);
  });
  process.on('uncaughtException', (err) => {
    log.fatal({ err }, 'uncaughtException');
    process.exit(1);
  });
};

main().catch((err) => {
  console.error('fatal startup error', err);
  process.exit(1);
});
