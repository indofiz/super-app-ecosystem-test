import { generateKeyPairSync } from 'node:crypto';
import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore } from '../src/auth/stores/bffCode.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';
import { UserSessionsStore } from '../src/auth/stores/userSessions.store.js';
import type { Env } from '../src/config/env.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import type { KeycloakClient, OidcDiscovery } from '../src/lib/keycloak.js';
import { createLogger } from '../src/lib/logger.js';
import { buildMetrics, normalizeRoute } from '../src/lib/metrics.js';
import { buildTestVerifier } from './helpers/fakeKc.js';

// IMPROVEMENT_PLAN §3.1 / item #6: /metrics endpoint, http counters, KC
// timing, auth mint/fail counters.

const REDIRECT = 'id.go.pangkalpinangkota.smartapptest:/oauth2redirect';

const { publicKey: TEST_PUBLIC_PEM, privateKey: TEST_PRIVATE_PEM } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const env: Env = {
  PORT: 3000,
  NODE_ENV: 'test',
  LOG_LEVEL: 'error',
  PUBLIC_BASE_URL: 'http://localhost:3000',
  KC_ISSUER: 'https://kc.example.test/realms/pangkalpinang',
  KC_CLIENT_ID: 'super-app-bff',
  KC_CLIENT_SECRET: 'shh',
  KC_SCOPES: 'openid profile email',
  ALLOWED_APP_CLIENTS: ['super-app-eco'],
  ALLOWED_APP_REDIRECT_URIS: [REDIRECT],
  REDIS_URL: 'redis://localhost:6379',
  SESSION_TTL_SECONDS: 600,
  AUTHSTATE_TTL_SECONDS: 600,
  BFFCODE_TTL_SECONDS: 600,
  CORS_ORIGINS: [],
  BFF_INTERNAL_JWT_ALG: 'RS256',
  BFF_INTERNAL_JWT_ACTIVE_KID: 'v1',
  BFF_INTERNAL_JWT_PRIVATE_KEY: TEST_PRIVATE_PEM,
  BFF_INTERNAL_JWT_PUBLIC_KEYS: [{ kid: 'v1', pem: TEST_PUBLIC_PEM }],
  BFF_INTERNAL_JWT_TTL_SECONDS: 300,
  BFF_INTERNAL_JWT_ISSUER: 'super-app-bff',
  BFF_INTERNAL_JWT_AUDIENCE: 'super-app-services',
  METRICS_ENABLED: true,
  TRACING_ENABLED: false,
  OTEL_SERVICE_NAME: 'super-app-bff',
  BUILD_COMMIT: 'test-commit',
  BUILD_VERSION: '0.0.0-test',
  TRUST_PROXY: 'loopback',
  REQUEST_TIMEOUT_MS: 12_000,
};

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

const installCallShim = (mock: Redis): Redis => {
  if (typeof (mock as unknown as { call?: unknown }).call === 'function') return mock;
  const scriptCache = new Map<string, string>();
  let nextSha = 0;
  const fakeSha = (body: string): string => {
    for (const [sha, b] of scriptCache) if (b === body) return sha;
    const sha = `fakesha-${++nextSha}`;
    scriptCache.set(sha, body);
    return sha;
  };
  (mock as unknown as { call: (...a: unknown[]) => Promise<unknown> }).call = async (
    cmd: string,
    ...args: unknown[]
  ) => {
    const upper = cmd.toUpperCase();
    if (upper === 'SCRIPT' && String(args[0]).toUpperCase() === 'LOAD') {
      return fakeSha(String(args[1]));
    }
    if (upper === 'EVALSHA') {
      const body = scriptCache.get(String(args[0]));
      if (!body) throw new Error('NOSCRIPT No matching script');
      return mock.eval(body, ...(args.slice(1) as [string, ...string[]]));
    }
    const fn = (mock as unknown as Record<string, unknown>)[cmd.toLowerCase()];
    if (typeof fn !== 'function') throw new Error(`ioredis-mock: unsupported command ${cmd}`);
    return (fn as (...a: unknown[]) => Promise<unknown>).apply(mock, args);
  };
  return mock;
};

const noopKeycloak: KeycloakClient = {
  getDiscovery: async () => baseDiscovery,
} as unknown as KeycloakClient;

const buildHarness = async () => {
  const log = createLogger(env);
  const redis = installCallShim(new IoRedisMock());
  const metrics = buildMetrics();
  const internalJwtIssuer = await InternalJwtIssuer.create({
    alg: env.BFF_INTERNAL_JWT_ALG,
    activeKid: env.BFF_INTERNAL_JWT_ACTIVE_KID,
    privateKeyPem: env.BFF_INTERNAL_JWT_PRIVATE_KEY,
    publicKeys: env.BFF_INTERNAL_JWT_PUBLIC_KEYS,
    issuer: env.BFF_INTERNAL_JWT_ISSUER,
    audience: env.BFF_INTERNAL_JWT_AUDIENCE,
    ttlSeconds: env.BFF_INTERNAL_JWT_TTL_SECONDS,
  });
  const keycloakJwtVerifier = await buildTestVerifier(metrics);
  const app = createApp({
    env,
    log,
    redis,
    keycloak: noopKeycloak,
    metrics,
    authDeps: {
      env,
      redis,
      keycloak: noopKeycloak,
      keycloakJwtVerifier,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
      internalJwtIssuer,
      metrics,
    },
  });
  return { app, metrics };
};

describe('metrics — §3.1', () => {
  it('exposes /metrics with the prom-client default registry shape', async () => {
    const { app } = await buildHarness();
    // Prime: one /healthz call so http_requests_total has a known sample.
    await request(app).get('/healthz');
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
    expect(res.text).toContain('http_requests_total');
    expect(res.text).toContain('http_request_duration_seconds');
    expect(res.text).toContain('process_cpu_user_seconds_total'); // default metrics
    // The /healthz hit should be recorded.
    expect(res.text).toMatch(
      /http_requests_total\{[^}]*route="\/healthz"[^}]*method="GET"[^}]*status="200"[^}]*\} \d/,
    );
  });

  it('returns 404 for /metrics when METRICS_ENABLED=false', async () => {
    const log = createLogger(env);
    const redis = installCallShim(new IoRedisMock());
    const metrics = buildMetrics();
    const internalJwtIssuer = await InternalJwtIssuer.create({
      alg: env.BFF_INTERNAL_JWT_ALG,
      activeKid: env.BFF_INTERNAL_JWT_ACTIVE_KID,
      privateKeyPem: env.BFF_INTERNAL_JWT_PRIVATE_KEY,
      publicKeys: env.BFF_INTERNAL_JWT_PUBLIC_KEYS,
      issuer: env.BFF_INTERNAL_JWT_ISSUER,
      audience: env.BFF_INTERNAL_JWT_AUDIENCE,
      ttlSeconds: env.BFF_INTERNAL_JWT_TTL_SECONDS,
    });
    const keycloakJwtVerifier = await buildTestVerifier(metrics);
    const app = createApp({
      env: { ...env, METRICS_ENABLED: false },
      log,
      redis,
      keycloak: noopKeycloak,
      metrics,
      authDeps: {
        env,
        redis,
        keycloak: noopKeycloak,
        keycloakJwtVerifier,
        authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
        bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
        sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
        userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
        internalJwtIssuer,
        metrics,
      },
    });
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(404);
  });

  it('increments auth_failed_total on 4xx error responses', async () => {
    const { app, metrics } = await buildHarness();
    // Bad client_id at /authorize → 400 invalid_client.
    await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'rogue',
      redirect_uri: REDIRECT,
      code_challenge: 'a'.repeat(43),
      code_challenge_method: 'S256',
      state: 's',
    });
    const text = await metrics.registry.metrics();
    expect(text).toMatch(/auth_failed_total\{[^}]*reason="invalid_client"[^}]*\} \d/);
  });

  it('collapses non-allowlisted routes to "other" (cardinality guard)', () => {
    expect(normalizeRoute('/auth/token')).toBe('/auth/token');
    expect(normalizeRoute('/auth/token/')).toBe('/auth/token');
    expect(normalizeRoute('/auth/token?x=1')).toBe('/auth/token');
    expect(normalizeRoute('/some/random/path')).toBe('other');
    expect(normalizeRoute(undefined)).toBe('other');
  });
});
