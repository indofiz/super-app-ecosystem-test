import { randomInt } from 'node:crypto';
import type { RequestHandler } from 'express';
import { z } from 'zod';
import type { Env } from '../../config/env.js';
import { badRequestFromZod, unauthorized } from '../../lib/errors.js';
import type { Logger } from '../../lib/logger.js';
import type { WaOtpSender } from '../../lib/waOtp.js';
import type { OtpStore } from '../stores/otp.store.js';
import type { SessionStore } from '../stores/session.store.js';

// E.164-ish Indonesian mobile: +62 followed by 8-12 digits. Matches the
// regex declared in the realm User Profile policy (Appendix A of the
// verification doc), so a phone that passes here will also pass KC's
// User Profile validators when the Admin API write fires.
const BodySchema = z.object({
  phone: z.string().regex(/^\+62\d{8,12}$/, 'Phone must be +62 followed by 8-12 digits'),
});

/**
 * POST /auth/phone/send-otp
 *
 * Body carries the phone because it's the user's first opportunity to
 * provide it (unlike email, KC has no phone at registration time unless
 * the User Profile policy is enabled and the user filled the field).
 * The verify handler enforces that the verifying phone matches the
 * issued phone, so swapping mid-flow doesn't grant a verified flag on
 * the new number.
 *
 * Idempotency: if the phone is already verified to the same number,
 * 200 fast. Otherwise we always issue a fresh OTP (overwriting any
 * outstanding record).
 */
export const makeSendPhoneOtpHandler = (deps: {
  env: Env;
  sessionStore: SessionStore;
  otpStore: OtpStore;
  waOtp: WaOtpSender;
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

      if (
        session.profile?.phoneNumberVerified &&
        session.profile?.phoneNumber === parsed.data.phone
      ) {
        res.json({ verified: true, delivery: 'wa' });
        return;
      }

      const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
      await deps.otpStore.issue({
        channel: 'phone',
        sub: claims.sub,
        destination: parsed.data.phone,
        code,
      });
      await deps.waOtp.sendOtp(parsed.data.phone, code);

      deps.log.info(
        { sub: claims.sub.substring(0, 8), channel: 'wa' },
        'otp issued',
      );

      res.setHeader('Cache-Control', 'no-store');
      res.status(202).json({
        delivery: 'wa',
        expires_in: deps.env.OTP_TTL_SECONDS,
      });
    } catch (err) {
      next(err);
    }
  };
};
