// AUDIT M-3: module augmentation so `req.id` and `req.claims` are
// first-class properties of Express's Request type. Centralized here
// to keep handlers free of `as unknown as { id }` casts.
import type { InternalJwtVerifiedClaims } from '../lib/internalJwt.js';

declare module 'express-serve-static-core' {
  interface Request {
    /** Set by `requestIdMiddleware` — echoed in the response x-request-id header. */
    id: string;
    /** Set by `requireSessionBearer` after verifying the internal JWT. */
    claims?: InternalJwtVerifiedClaims;
  }
}

export {};
