import type { Redis } from 'ioredis';
import { z } from 'zod';
import { RedisJsonStore } from './redisJson.store.js';

export const BffCodeRecordZ = z.object({
  accessToken: z.string().min(1),
  refreshToken: z.string().min(1).optional(),
  idToken: z.string().min(1).optional(),
  tokenType: z.string().min(1),
  expiresIn: z.number().int().nonnegative(),
  scope: z.string().optional(),
  sub: z.string().optional(),
  appCodeChallenge: z.string().min(1),
  appRedirectUri: z.string().min(1),
  appClientId: z.string().min(1),
});

export type BffCodeRecord = z.infer<typeof BffCodeRecordZ>;

export class BffCodeStore extends RedisJsonStore<BffCodeRecord> {
  constructor(redis: Redis, ttlSeconds: number) {
    super(redis, 'bffcode', ttlSeconds, BffCodeRecordZ);
  }
}
