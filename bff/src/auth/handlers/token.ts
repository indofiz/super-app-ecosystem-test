import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequest, unauthorized } from '../../lib/errors.js';
import { randomUrlSafe } from '../../lib/ids.js';
import type { InternalJwtIssuer } from '../../lib/internalJwt.js';
import {
  KeycloakJwtVerificationError,
  type KeycloakJwtVerifier,
} from '../../lib/keycloakJwt.js';
import type { MetricsBundle } from '../../lib/metrics.js';
import { verifyChallenge } from '../../lib/pkce.js';
import type { BffCodeStore } from '../stores/bffCode.store.js';
import type { SessionProfile, SessionStore } from '../stores/session.store.js';

const BodySchema = z.object({
  grant_type: z.literal('authorization_code'),
  code: z.string().min(1),
  code_verifier: z.string().min(43).max(128),
  client_id: z.string().min(1),
  redirect_uri: z.string().min(1),
});

/**
 * Verify upstream tokens and project them into the BFF's `SessionProfile`.
 *
 * Used by /auth/callback (fresh from KC), /auth/refresh (fresh from KC),
 * and /auth/token (loaded from `bffcode:*` Redis records).
 *
 * The verifier guarantees:
 *   - signature against KC's JWKS
 *   - issuer = KC_ISSUER
 *   - id_token aud = KC_CLIENT_ID
 *   - exp not past (with clockTolerance)
 *
 * If verification fails the error propagates as a `KeycloakJwtVerificationError`
 * which callers translate to the right HTTP status (400/401 vs 502).
 */
export const verifyAndExtractProfile = async (
  verifier: KeycloakJwtVerifier,
  accessToken: string | undefined,
  idToken: string | undefined,
  fallbackSub: string,
): Promise<{ sub: string; profile: SessionProfile }> => {
  const idClaims = idToken ? await verifier.verifyIdToken(idToken) : null;
  const acClaims = accessToken ? await verifier.verifyAccessToken(accessToken) : null;
  const sub = idClaims?.sub ?? acClaims?.sub ?? fallbackSub;
  return {
    sub,
    profile: {
      username: idClaims?.preferred_username,
      email: idClaims?.email,
      roles: acClaims?.realm_access?.roles ?? [],
    },
  };
};

export const makeTokenHandler = (deps: {
  env: Env;
  bffCodeStore: BffCodeStore;
  sessionStore: SessionStore;
  internalJwtIssuer: InternalJwtIssuer;
  keycloakJwtVerifier: KeycloakJwtVerifier;
  metrics?: MetricsBundle;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = BodySchema.safeParse(req.body);
      if (!parsed.success) {
        throw badRequest('invalid_request', parsed.error.issues[0]?.message ?? 'Invalid body');
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
