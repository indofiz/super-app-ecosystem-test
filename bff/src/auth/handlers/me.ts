import type { RequestHandler } from 'express';
import { unauthorized } from '../../lib/errors.js';
import type { SessionStore } from '../stores/session.store.js';

/**
 * Returns the authenticated user's profile.
 *
 * Mobile sends `Authorization: Bearer <internal-jwt>`. The bearer is verified
 * by `requireSessionBearer('strict')` in the router and the verified claims
 * are attached to the request. We just look up the cached session profile.
 */
export const makeMeHandler = (deps: {
  sessionStore: SessionStore;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const claims = req.claims;
      if (!claims) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      const session = await deps.sessionStore.get(claims.sid);
      if (!session) {
        throw unauthorized('invalid_session', 'Session not found or expired');
      }

      res.setHeader('Cache-Control', 'no-store');
      res.json({
        sub: claims.sub,
        username: session.profile?.username ?? null,
        email: session.profile?.email ?? null,
        roles: session.profile?.roles ?? [],
        expiresAt: new Date(claims.exp * 1000).toISOString(),
      });
    } catch (err) {
      next(err);
    }
  };
};
