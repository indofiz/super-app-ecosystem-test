import {
  createRemoteJWKSet,
  jwtVerify,
  type FlattenedJWSInput,
  type JWSHeaderParameters,
  type KeyLike,
} from 'jose';
import { upstream } from './errors.js';
import type { KeycloakClient } from './keycloak.js';
import type { MetricsBundle } from './metrics.js';

// IMPROVEMENT_PLAN §2.3 / item #3 — verifies KC-issued tokens against the
// realm's JWKS instead of decoding payloads blindly. This is the
// belt-and-braces fix: a forged or tampered token (Redis poisoning,
// MITM with a leaked TLS cert, future refactor that loads tokens from a
// less-trusted place) gets caught by signature check.

/** Subset of KC id_token claims we read. KC always issues an id_token in
 *  the openid scope, so callers that care about identity can rely on
 *  these being present after verification. */
export interface KeycloakIdClaims {
  sub: string;
  iss: string;
  aud: string | string[];
  exp: number;
  iat: number;
  azp?: string;
  preferred_username?: string;
  email?: string;
  email_verified?: boolean;
  name?: string;
}

/** Subset of KC access_token claims we read. KC's access tokens carry
 *  realm and resource roles. */
export interface KeycloakAccessClaims {
  sub: string;
  iss: string;
  exp: number;
  iat: number;
  azp?: string;
  realm_access?: { roles?: string[] };
  resource_access?: Record<string, { roles?: string[] }>;
}

export interface KeycloakJwtVerifier {
  verifyIdToken(token: string): Promise<KeycloakIdClaims>;
  verifyAccessToken(token: string): Promise<KeycloakAccessClaims>;
}

export class KeycloakJwtVerificationError extends Error {
  constructor(
    public readonly kind: 'idtoken' | 'accesstoken',
    message: string,
    public override readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'KeycloakJwtVerificationError';
  }
}

type JwksFn = (
  protectedHeader?: JWSHeaderParameters,
  token?: FlattenedJWSInput,
) => Promise<KeyLike>;

export interface KeycloakJwtVerifierOptions {
  keycloak: KeycloakClient;
  /** Expected `iss` claim. Same as KC_ISSUER. */
  issuer: string;
  /** Expected `aud` on id_token (the BFF's KC client_id). */
  clientId: string;
  /** Test-only override. When omitted, JWKS is fetched from `disc.jwks_uri`. */
  jwks?: JwksFn;
  /** Seconds of clock skew allowed; jose's default is 0. KC and BFF should
   *  both be NTP'd, but 30s gives room for transient drift. */
  clockTolerance?: number;
  metrics?: MetricsBundle;
}

export const createKeycloakJwtVerifier = (
  opts: KeycloakJwtVerifierOptions,
): KeycloakJwtVerifier => {
  const clockTolerance = opts.clockTolerance ?? 30;

  // Lazy-init the remote JWKS function. `createRemoteJWKSet` itself is
  // cheap (it just returns a closure) but it requires a URL, which we
  // can only build after `getDiscovery()` resolves. Cache the resolved
  // function so concurrent first verifies share one fetch.
  let jwksPromise: Promise<JwksFn> | undefined;
  const getJwks = async (): Promise<JwksFn> => {
    if (opts.jwks) return opts.jwks;
    if (!jwksPromise) {
      jwksPromise = (async () => {
        const disc = await opts.keycloak.getDiscovery();
        if (!disc.jwks_uri) {
          throw upstream(
            'keycloak_jwks_unavailable',
            'OIDC discovery did not include jwks_uri',
          );
        }
        // 1s timeout matches /readyz's KC probe budget; a slow KC must
        // not stall verification indefinitely.
        return createRemoteJWKSet(new URL(disc.jwks_uri), { timeoutDuration: 1000 });
      })();
    }
    return jwksPromise;
  };

  const verify = async (
    kind: 'idtoken' | 'accesstoken',
    token: string,
    audience: string | undefined,
  ) => {
    try {
      const jwks = await getJwks();
      const { payload } = await jwtVerify(token, jwks, {
        issuer: opts.issuer,
        ...(audience ? { audience } : {}),
        algorithms: ['RS256'],
        clockTolerance,
      });
      return payload;
    } catch (err) {
      if (opts.metrics) {
        opts.metrics.authFailedTotal.inc({
          reason: kind === 'idtoken' ? 'idtoken_verify_failed' : 'accesstoken_verify_failed',
        });
      }
      throw new KeycloakJwtVerificationError(
        kind,
        err instanceof Error ? err.message : 'verification failed',
        err,
      );
    }
  };

  return {
    async verifyIdToken(token) {
      const payload = await verify('idtoken', token, opts.clientId);
      // §2.3 belt-and-braces: id_token's `azp` (authorized party) MUST be
      // the BFF's client_id when present. jose validates `aud`; this
      // tightens the contract.
      if (payload.azp && payload.azp !== opts.clientId) {
        if (opts.metrics) {
          opts.metrics.authFailedTotal.inc({ reason: 'idtoken_verify_failed' });
        }
        throw new KeycloakJwtVerificationError(
          'idtoken',
          `azp mismatch: expected ${opts.clientId}, got ${payload.azp}`,
        );
      }
      return payload as unknown as KeycloakIdClaims;
    },
    async verifyAccessToken(token) {
      // No audience check — KC access tokens don't carry a stable `aud`
      // across realm configs. Signature + iss + exp is the contract.
      const payload = await verify('accesstoken', token, undefined);
      return payload as unknown as KeycloakAccessClaims;
    },
  };
};
