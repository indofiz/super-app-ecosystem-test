import { Router } from 'express';
import type { InternalJwtIssuer } from '../lib/internalJwt.js';

export const buildWellKnownRouter = (issuer: InternalJwtIssuer): Router => {
  const router = Router();

  // OIDC-style discovery endpoint for the BFF's *internal* JWTs. Today this
  // is informational — Kong is configured with static rsa_public_key entries
  // (community Kong's bundled jwt plugin doesn't fetch JWKS). Useful for
  // debugging tokens at jwt.io and for any downstream service that prefers
  // JWKS-based verification over a baked-in PEM.
  router.get('/.well-known/jwks.json', (_req, res) => {
    res.setHeader('Cache-Control', 'public, max-age=300');
    res.json(issuer.getJwks());
  });

  return router;
};
