import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

// RFC 7636: `plain` is permitted by the spec but discouraged. The Flutter
// client signs S256 (flutter_appauth) so we hard-reject `plain` to remove
// the downgrade option entirely. See IMPROVEMENT_PLAN §2.4.
export type PkceMethod = 'S256';

export const parsePkceMethod = (raw: string | undefined): PkceMethod => {
  const m = raw ?? 'S256';
  if (m !== 'S256') throw new Error(`Unsupported code_challenge_method: ${m} (only S256 allowed)`);
  return 'S256';
};

export const generateVerifier = (): string =>
  // 43–128 chars per RFC 7636. 64 random bytes → ~86 base64url chars.
  randomBytes(64).toString('base64url');

export const challengeFromVerifier = (verifier: string, _method: PkceMethod = 'S256'): string =>
  createHash('sha256').update(verifier).digest('base64url');

export const verifyChallenge = (verifier: string, expectedChallenge: string): boolean => {
  const computed = challengeFromVerifier(verifier);
  const a = Buffer.from(computed);
  const b = Buffer.from(expectedChallenge);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
};
