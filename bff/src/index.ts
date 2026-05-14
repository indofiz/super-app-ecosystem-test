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
  const { OtpStore } = await import('./auth/stores/otp.store.js');
  const { SessionStore } = await import('./auth/stores/session.store.js');
  const { UserSessionsStore } = await import('./auth/stores/userSessions.store.js');
  const { buildEmailOtpFromEnv } = await import('./lib/emailOtp.js');
  const { InternalJwtIssuer } = await import('./lib/internalJwt.js');
  const { KeycloakClient } = await import('./lib/keycloak.js');
  const { buildKeycloakAdmin, parseRealmFromIssuer } = await import('./lib/keycloakAdmin.js');
  const { createKeycloakJwtVerifier } = await import('./lib/keycloakJwt.js');
  const { buildWaOtpFromEnv } = await import('./lib/waOtp.js');
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

  // Verification dependencies (Phase 1). The admin client uses the same
  // `super-app-bff` credentials as the OAuth flows — the realm needs the
  // service account to hold `manage-users` + `view-users` (see Phase 0.1
  // of docs/registration-and-verification.md).
  const { realm, baseUrl } = parseRealmFromIssuer(env.KC_ISSUER);
  const keycloakAdmin = buildKeycloakAdmin({
    keycloak,
    realm,
    baseUrl: env.KC_ADMIN_BASE_URL ?? baseUrl,
    clientId: env.KC_CLIENT_ID,
    clientSecret: env.KC_CLIENT_SECRET,
    log,
  });
  const emailOtp = buildEmailOtpFromEnv(env, log);
  const waOtp = buildWaOtpFromEnv(env, log);

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
      keycloakAdmin,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
      otpStore: new OtpStore(redis, env.OTP_TTL_SECONDS),
      emailOtp,
      waOtp,
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
    // Arm the force-exit watchdog only now — outside the shutdown path it
    // would just kill a healthy server 25s after boot, since unref() can't
    // detach a timer from an event loop kept alive by the HTTP server,
    // Redis client, and OTEL exporter.
    const force = setTimeout(() => {
      log.fatal('shutdown force-exit timer elapsed');
      process.exit(1);
    }, 25_000).unref();
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
      clearTimeout(force);
      await new Promise<void>((resolve) => log.flush(() => resolve()));
      process.exit(0);
    }
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));

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
