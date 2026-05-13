import pino from 'pino';
import type { Env } from '../config/env.js';

// AUDIT S-7: explicit redaction list. pino's `*.x` wildcards only match
// one level deep, so we enumerate the realistic shapes (top-level,
// req/res-nested, and tokens-bag-nested) explicitly. Exported so tests
// can assert against the same list the logger uses.
export const REDACT_PATHS: readonly string[] = [
  'req.headers.authorization',
  'req.headers.cookie',
  'req.headers["x-api-key"]',
  'res.headers["set-cookie"]',
  'req.body.code',
  'req.body.code_verifier',
  'req.body.session_id',
  'req.body.refresh_token',
  'req.body.access_token',
  'req.body.tokens.access_token',
  'req.body.tokens.refresh_token',
  'req.body.tokens.id_token',
  'req.query.code',
  'req.query.state',
  'access_token',
  'refresh_token',
  'id_token',
  'session_id',
  'client_secret',
  '*.access_token',
  '*.refresh_token',
  '*.id_token',
  '*.session_id',
  '*.client_secret',
  '*.tokens.access_token',
  '*.tokens.refresh_token',
  '*.tokens.id_token',
  'tokens.access_token',
  'tokens.refresh_token',
  'tokens.id_token',
];

export const createLogger = (env: Pick<Env, 'LOG_LEVEL' | 'NODE_ENV'>) =>
  pino({
    level: env.LOG_LEVEL,
    base: { env: env.NODE_ENV },
    redact: {
      paths: [...REDACT_PATHS],
      remove: true,
    },
    timestamp: pino.stdTimeFunctions.isoTime,
  });

export type Logger = ReturnType<typeof createLogger>;
