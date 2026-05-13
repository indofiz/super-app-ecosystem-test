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
import { challengeFromVerifier, generateVerifier } from '../src/lib/pkce.js';
import {
  buildTestVerifier,
  KC_TEST_CLIENT_ID,
  KC_TEST_ISSUER,
  signKcAccessToken,
  signKcIdToken,
  signKcToken,
} from './helpers/fakeKc.js';

// AUDIT S-5 — POST /auth/back-channel-logout verifies a KC logout_token
// against the same JWKS used for id/access token verification, then
// deletes every session for the matching `sub`.

const REDIRECT = 'id.go.pangkalpinangkota.smartapptest:/oauth2redirect';

const { publicKey: TEST_PUBLIC_PEM, privateKey: TEST_PRIVATE_PEM } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const env: Env = {
  PORT: 3000,
  NODE_ENV: 'test',
  LOG_LEVEL: 'fatal',
  PUBLIC_BASE_URL: 'http://localhost:3000',
  KC_ISSUER: KC_TEST_ISSUER,
  KC_CLIENT_ID: KC_TEST_CLIENT_ID,
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
  METRICS_ENABLED: false,
  TRACING_ENABLED: false,
  OTEL_SERVICE_NAME: 'super-app-bff-test',
  BUILD_COMMIT: 'test',
  BUILD_VERSION: 'test',
  TRUST_PROXY: 'loopback',
  REQUEST_TIMEOUT_MS: 12_000,
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
    if (upper === 'SCRIPT' && String(args[0]).toUpperCase() === 'LOAD') return fakeSha(String(args[1]));
    if (upper === 'EVALSHA') {
      const body = scriptCache.get(String(args[0]));
      if (!body) throw new Error('NOSCRIPT');
      return mock.eval(body, ...(args.slice(1) as [string, ...string[]]));
    }
    const fn = (mock as unknown as Record<string, unknown>)[cmd.toLowerCase()];
    if (typeof fn !== 'function') throw new Error(`unsupported ${cmd}`);
    return (fn as (...a: unknown[]) => Promise<unknown>).apply(mock, args);
  };
  return mock;
};

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

const buildHarness = async () => {
  const log = createLogger(env);
  const redis = installCallShim(new IoRedisMock());
  const calls = { exchangeCode: 0 };
  const keycloak = {
    getDiscovery: async () => baseDiscovery,
    exchangeCode: async () => {
      calls.exchangeCode++;
      return {
        access_token: await signKcAccessToken('user-bcl', ['citizen']),
        refresh_token: 'rt-bcl',
        id_token: await signKcIdToken('user-bcl'),
        token_type: 'Bearer',
        expires_in: 300,
        scope: 'openid',
      };
    },
    refresh: async () => ({}) as never,
    endSession: async () => {},
  } as unknown as KeycloakClient;
  const verifier = await buildTestVerifier();
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
    authDeps: {
      env,
      redis,
      keycloak,
      keycloakJwtVerifier: verifier,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
      internalJwtIssuer,
    },
  });
  return { app, redis, calls };
};

const login = async (app: ReturnType<typeof createApp>) => {
  const verifier = generateVerifier();
  const challenge = challengeFromVerifier(verifier);
  const authRes = await request(app).get('/auth/authorize').query({
    response_type: 'code',
    client_id: 'super-app-eco',
    redirect_uri: REDIRECT,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    state: 's',
  });
  const bffState = new URL(authRes.headers.location).searchParams.get('state')!;
  const cbRes = await request(app)
    .get('/auth/callback')
    .query({ code: 'kc-code', state: bffState });
  const bffAuthCode = new URL(cbRes.headers.location).searchParams.get('code')!;
  const tokenRes = await request(app).post('/auth/token').send({
    grant_type: 'authorization_code',
    code: bffAuthCode,
    code_verifier: verifier,
    client_id: 'super-app-eco',
    redirect_uri: REDIRECT,
  });
  return tokenRes.body.session_id as string;
};

describe('/auth/back-channel-logout — AUDIT S-5', () => {
  it('purges every session for a sub when KC sends a valid logout_token', async () => {
    const { app, redis } = await buildHarness();
    const sid = await login(app);
    expect(await redis.get(`session:${sid}`)).not.toBeNull();
    expect(await redis.smembers('sub:user-bcl')).toContain(sid);

    const logoutToken = await signKcToken(
      {
        sub: 'user-bcl',
        events: { 'http://schemas.openid.net/event/backchannel-logout': {} },
      },
      { audience: KC_TEST_CLIENT_ID, expiresIn: 300 },
    );

    const res = await request(app)
      .post('/auth/back-channel-logout')
      .set('Content-Type', 'application/x-www-form-urlencoded')
      .send(`logout_token=${encodeURIComponent(logoutToken)}`);

    expect(res.status).toBe(200);
    expect(await redis.get(`session:${sid}`)).toBeNull();
  });

  it('rejects logout_token missing the back-channel event', async () => {
    const { app } = await buildHarness();
    await login(app);

    const badToken = await signKcToken(
      { sub: 'user-bcl', events: { 'something-else': {} } },
      { audience: KC_TEST_CLIENT_ID, expiresIn: 300 },
    );

    const res = await request(app)
      .post('/auth/back-channel-logout')
      .set('Content-Type', 'application/x-www-form-urlencoded')
      .send(`logout_token=${encodeURIComponent(badToken)}`);

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid_request');
  });

  it('rejects logout_token signed by an unknown key', async () => {
    const { app } = await buildHarness();
    const rogueToken = await signKcToken(
      {
        sub: 'user-bcl',
        events: { 'http://schemas.openid.net/event/backchannel-logout': {} },
      },
      { audience: KC_TEST_CLIENT_ID, expiresIn: 300, withRogueKey: true },
    );

    const res = await request(app)
      .post('/auth/back-channel-logout')
      .set('Content-Type', 'application/x-www-form-urlencoded')
      .send(`logout_token=${encodeURIComponent(rogueToken)}`);

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid_request');
  });

  it('rejects logout_token that carries a nonce (would be an id_token)', async () => {
    const { app } = await buildHarness();
    const bad = await signKcToken(
      {
        sub: 'user-bcl',
        nonce: 'x',
        events: { 'http://schemas.openid.net/event/backchannel-logout': {} },
      },
      { audience: KC_TEST_CLIENT_ID, expiresIn: 300 },
    );
    const res = await request(app)
      .post('/auth/back-channel-logout')
      .set('Content-Type', 'application/x-www-form-urlencoded')
      .send(`logout_token=${encodeURIComponent(bad)}`);
    expect(res.status).toBe(400);
  });
});
