import { generateKeyPairSync } from 'node:crypto';
import { SignJWT, decodeProtectedHeader, importPKCS8 } from 'jose';
import { beforeAll, describe, expect, it } from 'vitest';
import { InternalJwtIssuer, type PublicKeyEntry } from '../src/lib/internalJwt.js';

const ISSUER = 'super-app-bff';
const AUDIENCE = 'super-app-services';

interface KeyPair {
  kid: string;
  privatePem: string;
  publicPem: string;
}
const generatePair = (kid: string): KeyPair => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  return { kid, privatePem: privateKey, publicPem: publicKey };
};

const buildIssuer = async (
  active: KeyPair,
  rest: KeyPair[] = [],
  ttl = 300,
): Promise<InternalJwtIssuer> => {
  const publicKeys: PublicKeyEntry[] = [active, ...rest].map((p) => ({
    kid: p.kid,
    pem: p.publicPem,
  }));
  return InternalJwtIssuer.create({
    alg: 'RS256',
    activeKid: active.kid,
    privateKeyPem: active.privatePem,
    publicKeys,
    issuer: ISSUER,
    audience: AUDIENCE,
    ttlSeconds: ttl,
  });
};

const sampleClaims = {
  sub: 'user-123',
  sid: 'sid-abc',
  username: 'andi.permana',
  email: 'andi@example.test',
  roles: ['citizen'],
};

describe('InternalJwtIssuer (RS256)', () => {
  let v1: KeyPair;
  let v2: KeyPair;
  beforeAll(() => {
    v1 = generatePair('v1');
    v2 = generatePair('v2');
  });

  it('round-trips mint → verify with all expected claims', async () => {
    const issuer = await buildIssuer(v1);
    const { token, expiresIn } = await issuer.mint(sampleClaims);
    expect(expiresIn).toBe(300);

    // Header carries the alg + kid.
    const header = decodeProtectedHeader(token);
    expect(header.alg).toBe('RS256');
    expect(header.kid).toBe('v1');

    const claims = await issuer.verify(token);
    expect(claims.sub).toBe('user-123');
    expect(claims.sid).toBe('sid-abc');
    expect(claims.username).toBe('andi.permana');
    expect(claims.email).toBe('andi@example.test');
    expect(claims.roles).toEqual(['citizen']);
    expect(claims.iss).toBe(ISSUER);
    expect(claims.aud).toBe(AUDIENCE);
    expect(claims.kid).toBe('v1');
    expect(claims.jti).toBeTruthy();
    expect(claims.exp).toBeGreaterThan(claims.iat);
  });

  it('echoes kid into the payload (for Kong key_claim_name=kid lookup)', async () => {
    const issuer = await buildIssuer(v1);
    const { token } = await issuer.mint(sampleClaims);
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString('utf8')) as {
      kid?: string;
    };
    expect(payload.kid).toBe('v1');
  });

  it('selects verification key by header kid when multiple are loaded', async () => {
    // Issuer signs with v2 but knows about both v1 and v2.
    const issuer = await buildIssuer(v2, [v1]);
    const { token } = await issuer.mint(sampleClaims);
    expect(decodeProtectedHeader(token).kid).toBe('v2');
    const claims = await issuer.verify(token);
    expect(claims.kid).toBe('v2');
  });

  it('verifies tokens signed by an old kid that is still listed (rotation overlap)', async () => {
    // Mint with an issuer that only has v1.
    const v1Only = await buildIssuer(v1);
    const { token: v1Token } = await v1Only.mint(sampleClaims);

    // A second issuer rotates to v2 but still lists v1 → must verify v1 tokens.
    const overlap = await buildIssuer(v2, [v1]);
    const claims = await overlap.verify(v1Token);
    expect(claims.kid).toBe('v1');
  });

  it('rejects token whose kid is not in the public-key map', async () => {
    const v1Only = await buildIssuer(v1);
    const { token } = await v1Only.mint(sampleClaims);

    const v2Only = await buildIssuer(v2);
    await expect(v2Only.verify(token)).rejects.toThrow(/unknown kid/);
  });

  it('rejects token signed with the wrong private key for a known kid', async () => {
    // Attacker mints a token claiming kid="v1" but signed with v2's private key.
    const v2Priv = await importPKCS8(v2.privatePem, 'RS256');
    const forged = await new SignJWT({ ...sampleClaims, kid: 'v1' })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT', kid: 'v1' })
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setSubject(sampleClaims.sub)
      .setIssuedAt()
      .setExpirationTime('5m')
      .setJti('forged')
      .sign(v2Priv);

    const issuer = await buildIssuer(v1);
    await expect(issuer.verify(forged)).rejects.toThrow();
  });

  it('rejects token with no kid header', async () => {
    const v1Priv = await importPKCS8(v1.privatePem, 'RS256');
    const noKid = await new SignJWT({ ...sampleClaims })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setSubject(sampleClaims.sub)
      .setIssuedAt()
      .setExpirationTime('5m')
      .setJti('nokid')
      .sign(v1Priv);

    const issuer = await buildIssuer(v1);
    await expect(issuer.verify(noKid)).rejects.toThrow(/missing kid/);
  });

  it('rejects expired tokens', async () => {
    const issuer = await buildIssuer(v1, [], -1);
    const { token } = await issuer.mint(sampleClaims);
    await expect(issuer.verify(token)).rejects.toThrow();
  });

  it('verifyAllowingExpired accepts expired tokens within grace window', async () => {
    const issuer = await buildIssuer(v1, [], -1);
    const { token } = await issuer.mint(sampleClaims);
    const claims = await issuer.verifyAllowingExpired(token);
    expect(claims.sub).toBe('user-123');
  });

  it('verifyAllowingExpired rejects tokens whose grace window has passed (AUDIT S-6)', async () => {
    // Token expired 1h ago. With grace=60 it's outside the window and
    // should be rejected. (The base 60s clockTolerance is the "live"
    // window; grace must extend past that to be meaningful.)
    const issuer = await buildIssuer(v1, [], -3600);
    const { token } = await issuer.mint(sampleClaims);
    await expect(issuer.verifyAllowingExpired(token, 60)).rejects.toThrow();
    // With a generous grace it goes through.
    const claims = await issuer.verifyAllowingExpired(token, 60 * 60 * 24);
    expect(claims.sub).toBe('user-123');
  });

  it('verifyAllowingExpired rejects tokens with a future nbf (AUDIT S-6)', async () => {
    // The narrowed clockTolerance (60s) means a token whose nbf is 1h in
    // the future is no longer accepted just because the legacy 24h
    // window allowed it.
    const issuer = await buildIssuer(v1);
    const futureNbf = new SignJWT({ sid: 's', roles: [] })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT', kid: 'v1' })
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setSubject('user-123')
      .setIssuedAt()
      .setNotBefore(`${60 * 60}s`)
      .setExpirationTime(`${60 * 60 * 2}s`);
    const privateKey = await importPKCS8(v1.privatePem, 'RS256');
    const token = await futureNbf.sign(privateKey);
    await expect(issuer.verifyAllowingExpired(token)).rejects.toThrow();
  });

  it('rejects tokens with wrong issuer or audience', async () => {
    const issuer = await buildIssuer(v1);
    const { token } = await issuer.mint(sampleClaims);
    const wrongIssuer = await InternalJwtIssuer.create({
      alg: 'RS256',
      activeKid: 'v1',
      privateKeyPem: v1.privatePem,
      publicKeys: [{ kid: 'v1', pem: v1.publicPem }],
      issuer: 'someone-else',
      audience: AUDIENCE,
      ttlSeconds: 300,
    });
    await expect(wrongIssuer.verify(token)).rejects.toThrow();

    const wrongAud = await InternalJwtIssuer.create({
      alg: 'RS256',
      activeKid: 'v1',
      privateKeyPem: v1.privatePem,
      publicKeys: [{ kid: 'v1', pem: v1.publicPem }],
      issuer: ISSUER,
      audience: 'someone-else',
      ttlSeconds: 300,
    });
    await expect(wrongAud.verify(token)).rejects.toThrow();
  });

  it('refuses to construct when activeKid is not in publicKeys', async () => {
    await expect(
      InternalJwtIssuer.create({
        alg: 'RS256',
        activeKid: 'v9',
        privateKeyPem: v1.privatePem,
        publicKeys: [{ kid: 'v1', pem: v1.publicPem }],
        issuer: ISSUER,
        audience: AUDIENCE,
        ttlSeconds: 300,
      }),
    ).rejects.toThrow(/activeKid/);
  });

  it('exposes a JWKS document with one entry per public key', async () => {
    const issuer = await buildIssuer(v1, [v2]);
    const jwks = issuer.getJwks();
    expect(jwks.keys).toHaveLength(2);
    const byKid = new Map(jwks.keys.map((k) => [k.kid, k]));
    expect(byKid.get('v1')).toMatchObject({ kty: 'RSA', alg: 'RS256', use: 'sig', kid: 'v1' });
    expect(byKid.get('v2')).toMatchObject({ kty: 'RSA', alg: 'RS256', use: 'sig', kid: 'v2' });
    // n + e are the RSA public components — must be present, never `d` (private).
    for (const k of jwks.keys) {
      expect(k.n).toBeTruthy();
      expect(k.e).toBeTruthy();
      expect((k as Record<string, unknown>).d).toBeUndefined();
    }
  });
});
