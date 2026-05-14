import { createHash, timingSafeEqual } from 'node:crypto';
import type { Redis } from 'ioredis';
import { z } from 'zod';
import { RedisJsonStore } from './redisJson.store.js';

/**
 * One in-flight OTP per (channel, user). The plaintext code is never
 * persisted — we store `sha256(code + ':' + sub)` so a Redis dump leak
 * doesn't reveal active codes. The `sub` acts as a per-user pepper:
 * identical codes for different users hash differently.
 *
 * `destination` carries the email / phone the OTP was sent to. Verify
 * checks it matches the body so a user can't request "send OTP to
 * +6281…" and then verify against "+6285…".
 *
 * Attempts counter lives in a sibling key (`otp:<channel>:<sub>:attempts`)
 * so we can use a plain `INCR` for atomicity — no Lua / WATCH-MULTI
 * dance, and it works against ioredis-mock in tests. The two keys share
 * the same TTL so they expire together.
 *
 * Lifecycle:
 *   issue(sub, ...)         on send-otp (overwrites any existing record + counter)
 *   get(channelKey(...))    on verify-otp to read the record for compareCode
 *   incrAttempts(...)       on a mismatch — returns the new count
 *   delete(channelKey(...)) when consumed or exhausted
 */
export const OtpChannelZ = z.enum(['email', 'phone']);
export type OtpChannel = z.infer<typeof OtpChannelZ>;

export const OtpRecordZ = z.object({
  channel: OtpChannelZ,
  destination: z.string().min(1),
  codeHash: z.string().min(1),
  createdAt: z.string().min(1),
});
export type OtpRecord = z.infer<typeof OtpRecordZ>;

const hashCode = (code: string, sub: string): string =>
  createHash('sha256').update(`${code}:${sub}`).digest('hex');

export const compareCode = (record: OtpRecord, code: string, sub: string): boolean => {
  const a = Buffer.from(record.codeHash, 'hex');
  const b = Buffer.from(hashCode(code, sub), 'hex');
  return a.length === b.length && timingSafeEqual(a, b);
};

export class OtpStore extends RedisJsonStore<OtpRecord> {
  constructor(redis: Redis, ttlSeconds: number) {
    super(redis, 'otp', ttlSeconds, OtpRecordZ);
  }

  protected override key(id: string): string {
    return `${this.prefix}:${id}`;
  }

  /** Build the storage key from channel + sub. Public so handlers can
   *  reference a single key for `get` / `delete` lookups. */
  channelKey(channel: OtpChannel, sub: string): string {
    return `${channel}:${sub}`;
  }

  private attemptsKey(channel: OtpChannel, sub: string): string {
    return `${this.prefix}:${channel}:${sub}:attempts`;
  }

  async issue(params: {
    channel: OtpChannel;
    sub: string;
    destination: string;
    code: string;
  }): Promise<void> {
    // Reset the attempts counter atomically with the new record so a
    // re-issue gives the user a fresh 5-tries budget.
    await this.redis.del(this.attemptsKey(params.channel, params.sub));
    await this.put(this.channelKey(params.channel, params.sub), {
      channel: params.channel,
      destination: params.destination,
      codeHash: hashCode(params.code, params.sub),
      createdAt: new Date().toISOString(),
    });
  }

  /** Read current attempts count without modifying it. Returns 0 when
   *  no counter exists (no failed attempts yet). */
  async getAttempts(channel: OtpChannel, sub: string): Promise<number> {
    const raw = await this.redis.get(this.attemptsKey(channel, sub));
    return raw ? parseInt(raw, 10) : 0;
  }

  /** Atomic `INCR` of the attempts counter. Returns the new count, or
   *  `null` if no OTP record exists for this (channel, sub) — the
   *  caller should treat that as 410 (resend required). The counter
   *  shares TTL with the record so they expire together.  */
  async incrAttempts(channel: OtpChannel, sub: string): Promise<number | null> {
    // No record → don't even start counting. Avoids leaking "has there
    // been an OTP attempt for this user?" info via a stray counter.
    const recordKey = this.key(this.channelKey(channel, sub));
    const exists = await this.redis.exists(recordKey);
    if (exists === 0) return null;
    const counterKey = this.attemptsKey(channel, sub);
    const next = await this.redis.incr(counterKey);
    // First increment → set TTL. Subsequent increments leave it alone
    // (re-EXPIRE would only push the counter past the record's expiry).
    if (next === 1) {
      await this.redis.expire(counterKey, this.ttlSeconds);
    }
    return next;
  }

  override async delete(id: string): Promise<void> {
    // Delete both keys. `id` is the channelKey (`<channel>:<sub>`).
    const [channel, sub] = id.split(':', 2);
    await this.redis.del(
      this.key(id),
      `${this.prefix}:${channel ?? ''}:${sub ?? ''}:attempts`,
    );
  }
}
