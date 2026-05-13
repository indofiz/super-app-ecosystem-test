import express from 'express';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { generateKeyPairSync } from 'node:crypto';
import { errorMiddleware } from '../src/middleware/error.js';
import { requireSessionBearer } from '../src/middleware/sessionAuth.js';
import { InternalJwtIssuer } from '../src/lib/internalJwt.js';
import { createLogger } from '../src/lib/logger.js';

// AUDIT §4.6 / M-5: focused tests for the bearer middleware so coverage
// doesn't depend only on the auth-flow happy path.

const { publicKey, privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const buildApp = async () => {
  const issuer = await InternalJwtIssuer.create({
    alg: 'RS256',
    activeKid: 'v1',
    privateKeyPem: privateKey,
    publicKeys: [{ kid: 'v1', pem: publicKey }],
    issuer: 'super-app-bff',
    audience: 'super-app-services',
    ttlSeconds: 300,
  });
  const log = createLogger({ LOG_LEVEL: 'fatal', NODE_ENV: 'test' });
  const app = express();
  app.use(express.json());
  app.get('/check', requireSessionBearer(issuer, 'strict', log), (req, res) => {
    res.json({ sub: req.claims!.sub, sid: req.claims!.sid });
  });
  app.use(errorMiddleware(log));
  return { app, issuer };
};

describe('requireSessionBearer — AUDIT §4.6 + M-5', () => {
  it('rejects when Authorization header is absent', async () => {
    const { app } = await buildApp();
    const res = await request(app).get('/check');
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('missing_bearer');
  });

  it('rejects when scheme is not Bearer', async () => {
    const { app } = await buildApp();
    const res = await request(app).get('/check').set('Authorization', 'Basic abc');
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('missing_bearer');
  });

  it('rejects a malformed JWT', async () => {
    const { app } = await buildApp();
    const res = await request(app).get('/check').set('Authorization', 'Bearer not.a.jwt');
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('invalid_token');
  });

  it('rejects a JWT signed with an unknown key', async () => {
    const { app } = await buildApp();
    const rogueKeys = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const rogueIssuer = await InternalJwtIssuer.create({
      alg: 'RS256',
      activeKid: 'rogue',
      privateKeyPem: rogueKeys.privateKey,
      publicKeys: [{ kid: 'rogue', pem: rogueKeys.publicKey }],
      issuer: 'super-app-bff',
      audience: 'super-app-services',
      ttlSeconds: 300,
    });
    const { token } = await rogueIssuer.mint({ sub: 'attacker', sid: 's', roles: [] });
    const res = await request(app).get('/check').set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe('invalid_token');
  });

  it('accepts a valid bearer and exposes claims to the handler', async () => {
    const { app, issuer } = await buildApp();
    const { token } = await issuer.mint({ sub: 'u1', sid: 's1', roles: ['citizen'] });
    const res = await request(app).get('/check').set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ sub: 'u1', sid: 's1' });
  });
});
