import http from 'node:http';
import https from 'node:https';
import axios, { type AxiosInstance } from 'axios';
import { z } from 'zod';
import type { Env } from '../config/env.js';
import { upstream } from './errors.js';
import type { Logger } from './logger.js';

/**
 * WhatsApp OTP transport via Fonnte (https://fonnte.com).
 *
 * Fonnte is an Indonesian reseller — fast onboarding, unofficial channel.
 * Sessions can break under load; non-2xx responses or `status:false`
 * payloads bubble up as `upstream_unavailable` so callers can surface a
 * "coba lagi" toast on mobile.
 *
 * Long-term path: migrate to Meta WhatsApp Cloud API once WABA + verified
 * business + OTP template approval are in place. The `WaOtpSender`
 * interface is provider-agnostic; swap the implementation, leave the
 * handler signatures alone.
 *
 * Phone format: Fonnte's `target` expects `628...` (no leading `+`). We
 * strip `+` here; handler validates the inbound format separately.
 */
export interface WaOtpSender {
  sendOtp(phoneE164: string, code: string): Promise<void>;
}

const FonnteResponseZ = z.object({
  // Fonnte returns either a boolean or "true"/"false" string depending
  // on endpoint version. Coerce both shapes to a boolean.
  status: z
    .union([z.boolean(), z.string()])
    .transform((v) => (typeof v === 'boolean' ? v : v.toLowerCase() === 'true')),
  reason: z.string().optional(),
  detail: z.string().optional(),
  message: z.string().optional(),
});

const HTTP_TIMEOUT_MS = 10_000;
const MAX_BODY = 16 * 1024;

interface WaOpts {
  baseUrl: string;
  token?: string;
  log: Logger;
  http?: AxiosInstance;
}

export const buildWaOtpSender = (opts: WaOpts): WaOtpSender => {
  if (!opts.token) {
    opts.log.warn(
      'waOtp: FONNTE_TOKEN not set — WA OTP codes will be LOGGED, NOT SENT. Do not deploy this way.',
    );
    return {
      async sendOtp(phone: string, code: string): Promise<void> {
        await Promise.resolve();
        opts.log.info({ phone, code, channel: 'wa' }, 'waOtp[stub]: would send');
      },
    };
  }

  const client =
    opts.http ??
    axios.create({
      baseURL: opts.baseUrl,
      timeout: HTTP_TIMEOUT_MS,
      maxContentLength: MAX_BODY,
      maxBodyLength: MAX_BODY,
      httpAgent: new http.Agent({ keepAlive: true, maxSockets: 25 }),
      httpsAgent: new https.Agent({ keepAlive: true, maxSockets: 25 }),
    });

  return {
    async sendOtp(phoneE164: string, code: string): Promise<void> {
      // Fonnte target format: 628..., not +628...
      const target = phoneE164.startsWith('+') ? phoneE164.slice(1) : phoneE164;
      const message =
        `Kode OTP Anda: *${code}*\n\n` +
        `Berlaku selama 5 menit. Jangan bagikan kode ini kepada siapa pun.\n\n` +
        `_Pesan otomatis dari Pemkot Pangkal Pinang._`;

      const body = new URLSearchParams({
        target,
        message,
        countryCode: '62',
      });

      try {
        const res = await client.post('/send', body, {
          headers: {
            Authorization: opts.token!,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        });
        const parsed = FonnteResponseZ.safeParse(res.data);
        if (!parsed.success) {
          throw upstream(
            'wa_otp_send_failed',
            'Fonnte returned an unexpected response shape',
            parsed.error,
          );
        }
        if (!parsed.data.status) {
          const reason =
            parsed.data.reason ??
            parsed.data.detail ??
            parsed.data.message ??
            'unknown';
          throw upstream('wa_otp_send_failed', `Fonnte rejected: ${reason}`, parsed.data);
        }
      } catch (err) {
        // Already-typed HttpErrors pass through unchanged.
        if (err instanceof Error && err.name === 'HttpError') throw err;
        throw upstream(
          'wa_otp_send_failed',
          'Fonnte request failed',
          err instanceof Error ? err.message : err,
        );
      }
    },
  };
};

export const buildWaOtpFromEnv = (env: Env, log: Logger): WaOtpSender =>
  buildWaOtpSender({
    baseUrl: env.FONNTE_BASE_URL,
    token: env.FONNTE_TOKEN,
    log,
  });
