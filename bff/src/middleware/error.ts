import type { ErrorRequestHandler } from 'express';
import { HttpError } from '../lib/errors.js';
import type { Logger } from '../lib/logger.js';
import type { MetricsBundle } from '../lib/metrics.js';

// Error codes worth alerting on (auth-failure pattern). Anything else
// becomes "other" so cardinality stays bounded.
const FAILED_AUTH_CODES = new Set([
  'invalid_request',
  'invalid_client',
  'invalid_grant',
  'invalid_token',
  'invalid_session',
  'missing_bearer',
  'sid_mismatch',
  'pkce_mismatch',
]);

export const errorMiddleware =
  (log: Logger, metrics?: MetricsBundle): ErrorRequestHandler =>
  (err, req, res, _next) => {
    if (err instanceof HttpError) {
      // AUDIT S-2: log `detail` server-side only — never put it on the wire.
      log.warn(
        {
          err,
          code: err.code,
          status: err.status,
          path: req.path,
          // detail can contain zod issues; logger redaction handles secrets.
          detail: err.detail,
        },
        'http error',
      );
      if (metrics && err.status >= 400 && err.status < 500) {
        const reason = FAILED_AUTH_CODES.has(err.code) ? err.code : 'other';
        metrics.authFailedTotal.inc({ reason });
      }
      res.status(err.status).json({
        error: err.code,
        error_description: err.message,
        // Only echoed when the handler explicitly opted in via
        // `publicDetail`. `detail` (server-side-only) is never on the wire.
        ...(err.publicDetail ? { detail: err.publicDetail } : {}),
      });
      return;
    }
    log.error({ err, path: req.path }, 'unhandled error');
    if (metrics) metrics.authFailedTotal.inc({ reason: 'internal_error' });
    res.status(500).json({ error: 'internal_error', error_description: 'Internal server error' });
  };
