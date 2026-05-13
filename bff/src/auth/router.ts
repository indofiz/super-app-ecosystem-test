import { Router } from 'express';
import type { Redis } from 'ioredis';
import type { Env } from '../config/env.js';
import type { InternalJwtIssuer } from '../lib/internalJwt.js';
import type { KeycloakClient } from '../lib/keycloak.js';
import type { KeycloakJwtVerifier } from '../lib/keycloakJwt.js';
import type { Logger } from '../lib/logger.js';
import type { MetricsBundle } from '../lib/metrics.js';
import {
  buildAuthorizeLimiter,
  buildMeLimiter,
  buildRefreshLimiter,
  buildTokenLimiter,
} from '../middleware/rateLimit.js';
import { requireSessionBearer } from '../middleware/sessionAuth.js';
import { makeAuthorizeHandler } from './handlers/authorize.js';
import {
  backchannelLogoutUrlencoded,
  makeBackchannelLogoutHandler,
} from './handlers/backchannelLogout.js';
import { makeCallbackHandler } from './handlers/callback.js';
import { makeLogoutHandler } from './handlers/logout.js';
import { makeMeHandler } from './handlers/me.js';
import { makeRefreshHandler } from './handlers/refresh.js';
import { makeTokenHandler } from './handlers/token.js';
import type { AuthStateStore } from './stores/authState.store.js';
import type { BffCodeStore } from './stores/bffCode.store.js';
import type { SessionStore } from './stores/session.store.js';
import type { UserSessionsStore } from './stores/userSessions.store.js';

export interface AuthRouterDeps {
  env: Env;
  redis: Redis;
  keycloak: KeycloakClient;
  keycloakJwtVerifier: KeycloakJwtVerifier;
  authStateStore: AuthStateStore;
  bffCodeStore: BffCodeStore;
  sessionStore: SessionStore;
  userSessionsStore: UserSessionsStore;
  internalJwtIssuer: InternalJwtIssuer;
  metrics?: MetricsBundle;
  log?: Logger;
}

export const buildAuthRouter = (deps: AuthRouterDeps): Router => {
  const router = Router();
  const authorizeLimiter = buildAuthorizeLimiter(deps.redis);
  const tokenLimiter = buildTokenLimiter(deps.redis);
  const refreshLimiter = buildRefreshLimiter(deps.redis);
  const meLimiter = buildMeLimiter(deps.redis);
  const bearerStrict = requireSessionBearer(deps.internalJwtIssuer, 'strict', deps.log);
  const bearerAllowExpired = requireSessionBearer(deps.internalJwtIssuer, 'allowExpired', deps.log);

  router.get('/authorize', authorizeLimiter, makeAuthorizeHandler(deps));
  router.get('/callback', makeCallbackHandler(deps));
  router.post('/token', tokenLimiter, makeTokenHandler(deps));
  router.post('/refresh', refreshLimiter, bearerAllowExpired, makeRefreshHandler(deps));
  router.post('/logout', bearerAllowExpired, makeLogoutHandler(deps));
  router.get('/me', bearerStrict, meLimiter, makeMeHandler(deps));
  // AUDIT S-5: OIDC back-channel logout. KC POSTs a `logout_token`
  // (urlencoded) when the user logs out elsewhere; we delete every
  // session belonging to that `sub`.
  router.post(
    '/back-channel-logout',
    backchannelLogoutUrlencoded,
    makeBackchannelLogoutHandler({
      keycloakJwtVerifier: deps.keycloakJwtVerifier,
      sessionStore: deps.sessionStore,
      userSessionsStore: deps.userSessionsStore,
      metrics: deps.metrics,
      log: deps.log,
    }),
  );
  return router;
};
