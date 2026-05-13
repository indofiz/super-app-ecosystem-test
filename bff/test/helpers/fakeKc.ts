import { generateKeyPairSync } from 'node:crypto';
import {
  SignJWT,
  createLocalJWKSet,
  exportJWK,
  importPKCS8,
  importSPKI,
  type FlattenedJWSInput,
  type JWSHeaderParameters,
  type KeyLike,
} from 'jose';
import type { KeycloakJwtVerifier } from '../../src/lib/keycloakJwt.js';
import { createKeycloakJwtVerifier } from '../../src/lib/keycloakJwt.js';
import type { MetricsBundle } from '../../src/lib/metrics.js';

// Test scaffolding for §2.3 (id_token / access_token signature
// verification). Generates an RS256 keypair once at module load and
// exposes:
//   - signKcToken(payload) → real RS256 JWT signed with that key
//   - fakeKcJwks()         → JWKS function the verifier can pass to jose
//   - buildTestVerifier()  → KeycloakJwtVerifier wired to fakeKcJwks
//
// A "rogue" keypair is also exported so tests can mint a token that
// signature-verifies against a *different* key (i.e. a forgery attempt).

const KID = 'test-kc-1';
const ROGUE_KID = 'rogue-1';

const { publicKey: kcPublicPem, privateKey: kcPrivatePem } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const { privateKey: roguePrivatePem } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const kcPrivateKeyPromise = importPKCS8(kcPrivatePem, 'RS256');
const kcPublicKeyPromise = importSPKI(kcPublicPem, 'RS256', { extractable: true });
const roguePrivateKeyPromise = importPKCS8(roguePrivatePem, 'RS256');

export const KC_TEST_ISSUER = 'https://kc.example.test/realms/pangkalpinang';
export const KC_TEST_CLIENT_ID = 'super-app-bff';

export interface SignKcTokenOpts {
  issuer?: string;
  audience?: string | string[];
  expiresIn?: number; // seconds from now
  notBefore?: number; // seconds from now
  /** Sign with the rogue keypair (not in fakeKcJwks). For tampering tests. */
  withRogueKey?: boolean;
  /** Override the kid header — defaults to KID for the trusted key. */
  kid?: string;
}

export const signKcToken = async (
  payload: Record<string, unknown>,
  opts: SignKcTokenOpts = {},
): Promise<string> => {
  const key = opts.withRogueKey ? await roguePrivateKeyPromise : await kcPrivateKeyPromise;
  const jwt = new SignJWT(payload)
    .setProtectedHeader({
      alg: 'RS256',
      kid: opts.kid ?? (opts.withRogueKey ? ROGUE_KID : KID),
      typ: 'JWT',
    })
    .setIssuedAt()
    .setIssuer(opts.issuer ?? KC_TEST_ISSUER)
    .setExpirationTime(`${opts.expiresIn ?? 300}s`);
  if (opts.audience !== undefined) jwt.setAudience(opts.audience);
  if (opts.notBefore !== undefined) jwt.setNotBefore(`${opts.notBefore}s`);
  return jwt.sign(key);
};

export const signKcIdToken = async (
  sub: string,
  extras: Record<string, unknown> = {},
  opts: SignKcTokenOpts = {},
): Promise<string> =>
  signKcToken(
    {
      sub,
      preferred_username: 'andi.permana',
      email: 'andi@example.test',
      azp: KC_TEST_CLIENT_ID,
      ...extras,
    },
    { audience: KC_TEST_CLIENT_ID, ...opts },
  );

export const signKcAccessToken = async (
  sub: string,
  roles: string[],
  opts: SignKcTokenOpts = {},
): Promise<string> =>
  signKcToken(
    {
      sub,
      realm_access: { roles },
      azp: KC_TEST_CLIENT_ID,
    },
    opts,
  );

export const fakeKcJwks = async (): Promise<
  (header?: JWSHeaderParameters, token?: FlattenedJWSInput) => Promise<KeyLike>
> => {
  const key = await kcPublicKeyPromise;
  const jwk = { ...(await exportJWK(key)), alg: 'RS256', use: 'sig', kid: KID };
  return createLocalJWKSet({ keys: [jwk] });
};

export const buildTestVerifier = async (
  metrics?: MetricsBundle,
): Promise<KeycloakJwtVerifier> => {
  const jwks = await fakeKcJwks();
  return createKeycloakJwtVerifier({
    // The verifier's getDiscovery() is only consulted when `jwks` is not
    // provided. We pass a stub anyway so the type checks.
    keycloak: { getDiscovery: async () => ({ issuer: KC_TEST_ISSUER }) } as never,
    issuer: KC_TEST_ISSUER,
    clientId: KC_TEST_CLIENT_ID,
    jwks,
    metrics,
  });
};
