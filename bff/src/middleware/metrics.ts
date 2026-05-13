import type { RequestHandler } from 'express';
import type { MetricsBundle } from '../lib/metrics.js';
import { normalizeRoute } from '../lib/metrics.js';

export const metricsMiddleware = (m: MetricsBundle): RequestHandler => {
  return (req, res, next) => {
    const startNs = process.hrtime.bigint();
    res.on('finish', () => {
      const durationS = Number(process.hrtime.bigint() - startNs) / 1e9;
      // req.route?.path is undefined for 404s and middleware-rejected paths.
      // Falling back to req.path keeps the label populated; normalizeRoute
      // collapses anything not in the allowlist to "other".
      const route = normalizeRoute(req.route?.path ?? req.path);
      const method = req.method;
      m.httpRequestsTotal.inc({ route, method, status: String(res.statusCode) });
      m.httpRequestDurationSeconds.observe({ route, method }, durationS);
    });
    next();
  };
};
