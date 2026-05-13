import { randomUUID } from 'node:crypto';
import type { RequestHandler } from 'express';

const HEADER = 'x-request-id';

export const requestIdMiddleware: RequestHandler = (req, res, next) => {
  const incoming = req.headers[HEADER];
  const id = (Array.isArray(incoming) ? incoming[0] : incoming) ?? randomUUID();
  res.setHeader(HEADER, id);
  (req as unknown as { id: string }).id = id;
  next();
};
