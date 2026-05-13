import { generateKeyPairSync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { loadEnv } from '../src/config/env.js';

const { publicKey, privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const PRIVATE_B64 = Buffer.from(privateKey).toString('base64');
const PUBLIC_B64 = Buffer.from(publicKey).toString('base64');

const baseProcessEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
  PUBLIC_BASE_URL: 'http://localhost:3000',
  KC_ISSUER: 'https://kc.example.test/realms/x',
  KC_CLIENT_ID: 'super-app-bff',
  KC_CLIENT_SECRET: 'shh',
  ALLOWED_APP_CLIENTS: 'super-app-eco',
  ALLOWED_APP_REDIRECT_URIS: 'app:/cb',
  REDIS_URL: 'redis://localhost:6379',
  BFF_INTERNAL_JWT_ACTIVE_KID: 'dev-v1',
  BFF_INTERNAL_JWT_PRIVATE_KEY: PRIVATE_B64,
  BFF_INTERNAL_JWT_PUBLIC_KEYS: JSON.stringify([{ kid: 'dev-v1', pem: PUBLIC_B64 }]),
  ...overrides,
});

describe('env schema — AUDIT PR-7 caps + S-3 trust proxy', () => {
  it('accepts a minimal valid env', () => {
    const env = loadEnv(baseProcessEnv());
    expect(env.SESSION_TTL_SECONDS).toBeGreaterThan(0);
    expect(env.REQUEST_TIMEOUT_MS).toBe(12_000);
  });

  it('rejects SESSION_TTL_SECONDS above the 90-day cap', () => {
    expect(() =>
      loadEnv(baseProcessEnv({ SESSION_TTL_SECONDS: String(60 * 60 * 24 * 91) })),
    ).toThrow(/SESSION_TTL_SECONDS/);
  });

  it('rejects AUTHSTATE_TTL_SECONDS above the 1h cap', () => {
    expect(() => loadEnv(baseProcessEnv({ AUTHSTATE_TTL_SECONDS: String(60 * 60 + 1) }))).toThrow(
      /AUTHSTATE_TTL_SECONDS/,
    );
  });

  it('rejects BFFCODE_TTL_SECONDS above the 1h cap', () => {
    expect(() => loadEnv(baseProcessEnv({ BFFCODE_TTL_SECONDS: String(60 * 60 + 1) }))).toThrow(
      /BFFCODE_TTL_SECONDS/,
    );
  });

  it('rejects BFF_INTERNAL_JWT_TTL_SECONDS above the 30min cap', () => {
    expect(() =>
      loadEnv(baseProcessEnv({ BFF_INTERNAL_JWT_TTL_SECONDS: String(60 * 30 + 1) })),
    ).toThrow(/BFF_INTERNAL_JWT_TTL_SECONDS/);
  });

  it('rejects REQUEST_TIMEOUT_MS above 30_000', () => {
    expect(() => loadEnv(baseProcessEnv({ REQUEST_TIMEOUT_MS: '30001' }))).toThrow(
      /REQUEST_TIMEOUT_MS/,
    );
  });

  it('TRUST_PROXY supports integer hop counts', () => {
    const env = loadEnv(baseProcessEnv({ TRUST_PROXY: '2' }));
    expect(env.TRUST_PROXY).toBe(2);
  });

  it('TRUST_PROXY supports CSV CIDRs', () => {
    const env = loadEnv(baseProcessEnv({ TRUST_PROXY: '10.0.0.0/8,172.16.0.0/12' }));
    expect(env.TRUST_PROXY).toEqual(['10.0.0.0/8', '172.16.0.0/12']);
  });

  it('TRUST_PROXY supports named modes', () => {
    const env = loadEnv(baseProcessEnv({ TRUST_PROXY: 'uniquelocal' }));
    expect(env.TRUST_PROXY).toBe('uniquelocal');
  });

  it('rejects missing required env (PUBLIC_BASE_URL)', () => {
    const env = baseProcessEnv();
    delete env.PUBLIC_BASE_URL;
    expect(() => loadEnv(env)).toThrow(/PUBLIC_BASE_URL/);
  });

  it('rejects malformed PEM (non-base64)', () => {
    expect(() => loadEnv(baseProcessEnv({ BFF_INTERNAL_JWT_PRIVATE_KEY: '!!notbase64!!' }))).toThrow(
      /BFF_INTERNAL_JWT_PRIVATE_KEY/,
    );
  });

  it('rejects PUBLIC_KEYS that is not JSON', () => {
    expect(() =>
      loadEnv(baseProcessEnv({ BFF_INTERNAL_JWT_PUBLIC_KEYS: 'not json' })),
    ).toThrow(/BFF_INTERNAL_JWT_PUBLIC_KEYS/);
  });

  it('rejects activeKid missing from publicKeys', () => {
    expect(() =>
      loadEnv(
        baseProcessEnv({
          BFF_INTERNAL_JWT_ACTIVE_KID: 'no-such-kid',
        }),
      ),
    ).toThrow(/BFF_INTERNAL_JWT_ACTIVE_KID/);
  });
});
