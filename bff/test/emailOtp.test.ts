import { createTransport, type Transporter } from 'nodemailer';
import pino from 'pino';
import { describe, expect, it } from 'vitest';
import { buildEmailOtpSender } from '../src/lib/emailOtp.js';

// `pino({ level: 'silent' })` keeps test output clean while still
// exercising the same log signature the production code uses.
const silentLog = pino({ level: 'silent' });

// nodemailer's jsonTransport wraps string addresses into
// `{address, name}` objects in the parsed JSON message. We accept both
// shapes so the assertions read naturally.
type Address = string | { address: string; name?: string };
interface JsonMessage {
  from?: Address;
  to: Address | Address[];
  subject: string;
  text?: string;
  html?: string;
  envelope?: { from: string; to: string[] };
}

const addressOf = (a: Address | Address[] | undefined): string | undefined => {
  if (a === undefined) return undefined;
  const one = Array.isArray(a) ? a[0] : a;
  if (typeof one === 'string') return one;
  return one?.address;
};

const jsonMessages: JsonMessage[] = [];

/**
 * nodemailer's built-in jsonTransport returns the message envelope as
 * a stringified JSON payload in `info.message` — no SMTP connection
 * required. Captures into `jsonMessages` for assertion.
 */
const captureTransporter = (): Transporter => {
  const t = createTransport({ jsonTransport: true });
  const origSendMail = t.sendMail.bind(t);
  t.sendMail = async (opts: Parameters<typeof origSendMail>[0]) => {
    const info = await origSendMail(opts);
    // info.message is a JSON string per nodemailer's jsonTransport contract.
    jsonMessages.push(JSON.parse(info.message) as JsonMessage);
    return info;
  };
  return t;
};

describe('emailOtp adapter', () => {
  it('stub path: logs the OTP when SMTP creds are missing', async () => {
    const sender = buildEmailOtpSender({
      smtpHost: 'smtp.gmail.com',
      smtpPort: 587,
      log: silentLog,
    });
    // Should resolve without throwing — no real SMTP call attempted.
    await expect(sender.sendOtp('a@b', '123456')).resolves.toBeUndefined();
  });

  it('real path: sends a plain-text Indonesian email with the OTP', async () => {
    jsonMessages.length = 0;
    const sender = buildEmailOtpSender({
      smtpHost: 'smtp.gmail.com',
      smtpPort: 587,
      smtpUser: 'ops@pemkot.test',
      smtpPass: 'app-pw',
      smtpFrom: '"Pemkot" <ops@pemkot.test>',
      log: silentLog,
      transporter: captureTransporter(),
    });
    await sender.sendOtp('andi@example.test', '987654');
    expect(jsonMessages).toHaveLength(1);
    const msg = jsonMessages[0]!;
    expect(addressOf(msg.to)).toBe('andi@example.test');
    expect(addressOf(msg.from)).toBe('ops@pemkot.test');
    expect(msg.subject).toBe('Kode verifikasi Pemkot Pangkal Pinang');
    expect(msg.text).toContain('987654');
    expect(msg.text).toContain('Berlaku selama 5 menit');
    // No HTML body — keeps deliverability simple.
    expect(msg.html).toBeUndefined();
  });

  it('falls back to smtpUser as From when smtpFrom is missing', async () => {
    jsonMessages.length = 0;
    const sender = buildEmailOtpSender({
      smtpHost: 'smtp.gmail.com',
      smtpPort: 587,
      smtpUser: 'ops@pemkot.test',
      smtpPass: 'app-pw',
      log: silentLog,
      transporter: captureTransporter(),
    });
    await sender.sendOtp('andi@example.test', '111111');
    expect(addressOf(jsonMessages[0]?.from)).toBe('ops@pemkot.test');
  });

  it('wraps SMTP errors as upstream HttpError', async () => {
    const failing: Transporter = {
      sendMail: async () => {
        throw new Error('smtp connection refused');
      },
    } as unknown as Transporter;
    const sender = buildEmailOtpSender({
      smtpHost: 'smtp.gmail.com',
      smtpPort: 587,
      smtpUser: 'ops@pemkot.test',
      smtpPass: 'app-pw',
      log: silentLog,
      transporter: failing,
    });
    await expect(sender.sendOtp('a@b', '123456')).rejects.toMatchObject({
      code: 'email_otp_send_failed',
      status: 502,
    });
  });
});
