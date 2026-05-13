import { loadEnv } from './config/env.js';
import { createLogger } from './lib/logger.js';
import { buildMetrics } from './lib/metrics.js';
import { createRedis } from './lib/redis.js';
import { startTracing, stopTracing } from './observability/tracing.js';

const main = async () => {
  const env = loadEnv();
  const log = createLogger(env);

  // §3.1: tracing must start BEFORE the app's modules are imported, so
  // auto-instrumentations can patch http/express/axios. If you replace the
  // dynamic imports below with static top-level imports, the http/express
  // module references will already exist by the time OTEL tries to wrap
  // them and instrumentation becomes a no-op for those modules.
  startTracing(env);

  const { createApp } = await import('./app.js');
  const { AuthStateStore } = await import('./auth/stores/authState.store.js');
  const { BffCodeStore } = await import('./auth/stores/bffCode.store.js');
  const { SessionStore } = await import('./auth/stores/session.store.js');
  const { UserSessionsStore } = await import('./auth/stores/userSessions.store.js');
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
      userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
      internalJwtIssuer,
      metrics,
      log,
    },
  });

  const server = app.listen(env.PORT, () => {
    log.info({ port: env.PORT, env: env.NODE_ENV }, 'bff listening');
  });

  // Graceful shutdown (AUDIT PR-1):
  //   - stop accepting new connections, drain idle ones
  //   - wait for in-flight requests to finish (bounded by force timer below)
  //   - quit redis cleanly so pending commands flush
  //   - stop OTEL exporter
  //   - flush pino so the last few error lines hit stdout before exit
  // The 25s force-exit budget sits just under typical K8s
  // terminationGracePeriodSeconds=30, so we always exit by our hand, not by
  // SIGKILL.
  let shuttingDown = false;
  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info({ signal }, 'shutting down');
    try {
      server.closeIdleConnections?.();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      try {
        await redis.quit();
      } catch {
        redis.disconnect();
      }
      await stopTracing();
    } catch (err) {
      log.error({ err }, 'shutdown encountered an error');
    } finally {
      await new Promise<void>((resolve) => log.flush(() => resolve()));
      process.exit(0);
    }
  };
  const force = setTimeout(() => {
    log.fatal('shutdown force-exit timer elapsed');
    process.exit(1);
  }, 25_000).unref();
  process.on('SIGTERM', () => void shutdown('SIGTERM').finally(() => clearTimeout(force)));
  process.on('SIGINT', () => void shutdown('SIGINT').finally(() => clearTimeout(force)));

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
