import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import { describe, expect, it } from 'vitest';
import { AuthStateStore } from '../src/auth/stores/authState.store.js';
import { BffCodeStore } from '../src/auth/stores/bffCode.store.js';
import { SessionStore } from '../src/auth/stores/session.store.js';

// AUDIT P-2 / M-2: stores now schema-check on read. A record poisoned via
// manual `redis-cli SET` (or a partial deploy with a drifting shape)
// surfaces as a stable `store_corrupted` HttpError instead of a deep
// TypeError 500.

const redis = (): Redis => new IoRedisMock();

describe('RedisJsonStore — AUDIT P-2', () => {
  it('SessionStore.get throws store_corrupted on missing required fields', async () => {
    const r = redis();
    const store = new SessionStore(r, 600);
    await r.set('session:abc', JSON.stringify({ sub: 'u1' }));
    await expect(store.get('abc')).rejects.toMatchObject({
      code: 'store_corrupted',
      status: 502,
    });
  });

  it('SessionStore.get throws store_corrupted on non-JSON payload', async () => {
    const r = redis();
    const store = new SessionStore(r, 600);
    await r.set('session:abc', 'not-json-at-all');
    await expect(store.get('abc')).rejects.toMatchObject({
      code: 'store_corrupted',
      status: 502,
    });
  });

  it('BffCodeStore.take throws store_corrupted on poisoned record', async () => {
    const r = redis();
    const store = new BffCodeStore(r, 600);
    await r.set('bffcode:c1', JSON.stringify({ tokenType: 'Bearer' }));
    await expect(store.take('c1')).rejects.toMatchObject({ code: 'store_corrupted' });
  });

  it('AuthStateStore happy roundtrip', async () => {
    const r = redis();
    const store = new AuthStateStore(r, 600);
    await store.put('s1', {
      appCodeChallenge: 'cc',
      appRedirectUri: 'app:/cb',
      appState: 'st',
      appClientId: 'app',
      bffCodeVerifier: 'cv',
    });
    const out = await store.take('s1');
    expect(out?.appClientId).toBe('app');
    // single-use
    expect(await store.take('s1')).toBeNull();
  });

  it('SessionStore.touch slides TTL only on existing key', async () => {
    const r = redis();
    const store = new SessionStore(r, 600);
    expect(await store.touch('missing')).toBe(false);
    await store.put('s1', {
      refreshToken: 'rt',
      sub: 'u1',
      appClientId: 'app',
      createdAt: '2026-01-01',
      lastUsedAt: '2026-01-01',
      profile: { roles: ['citizen'] },
    });
    expect(await store.touch('s1')).toBe(true);
  });
});
