import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import express from 'express';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import type { Env } from '../src/config/env.js';
import { buildHealthRouter } from '../src/health/router.js';
import type { KeycloakClient, OidcDiscovery } from '../src/lib/keycloak.js';

// IMPROVEMENT_PLAN §3.1 / item #6 (health probes slice).

const env = {
  BUILD_COMMIT: 'abcdef0',
  BUILD_VERSION: '0.0.0-test',
} as unknown as Env;

const baseDiscovery: OidcDiscovery = {
  issuer: 'https://kc.example.test/realms/x',
  authorization_endpoint: 'https://kc.example.test/auth',
  token_endpoint: 'https://kc.example.test/token',
};

const okKc: KeycloakClient = {
  getDiscovery: async () => baseDiscovery,
} as unknown as KeycloakClient;

const slowKc: KeycloakClient = {
  getDiscovery: () => new Promise<OidcDiscovery>(() => {}), // never resolves
} as unknown as KeycloakClient;

const buildAppWith = (redis: Redis, keycloak?: KeycloakClient) => {
  const app = express();
  app.use('/', buildHealthRouter({ redis, keycloak, env }));
  return app;
};

describe('health router — §3.1', () => {
  it('/healthz returns 200 with version + commit + uptime', async () => {
    const redis = new IoRedisMock() as unknown as Redis;
    const app = buildAppWith(redis);
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'ok',
      version: '0.0.0-test',
      commit: 'abcdef0',
    });
    expect(typeof res.body.uptime_s).toBe('number');
  });

  it('/readyz returns 200 with redis ok and keycloak ok', async () => {
    const redis = new IoRedisMock() as unknown as Redis;
    const app = buildAppWith(redis, okKc);
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(200);
    expect(res.body.checks).toEqual({ redis: 'ok', keycloak: 'ok' });
  });

  it('/readyz returns 503 when keycloak discovery times out', async () => {
    const redis = new IoRedisMock() as unknown as Redis;
    const app = buildAppWith(redis, slowKc);
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(503);
    expect(res.body.status).toBe('unavailable');
    expect(res.body.checks.redis).toBe('ok');
    expect(res.body.checks.keycloak).toMatch(/timed out/);
  });

  it('/readyz returns 503 when redis ping fails', async () => {
    const redis = {
      ping: async () => {
        throw new Error('ECONNREFUSED');
      },
    } as unknown as Redis;
    const app = buildAppWith(redis, okKc);
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(503);
    expect(res.body.checks.redis).toMatch(/ECONNREFUSED/);
  });

  it('/livez returns 200 by default with event-loop p99', async () => {
    const redis = new IoRedisMock() as unknown as Redis;
    const app = buildAppWith(redis);
    const res = await request(app).get('/livez');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(typeof res.body.event_loop_p99_ms).toBe('number');
  });
});
