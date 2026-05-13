import type { RequestHandler } from 'express';
import { unauthorized } from '../lib/errors.js';
import type { InternalJwtIssuer, InternalJwtVerifiedClaims } from '../lib/internalJwt.js';
import type { Logger } from '../lib/logger.js';

// Request augmentation for `claims` lives in `src/types/express.d.ts`
// alongside `req.id` (AUDIT M-3).

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
  log?: Logger,
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
      } catch (verifyErr) {
        // AUDIT M-5: collapse to a generic 401 on the wire (no oracle for
        // attackers) but log the underlying reason so ops can correlate
        // support tickets. Pino redaction strips the token itself.
        log?.debug(
          {
            err: verifyErr instanceof Error ? { name: verifyErr.name, message: verifyErr.message } : verifyErr,
            mode,
          },
          'bearer verify failed',
        );
        throw unauthorized('invalid_token', 'Bearer verification failed');
      }
      req.claims = claims;
      next();
    } catch (err) {
      next(err);
    }
  };
};
