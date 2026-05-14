import 'dotenv/config';
import { z } from 'zod';

const csv = (s: string) =>
  s
    .split(',')
    .map((x) => x.trim())
    .filter((x) => x.length > 0);

const decodeBase64Pem = (b64: string, label: string): string => {
  const decoded = Buffer.from(b64, 'base64').toString('utf8');
  if (!/-----BEGIN [A-Z ]+-----/.test(decoded)) {
    throw new Error(`${label} is not a valid base64-encoded PEM`);
  }
  return decoded;
};

const PublicKeyEntry = z.object({
  kid: z.string().min(1),
  pem: z.string().min(1),
});

const EnvSchema = z.object({
  PORT: z.coerce.number().int().positive().default(3000),
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  PUBLIC_BASE_URL: z.string().url(),

  KC_ISSUER: z.string().url(),
  KC_CLIENT_ID: z.string().min(1),
  KC_CLIENT_SECRET: z.string().min(1),
  // `phone` is required for KC to ship `phone_number` + `phone_number_verified`
  // claims (sourced from the `phoneNumber` / `phoneNumberVerified` user attrs)
  // on the access_token. Without it the OTP-verify path has no way to read
  // the current verification state from upstream.
  KC_SCOPES: z.string().min(1).default('openid profile email phone'),
  // Realm-relative admin API base. Derived from KC_ISSUER if absent.
  KC_ADMIN_BASE_URL: z.string().url().optional(),

  ALLOWED_APP_CLIENTS: z.string().min(1).transform(csv),
  ALLOWED_APP_REDIRECT_URIS: z.string().min(1).transform(csv),

  REDIS_URL: z.string().min(1),

  // AUDIT PR-7: TTL ceilings prevent typo foot-guns (an extra zero turning
  // a 30-day session into an 8-month one). Numbers chosen to comfortably
  // fit any realistic config; if you need more, raise the cap deliberately.
  SESSION_TTL_SECONDS: z
    .coerce.number()
    .int()
    .positive()
    .max(60 * 60 * 24 * 90)
    .default(60 * 60 * 24 * 30),
  AUTHSTATE_TTL_SECONDS: z
    .coerce.number()
    .int()
    .positive()
    .max(60 * 60)
    .default(60 * 10),
  BFFCODE_TTL_SECONDS: z
    .coerce.number()
    .int()
    .positive()
    .max(60 * 60)
    .default(60 * 5),

  CORS_ORIGINS: z
    .string()
    .default('')
    .transform((s) => (s ? csv(s) : [])),

  // AUDIT S-3 / PR-4: networking knobs that used to be hardcoded.
  //   TRUST_PROXY: passed through to Express's `trust proxy` setting.
  //     Accept any of:
  //       - integer hop count           e.g. "1"
  //       - the names Express supports  e.g. "loopback", "linklocal", "uniquelocal"
  //       - one or more CSV of CIDRs    e.g. "10.0.0.0/8,172.16.0.0/12"
  //   REQUEST_TIMEOUT_MS: per-route timeout (must be > axios's 10s budget).
  TRUST_PROXY: z
    .string()
    .default('loopback')
    .transform((raw): boolean | number | string | string[] => {
      const trimmed = raw.trim();
      if (trimmed === 'true') return true;
      if (trimmed === 'false') return false;
      const asInt = Number(trimmed);
      if (Number.isInteger(asInt) && asInt >= 0 && /^\d+$/.test(trimmed)) return asInt;
      if (trimmed.includes(',')) return csv(trimmed);
      return trimmed;
    }),
  REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().max(30_000).default(12_000),

  BFF_INTERNAL_JWT_ALG: z.enum(['RS256']).default('RS256'),
  BFF_INTERNAL_JWT_ACTIVE_KID: z.string().min(1),
  BFF_INTERNAL_JWT_PRIVATE_KEY: z
    .string()
    .min(1)
    .transform((s) => decodeBase64Pem(s, 'BFF_INTERNAL_JWT_PRIVATE_KEY')),
  BFF_INTERNAL_JWT_PUBLIC_KEYS: z
    .string()
    .min(1)
    .transform((raw, ctx): Array<{ kid: string; pem: string }> => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'must be valid JSON' });
        return z.NEVER;
      }
      const arr = z.array(PublicKeyEntry).min(1).safeParse(parsed);
      if (!arr.success) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'must be a non-empty array of {kid, pem}',
        });
        return z.NEVER;
      }
      try {
        return arr.data.map((e) => ({ kid: e.kid, pem: decodeBase64Pem(e.pem, `kid=${e.kid}`) }));
      } catch (err) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: err instanceof Error ? err.message : 'invalid PEM',
        });
        return z.NEVER;
      }
    }),
  // AUDIT PR-7: keep TTL well under 30 min — these tokens have no
  // denylist (see AUDIT S-8). Any future bump must add replay protection.
  BFF_INTERNAL_JWT_TTL_SECONDS: z.coerce.number().int().positive().max(60 * 30).default(300),
  BFF_INTERNAL_JWT_ISSUER: z.string().min(1).default('super-app-bff'),
  BFF_INTERNAL_JWT_AUDIENCE: z.string().min(1).default('super-app-services'),

  // --- Email OTP (Gmail SMTP for MVP — swap adapter for SES/SendGrid later) ---
  //
  // Gmail requires:
  //   - 2-Step Verification ON for the sending account
  //   - an App Password (https://myaccount.google.com/apppasswords) — the
  //     regular account password will be rejected
  // Free-tier Gmail caps at ~500 sends/day; move to a real relay before
  // production traffic.
  SMTP_HOST: z.string().min(1).default('smtp.gmail.com'),
  SMTP_PORT: z.coerce.number().int().positive().max(65535).default(587),
  SMTP_USER: z.string().min(1).optional(),
  SMTP_PASS: z.string().min(1).optional(),
  SMTP_FROM: z.string().min(1).optional(),

  // --- WhatsApp OTP (Fonnte for MVP) ---
  // Token from the Fonnte device dashboard. Migrate to Meta Cloud API
  // when volume justifies WABA verification (see docs/registration-and-
  // verification.md §4.D).
  FONNTE_TOKEN: z.string().min(1).optional(),
  FONNTE_BASE_URL: z.string().url().default('https://api.fonnte.com'),

  // --- OTP behaviour ---
  // Single OTP record per (channel, user). TTL bounds the verify window;
  // attempts cap prevents online brute force without rate-limiting the
  // user out of resend.
  OTP_TTL_SECONDS: z.coerce.number().int().positive().max(60 * 30).default(300),
  OTP_MAX_ATTEMPTS: z.coerce.number().int().positive().max(20).default(5),

  // Observability (IMPROVEMENT_PLAN §3.1). All default off — flip on per
  // environment. /metrics MUST NOT be reachable from the public internet;
  // gate at nginx/Kong before enabling in production.
  METRICS_ENABLED: z
    .union([z.boolean(), z.string()])
    .default(false)
    .transform((v) => (typeof v === 'boolean' ? v : v.toLowerCase() === 'true')),
  TRACING_ENABLED: z
    .union([z.boolean(), z.string()])
    .default(false)
    .transform((v) => (typeof v === 'boolean' ? v : v.toLowerCase() === 'true')),
  OTEL_EXPORTER_OTLP_ENDPOINT: z.string().url().optional(),
  OTEL_SERVICE_NAME: z.string().min(1).default('super-app-bff'),
  BUILD_COMMIT: z.string().default('unknown'),
  BUILD_VERSION: z.string().default('0.0.0'),
});

export type Env = z.infer<typeof EnvSchema>;

export const loadEnv = (source: NodeJS.ProcessEnv = process.env): Env => {
  const parsed = EnvSchema.safeParse(source);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  const env = parsed.data;
  if (!env.BFF_INTERNAL_JWT_PUBLIC_KEYS.some((k) => k.kid === env.BFF_INTERNAL_JWT_ACTIVE_KID)) {
    throw new Error(
      `BFF_INTERNAL_JWT_ACTIVE_KID="${env.BFF_INTERNAL_JWT_ACTIVE_KID}" has no matching entry in BFF_INTERNAL_JWT_PUBLIC_KEYS`,
    );
  }
  return env;
};
