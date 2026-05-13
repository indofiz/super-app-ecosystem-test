import type { RequestHandler } from 'express';
import express from 'express';
import { z } from 'zod';
import { badRequest, badRequestFromZod } from '../../lib/errors.js';
import type { KeycloakJwtVerifier } from '../../lib/keycloakJwt.js';
import type { Logger } from '../../lib/logger.js';
import type { MetricsBundle } from '../../lib/metrics.js';
import type { SessionStore } from '../stores/session.store.js';
import type { UserSessionsStore } from '../stores/userSessions.store.js';

const BodySchema = z.object({
  logout_token: z.string().min(1),
});

// OIDC back-channel logout: https://openid.net/specs/openid-connect-backchannel-1_0.html
// The logout_token MUST:
//   - be JWT-signed by KC's JWKS (handled by keycloakJwtVerifier)
//   - have iss = KC realm issuer                   (handled by verifier)
//   - have aud = KC client_id of the BFF           (handled by verifier)
//   - contain `events` claim with the back-channel-logout event URI
//   - contain `sub` and/or `sid`
//   - MUST NOT contain `nonce` (that would mean it's actually an id_token)
const BACKCHANNEL_EVENT_URI = 'http://schemas.openid.net/event/backchannel-logout';

export const makeBackchannelLogoutHandler = (deps: {
  keycloakJwtVerifier: KeycloakJwtVerifier;
  sessionStore: SessionStore;
  userSessionsStore: UserSessionsStore;
  metrics?: MetricsBundle;
  log?: Logger;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = BodySchema.safeParse(req.body);
      if (!parsed.success) {
        throw badRequestFromZod(parsed.error, 'logout_token required');
      }

      let claims;
      try {
        claims = await deps.keycloakJwtVerifier.verifyLogoutToken(parsed.data.logout_token);
      } catch (err) {
        deps.log?.warn({ err }, 'back-channel logout: token verification failed');
        throw badRequest('invalid_request', 'logout_token verification failed');
      }

      if (!claims.events || !(BACKCHANNEL_EVENT_URI in claims.events)) {
        throw badRequest('invalid_request', 'logout_token missing back-channel event');
      }
      if (!claims.sub && !claims.sid) {
        throw badRequest('invalid_request', 'logout_token must contain sub or sid');
      }
      // OIDC forbids `nonce`; presence indicates this is an id_token, not a
      // logout_token. Defence-in-depth.
      if (claims.nonce !== undefined) {
        throw badRequest('invalid_request', 'logout_token must not contain nonce');
      }

      let purged = 0;
      if (claims.sub) {
        const sids = await deps.userSessionsStore.list(claims.sub);
        for (const sid of sids) {
          await deps.sessionStore.delete(sid);
          await deps.userSessionsStore.remove(claims.sub, sid);
          purged++;
        }
      }
      if (claims.sid && !claims.sub) {
        // KC's `sid` may not equal our internal `sid`. We don't index by
        // KC sid today; document and ignore. Tools that want strict
        // sid-based revocation should also send `sub`.
        deps.log?.debug({ kcSid: claims.sid }, 'back-channel logout: ignoring KC sid');
      }

      deps.log?.info({ sub: claims.sub, purged }, 'back-channel logout processed');

      res.setHeader('Cache-Control', 'no-store');
      res.status(200).end();
    } catch (err) {
      next(err);
    }
  };
};

/**
 * urlencoded parser scoped to this single route, since the rest of the
 * BFF accepts only JSON. AUDIT PR-6 dropped the global urlencoded body
 * parser; back-channel logout is the only endpoint that needs it (the
 * spec mandates application/x-www-form-urlencoded).
 */
export const backchannelLogoutUrlencoded = express.urlencoded({
  extended: false,
  limit: '8kb',
});
