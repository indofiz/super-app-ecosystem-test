import type { Redis } from 'ioredis';
import { z } from 'zod';
import { RedisJsonStore } from './redisJson.store.js';

export const AuthStateRecordZ = z.object({
  appCodeChallenge: z.string().min(1),
  appRedirectUri: z.string().min(1),
  appState: z.string().min(1),
  appClientId: z.string().min(1),
  bffCodeVerifier: z.string().min(1),
});

export type AuthStateRecord = z.infer<typeof AuthStateRecordZ>;

export class AuthStateStore extends RedisJsonStore<AuthStateRecord> {
  constructor(redis: Redis, ttlSeconds: number) {
    super(redis, 'authstate', ttlSeconds, AuthStateRecordZ);
  }
}
