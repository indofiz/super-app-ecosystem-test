import type { Redis } from 'ioredis';

/**
 * Index of `sub → {sid, ...}` so we can revoke every session for a user
 * in O(1) per session. Maintained alongside `session:*` rows.
 *
 * Used by:
 *   - back-channel logout (AUDIT S-5): KC sends a `logout_token` carrying
 *     `sub`; we look up all sids and delete them.
 *   - admin tooling: not yet, but the index is the only reasonable way to
 *     do a bulk revoke without SCAN.
 */
export class UserSessionsStore {
  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  private key(sub: string): string {
    return `sub:${sub}`;
  }

  async add(sub: string, sid: string): Promise<void> {
    await this.redis.sadd(this.key(sub), sid);
    // Set/refresh TTL on the index itself so an idle user's index doesn't
    // linger forever after their session expires.
    await this.redis.expire(this.key(sub), this.ttlSeconds);
  }

  async remove(sub: string, sid: string): Promise<void> {
    await this.redis.srem(this.key(sub), sid);
  }

  async list(sub: string): Promise<string[]> {
    return this.redis.smembers(this.key(sub));
  }

  async clear(sub: string): Promise<void> {
    await this.redis.del(this.key(sub));
  }
}
