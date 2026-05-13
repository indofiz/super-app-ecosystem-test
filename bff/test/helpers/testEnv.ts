import type { Env } from '../../src/config/env.js';

/**
 * Default-shaped Env for tests. Use spread + override:
 *   const env = makeTestEnv({ SESSION_TTL_SECONDS: 5 });
 *
 * Keep this in sync with `src/config/env.ts`'s `EnvSchema`. The helper is
 * the single point where new env fields land — adding a field to the
 * schema with a default no longer requires editing every test fixture.
 */
export const makeTestEnv = (overrides: Partial<Env> = {}): Env => ({
  PORT: 3000,
  NODE_ENV: 'test',
  LOG_LEVEL: 'error',
  PUBLIC_BASE_URL: 'http://localhost:3000',
  KC_ISSUER: 'https://kc.example.test/realms/pangkalpinang',
  KC_CLIENT_ID: 'super-app-bff',
  KC_CLIENT_SECRET: 'shh',
  KC_SCOPES: 'openid profile email',
  ALLOWED_APP_CLIENTS: ['super-app-eco'],
  ALLOWED_APP_REDIRECT_URIS: ['id.go.pangkalpinangkota.smartapptest:/oauth2redirect'],
  REDIS_URL: 'redis://localhost:6379',
  SESSION_TTL_SECONDS: 600,
  AUTHSTATE_TTL_SECONDS: 600,
  BFFCODE_TTL_SECONDS: 600,
  CORS_ORIGINS: [],
  TRUST_PROXY: 'loopback',
  REQUEST_TIMEOUT_MS: 12_000,
  BFF_INTERNAL_JWT_ALG: 'RS256',
  BFF_INTERNAL_JWT_ACTIVE_KID: 'v1',
  BFF_INTERNAL_JWT_PRIVATE_KEY: '',
  BFF_INTERNAL_JWT_PUBLIC_KEYS: [],
  BFF_INTERNAL_JWT_TTL_SECONDS: 300,
  BFF_INTERNAL_JWT_ISSUER: 'super-app-bff',
  BFF_INTERNAL_JWT_AUDIENCE: 'super-app-services',
  METRICS_ENABLED: false,
  TRACING_ENABLED: false,
  OTEL_SERVICE_NAME: 'super-app-bff-test',
  BUILD_COMMIT: 'test',
  BUILD_VERSION: 'test',
  ...overrides,
});
