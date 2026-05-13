import type { Redis } from 'ioredis';

export interface SessionProfile {
  username?: string;
  email?: string;
  roles: string[];
}

export interface SessionRecord {
  refreshToken: string;
  sub: string;
  appClientId: string;
  createdAt: string;
  lastUsedAt: string;
  /** Snapshot of user profile from the most recent KC token, used by /auth/me. */
  profile?: SessionProfile;
}

const key = (sid: string) => `session:${sid}`;

export class SessionStore {
  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  async put(sessionId: string, record: SessionRecord): Promise<void> {
    await this.redis.set(key(sessionId), JSON.stringify(record), 'EX', this.ttlSeconds);
  }

  async get(sessionId: string): Promise<SessionRecord | null> {
    const raw = await this.redis.get(key(sessionId));
    return raw ? (JSON.parse(raw) as SessionRecord) : null;
  }

  async update(sessionId: string, record: SessionRecord): Promise<void> {
    // Re-set with full TTL window (sliding session).
    await this.put(sessionId, record);
  }

  async delete(sessionId: string): Promise<void> {
    await this.redis.del(key(sessionId));
  }
}
