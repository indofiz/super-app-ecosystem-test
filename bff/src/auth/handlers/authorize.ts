import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequest, badRequestFromZod } from '../../lib/errors.js';
import { randomUrlSafe } from '../../lib/ids.js';
import type { KeycloakClient } from '../../lib/keycloak.js';
import { challengeFromVerifier, generateVerifier, parsePkceMethod } from '../../lib/pkce.js';
import type { AuthStateStore } from '../stores/authState.store.js';

// OIDC-defined values per https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
// `none` is intentionally omitted: it implies "no UI" which only makes sense
// when the caller already holds a session — not applicable to a fresh mobile
// login through this BFF.
const PromptValues = z.enum(['login', 'consent', 'select_account']);

const QuerySchema = z.object({
  response_type: z.literal('code'),
  client_id: z.string().min(1),
  redirect_uri: z.string().min(1),
  code_challenge: z.string().min(1),
  code_challenge_method: z.string().default('S256'),
  state: z.string().min(1),
  scope: z.string().optional(),
  prompt: PromptValues.optional(),
  max_age: z.string().regex(/^\d+$/).optional(),
  login_hint: z.string().min(1).max(255).optional(),
  ui_locales: z
    .string()
    .regex(/^[A-Za-z0-9\- ]{1,64}$/)
    .optional(),
});

export const makeAuthorizeHandler = (deps: {
  env: Env;
  keycloak: KeycloakClient;
  authStateStore: AuthStateStore;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const parsed = QuerySchema.safeParse(req.query);
      if (!parsed.success) {
        throw badRequestFromZod(parsed.error, 'Invalid query');
      }
      const q = parsed.data;

      if (!deps.env.ALLOWED_APP_CLIENTS.includes(q.client_id)) {
        throw badRequest('invalid_client', `client_id not allowed: ${q.client_id}`);
      }
      if (!deps.env.ALLOWED_APP_REDIRECT_URIS.includes(q.redirect_uri)) {
        throw badRequest('invalid_request', `redirect_uri not allowed: ${q.redirect_uri}`);
      }

      // §2.4: only S256 is allowed. Reject `plain` (and anything else) at the
      // HTTP boundary with a proper 400.
      try {
        parsePkceMethod(q.code_challenge_method);
      } catch (err) {
        throw badRequest(
          'invalid_request',
          err instanceof Error ? err.message : 'Invalid code_challenge_method',
        );
      }
      const bffState = randomUrlSafe(24);
      const bffCodeVerifier = generateVerifier();
      const bffCodeChallenge = challengeFromVerifier(bffCodeVerifier);

      await deps.authStateStore.put(bffState, {
        appCodeChallenge: q.code_challenge,
        appRedirectUri: q.redirect_uri,
        appState: q.state,
        appClientId: q.client_id,
        bffCodeVerifier,
      });

      const disc = await deps.keycloak.getDiscovery();
      const callback = `${deps.env.PUBLIC_BASE_URL.replace(/\/$/, '')}/auth/callback`;

      const url = new URL(disc.authorization_endpoint);
      url.searchParams.set('response_type', 'code');
      url.searchParams.set('client_id', deps.env.KC_CLIENT_ID);
      url.searchParams.set('redirect_uri', callback);
      url.searchParams.set('state', bffState);
      url.searchParams.set('scope', q.scope ?? deps.env.KC_SCOPES);
      url.searchParams.set('code_challenge', bffCodeChallenge);
      url.searchParams.set('code_challenge_method', 'S256');
      // Forward OIDC UX params so the app can ask Keycloak to bypass the
      // SSO cookie (`prompt=login`) or pre-fill a username (`login_hint`).
      // Without this, a second login attempt silently reuses KC's cookie
      // and never re-prompts the user.
      if (q.prompt) url.searchParams.set('prompt', q.prompt);
      if (q.max_age) url.searchParams.set('max_age', q.max_age);
      if (q.login_hint) url.searchParams.set('login_hint', q.login_hint);
      if (q.ui_locales) url.searchParams.set('ui_locales', q.ui_locales);

      res.setHeader('Cache-Control', 'no-store');
      res.redirect(302, url.toString());
    } catch (err) {
      next(err);
    }
  };
};
