import { createTransport, type Transporter } from 'nodemailer';
import type { Env } from '../config/env.js';
import { upstream } from './errors.js';
import type { Logger } from './logger.js';

/**
 * Email OTP transport. MVP target is Gmail SMTP on port 587 (STARTTLS).
 *
 * Gmail requires:
 *   - 2-Step Verification enabled on the sending account
 *   - an App Password (https://myaccount.google.com/apppasswords);
 *     regular passwords are rejected
 *
 * Free-tier Gmail caps at ~500 sends/day and may rate-limit aggressively
 * if patterns look bulk-mail-like. For production volume, swap to a
 * real relay (SES / SendGrid / Mailgun / Workspace SMTP relay) — the
 * `EmailOtpSender` interface stays identical, only the constructor
 * implementation changes.
 *
 * When SMTP_USER / SMTP_PASS are unset the sender logs the OTP to
 * stdout instead of mailing it. This is intentional for local dev so
 * a developer can grab the code from the BFF log without configuring
 * Gmail. Production deploys MUST set credentials — `index.ts` warns
 * loudly when running without them.
 */
export interface EmailOtpSender {
  sendOtp(to: string, code: string): Promise<void>;
}

interface MailOpts {
  smtpHost: string;
  smtpPort: number;
  smtpUser?: string;
  smtpPass?: string;
  smtpFrom?: string;
  log: Logger;
  /** Test-only injection point. Bypasses the SMTP transporter and the
   *  credential check so tests can pass a nodemailer `jsonTransport`. */
  transporter?: Transporter;
}

export const buildEmailOtpSender = (opts: MailOpts): EmailOtpSender => {
  // No credentials AND no injected transporter → log-only stub. Surface
  // this prominently so it's not mistaken for a working sender in staging.
  if (!opts.transporter && (!opts.smtpUser || !opts.smtpPass)) {
    opts.log.warn(
      'emailOtp: SMTP_USER / SMTP_PASS not set — OTP codes will be LOGGED, NOT EMAILED. Do not deploy this way.',
    );
    return {
      async sendOtp(to: string, code: string): Promise<void> {
        // The stub is intentionally fire-and-forget — log + resolve.
        // The await keeps eslint's require-await happy and gives the
        // log call a tick to flush before the response.
        await Promise.resolve();
        opts.log.info({ to, code, channel: 'email' }, 'emailOtp[stub]: would send');
      },
    };
  }

  const transporter: Transporter = opts.transporter ?? createTransport({
    host: opts.smtpHost,
    port: opts.smtpPort,
    // 587 is the standard submission port; secure:false + requireTLS
    // forces STARTTLS upgrade. 465 with secure:true is the legacy
    // implicit-TLS alternative; we default to 587 because it's what
    // Gmail recommends.
    secure: opts.smtpPort === 465,
    requireTLS: opts.smtpPort !== 465,
    auth: { user: opts.smtpUser, pass: opts.smtpPass },
    // Bound the SMTP call so a slow Gmail doesn't tie up our request
    // budget; matches the 10s axios budget elsewhere.
    connectionTimeout: 10_000,
    greetingTimeout: 5_000,
    socketTimeout: 10_000,
  });

  const from = opts.smtpFrom ?? opts.smtpUser;

  return {
    async sendOtp(to: string, code: string): Promise<void> {
      try {
        await transporter.sendMail({
          from,
          to,
          subject: 'Kode verifikasi Pemkot Pangkal Pinang',
          text:
            `Kode OTP Anda: ${code}\n\n` +
            `Berlaku selama 5 menit. Jangan bagikan kode ini kepada siapa pun.\n\n` +
            `Jika Anda tidak meminta kode ini, abaikan email ini.`,
          // Plain-text only — keeps deliverability scores high and
          // dodges Gmail's heuristic for HTML+links in OTP mail.
        });
      } catch (err) {
        throw upstream(
          'email_otp_send_failed',
          'Email OTP provider rejected the request',
          err,
        );
      }
    },
  };
};

/** Factory hook from env. Kept thin so `index.ts` is the only place that
 *  passes `Env` shape around. */
export const buildEmailOtpFromEnv = (env: Env, log: Logger): EmailOtpSender =>
  buildEmailOtpSender({
    smtpHost: env.SMTP_HOST,
    smtpPort: env.SMTP_PORT,
    smtpUser: env.SMTP_USER,
    smtpPass: env.SMTP_PASS,
    smtpFrom: env.SMTP_FROM,
    log,
  });
