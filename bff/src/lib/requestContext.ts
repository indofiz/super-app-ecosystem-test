import { AsyncLocalStorage } from 'node:async_hooks';
import type { RequestHandler } from 'express';

interface RequestContext {
  requestId: string;
}

const als = new AsyncLocalStorage<RequestContext>();

/**
 * Express middleware that pins the per-request `req.id` into an
 * AsyncLocalStorage. Downstream HTTP clients (e.g. KeycloakClient) can
 * then read the current request id without explicit plumbing.
 *
 * AUDIT PR-3: lets the KC client tag outbound calls with the same
 * x-request-id the inbound call carried, so traces stitch end-to-end.
 */
export const requestContextMiddleware: RequestHandler = (req, _res, next) => {
  if (!req.id) {
    next();
    return;
  }
  als.run({ requestId: req.id }, () => next());
};

export const getCurrentRequestId = (): string | undefined => {
  return als.getStore()?.requestId;
};
