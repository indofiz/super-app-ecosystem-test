import express from 'express';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { timeoutMiddleware } from '../src/middleware/timeout.js';

describe('timeoutMiddleware — AUDIT PR-4', () => {
  it('returns 504 upstream_timeout when a handler does not respond in time', async () => {
    const app = express();
    app.use(timeoutMiddleware(50));
    app.get('/slow', (_req, _res) => {
      // intentionally never responds
    });
    const res = await request(app).get('/slow');
    expect(res.status).toBe(504);
    expect(res.body).toMatchObject({ error: 'upstream_timeout' });
  });

  it('does not interfere with a fast handler', async () => {
    const app = express();
    app.use(timeoutMiddleware(5_000));
    app.get('/fast', (_req, res) => {
      res.json({ ok: true });
    });
    const res = await request(app).get('/fast');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });
});
