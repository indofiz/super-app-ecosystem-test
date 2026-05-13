import type { RequestHandler } from 'express';
import { unauthorized } from '../lib/errors.js';
import type { InternalJwtIssuer, InternalJwtVerifiedClaims } from '../lib/internalJwt.js';

// Augment Express's Request with the verified claims from the bearer.
// Routes that mount `requireSessionBearer` can read `req.claims!` safely;
// routes that don't will see `undefined`.
declare module 'express-serve-static-core' {
  interface Request {
    claims?: InternalJwtVerifiedClaims;
  }
}

/**
 * Bearer-required middleware for /refresh, /logout, /me. Closes
 * IMPROVEMENT_PLAN §2.1: a leaked `session_id` is no longer enough — the
 * caller must also present a bearer that was minted for that session.
 *
 * mode='strict':       full validation including `exp`. Used by /me.
 * mode='allowExpired': accepts a bearer whose `exp` is up to 24h in the past.
 *                       Used by /refresh (so a returning user can refresh a
 *                       just-expired access token) and /logout (the user is
 *                       leaving — we don't want to force a re-auth first).
 *                       Signature, iss, and aud are still required.
 */
export const requireSessionBearer = (
  issuer: InternalJwtIssuer,
  mode: 'strict' | 'allowExpired',
): RequestHandler => {
  return async (req, _res, next) => {
    try {
      const auth = req.headers.authorization ?? '';
      if (!auth.startsWith('Bearer ')) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      const token = auth.slice('Bearer '.length).trim();
      let claims: InternalJwtVerifiedClaims;
      try {
        claims =
          mode === 'allowExpired'
            ? await issuer.verifyAllowingExpired(token)
            : await issuer.verify(token);
      } catch {
        throw unauthorized('invalid_token', 'Bearer verification failed');
      }
      req.claims = claims;
      next();
    } catch (err) {
      next(err);
    }
  };
};
