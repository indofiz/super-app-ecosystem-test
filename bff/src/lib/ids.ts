import { randomBytes } from 'node:crypto';

export const randomUrlSafe = (bytes = 32): string =>
  randomBytes(bytes).toString('base64url');
