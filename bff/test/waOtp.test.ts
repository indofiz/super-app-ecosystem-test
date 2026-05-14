import type { AxiosInstance } from 'axios';
import pino from 'pino';
import { describe, expect, it } from 'vitest';
import { buildWaOtpSender } from '../src/lib/waOtp.js';

const silentLog = pino({ level: 'silent' });

interface FonnteCall {
  url: string;
  body: URLSearchParams;
  headers: Record<string, string>;
}

/**
 * Stub axios instance shaped just enough for waOtp.ts to call `.post`.
 * Matches the hand-rolled stub style in keycloakClient.test.ts. Returns
 * the response described by `responder` and records every call.
 */
const stubAxios = (
  responder: (call: FonnteCall) => { status: number; data: unknown },
): { http: AxiosInstance; calls: FonnteCall[] } => {
  const calls: FonnteCall[] = [];
  const http = {
    post: async (
      url: string,
      body: URLSearchParams,
      opts?: { headers?: Record<string, string> },
    ) => {
      const call: FonnteCall = {
        url,
        body,
        headers: opts?.headers ?? {},
      };
      calls.push(call);
      const { status, data } = responder(call);
      if (status >= 200 && status < 300) {
        return { status, data };
      }
      // Mimic axios's error shape so the adapter's catch path matches
      // what production code sees on non-2xx. axios actually constructs
      // a real Error and decorates it — we do the same here.
      const err = new Error(`Request failed with status code ${status}`);
      Object.assign(err, { isAxiosError: true, response: { status, data } });
      throw err;
    },
  } as unknown as AxiosInstance;
  return { http, calls };
};

describe('waOtp adapter (Fonnte)', () => {
  it('stub path: no FONNTE_TOKEN → log + resolve', async () => {
    const sender = buildWaOtpSender({
      baseUrl: 'https://api.fonnte.com',
      log: silentLog,
    });
    await expect(sender.sendOtp('+6281234567890', '123456')).resolves.toBeUndefined();
  });

  it('sends `target=628…` (no `+`), Authorization header, urlencoded body, Indonesian message', async () => {
    const { http, calls } = stubAxios(() => ({ status: 200, data: { status: true } }));
    const sender = buildWaOtpSender({
      baseUrl: 'https://fake.fonnte',
      token: 'tk-123',
      log: silentLog,
      http,
    });
    await sender.sendOtp('+6281234567890', '987654');
    expect(calls).toHaveLength(1);
    const c = calls[0]!;
    expect(c.url).toBe('/send');
    expect(c.body.get('target')).toBe('6281234567890');
    expect(c.body.get('countryCode')).toBe('62');
    expect(c.body.get('message')).toContain('987654');
    expect(c.body.get('message')).toContain('Berlaku selama 5 menit');
    expect(c.headers['Authorization']).toBe('tk-123');
    expect(c.headers['Content-Type']).toBe('application/x-www-form-urlencoded');
  });

  it('handles status:"false" string-shape from older Fonnte responses', async () => {
    const { http } = stubAxios(() => ({
      status: 200,
      data: { status: 'false', reason: 'invalid number' },
    }));
    const sender = buildWaOtpSender({
      baseUrl: 'https://fake.fonnte',
      token: 'tk',
      log: silentLog,
      http,
    });
    await expect(sender.sendOtp('+6281234567890', '123456')).rejects.toMatchObject({
      code: 'wa_otp_send_failed',
      status: 502,
    });
  });

  it('treats status:true as success', async () => {
    const { http } = stubAxios(() => ({ status: 200, data: { status: 'true' } }));
    const sender = buildWaOtpSender({
      baseUrl: 'https://fake.fonnte',
      token: 'tk',
      log: silentLog,
      http,
    });
    await expect(sender.sendOtp('+6281234567890', '123456')).resolves.toBeUndefined();
  });

  it('non-2xx HTTP surfaces as upstream HttpError', async () => {
    const { http } = stubAxios(() => ({ status: 500, data: 'bad gateway' }));
    const sender = buildWaOtpSender({
      baseUrl: 'https://fake.fonnte',
      token: 'tk',
      log: silentLog,
      http,
    });
    await expect(sender.sendOtp('+6281234567890', '123456')).rejects.toMatchObject({
      code: 'wa_otp_send_failed',
      status: 502,
    });
  });
});
