import type { RequestHandler } from 'express';
import { z } from 'zod';
import { badRequest, unauthorized } from '../../lib/errors.js';
import type { KeycloakClient } from '../../lib/keycloak.js';
import type { SessionStore } from '../stores/session.store.js';

const BodySchema = z.object({
  session_id: z.string().min(1),
});

export const makeLogoutHandler = (deps: {
  keycloak: KeycloakClient;
  sessionStore: SessionStore;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = BodySchema.safeParse(req.body);
      if (!parsed.success) {
        throw badRequest('invalid_request', parsed.error.issues[0]?.message ?? 'Invalid body');
      }
      // §2.1: bearer required (router middleware), sid must match body.
      const claims = req.claims;
      if (!claims) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      if (claims.sid !== parsed.data.session_id) {
        throw unauthorized('sid_mismatch', 'Bearer is not bound to this session_id');
      }

      const session = await deps.sessionStore.get(parsed.data.session_id);
      if (session) {
        await deps.keycloak.endSession(session.refreshToken);
        await deps.sessionStore.delete(parsed.data.session_id);
      }
      res.setHeader('Cache-Control', 'no-store');
      res.status(204).end();
    } catch (err) {
      next(err);
    }
  };
};
