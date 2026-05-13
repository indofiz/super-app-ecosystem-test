import type { Redis } from 'ioredis';

export interface BffCodeRecord {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  tokenType: string;
  expiresIn: number;
  scope?: string;
  sub?: string;
  appCodeChallenge: string;
  appRedirectUri: string;
  appClientId: string;
}

const key = (code: string) => `bffcode:${code}`;

export class BffCodeStore {
  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  async put(code: string, record: BffCodeRecord): Promise<void> {
    await this.redis.set(key(code), JSON.stringify(record), 'EX', this.ttlSeconds);
  }

  /** Atomic get + delete (single-use). */
  async take(code: string): Promise<BffCodeRecord | null> {
    const raw = await this.redis.getdel(key(code));
    return raw ? (JSON.parse(raw) as BffCodeRecord) : null;
  }
}
