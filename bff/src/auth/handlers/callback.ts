import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequest, badRequestFromZod } from '../../lib/errors.js';
import { randomUrlSafe } from '../../lib/ids.js';
import type { KeycloakClient } from '../../lib/keycloak.js';
import {
  KeycloakJwtVerificationError,
  type KeycloakJwtVerifier,
} from '../../lib/keycloakJwt.js';
import type { Logger } from '../../lib/logger.js';
import type { AuthStateStore } from '../stores/authState.store.js';
import type { BffCodeStore } from '../stores/bffCode.store.js';

const QuerySchema = z.object({
  code: z.string().min(1).optional(),
  state: z.string().min(1),
  error: z.string().optional(),
  error_description: z.string().optional(),
});

export const makeCallbackHandler = (deps: {
  env: Env;
  keycloak: KeycloakClient;
  authStateStore: AuthStateStore;
  bffCodeStore: BffCodeStore;
  keycloakJwtVerifier: KeycloakJwtVerifier;
  log?: Logger;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = QuerySchema.safeParse(req.query);
      if (!parsed.success) {
        throw badRequestFromZod(parsed.error, 'Invalid query');
      }
      const q = parsed.data;

      const stateRecord = await deps.authStateStore.take(q.state);
      if (!stateRecord) {
        throw badRequest('invalid_state', 'Unknown or expired state');
      }

      // If Keycloak returned an OAuth error, surface it back to the app via deeplink.
      if (q.error || !q.code) {
        const url = new URL(stateRecord.appRedirectUri);
        url.searchParams.set('error', q.error ?? 'invalid_request');
        if (q.error_description) url.searchParams.set('error_description', q.error_description);
        url.searchParams.set('state', stateRecord.appState);
        res.setHeader('Cache-Control', 'no-store');
        res.redirect(302, url.toString());
        return;
      }

      const callback = `${deps.env.PUBLIC_BASE_URL.replace(/\/$/, '')}/auth/callback`;
      const tokens = await deps.keycloak.exchangeCode({
        code: q.code,
        redirectUri: callback,
        codeVerifier: stateRecord.bffCodeVerifier,
      });

      // §2.3: id_token MUST be present and signature-valid. Without a
      // verified id_token we don't know who the user is — fall back to a
      // deeplink error rather than mint a session for an unknown sub.
      if (!tokens.id_token) {
        deps.log?.warn('keycloak token response had no id_token; aborting callback');
        const url = new URL(stateRecord.appRedirectUri);
        url.searchParams.set('error', 'server_error');
        url.searchParams.set('error_description', 'Upstream did not return an id_token');
        url.searchParams.set('state', stateRecord.appState);
        res.setHeader('Cache-Control', 'no-store');
        res.redirect(302, url.toString());
        return;
      }

      let idClaims;
      try {
        idClaims = await deps.keycloakJwtVerifier.verifyIdToken(tokens.id_token);
      } catch (err) {
        // KC just returned a token its own JWKS can't verify. Loud failure:
        // log + deeplink server_error. Don't persist a bffcode record.
        deps.log?.error({ err }, 'id_token verification failed at callback');
        if (!(err instanceof KeycloakJwtVerificationError)) throw err;
        const url = new URL(stateRecord.appRedirectUri);
        url.searchParams.set('error', 'server_error');
        url.searchParams.set('error_description', 'Upstream returned an unverifiable id_token');
        url.searchParams.set('state', stateRecord.appState);
        res.setHeader('Cache-Control', 'no-store');
        res.redirect(302, url.toString());
        return;
      }

      const bffAuthCode = randomUrlSafe(32);
      await deps.bffCodeStore.put(bffAuthCode, {
        accessToken: tokens.access_token,
        refreshToken: tokens.refresh_token,
        idToken: tokens.id_token,
        tokenType: tokens.token_type,
        expiresIn: tokens.expires_in,
        scope: tokens.scope,
        sub: idClaims.sub,
        appCodeChallenge: stateRecord.appCodeChallenge,
        appRedirectUri: stateRecord.appRedirectUri,
        appClientId: stateRecord.appClientId,
      });

      const url = new URL(stateRecord.appRedirectUri);
      url.searchParams.set('code', bffAuthCode);
      url.searchParams.set('state', stateRecord.appState);
      res.setHeader('Cache-Control', 'no-store');
      res.redirect(302, url.toString());
    } catch (err) {
      next(err);
    }
  };
};
