import type { RequestHandler } from 'express';
import { z } from 'zod';
import { badRequestFromZod, unauthorized } from '../../lib/errors.js';
import type { InternalJwtIssuer } from '../../lib/internalJwt.js';
import { InvalidGrantError, type KeycloakClient } from '../../lib/keycloak.js';
import {
  KeycloakJwtVerificationError,
  verifyAndExtractProfile,
  type KeycloakJwtVerifier,
} from '../../lib/keycloakJwt.js';
import type { MetricsBundle } from '../../lib/metrics.js';
import type { SessionStore } from '../stores/session.store.js';
import type { UserSessionsStore } from '../stores/userSessions.store.js';

const BodySchema = z.object({
  session_id: z.string().min(1),
});

export const makeRefreshHandler = (deps: {
  keycloak: KeycloakClient;
  sessionStore: SessionStore;
  userSessionsStore: UserSessionsStore;
  internalJwtIssuer: InternalJwtIssuer;
  keycloakJwtVerifier: KeycloakJwtVerifier;
  metrics?: MetricsBundle;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = BodySchema.safeParse(req.body);
      if (!parsed.success) {
        throw badRequestFromZod(parsed.error, 'Invalid body');
      }
      // §2.1: bearer is required (router middleware) and its sid must match
      // the body session_id. Stops a leaked session_id from being usable
      // without the matching access_token.
      const claims = req.claims;
      if (!claims) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      if (claims.sid !== parsed.data.session_id) {
        throw unauthorized('sid_mismatch', 'Bearer is not bound to this session_id');
      }

      const session = await deps.sessionStore.get(parsed.data.session_id);
      if (!session) {
        throw unauthorized('invalid_session', 'Session not found or expired');
      }

      let tokens;
      try {
        tokens = await deps.keycloak.refresh(session.refreshToken);
      } catch (err) {
        // §5.3: KC says the refresh token is gone (revoked, super-session
        // ended, realm change). The local session is now unusable; purge it
        // so the next call returns invalid_session immediately instead of
        // hammering KC with a dead token.
        if (err instanceof InvalidGrantError) {
          await deps.sessionStore.delete(parsed.data.session_id);
          await deps.userSessionsStore.remove(session.sub, parsed.data.session_id);
          throw unauthorized('invalid_session', 'Upstream rejected refresh; session cleared');
        }
        throw err;
      }

      // §2.3: verify the refreshed tokens before trusting their claims. If
      // KC just handed us tokens we can't verify, treat it like §5.3 — the
      // upstream view of this session is broken; purge and force re-auth.
      let extracted;
      try {
        extracted = await verifyAndExtractProfile(
          deps.keycloakJwtVerifier,
          tokens.access_token,
          tokens.id_token,
          session.sub,
        );
      } catch (err) {
        if (err instanceof KeycloakJwtVerificationError) {
          await deps.sessionStore.delete(parsed.data.session_id);
          await deps.userSessionsStore.remove(session.sub, parsed.data.session_id);
          throw unauthorized(
            'invalid_session',
            'Upstream returned untrusted tokens; session cleared',
          );
        }
        throw err;
      }

      // Refresh-token rotation: persist the new one if Keycloak issued it.
      const nextRefreshToken = tokens.refresh_token ?? session.refreshToken;
      await deps.sessionStore.put(parsed.data.session_id, {
        ...session,
        refreshToken: nextRefreshToken,
        sub: extracted.sub,
        profile: extracted.profile,
        lastUsedAt: new Date().toISOString(),
      });

      const { token: internalJwt, expiresIn } = await deps.internalJwtIssuer.mint({
        sub: extracted.sub,
        sid: parsed.data.session_id,
        username: extracted.profile.username,
        email: extracted.profile.email,
        email_verified: extracted.profile.emailVerified,
        phone_number: extracted.profile.phoneNumber,
        phone_number_verified: extracted.profile.phoneNumberVerified,
        roles: extracted.profile.roles,
      });

      res.setHeader('Cache-Control', 'no-store');
      deps.metrics?.authTokenMintTotal.inc({ kind: 'refresh' });
      res.json({
        access_token: internalJwt,
        token_type: 'Bearer',
        expires_in: expiresIn,
        scope: tokens.scope,
        session_id: parsed.data.session_id,
      });
    } catch (err) {
      next(err);
    }
  };
};
