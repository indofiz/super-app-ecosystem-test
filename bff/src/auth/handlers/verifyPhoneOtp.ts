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
  phone: z.string().regex(/^\+62\d{8,12}$/, 'Phone must be +62 followed by 8-12 digits'),
  code: z.string().regex(/^\d{6}$/, 'OTP must be 6 digits'),
});

/**
 * POST /auth/phone/verify-otp
 *
 * On success:
 *   1. KC Admin API merges `phoneNumber` + `phoneNumberVerified=true`
 *      into the user's attributes.
 *   2. Session profile is updated locally so the freshly-minted JWT
 *      carries the new flag immediately.
 *   3. Returns a new internal JWT (same shape as /auth/refresh).
 *
 * Phone-binding: the OTP record's `destination` MUST match the body
 * `phone` — without this check, a user could request OTP to phone A,
 * then verify against phone B and get B written to KC as their verified
 * number.
 */
export const makeVerifyPhoneOtpHandler = (deps: {
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

      const key = deps.otpStore.channelKey('phone', claims.sub);
      const record = await deps.otpStore.get(key);
      if (!record) {
        throw gone('otp_expired', 'No OTP outstanding; request a new code');
      }

      // Phone binding: don't let a verify against a different number
      // succeed against an OTP issued for another. Same opaque 410 — no
      // oracle on which value was wrong.
      if (record.destination !== parsed.data.phone) {
        throw gone('otp_expired', 'No OTP outstanding; request a new code');
      }

      if (!compareCode(record, parsed.data.code, claims.sub)) {
        const attempts = await deps.otpStore.incrAttempts('phone', claims.sub);
        const attemptsLeft = Math.max(0, deps.env.OTP_MAX_ATTEMPTS - (attempts ?? 0));
        if (attemptsLeft <= 0) {
          await deps.otpStore.delete(key);
          throw gone('otp_exhausted', 'Too many wrong attempts; request a new code');
        }
        deps.metrics?.authFailedTotal.inc({ reason: 'otp_mismatch' });
        throw unprocessable(
          'otp_invalid',
          'OTP code did not match',
          { attempts_left: attemptsLeft },
          { attempts_left: attemptsLeft },
        );
      }

      await deps.otpStore.delete(key);

      await deps.keycloakAdmin.setPhoneVerified(claims.sub, parsed.data.phone);

      await deps.sessionStore.put(claims.sid, {
        ...session,
        profile: {
          ...session.profile,
          username: session.profile?.username,
          email: session.profile?.email,
          emailVerified: session.profile?.emailVerified ?? false,
          phoneNumber: parsed.data.phone,
          phoneNumberVerified: true,
          roles: session.profile?.roles ?? [],
        },
        lastUsedAt: new Date().toISOString(),
      });

      const { token: jwt, expiresIn } = await deps.internalJwtIssuer.mint({
        sub: claims.sub,
        sid: claims.sid,
        username: session.profile?.username,
        email: session.profile?.email,
        email_verified: session.profile?.emailVerified ?? false,
        phone_number: parsed.data.phone,
        phone_number_verified: true,
        roles: session.profile?.roles ?? [],
      });

      deps.metrics?.authTokenMintTotal.inc({ kind: 'refresh' });
      deps.log.info(
        { sub: claims.sub.substring(0, 8), channel: 'wa' },
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
