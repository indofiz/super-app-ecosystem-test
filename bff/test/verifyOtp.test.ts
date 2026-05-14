import { generateKeyPairSync } from 'node:crypto';
import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore } from '../src/auth/stores/bffCode.store.js';
import { OtpStore } from '../src/auth/stores/otp.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';
import { UserSessionsStore } from '../src/auth/stores/userSessions.store.js';
import type { Env } from '../src/config/env.js';
import type { EmailOtpSender } from '../src/lib/emailOtp.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import type { KeycloakClient, KeycloakTokens, OidcDiscovery } from '../src/lib/keycloak.js';
import type { KeycloakAdminClient } from '../src/lib/keycloakAdmin.js';
import { createLogger } from '../src/lib/logger.js';
import { challengeFromVerifier, generateVerifier } from '../src/lib/pkce.js';
import type { WaOtpSender } from '../src/lib/waOtp.js';
import {
  buildTestVerifier,
  KC_TEST_CLIENT_ID,
  KC_TEST_ISSUER,
  signKcAccessToken,
  signKcIdToken,
} from './helpers/fakeKc.js';

// Same harness shape as auth.flow.test.ts — fork rather than share so
// neither file owns the other's evolving env / deps surface.

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
  KC_SCOPES: 'openid profile email phone',
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
  METRICS_ENABLED: false,
  TRACING_ENABLED: false,
  OTEL_SERVICE_NAME: 'super-app-bff-test',
  BUILD_COMMIT: 'test',
  BUILD_VERSION: 'test',
  SMTP_HOST: 'smtp.gmail.com',
  SMTP_PORT: 587,
  FONNTE_BASE_URL: 'https://api.fonnte.com',
  OTP_TTL_SECONDS: 300,
  OTP_MAX_ATTEMPTS: 5,
};

const baseDiscovery: OidcDiscovery = {
  issuer: env.KC_ISSUER,
  authorization_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${env.KC_ISSUER}/protocol/openid-connect/logout`,
};

const buildFakeKeycloak = (): KeycloakClient =>
  ({
    getDiscovery: async () => baseDiscovery,
    exchangeCode: async (): Promise<KeycloakTokens> => ({
      access_token: await signKcAccessToken('user-123', ['citizen']),
      refresh_token: 'refresh-1',
      // Mark email as already-verified upstream by default; tests that
      // want the "unverified" case rebuild the harness.
      id_token: await signKcIdToken('user-123', {
        email: 'andi@example.test',
        email_verified: false,
        phone_number_verified: false,
      }),
      token_type: 'Bearer',
      expires_in: 300,
      scope: 'openid profile email phone',
    }),
    refresh: async (): Promise<KeycloakTokens> => ({
      access_token: await signKcAccessToken('user-123', ['citizen']),
      refresh_token: 'refresh-2',
      id_token: await signKcIdToken('user-123'),
      token_type: 'Bearer',
      expires_in: 300,
      scope: 'openid profile email phone',
    }),
    endSession: async () => {},
  }) as unknown as KeycloakClient;

interface FakeEmail extends EmailOtpSender {
  calls: Array<{ to: string; code: string }>;
}
const buildFakeEmail = (): FakeEmail => {
  const calls: FakeEmail['calls'] = [];
  return {
    calls,
    async sendOtp(to, code) {
      calls.push({ to, code });
    },
  };
};

interface FakeWa extends WaOtpSender {
  calls: Array<{ phone: string; code: string }>;
}
const buildFakeWa = (): FakeWa => {
  const calls: FakeWa['calls'] = [];
  return {
    calls,
    async sendOtp(phone, code) {
      calls.push({ phone, code });
    },
  };
};

interface FakeAdmin extends KeycloakAdminClient {
  emailVerifiedCalls: Array<{ sub: string; verifiedAt: string }>;
  phoneVerifiedCalls: Array<{ sub: string; phone: string; verifiedAt: string }>;
}
const buildFakeAdmin = (): FakeAdmin => {
  const emailVerifiedCalls: FakeAdmin['emailVerifiedCalls'] = [];
  const phoneVerifiedCalls: FakeAdmin['phoneVerifiedCalls'] = [];
  return {
    emailVerifiedCalls,
    phoneVerifiedCalls,
    async setEmailVerified(sub, verifiedAt) {
      emailVerifiedCalls.push({ sub, verifiedAt });
    },
    async setPhoneVerified(sub, phone, verifiedAt) {
      phoneVerifiedCalls.push({ sub, phone, verifiedAt });
    },
  };
};

// Same call-shim as auth.flow.test.ts (rate-limit-redis needs SCRIPT/EVALSHA).
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

const buildHarness = async () => {
  const log = createLogger(env);
  // ioredis-mock shares its in-memory store across instances by default.
  // Flush before each harness so a previous test's rate-limit counter
  // doesn't leak into this one (the send-otp limiter is per-`sub` and
  // every test logs in as `user-123`).
  const redis = installCallShim(new IoRedisMock());
  await redis.flushall();
  const keycloak = buildFakeKeycloak();
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
  const otpStore = new OtpStore(redis, env.OTP_TTL_SECONDS);
  const emailOtp = buildFakeEmail();
  const waOtp = buildFakeWa();
  const keycloakAdmin = buildFakeAdmin();
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
      keycloakAdmin,
      authStateStore: new AuthStateStore(redis, env.AUTHSTATE_TTL_SECONDS),
      bffCodeStore: new BffCodeStore(redis, env.BFFCODE_TTL_SECONDS),
      sessionStore: new SessionStore(redis, env.SESSION_TTL_SECONDS),
      userSessionsStore: new UserSessionsStore(redis, env.SESSION_TTL_SECONDS),
      otpStore,
      emailOtp,
      waOtp,
      internalJwtIssuer,
    },
  });
  return { app, redis, otpStore, emailOtp, waOtp, keycloakAdmin };
};

/** Log a user in and return the bearer + session_id. */
const login = async (app: ReturnType<typeof createApp>) => {
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

/** Decode a JWT payload without verifying. */
const claims = (jwt: string): Record<string, unknown> => {
  const part = jwt.split('.')[1] ?? '';
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
};

describe('email OTP — POST /auth/email/{send,verify}-otp', () => {
  let h: Awaited<ReturnType<typeof buildHarness>>;

  beforeEach(async () => {
    h = await buildHarness();
  });

  it('happy path: send → verify with correct code → JWT flips email_verified=true', async () => {
    const { bearer } = await login(h.app);

    const sendRes = await request(h.app)
      .post('/auth/email/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({});
    expect(sendRes.status).toBe(202);
    expect(sendRes.body).toMatchObject({ delivery: 'email', expires_in: 300 });
    expect(h.emailOtp.calls).toHaveLength(1);
    const code = h.emailOtp.calls[0]!.code;
    expect(code).toMatch(/^\d{6}$/);
    expect(h.emailOtp.calls[0]!.to).toBe('andi@example.test');

    const verifyRes = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code });
    expect(verifyRes.status).toBe(200);
    expect(verifyRes.body.verified).toBe(true);
    expect(verifyRes.body.access_token).toBeTypeOf('string');
    expect(verifyRes.body.session_id).toBeTypeOf('string');

    // New JWT carries email_verified=true.
    expect(claims(verifyRes.body.access_token).email_verified).toBe(true);
    // Admin API was called for the right user with an ISO timestamp.
    expect(h.keycloakAdmin.emailVerifiedCalls).toHaveLength(1);
    expect(h.keycloakAdmin.emailVerifiedCalls[0]!.sub).toBe('user-123');
    expect(h.keycloakAdmin.emailVerifiedCalls[0]!.verifiedAt).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/,
    );
  });

  it('wrong code: 422 with attempts_left in detail; record still alive', async () => {
    const { bearer } = await login(h.app);
    await request(h.app)
      .post('/auth/email/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({});

    const res = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code: '000000' }); // very unlikely to collide with the real code
    expect(res.status).toBe(422);
    expect(res.body.error).toBe('otp_invalid');
    expect(res.body.detail.attempts_left).toBe(env.OTP_MAX_ATTEMPTS - 1);
    // No admin write on failure.
    expect(h.keycloakAdmin.emailVerifiedCalls).toEqual([]);
  });

  it('exhausted budget: 5 wrong attempts purge the record; 6th returns 410', async () => {
    const { bearer } = await login(h.app);
    await request(h.app)
      .post('/auth/email/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({});

    for (let i = 0; i < env.OTP_MAX_ATTEMPTS - 1; i++) {
      const r = await request(h.app)
        .post('/auth/email/verify-otp')
        .set('Authorization', `Bearer ${bearer}`)
        .send({ code: '000000' });
      expect(r.status).toBe(422);
      expect(r.body.detail.attempts_left).toBe(env.OTP_MAX_ATTEMPTS - 1 - i);
    }

    // Last wrong attempt: 410 otp_exhausted.
    const exhaust = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code: '000000' });
    expect(exhaust.status).toBe(410);
    expect(exhaust.body.error).toBe('otp_exhausted');

    // Any further attempts hit otp_expired (no record left).
    const next = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code: '000000' });
    expect(next.status).toBe(410);
    expect(next.body.error).toBe('otp_expired');
  });

  it('verify without a send: 410 otp_expired', async () => {
    const { bearer } = await login(h.app);
    const res = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code: '123456' });
    expect(res.status).toBe(410);
    expect(res.body.error).toBe('otp_expired');
  });

  it('missing bearer: 401', async () => {
    const res = await request(h.app).post('/auth/email/send-otp').send({});
    expect(res.status).toBe(401);
  });

  it('malformed body (code wrong length): 400', async () => {
    const { bearer } = await login(h.app);
    await request(h.app)
      .post('/auth/email/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({});
    const res = await request(h.app)
      .post('/auth/email/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ code: '12345' });
    expect(res.status).toBe(400);
  });
});

describe('phone OTP — POST /auth/phone/{send,verify}-otp', () => {
  let h: Awaited<ReturnType<typeof buildHarness>>;

  beforeEach(async () => {
    h = await buildHarness();
  });

  it('happy path: send {phone} → verify with correct {phone,code} → JWT flips', async () => {
    const { bearer } = await login(h.app);
    const sendRes = await request(h.app)
      .post('/auth/phone/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ phone: '+6281234567890' });
    expect(sendRes.status).toBe(202);
    expect(h.waOtp.calls).toHaveLength(1);
    expect(h.waOtp.calls[0]!.phone).toBe('+6281234567890');
    const code = h.waOtp.calls[0]!.code;

    const verifyRes = await request(h.app)
      .post('/auth/phone/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ phone: '+6281234567890', code });
    expect(verifyRes.status).toBe(200);
    expect(verifyRes.body.verified).toBe(true);
    expect(claims(verifyRes.body.access_token).phone_number_verified).toBe(true);
    expect(claims(verifyRes.body.access_token).phone_number).toBe('+6281234567890');
    expect(h.keycloakAdmin.phoneVerifiedCalls).toHaveLength(1);
    expect(h.keycloakAdmin.phoneVerifiedCalls[0]!.sub).toBe('user-123');
    expect(h.keycloakAdmin.phoneVerifiedCalls[0]!.phone).toBe('+6281234567890');
    expect(h.keycloakAdmin.phoneVerifiedCalls[0]!.verifiedAt).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/,
    );
  });

  it('phone binding: verifying against a different number than was issued is rejected (410)', async () => {
    const { bearer } = await login(h.app);
    await request(h.app)
      .post('/auth/phone/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ phone: '+6281234567890' });
    const code = h.waOtp.calls[0]!.code;

    const res = await request(h.app)
      .post('/auth/phone/verify-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ phone: '+6285999999999', code }); // different number, same code
    // Same opaque 410 — no oracle for which field was wrong.
    expect(res.status).toBe(410);
    expect(h.keycloakAdmin.phoneVerifiedCalls).toEqual([]);
  });

  it('invalid phone format: 400', async () => {
    const { bearer } = await login(h.app);
    const res = await request(h.app)
      .post('/auth/phone/send-otp')
      .set('Authorization', `Bearer ${bearer}`)
      .send({ phone: '081234567890' }); // missing +62
    expect(res.status).toBe(400);
  });
});
