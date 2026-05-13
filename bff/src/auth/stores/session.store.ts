import type { Redis } from 'ioredis';
import { z } from 'zod';
import { RedisJsonStore } from './redisJson.store.js';

export const SessionProfileZ = z.object({
  username: z.string().optional(),
  email: z.string().optional(),
  roles: z.array(z.string()),
});

export const SessionRecordZ = z.object({
  refreshToken: z.string().min(1),
  sub: z.string().min(1),
  appClientId: z.string().min(1),
  createdAt: z.string().min(1),
  lastUsedAt: z.string().min(1),
  profile: SessionProfileZ.optional(),
});

export type SessionProfile = z.infer<typeof SessionProfileZ>;
export type SessionRecord = z.infer<typeof SessionRecordZ>;

export class SessionStore extends RedisJsonStore<SessionRecord> {
  constructor(redis: Redis, ttlSeconds: number) {
    super(redis, 'session', ttlSeconds, SessionRecordZ);
  }
}
