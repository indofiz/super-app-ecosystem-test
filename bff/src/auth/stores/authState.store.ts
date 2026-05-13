import type { Redis } from 'ioredis';

export interface AuthStateRecord {
  appCodeChallenge: string;
  appRedirectUri: string;
  appState: string;
  appClientId: string;
  bffCodeVerifier: string;
}

const key = (state: string) => `authstate:${state}`;

export class AuthStateStore {
  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  async put(state: string, record: AuthStateRecord): Promise<void> {
    await this.redis.set(key(state), JSON.stringify(record), 'EX', this.ttlSeconds);
  }

  /** Atomic get + delete (single-use). */
  async take(state: string): Promise<AuthStateRecord | null> {
    const raw = await this.redis.getdel(key(state));
    return raw ? (JSON.parse(raw) as AuthStateRecord) : null;
  }
}
