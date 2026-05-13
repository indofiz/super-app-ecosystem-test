import type { ZodError, ZodIssue } from 'zod';

/**
 * AUDIT S-2 — Stable error vocabulary.
 *
 * The legacy code path put zod's issue text directly into the public
 * `error_description`, which echoes the user-supplied bad value back into
 * the response and acts as a parser-error oracle. The new helpers:
 *
 *  - `HttpError` carries a stable `code` + a public `message`. The
 *    `message` is the only thing handed to the client.
 *  - `HttpError.cause` carries the underlying detail (e.g. zod issue
 *    array) for server-side logging.
 *  - `badRequestFromZod` projects a `ZodError` into a stable message.
 */
export class HttpError extends Error {
  public readonly status: number;
  public readonly code: string;
  /** Optional detail for server-side logs only. Never sent to the client. */
  public readonly detail?: unknown;

  constructor(status: number, code: string, message: string, detail?: unknown) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

export const badRequest = (code: string, message: string, detail?: unknown) =>
  new HttpError(400, code, message, detail);

export const unauthorized = (code: string, message: string, detail?: unknown) =>
  new HttpError(401, code, message, detail);

export const forbidden = (code: string, message: string, detail?: unknown) =>
  new HttpError(403, code, message, detail);

export const upstream = (code: string, message: string, detail?: unknown) =>
  new HttpError(502, code, message, detail);

/**
 * Project a `ZodError` into a `400 invalid_request` with a fixed message
 * vocabulary. The full issue array travels via `detail` so it can be logged
 * server-side without leaking into the wire response.
 */
export const badRequestFromZod = (error: ZodError, fallback = 'Invalid input'): HttpError => {
  const issues: readonly ZodIssue[] = error.issues;
  // Pick a stable, vocabulary-bound message based on the first issue's
  // shape (not its text). Keeps the wire response constant for any
  // particular failure mode.
  let message = fallback;
  if (issues.length > 0) {
    const i = issues[0]!;
    const path = i.path.join('.') || 'body';
    switch (i.code) {
      case 'invalid_type':
        message = `Field "${path}" has the wrong type`;
        break;
      case 'too_small':
        message = `Field "${path}" is too short`;
        break;
      case 'too_big':
        message = `Field "${path}" is too long`;
        break;
      case 'invalid_string':
        message = `Field "${path}" has an invalid format`;
        break;
      case 'invalid_enum_value':
        message = `Field "${path}" has an unsupported value`;
        break;
      case 'invalid_literal':
        message = `Field "${path}" has an unsupported value`;
        break;
      case 'unrecognized_keys':
        message = `Unexpected field(s) in body`;
        break;
      default:
        message = `Field "${path}" is invalid`;
    }
  }
  return new HttpError(400, 'invalid_request', message, issues);
};
