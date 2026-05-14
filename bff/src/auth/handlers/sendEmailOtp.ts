import { randomInt } from 'node:crypto';
import type { RequestHandler } from 'express';
import type { Env } from '../../config/env.js';
import type { EmailOtpSender } from '../../lib/emailOtp.js';
import { badRequest, unauthorized } from '../../lib/errors.js';
import type { Logger } from '../../lib/logger.js';
import type { OtpStore } from '../stores/otp.store.js';
import type { SessionStore } from '../stores/session.store.js';

/**
 * POST /auth/email/send-otp
 *
 * No body required — the destination is the session's `email` (set by KC
 * at registration). Idempotent if the email is already verified: returns
 * 200 with `{verified: true}` without burning a send.
 *
 * Rate limit: per-`sub` (see buildOtpSendLimiter). Per-Redis-key
 * single-record overwrite means a resend within 5 min replaces the
 * outstanding code with a fresh one and resets the attempts counter.
 */
export const makeSendEmailOtpHandler = (deps: {
  env: Env;
  sessionStore: SessionStore;
  otpStore: OtpStore;
  emailOtp: EmailOtpSender;
  log: Logger;
}): RequestHandler => {
  return async (req, res, next) => {
    try {
      const claims = req.claims;
      if (!claims) {
        throw unauthorized('missing_bearer', 'Authorization: Bearer required');
      }
      const session = await deps.sessionStore.get(claims.sid);
      if (!session) {
        throw unauthorized('invalid_session', 'Session not found or expired');
      }
      const email = session.profile?.email;
      if (!email) {
        // The user registered without an email somehow (shouldn't happen
        // with `registrationEmailAsUsername=true`, but be defensive).
        throw badRequest(
          'email_missing',
          'No email address on record — re-login may be required',
        );
      }
      if (session.profile?.emailVerified) {
        res.json({ verified: true, delivery: 'email' });
        return;
      }

      const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
      await deps.otpStore.issue({
        channel: 'email',
        sub: claims.sub,
        destination: email,
        code,
      });
      await deps.emailOtp.sendOtp(email, code);

      deps.log.info(
        { sub: claims.sub.substring(0, 8), channel: 'email' },
        'otp issued',
      );

      res.setHeader('Cache-Control', 'no-store');
      res.status(202).json({
        delivery: 'email',
        expires_in: deps.env.OTP_TTL_SECONDS,
      });
    } catch (err) {
      next(err);
    }
  };
};
