import { randomUUID } from 'node:crypto';
import {
  SignJWT,
  decodeProtectedHeader,
  exportJWK,
  importPKCS8,
  importSPKI,
  jwtVerify,
  type JWK,
  type KeyLike,
} from 'jose';

/** Claims the BFF puts into every internal JWT. Microservices receive these. */
export interface InternalJwtClaims {
  /** Keycloak `sub` (stable user id) — kept for traceability across systems. */
  sub: string;
  /** BFF session id; ties this token to a Redis session for revocation/refresh. */
  sid: string;
  username?: string;
  email?: string;
  /** Distilled role list. Start with Keycloak's `realm_access.roles`. */
  roles: string[];
}

export interface InternalJwtVerifiedClaims extends InternalJwtClaims {
  iss: string;
  aud: string;
  iat: number;
  exp: number;
  jti: string;
  /** Key id the token was signed with (echoed in payload for Kong's lookup). */
  kid: string;
}

export interface PublicKeyEntry {
  kid: string;
  /** SPKI PEM. */
  pem: string;
}

export interface InternalJwtIssuerOptions {
  alg: 'RS256';
  activeKid: string;
  privateKeyPem: string;
  publicKeys: PublicKeyEntry[];
  issuer: string;
  audience: string;
  ttlSeconds: number;
}

interface PublicKey {
  kid: string;
  key: KeyLike;
  jwk: JWK;
}

/**
 * Mints and verifies the short-lived RS256 JWT that mobile carries through
 * Kong. The BFF holds the private key; Kong (and any other verifier) only
 * needs the public key for the matching `kid`. See bff/docs/IMPROVEMENT_PLAN
 * §2.2 for the asymmetric-vs-symmetric reasoning.
 */
export class InternalJwtIssuer {
  private constructor(
    private readonly alg: 'RS256',
    private readonly activeKid: string,
    private readonly privateKey: KeyLike,
    private readonly publicKeys: ReadonlyMap<string, PublicKey>,
    private readonly issuer: string,
    private readonly audience: string,
    private readonly ttlSeconds: number,
  ) {}

  static async create(opts: InternalJwtIssuerOptions): Promise<InternalJwtIssuer> {
    const privateKey = await importPKCS8(opts.privateKeyPem, opts.alg);
    const entries: Array<[string, PublicKey]> = [];
    for (const pk of opts.publicKeys) {
      const key = await importSPKI(pk.pem, opts.alg, { extractable: true });
      const jwk: JWK = { ...(await exportJWK(key)), alg: opts.alg, use: 'sig', kid: pk.kid };
      entries.push([pk.kid, { kid: pk.kid, key, jwk }]);
    }
    const publicKeys = new Map(entries);
    if (!publicKeys.has(opts.activeKid)) {
      throw new Error(
        `activeKid="${opts.activeKid}" has no matching entry in publicKeys (have: ${[...publicKeys.keys()].join(', ')})`,
      );
    }
    return new InternalJwtIssuer(
      opts.alg,
      opts.activeKid,
      privateKey,
      publicKeys,
      opts.issuer,
      opts.audience,
      opts.ttlSeconds,
    );
  }

  async mint(claims: InternalJwtClaims): Promise<{ token: string; expiresIn: number }> {
    const token = await new SignJWT({
      sid: claims.sid,
      username: claims.username,
      email: claims.email,
      roles: claims.roles,
      kid: this.activeKid,
    })
      .setProtectedHeader({ alg: this.alg, typ: 'JWT', kid: this.activeKid })
      .setIssuer(this.issuer)
      .setAudience(this.audience)
      .setSubject(claims.sub)
      .setIssuedAt()
      // Kong's bundled jwt plugin enforces `nbf` (see kong/kong.yml,
      // claims_to_verify). Without an nbf claim on every token the plugin
      // would reject everything. nbf=now matches iat — a future-dated
      // token from a BFF whose clock has drifted forward will then be
      // rejected at the gateway (AUDIT S-4).
      .setNotBefore('0s')
      .setExpirationTime(`${this.ttlSeconds}s`)
      .setJti(randomUUID())
      .sign(this.privateKey);
    return { token, expiresIn: this.ttlSeconds };
  }

  async verify(token: string): Promise<InternalJwtVerifiedClaims> {
    return this.verifyInternal(token, {});
  }

  /**
   * Verifies signature + iss + aud but tolerates an expired `exp` up to
   * `graceSeconds` past expiry. Used by `/auth/logout` and the recently-expired
   * branch of `/auth/refresh` (see IMPROVEMENT_PLAN §2.1).
   */
  async verifyAllowingExpired(
    token: string,
    graceSeconds = 24 * 60 * 60,
  ): Promise<InternalJwtVerifiedClaims> {
    return this.verifyInternal(token, { clockTolerance: graceSeconds });
  }

  /** Public keys in JWKS shape — for `/.well-known/jwks.json`. */
  getJwks(): { keys: JWK[] } {
    return { keys: [...this.publicKeys.values()].map((p) => p.jwk) };
  }

  private async verifyInternal(
    token: string,
    extra: { clockTolerance?: number },
  ): Promise<InternalJwtVerifiedClaims> {
    const header = decodeProtectedHeader(token);
    const kid = typeof header.kid === 'string' ? header.kid : undefined;
    if (!kid) throw new Error('internal_jwt: missing kid header');
    const entry = this.publicKeys.get(kid);
    if (!entry) throw new Error(`internal_jwt: unknown kid "${kid}"`);
    const { payload } = await jwtVerify(token, entry.key, {
      issuer: this.issuer,
      audience: this.audience,
      algorithms: [this.alg],
      ...(extra.clockTolerance !== undefined ? { clockTolerance: extra.clockTolerance } : {}),
    });
    return { ...(payload as unknown as InternalJwtVerifiedClaims), kid };
  }
}
