import { Writable } from 'node:stream';
import pino from 'pino';
import { describe, expect, it } from 'vitest';
import { REDACT_PATHS } from '../src/lib/logger.js';

/**
 * AUDIT S-7: pino redaction wildcards do not match nested paths. We've
 * enumerated the realistic shapes; this test asserts the secrets are
 * actually stripped from logged payloads, including nested req/res shapes.
 */

const captureLines = (): { sink: Writable; lines: string[] } => {
  const lines: string[] = [];
  const sink = new Writable({
    write(chunk, _enc, cb) {
      lines.push(chunk.toString('utf8'));
      cb();
    },
  });
  return { sink, lines };
};

const FAKE_TOKEN_AT = 'eyJ-fake-access-NEVER-LOG-ME';
const FAKE_TOKEN_RT = 'eyJ-fake-refresh-NEVER-LOG-ME';
const FAKE_TOKEN_ID = 'eyJ-fake-id-NEVER-LOG-ME';
const FAKE_COOKIE = 'sid=super-secret-NEVER-LOG';
const FAKE_BEARER = 'Bearer eyJ-real-bearer-NEVER-LOG';

const buildLog = (sink: Writable) =>
  pino({ redact: { paths: [...REDACT_PATHS], remove: true } }, sink);

describe('logger redaction — AUDIT S-7', () => {
  it('strips top-level token-shaped fields', () => {
    const { sink, lines } = captureLines();
    const log = buildLog(sink);
    log.info({ access_token: FAKE_TOKEN_AT, refresh_token: FAKE_TOKEN_RT }, 'tokens minted');
    const out = lines.join('');
    expect(out).not.toContain(FAKE_TOKEN_AT);
    expect(out).not.toContain(FAKE_TOKEN_RT);
  });

  it('strips nested req/res shapes pino-http would produce', () => {
    const { sink, lines } = captureLines();
    const log = buildLog(sink);
    log.info(
      {
        req: {
          headers: {
            authorization: FAKE_BEARER,
            cookie: FAKE_COOKIE,
          },
          body: {
            code: 'auth-code-1',
            code_verifier: 'cv-12345',
            tokens: {
              access_token: FAKE_TOKEN_AT,
              refresh_token: FAKE_TOKEN_RT,
              id_token: FAKE_TOKEN_ID,
            },
          },
        },
        res: { headers: { 'set-cookie': FAKE_COOKIE } },
      },
      'incoming request',
    );
    const out = lines.join('');
    expect(out).not.toContain(FAKE_BEARER);
    expect(out).not.toContain(FAKE_COOKIE);
    expect(out).not.toContain('auth-code-1');
    expect(out).not.toContain('cv-12345');
    expect(out).not.toContain(FAKE_TOKEN_AT);
    expect(out).not.toContain(FAKE_TOKEN_RT);
    expect(out).not.toContain(FAKE_TOKEN_ID);
  });

  it('strips one-level-nested tokens bags', () => {
    const { sink, lines } = captureLines();
    const log = buildLog(sink);
    log.info(
      { ctx: { tokens: { access_token: FAKE_TOKEN_AT, refresh_token: FAKE_TOKEN_RT } } },
      'audit',
    );
    const out = lines.join('');
    expect(out).not.toContain(FAKE_TOKEN_AT);
    expect(out).not.toContain(FAKE_TOKEN_RT);
  });
});
