import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore, type BffCodeRecord } from '../src/auth/stores/bffCode.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';
import { UserSessionsStore } from '../src/auth/stores/userSessions.store.js';
import type { Env } from '../src/config/env.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import {
  InvalidGrantError,
  type KeycloakClient,
  type KeycloakTokens,
  type OidcDiscovery,
} from '../src/lib/keycloak.js';
import {
  createKeycloakJwtVerifier,
  KeycloakJwtVerificationError,
} from '../src/lib/keycloakJwt.js';
import { createLogger } from '../src/lib/logger.js';
import { buildMetrics } from '../src/lib/metrics.js';
import { challengeFromVerifier, generateVerifier } from '../src/lib/pkce.js';
import {
  buildTestVerifier,
  fakeKcJwks,
  KC_TEST_CLIENT_ID,
  KC_TEST_ISSUER,
  signKcAccessToken,
  signKcIdToken,
  signKcToken,
} from './helpers/fakeKc.js';

// IMPROVEMENT_PLAN §2.3 / item #3 — id_token / access_token are verified
// against KC's JWKS instead of decoded blindly. These tests exercise the
// failure paths: tampered tokens, wrong key, wrong audience, wrong
// issuer, and Redis poisoning.

const REDIRECT = 'id.go.pangkalpinangkota.smartapptest:/oauth2redirect';

const env: Env = {
  PORT: 3000,
  NODE_ENV: 'test',
  LOG_LEVEL: 'fatal', // silence the warn/error logs the failure paths emit
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
  BFF_INTERNAL_JWT_PRIVATE_KEY: '', // populated below
  BFF_INTERNAL_JWT_PUBLIC_KEYS: [],
  BFF_INTERNAL_JWT_TTL_SECONDS: 300,
  BFF_INTERNAL_JWT_ISSUER: 'super-app-bff',
  BFF_INTERNAL_JWT_AUDIENCE: 'super-app-services',
  METRICS_ENABLED: false,
  TRACING_ENABLED: false,
  OTEL_SERVICE_NAME: 'super-app-bff',
  BUILD_COMMIT: 'test',
  BUILD_VERSION: '0.0.0-test',
  TRUST_PROXY: 'loopback',
  REQUEST_TIMEOUT_MS: 12_000,
};

// Generate the internal-JWT keypair the same way auth.flow.test.ts does.
import { generateKeyPairSync } from 'node:crypto';
const { publicKey: TEST_PUBLIC_PEM, privateKey: TEST_PRIVATE_PEM } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
env.BFF_INTERNAL_JWT_PRIVATE_KEY = TEST_PRIVATE_PEM;
env.BFF_INTERNAL_JWT_PUBLIC_KEYS = [{ kid: 'v1', pem: TEST_PUBLIC_PEM }];

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

interface FakeKcOpts {
  exchangeIdToken?: string;
  refreshIdToken?: string;
  refreshAccessToken?: string;
}

const buildFakeKc = async (
  opts: FakeKcOpts = {},
): Promise<{ client: KeycloakClient; calls: Record<string, number> }> => {
  const calls = { exchangeCode: 0, refresh: 0, endSession: 0 };
  const client = {
    getDiscovery: async () => baseDiscovery,
    exchangeCode: async (): Promise<KeycloakTokens> => {
      calls.exchangeCode++;
      return {
        access_token: await signKcAccessToken('user-123', ['citizen']),
        refresh_token: 'refresh-1',
        id_token: opts.exchangeIdToken ?? (await signKcIdToken('user-123')),
        token_type: 'Bearer',
        expires_in: 300,
        scope: 'openid profile email',
      };
    },
    refresh: async (): Promise<KeycloakTokens> => {
      calls.refresh++;
      return {
        access_token: opts.refreshAccessToken ?? (await signKcAccessToken('user-123', ['citizen'])),
        refresh_token: 'refresh-2',
        id_token: opts.refreshIdToken ?? (await signKcIdToken('user-123')),
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

const buildHarness = async (kcOpts: FakeKcOpts = {}) => {
  const log = createLogger(env);
  const redis = installCallShim(new IoRedisMock());
  const metrics = buildMetrics();
  const { client: keycloak, calls } = await buildFakeKc(kcOpts);
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
    },
  });
  return { app, calls, redis, internalJwtIssuer, metrics };
};

const runAuthorize = async (app: ReturnType<typeof createApp>) => {
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
  return { codeVerifier, bffState };
};

describe('Keycloak JWT verifier — §2.3 unit', () => {
  it('verifies a well-formed id_token', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcIdToken('user-123');
    const claims = await verifier.verifyIdToken(token);
    expect(claims.sub).toBe('user-123');
    expect(claims.preferred_username).toBe('andi.permana');
  });

  it('rejects an id_token signed with the rogue (unknown) key', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcIdToken('user-123', {}, { withRogueKey: true });
    await expect(verifier.verifyIdToken(token)).rejects.toBeInstanceOf(
      KeycloakJwtVerificationError,
    );
  });

  it('rejects an id_token with the wrong audience', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcToken(
      { sub: 'user-123' },
      { audience: 'someone-else', expiresIn: 300 },
    );
    await expect(verifier.verifyIdToken(token)).rejects.toBeInstanceOf(
      KeycloakJwtVerificationError,
    );
  });

  it('rejects an id_token with the wrong issuer', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcToken(
      { sub: 'user-123' },
      { issuer: 'https://attacker.example/realms/x', audience: KC_TEST_CLIENT_ID },
    );
    await expect(verifier.verifyIdToken(token)).rejects.toBeInstanceOf(
      KeycloakJwtVerificationError,
    );
  });

  it('rejects an id_token whose azp does not match the BFF client_id', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcToken(
      { sub: 'user-123', azp: 'someone-else' },
      { audience: KC_TEST_CLIENT_ID },
    );
    await expect(verifier.verifyIdToken(token)).rejects.toBeInstanceOf(
      KeycloakJwtVerificationError,
    );
  });

  it('rejects a tampered id_token (signature broken by mutation)', async () => {
    const verifier = await buildTestVerifier();
    const good = await signKcIdToken('user-123');
    const parts = good.split('.');
    // Flip a bit in the payload — signature still references original.
    const payload = JSON.parse(Buffer.from(parts[1]!, 'base64url').toString('utf8'));
    payload.sub = 'attacker-sub';
    parts[1] = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const tampered = parts.join('.');
    await expect(verifier.verifyIdToken(tampered)).rejects.toBeInstanceOf(
      KeycloakJwtVerificationError,
    );
  });

  it('verifyAccessToken accepts no aud claim (KC access tokens have variable aud)', async () => {
    const verifier = await buildTestVerifier();
    const token = await signKcAccessToken('user-123', ['citizen']);
    const claims = await verifier.verifyAccessToken(token);
    expect(claims.realm_access?.roles).toEqual(['citizen']);
  });

  it('bumps auth_failed_total{reason=idtoken_verify_failed} on failure', async () => {
    const metrics = buildMetrics();
    const verifier = await buildTestVerifier(metrics);
    await expect(
      verifier.verifyIdToken(await signKcIdToken('x', {}, { withRogueKey: true })),
    ).rejects.toThrow();
    const text = await metrics.registry.metrics();
    expect(text).toMatch(/auth_failed_total\{[^}]*reason="idtoken_verify_failed"[^}]*\} \d/);
  });

  it('falls back to remote JWKS path when no `jwks` injected (smoke test)', async () => {
    // Without an injected jwks we'd hit a real network. Instead, verify
    // the lazy-init code-path by giving a discovery without jwks_uri →
    // expect a "keycloak_jwks_unavailable" upstream error.
    const v = createKeycloakJwtVerifier({
      keycloak: { getDiscovery: async () => ({ issuer: KC_TEST_ISSUER }) } as never,
      issuer: KC_TEST_ISSUER,
      clientId: KC_TEST_CLIENT_ID,
    });
    await expect(v.verifyIdToken('x.y.z')).rejects.toBeInstanceOf(KeycloakJwtVerificationError);
  });
});

describe('Keycloak JWT verifier — §2.3 end-to-end via handlers', () => {
  it('callback: KC returns a rogue-signed id_token → deeplink server_error, no bffcode persisted', async () => {
    const { app, redis } = await buildHarness({
      exchangeIdToken: await signKcIdToken('attacker-sub', {}, { withRogueKey: true }),
    });
    const { bffState } = await runAuthorize(app);
    const cbRes = await request(app)
      .get('/auth/callback')
      .query({ code: 'kc-code', state: bffState });
    expect(cbRes.status).toBe(302);
    const url = new URL(cbRes.headers.location);
    expect(url.searchParams.get('error')).toBe('server_error');
    // Nothing should have been written to bffcode:* — count keys.
    const keys = await redis.keys('bffcode:*');
    expect(keys).toHaveLength(0);
  });

  it('callback: KC returns id_token with wrong aud → deeplink server_error', async () => {
    const { app } = await buildHarness({
      exchangeIdToken: await signKcToken(
        { sub: 'user-123' },
        { audience: 'wrong-client', expiresIn: 300 },
      ),
    });
    const { bffState } = await runAuthorize(app);
    const cbRes = await request(app)
      .get('/auth/callback')
      .query({ code: 'kc-code', state: bffState });
    const url = new URL(cbRes.headers.location);
    expect(url.searchParams.get('error')).toBe('server_error');
  });

  it('token: bffcode record poisoned in Redis → 401 invalid_grant', async () => {
    // Drive a real callback first so a legitimate bffcode record exists.
    const { app, redis } = await buildHarness();
    const { codeVerifier, bffState } = await runAuthorize(app);
    const cbRes = await request(app)
      .get('/auth/callback')
      .query({ code: 'kc-code', state: bffState });
    const bffAuthCode = new URL(cbRes.headers.location).searchParams.get('code')!;

    // Now mutate the stored record so its id_token is signed by the
    // rogue key. This simulates Redis tampering — exactly the §2.3
    // "single layer of defence" scenario.
    const key = `bffcode:${bffAuthCode}`;
    const raw = await redis.get(key);
    expect(raw).not.toBeNull();
    const record: BffCodeRecord = JSON.parse(raw);
    record.idToken = await signKcIdToken('attacker-sub', {}, { withRogueKey: true });
    record.accessToken = await signKcAccessToken('attacker-sub', ['admin'], {
      withRogueKey: true,
    });
    await redis.set(key, JSON.stringify(record));

    const tokenRes = await request(app).post('/auth/token').send({
      grant_type: 'authorization_code',
      code: bffAuthCode,
      code_verifier: codeVerifier,
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
    });
    expect(tokenRes.status).toBe(401);
    expect(tokenRes.body.error).toBe('invalid_grant');
    expect(tokenRes.body.error_description).toMatch(/verification/i);
  });

  it('refresh: KC refresh returns rogue-signed tokens → 401 invalid_session and session purged', async () => {
    // Login normally, then swap the fake KC client into rogue-refresh mode
    // by rebuilding the harness for the second leg. Easier: configure the
    // harness up-front so refresh() returns rogue tokens.
    const goodLogin = await buildHarness();
    const { codeVerifier, bffState } = await runAuthorize(goodLogin.app);
    const cbRes = await request(goodLogin.app)
      .get('/auth/callback')
      .query({ code: 'kc-code', state: bffState });
    const bffAuthCode = new URL(cbRes.headers.location).searchParams.get('code')!;
    const tokenRes = await request(goodLogin.app).post('/auth/token').send({
      grant_type: 'authorization_code',
      code: bffAuthCode,
      code_verifier: codeVerifier,
      client_id: 'super-app-eco',
      redirect_uri: REDIRECT,
    });
    expect(tokenRes.status).toBe(200);
    const sessionId = tokenRes.body.session_id as string;
    const bearer = tokenRes.body.access_token as string;

    // Now reuse the same redis but install a fake KC that returns rogue
    // tokens on refresh. Build a new app pointed at the same redis so the
    // session_id is reachable.
    const log = createLogger(env);
    const metrics = buildMetrics();
    const { client: rogueKc } = await buildFakeKc({
      refreshIdToken: await signKcIdToken('attacker-sub', {}, { withRogueKey: true }),
      refreshAccessToken: await signKcAccessToken('attacker-sub', ['admin'], {
        withRogueKey: true,
      }),
    });
    const verifier = await buildTestVerifier(metrics);
    const app2 = createApp({
      env,
      log,
      redis: goodLogin.redis,
      keycloak: rogueKc,
      metrics,
      authDeps: {
        env,
        redis: goodLogin.redis,
        keycloak: rogueKc,
        keycloakJwtVerifier: verifier,
        authStateStore: new AuthStateStore(goodLogin.redis, env.AUTHSTATE_TTL_SECONDS),
        bffCodeStore: new BffCodeStore(goodLogin.redis, env.BFFCODE_TTL_SECONDS),
        sessionStore: new SessionStore(goodLogin.redis, env.SESSION_TTL_SECONDS),
        userSessionsStore: new UserSessionsStore(goodLogin.redis, env.SESSION_TTL_SECONDS),
        internalJwtIssuer: goodLogin.internalJwtIssuer,
        metrics,
      },
    });

    const refreshRes = await request(app2)
      .post('/auth/refresh')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ session_id: sessionId });
    expect(refreshRes.status).toBe(401);
    expect(refreshRes.body.error).toBe('invalid_session');
    expect(await goodLogin.redis.get(`session:${sessionId}`)).toBeNull();
  });

  it('exposes signKcToken / fakeKcJwks for downstream test files', async () => {
    // Self-test of the helper module: jwks() returns a valid resolver.
    const jwks = await fakeKcJwks();
    expect(typeof jwks).toBe('function');
  });
});

// Quiet a vitest warning about unused imports in narrow test branches.
void InvalidGrantError;
