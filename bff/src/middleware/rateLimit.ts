import rateLimit, { type RateLimitRequestHandler } from 'express-rate-limit';
import type { Redis } from 'ioredis';
import RedisStore, { type RedisReply } from 'rate-limit-redis';

// Redis-backed limiters (§3.5 / IMPROVEMENT_PLAN item #5). The previous
// in-memory store gave each replica its own counter — so an attacker
// effectively got `limit × N` per minute. With a shared Redis store the
// configured limits are global across the deployment.
//
// Each limiter gets a unique key prefix so counters don't collide across
// endpoints. Tests inject ioredis-mock and a per-test prefix is unnecessary
// because each test builds a fresh mock instance.

const buildStore = (redis: Redis, prefix: string): RedisStore =>
  new RedisStore({
    prefix,
    sendCommand: async (...args: string[]) => {
      const [cmd, ...rest] = args;
      return (await redis.call(cmd ?? '', ...rest)) as RedisReply;
    },
  });

export const buildAuthorizeLimiter = (redis: Redis): RateLimitRequestHandler =>
  rateLimit({
    store: buildStore(redis, 'rl:authorize:'),
    windowMs: 60_000,
    limit: 30,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'rate_limited', error_description: 'Too many authorize requests' },
  });

export const buildTokenLimiter = (redis: Redis): RateLimitRequestHandler =>
  rateLimit({
    store: buildStore(redis, 'rl:token:'),
    windowMs: 60_000,
    limit: 10,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'rate_limited', error_description: 'Too many token requests' },
  });

export const buildRefreshLimiter = (redis: Redis): RateLimitRequestHandler =>
  rateLimit({
    store: buildStore(redis, 'rl:refresh:'),
    windowMs: 60_000,
    limit: 10,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'rate_limited', error_description: 'Too many refresh requests' },
  });

// /me is cheap to call but enables session enumeration if unbounded. Keyed
// on the verified `sid` claim when present (set by requireSessionBearer in
// strict mode), with IP as a fallback for the missing-bearer path (which
// will already be 401'd before reaching the limiter, but the key still has
// to exist for express-rate-limit's contract).
export const buildMeLimiter = (redis: Redis): RateLimitRequestHandler =>
  rateLimit({
    store: buildStore(redis, 'rl:me:'),
    windowMs: 60_000,
    limit: 60,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => req.claims?.sid ?? req.ip ?? 'unknown',
    message: { error: 'rate_limited', error_description: 'Too many /me requests' },
  });
