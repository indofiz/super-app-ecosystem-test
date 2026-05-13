import type { RequestHandler } from 'express';

/**
 * Per-request timeout (AUDIT PR-4). If a handler hasn't sent headers within
 * `ms`, we return a clean 504 so a stalled upstream (KC, Redis) doesn't pin
 * the inbound connection open until axios's own 10s timeout fires plus the
 * client gives up.
 *
 * Default 12_000ms — slightly above the axios per-call timeout so a single
 * slow KC call can complete before this kicks in.
 */
export const timeoutMiddleware = (ms: number): RequestHandler => {
  return (_req, res, next) => {
    const timer = setTimeout(() => {
      if (!res.headersSent) {
        res.status(504).json({
          error: 'upstream_timeout',
          error_description: 'Request exceeded server budget',
        });
      }
    }, ms);
    timer.unref();
    const clear = () => clearTimeout(timer);
    res.on('finish', clear);
    res.on('close', clear);
    next();
  };
};
