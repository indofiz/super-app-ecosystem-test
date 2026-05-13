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
  KC_SCOPES: z.string().min(1).default('openid profile email'),

  ALLOWED_APP_CLIENTS: z.string().min(1).transform(csv),
  ALLOWED_APP_REDIRECT_URIS: z.string().min(1).transform(csv),

  REDIS_URL: z.string().min(1),

  SESSION_TTL_SECONDS: z.coerce.number().int().positive().default(60 * 60 * 24 * 30),
  AUTHSTATE_TTL_SECONDS: z.coerce.number().int().positive().default(60 * 10),
  BFFCODE_TTL_SECONDS: z.coerce.number().int().positive().default(60 * 5),

  CORS_ORIGINS: z
    .string()
    .default('')
    .transform((s) => (s ? csv(s) : [])),

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
  BFF_INTERNAL_JWT_TTL_SECONDS: z.coerce.number().int().positive().default(300),
  BFF_INTERNAL_JWT_ISSUER: z.string().min(1).default('super-app-bff'),
  BFF_INTERNAL_JWT_AUDIENCE: z.string().min(1).default('super-app-services'),

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
