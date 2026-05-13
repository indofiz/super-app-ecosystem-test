import { describe, expect, it } from 'vitest';
import { KeycloakClient } from '../src/lib/keycloak.js';
import { buildMetrics } from '../src/lib/metrics.js';
import { createLogger } from '../src/lib/logger.js';

// Lightweight axios stub. Each method records the URLs called and returns
// either a configured value or throws a configured error. We pass it via
// the http option so we don't need to monkey-patch axios's real client.
const stubAxios = (handlers: {
  get?: (url: string) => Promise<{ data: unknown }>;
  post?: (url: string) => Promise<{ data: unknown }>;
}) => {
  return {
    get: handlers.get ?? (async () => ({ data: {} })),
    post: handlers.post ?? (async () => ({ data: {} })),
  } as unknown as Parameters<typeof KeycloakClient.prototype.constructor>[0]['http'];
};

const log = createLogger({ LOG_LEVEL: 'fatal', NODE_ENV: 'test' });

describe('KeycloakClient.endSession — AUDIT S-1', () => {
  it('records outcome="error" when KC end_session returns 5xx', async () => {
    const metrics = buildMetrics();
    const client = new KeycloakClient({
      issuer: 'https://kc.example.test/realms/x',
      clientId: 'c',
      clientSecret: 's',
      log,
      metrics,
      http: stubAxios({
        get: async () => ({
          data: {
            issuer: 'https://kc.example.test/realms/x',
            authorization_endpoint: 'https://kc.example.test/auth',
            token_endpoint: 'https://kc.example.test/token',
            end_session_endpoint: 'https://kc.example.test/logout',
          },
        }),
        post: async () => {
          throw new Error('kc 503');
        },
      }),
    });

    // Should NOT throw — endSession is best-effort.
    await client.endSession('rt-1');

    const text = await metrics.registry.metrics();
    expect(text).toMatch(
      /keycloak_request_duration_seconds_count\{[^}]*op="end_session"[^}]*outcome="error"[^}]*\} 1/,
    );
    // And no "ok" outcome counter incremented for end_session.
    expect(text).not.toMatch(
      /keycloak_request_duration_seconds_count\{[^}]*op="end_session"[^}]*outcome="ok"[^}]*\} 1/,
    );
  });

  it('records outcome="ok" on successful end_session', async () => {
    const metrics = buildMetrics();
    const client = new KeycloakClient({
      issuer: 'https://kc.example.test/realms/x',
      clientId: 'c',
      clientSecret: 's',
      log,
      metrics,
      http: stubAxios({
        get: async () => ({
          data: {
            issuer: 'https://kc.example.test/realms/x',
            authorization_endpoint: 'https://kc.example.test/auth',
            token_endpoint: 'https://kc.example.test/token',
            end_session_endpoint: 'https://kc.example.test/logout',
          },
        }),
        post: async () => ({ data: {} }),
      }),
    });

    await client.endSession('rt-1');

    const text = await metrics.registry.metrics();
    expect(text).toMatch(
      /keycloak_request_duration_seconds_count\{[^}]*op="end_session"[^}]*outcome="ok"[^}]*\} 1/,
    );
  });
});
