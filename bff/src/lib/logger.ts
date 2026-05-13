import pino from 'pino';
import type { Env } from '../config/env.js';

export const createLogger = (env: Pick<Env, 'LOG_LEVEL' | 'NODE_ENV'>) =>
  pino({
    level: env.LOG_LEVEL,
    base: { env: env.NODE_ENV },
    redact: {
      // Defensive: never let any token-like thing slip into logs.
      paths: [
        'req.headers.authorization',
        'req.headers.cookie',
        'req.body.code',
        'req.body.code_verifier',
        'req.body.session_id',
        'req.body.refresh_token',
        'req.body.access_token',
        'req.query.code',
        'req.query.state',
        '*.access_token',
        '*.refresh_token',
        '*.id_token',
        '*.session_id',
        '*.client_secret',
      ],
      remove: true,
    },
    timestamp: pino.stdTimeFunctions.isoTime,
  });

export type Logger = ReturnType<typeof createLogger>;
