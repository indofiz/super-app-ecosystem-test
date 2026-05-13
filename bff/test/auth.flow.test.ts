import { generateKeyPairSync } from 'node:crypto';
import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore } from '../src/auth/stores/bffCode.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';
import type { Env } from '../src/config/env.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import {
  InvalidGrantError,
  type KeycloakClient,
  type KeycloakTokens,
  type OidcDiscovery,
} from '../src/lib/keycloak.js';
import { createLogger } from '../src/lib/logger.js';
import { challengeFromVerifier, generateVerifier } from '../src/lib/pkce.js';
import {
  buildTestVerifier,
  KC_TEST_CLIENT_ID,
  KC_TEST_ISSUER,
  signKcAccessToken,
  signKcIdToken,
} from './helpers/fakeKc.js';

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
};

const buildInternalJwtIssuer = (ttlOverride?: number): Promise<InternalJwtIssuer> =>
  InternalJwtIssuer.create({
    alg: env.BFF_INTERNAL_JWT_ALG,
    activeKid: env.BFF_INTERNAL_JWT_ACTIVE_KID,
    privateKeyPem: env.BFF_INTERNAL_JWT_PRIVATE_KEY,
    publicKeys: env.BFF_INTERNAL_JWT_PUBLIC_KEYS,
    issuer: env.BFF_INTERNAL_JWT_ISSUER,
    audience: env.BFF_INTERNAL_JWT_AUDIENCE,
    ttlSeconds: ttlOverride ?? env.BFF_INTERNAL_JWT_TTL_SECONDS,
  });

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

interface FakeKeycloakOpts {
  refreshFails?: 'invalid_grant' | 'network';
  /** When true the fake KC's refresh() returns tokens signed by the rogue
   *  key. Used to test the §2.3 path where verification fails after a
   *  successful refresh. */
  refreshReturnsRogueTokens?: boolean;
}

const buildFakeKeycloak = async (
  opts: FakeKeycloakOpts = {},
): Promise<{ client: KeycloakClient; calls: Record<string, number> }> => {
  const calls = { exchangeCode: 0, refresh: 0, endSession: 0 };
  const client = {
    getDiscovery: async () => baseDiscovery,
    exchangeCode: async (): Promise<KeycloakTokens> => {
      calls.exchangeCode++;
      return {
        access_token: await signKcAccessToken('user-123', ['citizen']),
        refresh_token: 'refresh-1',
        id_token: await signKcIdToken('user-123'),
        token_type: 'Bearer',
        expires_in: 300,
        scope: 'openid profile email',
      };
    },
    refresh: async (): Promise<KeycloakTokens> => {
      calls.refresh++;
      if (opts.refreshFails === 'invalid_grant') {
        throw new InvalidGrantError('Refresh token expired or revoked');
      }
      if (opts.refreshFails === 'network') {
        throw new Error('boom: kc unreachable');
      }
      const rogueOpts = opts.refreshReturnsRogueTokens ? { withRogueKey: true } : {};
      return {
        access_token: await signKcAccessToken('user-123', ['citizen', 'verified'], rogueOpts),
        refresh_token: `refresh-${calls.refresh + 1}`,
        id_token: await signKcIdToken('user-123', {}, rogueOpts),
        token_type: 'Bearer',
        expires_in: 300,
        scope: 'openid profile email',
      };
    },
    endSession: async () => {
      calls.endSession++;
    },
  } as unknown as KeycloakClient;
  return { client, calls };
};

// ioredis-mock omits the generic .call() that real ioredis exposes, and
// it doesn't implement SCRIPT LOAD. The rate-limit-redis store needs both
// (it loads a Lua script, then dispatches via EVALSHA). This shim:
//  - adds .call() routing to the lowercased method name on the mock
//  - intercepts SCRIPT LOAD: stash the script body keyed by a fake SHA
//  - intercepts EVALSHA: translate back to EVAL using the stashed body
// Real production code is unaffected — real ioredis already has .call(),
// and a real Redis server handles SCRIPT/EVALSHA natively.
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

const buildHarness = async (kcOpts: FakeKeycloakOpts = {}, issuerTtl?: number) => {
  const log = createLogger(env);
  const redis = installCallShim(new IoRedisMock() as unknown as Redis);
  const { client: keycloak, calls } = await buildFakeKeycloak(kcOpts);
  const internalJwtIssuer = await buildInternalJwtIssuer(issuerTtl);
  const keycloakJwtVerifier = await buildTestVerifier();
  const app = createApp({
    env,
    log,
    redis,
    keycloak,
    authDeps: {
      env,
      redis,
      keycloak,
      keycloakJwtVerifier,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      internalJwtIssuer,
    },
  });
  return { app, calls, redis, internalJwtIssuer };
};

/** Run the full /authorize → /callback → /token leg and return both the
 *  bearer (internal JWT) and the session_id needed for downstream calls. */
const loginAndGetSession = async (app: ReturnType<typeof createApp>) => {
  const codeVerifier = generateVerifier();
  const codeChallenge = challengeFromVerifier(codeVerifier);
  const authRes = await request(app).get('/auth/authorize').query({
    response_type: 'code',
    client_id: 'super-app-eco',
    redirect_uri: REDIRECT,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    state: 'app-state',
  });
  const bffState = new URL(authRes.headers.location).searchParams.get('state')!;
  const cbRes = await request(app)
    .get('/auth/callback')
    .query({ code: 'kc-issued-code', state: bffState });
  const bffAuthCode = new URL(cbRes.headers.location).searchParams.get('code')!;
  const tokenRes = await request(app).post('/auth/token').send({
    grant_type: 'authorization_code',
    code: bffAuthCode,
    code_verifier: codeVerifier,
    client_id: 'super-app-eco',
    redirect_uri: REDIRECT,
  });
  return {
    bearer: tokenRes.body.access_token as string,
    sessionId: tokenRes.body.session_id as string,
  };
};

describe('auth flow', () => {
  it('happy path: authorize → callback → token → refresh → logout', async () => {
    const { app, calls, internalJwtIssuer } = await buildHarness();
    const codeVerifier = generateVerifier();
    const codeChallenge = challengeFromVerifier(codeVerifier);
    const appState = 'app-state-1';

    const authRes = await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
      state: appState,
    });
    expect(authRes.status).toBe(302);
    const kcUrl = new URL(authRes.headers.location);
    expect(kcUrl.origin + kcUrl.pathname).toBe(`${env.KC_ISSUER}/protocol/openid-connect/auth`);
    expect(kcUrl.searchParams.get('client_id')).toBe(env.KC_CLIENT_ID);
    expect(kcUrl.searchParams.get('redirect_uri')).toBe(`${env.PUBLIC_BASE_URL}/auth/callback`);
    expect(kcUrl.searchParams.get('code_challenge_method')).toBe('S256');
    const bffState = kcUrl.searchParams.get('state');
    expect(bffState).toBeTruthy();

    const cbRes = await request(app)
      .get('/auth/callback')
      .query({ code: 'kc-issued-code', state: bffState! });
    expect(cbRes.status).toBe(302);
    expect(calls.exchangeCode).toBe(1);
    const appUrl = new URL(cbRes.headers.location);
    expect(`${appUrl.protocol}${appUrl.pathname}`).toBe(REDIRECT);
    expect(appUrl.searchParams.get('state')).toBe(appState);
    const bffAuthCode = appUrl.searchParams.get('code');
    expect(bffAuthCode).toBeTruthy();

    const tokenRes = await request(app).post('/auth/token').send({
      grant_type: 'authorization_code',
      code: bffAuthCode,
      code_verifier: codeVerifier,
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
    });
    expect(tokenRes.status).toBe(200);
    expect(tokenRes.body.session_id).toBeTruthy();
    expect(tokenRes.body).not.toHaveProperty('refresh_token');

    const claims = await internalJwtIssuer.verify(tokenRes.body.access_token);
    expect(claims.sub).toBe('user-123');
    expect(claims.sid).toBe(tokenRes.body.session_id);
    expect(claims.username).toBe('andi.permana');
    expect(claims.email).toBe('andi@example.test');
    expect(claims.roles).toEqual(['citizen']);
    expect(claims.kid).toBe('v1');

    const sessionId = tokenRes.body.session_id as string;
    const bearer = tokenRes.body.access_token as string;

    // /refresh now requires the bearer that was minted for this session.
    const refreshRes = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: sessionId });
    expect(refreshRes.status).toBe(200);
    expect(refreshRes.body.session_id).toBe(sessionId);
    expect(calls.refresh).toBe(1);
    const refreshedClaims = await internalJwtIssuer.verify(refreshRes.body.access_token);
    expect(refreshedClaims.roles).toEqual(['citizen', 'verified']);
    expect(refreshRes.body.access_token).not.toBe(bearer);

    const meRes = await request(app)
      .get('/auth/me')
      .set('Authorization', `Bearer ${refreshRes.body.access_token}`);
    expect(meRes.status).toBe(200);
    expect(meRes.body).toMatchObject({
      sub: 'user-123',
      username: 'andi.permana',
      email: 'andi@example.test',
      roles: ['citizen', 'verified'],
    });

    // /logout now also requires the bearer + matching sid.
    const logoutRes = await request(app)
      .post('/auth/logout')
      .set('Authorization', `Bearer ${refreshRes.body.access_token}`)
      .send({ session_id: sessionId });
    expect(logoutRes.status).toBe(204);
    expect(calls.endSession).toBe(1);

    // After logout the bearer is still cryptographically valid (5-min lag),
    // but the session is gone — refresh returns invalid_session.
    const refreshAfter = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${refreshRes.body.access_token}`)
      .send({ session_id: sessionId });
    expect(refreshAfter.status).toBe(401);
    expect(refreshAfter.body.error).toBe('invalid_session');

    const meAfter = await request(app)
      .get('/auth/me')
      .set('Authorization', `Bearer ${refreshRes.body.access_token}`);
    expect(meAfter.status).toBe(401);
  });

  it('/auth/me rejects missing or bad bearer', async () => {
    const { app } = await buildHarness();
    const noBearer = await request(app).get('/auth/me');
    expect(noBearer.status).toBe(401);
    expect(noBearer.body.error).toBe('missing_bearer');

    const badBearer = await request(app)
      .get('/auth/me')
      .set('Authorization', 'Bearer not.a.jwt');
    expect(badBearer.status).toBe(401);
    expect(badBearer.body.error).toBe('invalid_token');
  });

  // §2.1 — bearer required on /refresh and /logout.

  it('/auth/refresh rejects missing bearer (§2.1)', async () => {
    const { app } = await buildHarness();
    const { sessionId } = await loginAndGetSession(app);
    const res = await request(app).post('/auth/refresh').send({ session_id: sessionId });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('missing_bearer');
  });

  it('/auth/refresh rejects bearer whose sid does not match body (§2.1)', async () => {
    const { app } = await buildHarness();
    const { bearer } = await loginAndGetSession(app);
    const res = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: 'someone-elses-session' });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('sid_mismatch');
  });

  it('/auth/refresh rejects an unverifiable bearer (§2.1)', async () => {
    const { app } = await buildHarness();
    const { sessionId } = await loginAndGetSession(app);
    const res = await request(app)
      .post('/auth/refresh')
      .set('Authorization', 'Bearer not.a.jwt')
      .send({ session_id: sessionId });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('invalid_token');
  });

  it('/auth/refresh accepts a recently-expired bearer (allowExpired mode)', async () => {
    // Mint a bearer with TTL = -10s (already expired by the time we use it).
    // verifyAllowingExpired's 24h grace lets it through.
    const { app, calls, internalJwtIssuer } = await buildHarness({}, -10);
    // Manually drive login to get a session_id, then mint an expired bearer
    // for that sid using the harness's issuer (which is configured TTL=-10).
    const { sessionId } = await loginAndGetSession(app);
    const expiredBearer = (
      await internalJwtIssuer.mint({ sub: 'user-123', sid: sessionId, roles: ['citizen'] })
    ).token;
    const res = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${expiredBearer}`)
      .send({ session_id: sessionId });
    expect(res.status).toBe(200);
    expect(calls.refresh).toBe(1);
  });

  it('/auth/logout rejects missing bearer (§2.1)', async () => {
    const { app } = await buildHarness();
    const { sessionId } = await loginAndGetSession(app);
    const res = await request(app).post('/auth/logout').send({ session_id: sessionId });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('missing_bearer');
  });

  it('/auth/logout rejects sid mismatch (§2.1)', async () => {
    const { app } = await buildHarness();
    const { bearer } = await loginAndGetSession(app);
    const res = await request(app)
      .post('/auth/logout')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: 'wrong-session' });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('sid_mismatch');
  });

  // §5.3 — invalid_grant from KC purges the local session.

  it('/auth/refresh: KC invalid_grant → 401 invalid_session and session purged (§5.3)', async () => {
    const { app, redis } = await buildHarness({ refreshFails: 'invalid_grant' });
    const { bearer, sessionId } = await loginAndGetSession(app);

    expect(await redis.get(`session:${sessionId}`)).not.toBeNull();

    const res = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: sessionId });
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('invalid_session');

    expect(await redis.get(`session:${sessionId}`)).toBeNull();

    // Second refresh: bearer still valid, but session is gone — so handler
    // returns invalid_session before touching KC again.
    const second = await request(app)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: sessionId });
    expect(second.status).toBe(401);
    expect(second.body.error).toBe('invalid_session');
  });

  it('rejects unknown client_id at /authorize', async () => {
    const { app } = await buildHarness();
    const res = await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'rogue',
      redirect_uri: REDIRECT,
      code_challenge: 'a'.repeat(43),
      code_challenge_method: 'S256',
      state: 's',
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid_client');
  });

  it('rejects unknown redirect_uri at /authorize', async () => {
    const { app } = await buildHarness();
    const res = await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'super-app-eco',
      redirect_uri: 'evil:/redirect',
      code_challenge: 'a'.repeat(43),
      code_challenge_method: 'S256',
      state: 's',
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid_request');
  });

  it('rejects PKCE method=plain at /authorize (§2.4)', async () => {
    const { app } = await buildHarness();
    const res = await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
      code_challenge: 'a'.repeat(43),
      code_challenge_method: 'plain',
      state: 's',
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('invalid_request');
    expect(res.body.error_description).toMatch(/S256/);
  });

  it('rejects PKCE mismatch at /token', async () => {
    const { app } = await buildHarness();
    const goodVerifier = generateVerifier();
    const goodChallenge = challengeFromVerifier(goodVerifier);

    const authRes = await request(app).get('/auth/authorize').query({
      response_type: 'code',
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
      code_challenge: goodChallenge,
      code_challenge_method: 'S256',
      state: 's',
    });
    const bffState = new URL(authRes.headers.location).searchParams.get('state')!;

    const cbRes = await request(app)
      .get('/auth/callback')
      .query({ code: 'kc-code', state: bffState });
    const bffAuthCode = new URL(cbRes.headers.location).searchParams.get('code');

    const tokenRes = await request(app).post('/auth/token').send({
      grant_type: 'authorization_code',
      code: bffAuthCode,
      code_verifier: generateVerifier(),
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
    });
    expect(tokenRes.status).toBe(401);
    expect(tokenRes.body.error).toBe('invalid_grant');
  });

  it('healthz returns ok', async () => {
    const { app } = await buildHarness();
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  it('/.well-known/jwks.json exposes the public keys', async () => {
    const { app } = await buildHarness();
    const res = await request(app).get('/.well-known/jwks.json');
    expect(res.status).toBe(200);
    expect(res.body.keys).toHaveLength(1);
    const [k] = res.body.keys;
    expect(k).toMatchObject({ kty: 'RSA', alg: 'RS256', use: 'sig', kid: 'v1' });
    expect(k.n).toBeTruthy();
    expect(k.e).toBeTruthy();
    expect(k.d).toBeUndefined();
  });
});
