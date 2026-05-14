import IoRedisMock from 'ioredis-mock';
import type Redis from 'ioredis';
import { beforeEach, describe, expect, it } from 'vitest';
import { compareCode, OtpStore } from '../src/auth/stores/otp.store.js';

const redis = (): Redis => new IoRedisMock();

describe('OtpStore', () => {
  let r: Redis;
  let store: OtpStore;

  beforeEach(() => {
    r = redis();
    store = new OtpStore(r, 300);
  });

  it('issue() writes a record with a hashed code (plaintext NOT persisted)', async () => {
    await store.issue({
      channel: 'email',
      sub: 'user-1',
      destination: 'andi@example.test',
      code: '123456',
    });
    // Pull the raw Redis value to confirm the plaintext code isn't there.
    const raw = await r.get('otp:email:user-1');
    if (raw === null) throw new Error('expected Redis record to exist');
    expect(raw).not.toContain('123456');
    const parsed = JSON.parse(raw);
    expect(parsed.codeHash).toMatch(/^[a-f0-9]{64}$/);
    expect(parsed.destination).toBe('andi@example.test');
  });

  it('compareCode() returns true for the issued code, false otherwise', async () => {
    await store.issue({
      channel: 'phone',
      sub: 'user-2',
      destination: '+6281234567890',
      code: '654321',
    });
    const record = await store.get(store.channelKey('phone', 'user-2'));
    expect(record).not.toBeNull();
    expect(compareCode(record!, '654321', 'user-2')).toBe(true);
    expect(compareCode(record!, '654322', 'user-2')).toBe(false);
    // Pepper isolation: same code under a different sub does NOT match.
    expect(compareCode(record!, '654321', 'user-other')).toBe(false);
  });

  it('incrAttempts() bumps the counter and gives it the OTP TTL', async () => {
    await store.issue({
      channel: 'email',
      sub: 'user-3',
      destination: 'x@y',
      code: '000000',
    });
    expect(await store.incrAttempts('email', 'user-3')).toBe(1);
    expect(await store.incrAttempts('email', 'user-3')).toBe(2);
    expect(await store.incrAttempts('email', 'user-3')).toBe(3);
    expect(await store.getAttempts('email', 'user-3')).toBe(3);
    // Counter shares the record's TTL.
    const ttl = await r.ttl('otp:email:user-3:attempts');
    expect(ttl).toBeGreaterThan(0);
    expect(ttl).toBeLessThanOrEqual(300);
  });

  it('incrAttempts() returns null when no record exists', async () => {
    expect(await store.incrAttempts('email', 'missing-user')).toBeNull();
    // …and does NOT leave a stray counter behind (otherwise an attacker
    // could probe whether a user has an OTP outstanding).
    expect(await r.exists('otp:email:missing-user:attempts')).toBe(0);
  });

  it('delete() purges both the record and the attempts counter', async () => {
    await store.issue({
      channel: 'phone',
      sub: 'user-4',
      destination: '+6281234567890',
      code: '111111',
    });
    await store.incrAttempts('phone', 'user-4');
    await store.delete(store.channelKey('phone', 'user-4'));
    expect(await store.get(store.channelKey('phone', 'user-4'))).toBeNull();
    expect(await r.exists('otp:phone:user-4:attempts')).toBe(0);
  });

  it('issue() overwrites the previous record AND resets the attempts counter', async () => {
    await store.issue({
      channel: 'email',
      sub: 'user-5',
      destination: 'a@b',
      code: '111111',
    });
    await store.incrAttempts('email', 'user-5');
    await store.incrAttempts('email', 'user-5');
    expect(await store.getAttempts('email', 'user-5')).toBe(2);
    // Re-issue with a fresh code — fresh budget too.
    await store.issue({
      channel: 'email',
      sub: 'user-5',
      destination: 'a@b',
      code: '222222',
    });
    expect(await store.getAttempts('email', 'user-5')).toBe(0);
    const rec = await store.get(store.channelKey('email', 'user-5'));
    expect(rec).not.toBeNull();
    expect(compareCode(rec!, '222222', 'user-5')).toBe(true);
    expect(compareCode(rec!, '111111', 'user-5')).toBe(false);
  });
});
