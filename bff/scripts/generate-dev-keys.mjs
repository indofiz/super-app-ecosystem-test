#!/usr/bin/env node
// Generates an RSA-2048 keypair under bff/keys/ and prints the env-file
// fragment + the public PEM to paste into kong/kong.yml.
// Dev only. Production keys belong in a real secret manager.

import { generateKeyPairSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const keysDir = join(here, '..', 'keys');
// kid defaults to `dev-v1` — the `dev-` prefix is a tripwire so this key
// can never be mistaken for a prod credential. Override on the CLI when
// rotating: `npm run gen:keys dev-v2`.
const kid = process.argv[2] ?? 'dev-v1';

mkdirSync(keysDir, { recursive: true });

const { publicKey, privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

writeFileSync(join(keysDir, `internal-jwt-${kid}.private.pem`), privateKey);
writeFileSync(join(keysDir, `internal-jwt-${kid}.public.pem`), publicKey);

const b64priv = Buffer.from(privateKey).toString('base64');
const b64pub = Buffer.from(publicKey).toString('base64');
const publicKeysJson = JSON.stringify([{ kid, pem: b64pub }]);

process.stdout.write(`Generated kid="${kid}" — wrote PEMs to bff/keys/

# Paste into bff/.env (and the workspace .env):
BFF_INTERNAL_JWT_ALG=RS256
BFF_INTERNAL_JWT_ACTIVE_KID=${kid}
BFF_INTERNAL_JWT_PRIVATE_KEY=${b64priv}
BFF_INTERNAL_JWT_PUBLIC_KEYS=${publicKeysJson}

# Paste this PEM into kong/kong.yml under jwt_secrets[].rsa_public_key (kid="${kid}"):
${publicKey}`);
