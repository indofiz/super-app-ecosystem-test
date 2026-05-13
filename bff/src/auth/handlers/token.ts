import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequestFromZod, unauthorized } from '../../lib/errors.js';
import { randomUrlSafe } from '../../lib/ids.js';
import type { InternalJwtIssuer } from '../../lib/internalJwt.js';
import {
  KeycloakJwtVerificationError,
  verifyAndExtractProfile,
  type KeycloakJwtVerifier,
} from '../../lib/keycloakJwt.js';
import type { MetricsBundle } from '../../lib/metrics.js';
import { verifyChallenge } from '../../lib/pkce.js';
import type { BffCodeStore } from '../stores/bffCode.store.js';
import type { SessionStore } from '../stores/session.store.js';
import type { UserSessionsStore } from '../stores/userSessions.store.js';

const BodySchema = z.object({
  grant_type: z.literal('authorization_code'),
  code: z.string().min(1),
  code_verifier: z.string().min(43).max(128),
  client_id: z.string().min(1),
  redirect_uri: z.string().min(1),
});

export const makeTokenHandler = (deps: {
  env: Env;
  bffCodeStore: BffCodeStore;
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
      const b = parsed.data;

      const codeRecord = await deps.bffCodeStore.take(b.code);
      if (!codeRecord) {
        throw unauthorized('invalid_grant', 'Authorization code is invalid or expired');
      }

      if (codeRecord.appClientId !== b.client_id) {
        throw unauthorized('invalid_grant', 'client_id mismatch');
      }
      if (codeRecord.appRedirectUri !== b.redirect_uri) {
        throw unauthorized('invalid_grant', 'redirect_uri mismatch');
      }

      const ok = verifyChallenge(b.code_verifier, codeRecord.appCodeChallenge);
      if (!ok) {
        throw unauthorized('invalid_grant', 'PKCE verifier failed');
      }

      if (!codeRecord.refreshToken) {
        throw unauthorized('invalid_grant', 'Upstream did not issue refresh_token');
      }

      // §2.3 belt-and-braces: the bffcode record was just retrieved from
      // Redis. callback.ts already verified id_token before storing, so
      // this is a defence-in-depth check. If a verifier fails here, the
      // record is already gone (getdel) so no cleanup is needed.
      let extracted;
      try {
        extracted = await verifyAndExtractProfile(
          deps.keycloakJwtVerifier,
          codeRecord.accessToken,
          codeRecord.idToken,
          codeRecord.sub ?? '',
        );
      } catch (err) {
        if (err instanceof KeycloakJwtVerificationError) {
          throw unauthorized('invalid_grant', 'Stored tokens failed verification');
        }
        throw err;
      }

      const sessionId = randomUrlSafe(32);
      const now = new Date().toISOString();
      await deps.sessionStore.put(sessionId, {
        refreshToken: codeRecord.refreshToken,
        sub: extracted.sub,
        appClientId: codeRecord.appClientId,
        createdAt: now,
        lastUsedAt: now,
        profile: extracted.profile,
      });
      // AUDIT S-5: index this session under its sub so back-channel logout
      // can find it without SCANning the keyspace.
      await deps.userSessionsStore.add(extracted.sub, sessionId);

      // Mint the internal JWT mobile will carry. Keycloak's access_token never
      // leaves this handler.
      const { token: internalJwt, expiresIn } = await deps.internalJwtIssuer.mint({
        sub: extracted.sub,
        sid: sessionId,
        username: extracted.profile.username,
        email: extracted.profile.email,
        roles: extracted.profile.roles,
      });

      res.setHeader('Cache-Control', 'no-store');
      deps.metrics?.authTokenMintTotal.inc({ kind: 'token' });
      res.json({
        access_token: internalJwt,
        token_type: 'Bearer',
        expires_in: expiresIn,
        scope: codeRecord.scope,
        session_id: sessionId,
      });
    } catch (err) {
      next(err);
    }
  };
};
