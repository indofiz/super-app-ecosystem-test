import type { Redis } from 'ioredis';
import { z } from 'zod';
import { RedisJsonStore } from './redisJson.store.js';

export const SessionProfileZ = z.object({
  username: z.string().optional(),
  email: z.string().optional(),
  // Defaults keep pre-verification-feature sessions readable post-deploy.
  // New sessions will always have explicit values from the upstream JWT.
  emailVerified: z.boolean().default(false),
  fullName: z.string().optional(),
  phoneNumber: z.string().optional(),
  phoneNumberVerified: z.boolean().default(false),
  // ISO-8601 timestamps written by the BFF when the corresponding OTP
  // verify succeeds (KC user attribute is the source of truth; this is
  // the session-cache mirror so /auth/me can render without a KC GET).
  // Users verified before this field existed read as undefined — honest
  // null beats a synthetic backfill.
  emailVerifiedAt: z.string().datetime().optional(),
  phoneVerifiedAt: z.string().datetime().optional(),
  nikVerifiedAt: z.string().datetime().optional(),
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
