#!/usr/bin/env node
// AUDIT M-5: offline validation of kong.yml against the Kong 3.8 schema.
//
// Catches syntax / schema errors at edit time instead of at container start
// (which today silently leaves Kong serving an empty config when the YAML
// fails to parse). Run on demand or in CI:
//
//   node kong/scripts/validate.mjs
//
// Requires Docker (or Podman with `docker` alias). Pulls the same Kong image
// docker-compose uses, then runs `kong config parse` against a read-only
// mount of the YAML file. Exits with the underlying docker run exit code.

import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const kongDir = join(repoRoot, 'kong');
const KONG_IMAGE = 'kong:3.8.0-ubuntu'; // keep in sync with docker-compose.yml

console.log(`validate: parsing ${join(kongDir, 'kong.yml')} against ${KONG_IMAGE}`);

const result = spawnSync(
  'docker',
  [
    'run',
    '--rm',
    '-v',
    `${kongDir}:/k:ro`,
    KONG_IMAGE,
    'kong',
    'config',
    'parse',
    '/k/kong.yml',
  ],
  { stdio: 'inherit' },
);

if (result.error) {
  console.error(`validate: failed to invoke docker — ${result.error.message}`);
  console.error('validate: is Docker running? (the parse needs the Kong image)');
  process.exit(127);
}

process.exit(result.status ?? 1);
