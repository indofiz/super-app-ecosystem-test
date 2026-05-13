import { generateKeyPairSync } from 'node:crypto';
import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore } from '../src/auth/stores/bffCode.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';
import { UserSessionsStore } from '../src/auth/stores/userSessions.store.js';
import type { Env } from '../src/config/env.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import type { KeycloakClient, OidcDiscovery } from '../src/lib/keycloak.js';
import { createLogger } from '../src/lib/logger.js';
import { buildTestVerifier } from './helpers/fakeKc.js';

// Verifies §3.5 / IMPROVEMENT_PLAN item #5: limiters are now Redis-backed,
// so two replicas sharing a Redis instance share a single counter
// (vs. the old in-memory store where each replica had its own).

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
  TRUST_PROXY: 'loopback',
  REQUEST_TIMEOUT_MS: 12_000,
};

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

// Same SCRIPT-LOAD/EVALSHA shim used by auth.flow.test.ts. Duplicated here
// to keep this test self-contained; if a third file ever needs it, hoist
// to test/helpers/redisMock.ts.
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

const buildAppWithRedis = async (redis: Redis) => {
  const log = createLogger(env);
  const internalJwtIssuer = await InternalJwtIssuer.create({
    alg: env.BFF_INTERNAL_JWT_ALG,
    activeKid: env.BFF_INTERNAL_JWT_ACTIVE_KID,
    privateKeyPem: env.BFF_INTERNAL_JWT_PRIVATE_KEY,
    publicKeys: env.BFF_INTERNAL_JWT_PUBLIC_KEYS,
    issuer: env.BFF_INTERNAL_JWT_ISSUER,
    audience: env.BFF_INTERNAL_JWT_AUDIENCE,
    ttlSeconds: env.BFF_INTERNAL_JWT_TTL_SECONDS,
  });
  const keycloakJwtVerifier = await buildTestVerifier();
  return createApp({
    env,
    log,
    redis,
    keycloak: noopKeycloak,
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
    },
  });
};

describe('rate limiter (Redis-backed) — §3.5', () => {
  // ioredis-mock shares its keyspace across instances in the same process,
  // so flushall() before each test is required for counter isolation.
  beforeEach(async () => {
    await (new IoRedisMock() as unknown as Redis).flushall();
  });

  it('/auth/token returns 429 after the 10/min limit is exceeded', async () => {
    const redis = installCallShim(new IoRedisMock());
    const app = await buildAppWithRedis(redis);
    let last = 0;
    // First 10 are allowed (handler will respond 4xx on the bad payload, but
    // never 429); the 11th gets blocked by the limiter before the handler.
    for (let i = 0; i < 11; i++) {
      const res = await request(app).post('/auth/token').send({});
      last = res.status;
      if (i < 10) expect(res.status).not.toBe(429);
    }
    expect(last).toBe(429);
  });

  it('two app instances sharing a Redis instance share the same counter', async () => {
    // Proves the limiter is global across replicas — the failure mode of
    // the previous in-memory store was that each replica had its own count.
    const redis = installCallShim(new IoRedisMock());
    const appA = await buildAppWithRedis(redis);
    const appB = await buildAppWithRedis(redis);
    // 6 calls on A + 5 calls on B = 11 total → 12th should be 429.
    for (let i = 0; i < 6; i++) {
      const r = await request(appA).post('/auth/token').send({});
      expect(r.status).not.toBe(429);
    }
    for (let i = 0; i < 4; i++) {
      const r = await request(appB).post('/auth/token').send({});
      expect(r.status).not.toBe(429);
    }
    const blocked = await request(appB).post('/auth/token').send({});
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('rate_limited');
  });

  it('different endpoints get independent counters via key prefix', async () => {
    // Filling /token's bucket must not affect /authorize. Each limiter has
    // its own Redis prefix (rl:token:, rl:authorize:, ...).
    const redis = installCallShim(new IoRedisMock());
    const app = await buildAppWithRedis(redis);
    for (let i = 0; i < 11; i++) {
      await request(app).post('/auth/token').send({});
    }
    // /token is now blocked; /authorize must still be reachable.
    const auth = await request(app).get('/auth/authorize').query({});
    expect(auth.status).not.toBe(429);
  });
});
