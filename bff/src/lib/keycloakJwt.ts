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
  // Present when the `phone` scope is granted to the client. Sourced from
  // the `phoneNumber` / `phoneNumberVerified` user attributes by KC's
  // built-in phone scope.
  phone_number?: string;
  phone_number_verified?: boolean;
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
  email?: string;
  email_verified?: boolean;
  phone_number?: string;
  phone_number_verified?: boolean;
}

export interface KeycloakLogoutTokenClaims {
  sub?: string;
  sid?: string;
  iss: string;
  aud: string | string[];
  iat: number;
  jti?: string;
  events?: Record<string, unknown>;
  nonce?: string;
}

export interface KeycloakJwtVerifier {
  verifyIdToken(token: string): Promise<KeycloakIdClaims>;
  verifyAccessToken(token: string): Promise<KeycloakAccessClaims>;
  verifyLogoutToken(token: string): Promise<KeycloakLogoutTokenClaims>;
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
      // AUDIT S-4: if jose couldn't resolve the kid against the cached
      // JWKS, KC may have rotated keys. Invalidate the cached discovery
      // (and therefore the JWKS function on next call) and surface the
      // failure to the caller. We do NOT auto-retry — that would mask
      // genuine forgeries.
      const msg = err instanceof Error ? err.message : String(err);
      if (/no applicable key|kid|"JWKSNoMatchingKey"|JOSEAlgNotAllowed/i.test(msg)) {
        // Safe-call: test stubs may not implement invalidateDiscovery.
        (opts.keycloak as { invalidateDiscovery?: () => void }).invalidateDiscovery?.();
        jwksPromise = undefined;
      }
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
    async verifyIdToken(token: string) {
      const payload = await verify('idtoken', token, opts.clientId);
      // §2.3 belt-and-braces: id_token's `azp` (authorized party) MUST be
      // the BFF's client_id when present. jose validates `aud`; this
      // tightens the contract.
      const azp = typeof payload.azp === 'string' ? payload.azp : undefined;
      if (azp && azp !== opts.clientId) {
        if (opts.metrics) {
          opts.metrics.authFailedTotal.inc({ reason: 'idtoken_verify_failed' });
        }
        throw new KeycloakJwtVerificationError(
          'idtoken',
          `azp mismatch: expected ${opts.clientId}, got ${azp}`,
        );
      }
      return payload as unknown as KeycloakIdClaims;
    },
    async verifyAccessToken(token: string) {
      // No audience check — KC access tokens don't carry a stable `aud`
      // across realm configs. Signature + iss + exp is the contract.
      const payload = await verify('accesstoken', token, undefined);
      return payload as unknown as KeycloakAccessClaims;
    },
    async verifyLogoutToken(token: string) {
      // AUDIT S-5: back-channel logout tokens follow the OIDC spec —
      // same JWKS as id_tokens but with `events` and no `nonce`.
      const payload = (await verify('idtoken', token, opts.clientId)) as Record<string, unknown>;
      return payload as unknown as KeycloakLogoutTokenClaims;
    },
  };
};

/** Shape of the user-profile snapshot the BFF stores in Redis. Kept in
 *  sync with `SessionProfile` in `auth/stores/session.store.ts`. */
export interface VerifiedProfile {
  username?: string;
  email?: string;
  emailVerified: boolean;
  phoneNumber?: string;
  phoneNumberVerified: boolean;
  roles: string[];
}

/**
 * Verify upstream tokens and project them into a profile snapshot.
 *
 * Used by /auth/callback (fresh from KC), /auth/refresh (fresh from KC),
 * and /auth/token (loaded from `bffcode:*` Redis records).
 *
 * The verifier guarantees:
 *   - signature against KC's JWKS
 *   - issuer = KC_ISSUER
 *   - id_token aud = KC_CLIENT_ID
 *   - exp not past (with clockTolerance)
 *
 * AUDIT M-1 — moved here from `auth/handlers/token.ts` so callers
 * (`token.ts`, `refresh.ts`, …) depend on the same library symbol instead
 * of importing across the handler layer.
 */
export const verifyAndExtractProfile = async (
  verifier: KeycloakJwtVerifier,
  accessToken: string | undefined,
  idToken: string | undefined,
  fallbackSub: string,
): Promise<{ sub: string; profile: VerifiedProfile }> => {
  const idClaims = idToken ? await verifier.verifyIdToken(idToken) : null;
  const acClaims = accessToken ? await verifier.verifyAccessToken(accessToken) : null;
  const sub = idClaims?.sub ?? acClaims?.sub ?? fallbackSub;
  // Prefer the access_token for verification flags — KC writes the
  // freshest user-attribute view there. id_token is the fallback if the
  // `phone` scope wasn't granted on the AC.
  const emailVerified =
    acClaims?.email_verified ?? idClaims?.email_verified ?? false;
  const phoneNumber = acClaims?.phone_number ?? idClaims?.phone_number;
  const phoneNumberVerified =
    acClaims?.phone_number_verified ?? idClaims?.phone_number_verified ?? false;
  return {
    sub,
    profile: {
      username: idClaims?.preferred_username,
      email: idClaims?.email ?? acClaims?.email,
      emailVerified,
      phoneNumber,
      phoneNumberVerified,
      roles: acClaims?.realm_access?.roles ?? [],
    },
  };
};
