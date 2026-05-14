import type { Redis } from 'ioredis';
import type { ZodType, ZodTypeDef } from 'zod';
import { upstream } from '../../lib/errors.js';

/**
 * Generic JSON-in-Redis store with schema-on-read.
 *
 * AUDIT A-1 / P-2 / M-2: the three auth stores (`authstate`, `bffcode`,
 * `session`) duplicated `JSON.stringify` + `SET EX` + `GETDEL` + `JSON.parse`
 * boilerplate, and none of them validated the parsed shape. A schema drift
 * between deploys (or a manual `redis-cli SET`) used to surface as a deep
 * TypeError 500. With this base class, a malformed record is caught at the
 * boundary and translated into a stable `store_corrupted` HttpError.
 *
 * The `prefix` should NOT include a trailing colon — the key builder adds it.
 */
export class RedisJsonStore<T> {
  constructor(
    protected readonly redis: Redis,
    protected readonly prefix: string,
    protected readonly ttlSeconds: number,
    // `ZodType<T, ZodTypeDef, unknown>` — input can be anything; the
    // schema's job is to parse `unknown` into `T`. Lets stores with
    // `.default()` fields (where input is optional but output is
    // required) satisfy this signature without losing T-typing.
    protected readonly schema: ZodType<T, ZodTypeDef, unknown>,
  ) {}

  protected key(id: string): string {
    return `${this.prefix}:${id}`;
  }

  async put(id: string, value: T): Promise<void> {
    await this.redis.set(this.key(id), JSON.stringify(value), 'EX', this.ttlSeconds);
  }

  async get(id: string): Promise<T | null> {
    const raw = await this.redis.get(this.key(id));
    return raw ? this.parse(raw) : null;
  }

  /** Atomic get + delete (single-use). */
  async take(id: string): Promise<T | null> {
    const raw = await this.redis.getdel(this.key(id));
    return raw ? this.parse(raw) : null;
  }

  async delete(id: string): Promise<void> {
    await this.redis.del(this.key(id));
  }

  /** Slide TTL on an existing record without rewriting its value. */
  async touch(id: string): Promise<boolean> {
    const ok = await this.redis.expire(this.key(id), this.ttlSeconds);
    return ok === 1;
  }

  private parse(raw: string): T {
    let candidate: unknown;
    try {
      candidate = JSON.parse(raw);
    } catch (err) {
      throw upstream('store_corrupted', `${this.prefix}: stored value is not JSON`, err);
    }
    const parsed = this.schema.safeParse(candidate);
    if (!parsed.success) {
      throw upstream(
        'store_corrupted',
        `${this.prefix}: stored value failed schema check`,
        parsed.error,
      );
    }
    return parsed.data;
  }
}
