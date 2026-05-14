import { Router } from 'express';
import type { Redis } from 'ioredis';
import type { Env } from '../config/env.js';
import type { EmailOtpSender } from '../lib/emailOtp.js';
import type { InternalJwtIssuer } from '../lib/internalJwt.js';
import type { KeycloakClient } from '../lib/keycloak.js';
import type { KeycloakAdminClient } from '../lib/keycloakAdmin.js';
import type { KeycloakJwtVerifier } from '../lib/keycloakJwt.js';
import type { Logger } from '../lib/logger.js';
import type { MetricsBundle } from '../lib/metrics.js';
import type { WaOtpSender } from '../lib/waOtp.js';
import {
  buildAuthorizeLimiter,
  buildMeLimiter,
  buildOtpSendLimiter,
  buildOtpVerifyLimiter,
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
import { makeSendEmailOtpHandler } from './handlers/sendEmailOtp.js';
import { makeSendPhoneOtpHandler } from './handlers/sendPhoneOtp.js';
import { makeTokenHandler, tokenUrlencoded } from './handlers/token.js';
import { makeVerifyEmailOtpHandler } from './handlers/verifyEmailOtp.js';
import { makeVerifyPhoneOtpHandler } from './handlers/verifyPhoneOtp.js';
import type { AuthStateStore } from './stores/authState.store.js';
import type { BffCodeStore } from './stores/bffCode.store.js';
import type { OtpStore } from './stores/otp.store.js';
import type { SessionStore } from './stores/session.store.js';
import type { UserSessionsStore } from './stores/userSessions.store.js';

export interface AuthRouterDeps {
  env: Env;
  redis: Redis;
  keycloak: KeycloakClient;
  keycloakJwtVerifier: KeycloakJwtVerifier;
  keycloakAdmin: KeycloakAdminClient;
  authStateStore: AuthStateStore;
  bffCodeStore: BffCodeStore;
  sessionStore: SessionStore;
  userSessionsStore: UserSessionsStore;
  otpStore: OtpStore;
  emailOtp: EmailOtpSender;
  waOtp: WaOtpSender;
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
  const otpSendLimiter = buildOtpSendLimiter(deps.redis);
  const otpVerifyLimiter = buildOtpVerifyLimiter(deps.redis);
  const bearerStrict = requireSessionBearer(deps.internalJwtIssuer, 'strict', deps.log);
  const bearerAllowExpired = requireSessionBearer(deps.internalJwtIssuer, 'allowExpired', deps.log);
  const log = deps.log!;

  router.get('/authorize', authorizeLimiter, makeAuthorizeHandler(deps));
  router.get('/callback', makeCallbackHandler(deps));
  router.post('/token', tokenLimiter, tokenUrlencoded, makeTokenHandler(deps));
  router.post('/refresh', refreshLimiter, bearerAllowExpired, makeRefreshHandler(deps));
  router.post('/logout', bearerAllowExpired, makeLogoutHandler(deps));
  router.get('/me', bearerStrict, meLimiter, makeMeHandler(deps));

  // Verification — Phase 1 of registration-and-verification.md. All
  // require a strictly-valid bearer (otpStore is keyed off the verified
  // `sub`/`sid`) and return either 202 (send) or 200 with a fresh JWT
  // (verify).
  router.post(
    '/email/send-otp',
    bearerStrict,
    otpSendLimiter,
    makeSendEmailOtpHandler({
      env: deps.env,
      sessionStore: deps.sessionStore,
      otpStore: deps.otpStore,
      emailOtp: deps.emailOtp,
      log,
    }),
  );
  router.post(
    '/email/verify-otp',
    bearerStrict,
    otpVerifyLimiter,
    makeVerifyEmailOtpHandler({
      env: deps.env,
      sessionStore: deps.sessionStore,
      otpStore: deps.otpStore,
      keycloakAdmin: deps.keycloakAdmin,
      internalJwtIssuer: deps.internalJwtIssuer,
      metrics: deps.metrics,
      log,
    }),
  );
  router.post(
    '/phone/send-otp',
    bearerStrict,
    otpSendLimiter,
    makeSendPhoneOtpHandler({
      env: deps.env,
      sessionStore: deps.sessionStore,
      otpStore: deps.otpStore,
      waOtp: deps.waOtp,
      log,
    }),
  );
  router.post(
    '/phone/verify-otp',
    bearerStrict,
    otpVerifyLimiter,
    makeVerifyPhoneOtpHandler({
      env: deps.env,
      sessionStore: deps.sessionStore,
      otpStore: deps.otpStore,
      keycloakAdmin: deps.keycloakAdmin,
      internalJwtIssuer: deps.internalJwtIssuer,
      metrics: deps.metrics,
      log,
    }),
  );
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
