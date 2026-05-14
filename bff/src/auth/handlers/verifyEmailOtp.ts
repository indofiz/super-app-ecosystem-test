import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequestFromZod, gone, unauthorized, unprocessable } from '../../lib/errors.js';
import type { InternalJwtIssuer } from '../../lib/internalJwt.js';
import type { KeycloakAdminClient } from '../../lib/keycloakAdmin.js';
import type { Logger } from '../../lib/logger.js';
import type { MetricsBundle } from '../../lib/metrics.js';
import { compareCode, type OtpStore } from '../stores/otp.store.js';
import type { SessionStore } from '../stores/session.store.js';

const BodySchema = z.object({
  code: z.string().regex(/^\d{6}$/, 'OTP must be 6 digits'),
});

/**
 * POST /auth/email/verify-otp
 *
 * On success:
 *   1. Sets `emailVerified=true` on the Keycloak user (Admin API).
 *   2. Updates the cached session profile so future /me + /refresh see
 *      the new value without waiting for the next KC token round-trip.
 *   3. Mints a fresh internal JWT with `email_verified=true` and returns
 *      it (same shape as /auth/refresh).
 *
 * On failure:
 *   - 410 if no OTP outstanding (resend required)
 *   - 422 with `attempts_left` on code mismatch; record is purged when
 *     attempts_left hits 0 (next call returns 410)
 *
 * Verify-shaped errors are deliberately non-leaky: we don't tell the
 * caller whether the code or the destination was wrong.
 */
export const makeVerifyEmailOtpHandler = (deps: {
  env: Env;
  sessionStore: SessionStore;
  otpStore: OtpStore;
  keycloakAdmin: KeycloakAdminClient;
  internalJwtIssuer: InternalJwtIssuer;
  metrics?: MetricsBundle;
  log: Logger;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const claims = req.claims;
      if (!claims) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      const parsed = BodySchema.safeParse(req.body);
      if (!parsed.success) {
        throw badRequestFromZod(parsed.error, 'Invalid body');
      }

      const session = await deps.sessionStore.get(claims.sid);
      if (!session) {
        throw unauthorized('invalid_session', 'Session not found or expired');
      }
      if (session.profile?.emailVerified) {
        // Already verified — idempotent success without touching KC.
        const { token: jwt, expiresIn } = await deps.internalJwtIssuer.mint({
          sub: claims.sub,
          sid: claims.sid,
          username: session.profile?.username,
          email: session.profile?.email,
          email_verified: true,
          phone_number: session.profile?.phoneNumber,
          phone_number_verified: session.profile?.phoneNumberVerified ?? false,
          roles: session.profile?.roles ?? [],
        });
        res.json({
          verified: true,
          access_token: jwt,
          expires_in: expiresIn,
          session_id: claims.sid,
        });
        return;
      }

      const key = deps.otpStore.channelKey('email', claims.sub);
      const record = await deps.otpStore.get(key);
      if (!record) {
        throw gone('otp_expired', 'No OTP outstanding; request a new code');
      }

      if (!compareCode(record, parsed.data.code, claims.sub)) {
        const attempts = await deps.otpStore.incrAttempts('email', claims.sub);
        const attemptsLeft = Math.max(0, deps.env.OTP_MAX_ATTEMPTS - (attempts ?? 0));
        if (attemptsLeft <= 0) {
          await deps.otpStore.delete(key);
          throw gone('otp_exhausted', 'Too many wrong attempts; request a new code');
        }
        deps.metrics?.authFailedTotal.inc({ reason: 'otp_mismatch' });
        // `attempts_left` is server-determined and safe to echo so the
        // mobile UI can show "sisa N percobaan". Server-side log carries
        // the same value via `detail`.
        throw unprocessable(
          'otp_invalid',
          'OTP code did not match',
          { attempts_left: attemptsLeft },
          { attempts_left: attemptsLeft },
        );
      }

      // Match → atomically consume the record.
      await deps.otpStore.delete(key);

      await deps.keycloakAdmin.setEmailVerified(claims.sub);

      // Update the cached session so the next /me reads the new flag
      // without needing a /refresh round-trip to KC.
      await deps.sessionStore.put(claims.sid, {
        ...session,
        profile: {
          ...session.profile,
          username: session.profile?.username,
          email: session.profile?.email,
          emailVerified: true,
          phoneNumber: session.profile?.phoneNumber,
          phoneNumberVerified: session.profile?.phoneNumberVerified ?? false,
          roles: session.profile?.roles ?? [],
        },
        lastUsedAt: new Date().toISOString(),
      });

      const { token: jwt, expiresIn } = await deps.internalJwtIssuer.mint({
        sub: claims.sub,
        sid: claims.sid,
        username: session.profile?.username,
        email: session.profile?.email,
        email_verified: true,
        phone_number: session.profile?.phoneNumber,
        phone_number_verified: session.profile?.phoneNumberVerified ?? false,
        roles: session.profile?.roles ?? [],
      });

      deps.metrics?.authTokenMintTotal.inc({ kind: 'refresh' });
      deps.log.info(
        { sub: claims.sub.substring(0, 8), channel: 'email' },
        'otp verified',
      );

      res.setHeader('Cache-Control', 'no-store');
      res.json({
        verified: true,
        access_token: jwt,
        expires_in: expiresIn,
        session_id: claims.sid,
      });
    } catch (err) {
      next(err);
    }
  };
};
