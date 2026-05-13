import { describe, expect, it } from 'vitest';
import {
  challengeFromVerifier,
  generateVerifier,
  parsePkceMethod,
  verifyChallenge,
} from '../src/lib/pkce.js';

describe('pkce', () => {
  it('S256: round-trips verifier ↔ challenge', () => {
    const v = generateVerifier();
    const c = challengeFromVerifier(v);
    expect(verifyChallenge(v, c)).toBe(true);
  });

  it('S256: rejects mismatched verifier', () => {
    const v = generateVerifier();
    const c = challengeFromVerifier(v);
    expect(verifyChallenge('not-the-verifier-not-the-verifier-not-the-verifier', c)).toBe(false);
  });

  it('parsePkceMethod defaults to S256', () => {
    expect(parsePkceMethod(undefined)).toBe('S256');
  });

  it('parsePkceMethod accepts S256', () => {
    expect(parsePkceMethod('S256')).toBe('S256');
  });

  it('parsePkceMethod rejects plain', () => {
    expect(() => parsePkceMethod('plain')).toThrow(/only S256/);
  });

  it('parsePkceMethod rejects unknown', () => {
    expect(() => parsePkceMethod('weird')).toThrow();
  });
});
