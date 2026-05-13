export class HttpError extends Error {
  public readonly status: number;
  public readonly code: string;

  constructor(status: number, code: string, message: string, cause?: unknown) {
    super(message, cause !== undefined ? { cause } : undefined);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (code: string, message: string, cause?: unknown) =>
  new HttpError(400, code, message, cause);

export const unauthorized = (code: string, message: string, cause?: unknown) =>
  new HttpError(401, code, message, cause);

export const forbidden = (code: string, message: string, cause?: unknown) =>
  new HttpError(403, code, message, cause);

export const upstream = (code: string, message: string, cause?: unknown) =>
  new HttpError(502, code, message, cause);
