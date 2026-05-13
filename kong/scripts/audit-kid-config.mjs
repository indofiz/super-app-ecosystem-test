#!/usr/bin/env node
// AUDIT PR-1 (partial): rotation pre-flight checker.
//
// During a key rotation the same kid must appear consistently in THREE
// places. The most common rotation failure mode is forgetting one of them
// — e.g., adding a new kid to kong.yml but not to docker-compose.yml's
// env block, which leaves Kong unable to resolve the new PEM at boot.
// This script reads all three sources and reports any mismatch.
//
// Run on demand:
//   node kong/scripts/audit-kid-config.mjs
//
// Exits 0 if every kid declared in any source is present in every other
// source that should know about it. Exits 1 with a per-kid breakdown
// otherwise. Does not require Docker.
//
// Sources checked:
//   - kong/kong.yml          → `jwt_secrets[].key`, and the env-vault
//                              reference name inside `rsa_public_key`
//   - docker-compose.yml     → `INTERNAL_JWT_PUBKEY_*` env vars under kong
//   - .env / bff/.env        → BFF_INTERNAL_JWT_ACTIVE_KID,
//                              BFF_INTERNAL_JWT_PUBLIC_KEYS (JSON of kids)

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');

const read = (relPath) => {
  const p = join(repoRoot, relPath);
  return existsSync(p) ? readFileSync(p, 'utf8') : null;
};

// --- parsers ----------------------------------------------------------------

// Pull `- key: <kid>` lines from kong.yml's jwt_secrets block, plus the
// matching env-vault reference target on each entry.
const parseKongYml = (src) => {
  const out = []; // { kid, vaultEnvKey | null }
  const lines = src.split(/\r?\n/);
  let inSecrets = false;
  let current = null;
  for (const line of lines) {
    if (/^\s*jwt_secrets:\s*$/.test(line)) {
      inSecrets = true;
      continue;
    }
    if (!inSecrets) continue;
    // Exit the block when we hit a line dedented to root.
    if (line && !line.startsWith(' ') && line.trim() !== '') {
      if (current) out.push(current);
      current = null;
      inSecrets = false;
      continue;
    }
    const keyMatch = line.match(/^\s*-\s*key:\s*(\S+)\s*$/);
    if (keyMatch) {
      if (current) out.push(current);
      current = { kid: keyMatch[1], vaultEnvKey: null };
      continue;
    }
    // Look for the env-vault reference shape:
    //   rsa_public_key: "{vault://env/<key-name>}"
    const vaultMatch = line.match(/rsa_public_key:\s*["']?\{vault:\/\/env\/([a-zA-Z0-9_-]+)\}["']?/);
    if (vaultMatch && current) {
      // Kong env vault converts dashes to underscores and uppercases.
      current.vaultEnvKey = vaultMatch[1].replace(/-/g, '_').toUpperCase();
    }
  }
  if (current) out.push(current);
  return out;
};

// Pull `INTERNAL_JWT_PUBKEY_*: |` env-var declarations from docker-compose.yml.
// We only care about which keys are declared, not their PEM values.
const parseDockerComposeEnv = (src) => {
  const out = new Set();
  for (const line of src.split(/\r?\n/)) {
    const m = line.match(/^\s+(INTERNAL_JWT_PUBKEY_[A-Z0-9_]+):/);
    if (m) out.add(m[1]);
  }
  return out;
};

// Extract BFF kid config from a dotenv file.
const parseBffEnv = (src) => {
  const out = { activeKid: null, publicKids: [] };
  for (const line of src.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.startsWith('#') || trimmed === '') continue;
    const activeMatch = trimmed.match(/^BFF_INTERNAL_JWT_ACTIVE_KID=(.+)$/);
    if (activeMatch) {
      out.activeKid = activeMatch[1].trim();
      continue;
    }
    const publicMatch = trimmed.match(/^BFF_INTERNAL_JWT_PUBLIC_KEYS=(.+)$/);
    if (publicMatch) {
      try {
        const parsed = JSON.parse(publicMatch[1]);
        if (Array.isArray(parsed)) out.publicKids = parsed.map((e) => e.kid);
      } catch {
        // ignored; we'll report it as a finding
        out.publicKidsParseError = true;
      }
    }
  }
  return out;
};

// --- main -------------------------------------------------------------------

const kongYml = read('kong/kong.yml');
const dockerCompose = read('docker-compose.yml');
const workspaceEnv = read('.env');
const bffEnv = read('bff/.env');

if (!kongYml || !dockerCompose) {
  console.error('audit-kid-config: missing kong/kong.yml or docker-compose.yml at repo root');
  process.exit(2);
}

const kongKids = parseKongYml(kongYml);
const composeEnvKeys = parseDockerComposeEnv(dockerCompose);
const wsBff = workspaceEnv ? parseBffEnv(workspaceEnv) : null;
const localBff = bffEnv ? parseBffEnv(bffEnv) : null;

const findings = [];

if (kongKids.length === 0) {
  findings.push('kong.yml: no jwt_secrets entries found — gateway will 401 every request');
}

// Each kong.yml kid that references a vault env must have a matching env var
// declared in docker-compose.yml.
for (const { kid, vaultEnvKey } of kongKids) {
  if (vaultEnvKey && !composeEnvKeys.has(vaultEnvKey)) {
    findings.push(
      `kong.yml kid "${kid}" references vault env "${vaultEnvKey}", but docker-compose.yml has no matching env var on the kong service`,
    );
  }
}

// Each docker-compose env var that looks like a kid PEM should correspond
// to a kid in kong.yml.
const referencedComposeKeys = new Set(
  kongKids.filter((k) => k.vaultEnvKey).map((k) => k.vaultEnvKey),
);
for (const key of composeEnvKeys) {
  if (!referencedComposeKeys.has(key)) {
    findings.push(
      `docker-compose.yml declares ${key} but no kong.yml jwt_secrets entry references it — dead key material`,
    );
  }
}

// BFF env: active kid must be in publicKids; both must overlap with kong.yml's kids.
const kongKidSet = new Set(kongKids.map((k) => k.kid));
const checkBff = (label, bff) => {
  if (!bff) return;
  if (bff.publicKidsParseError) {
    findings.push(`${label}: BFF_INTERNAL_JWT_PUBLIC_KEYS is not valid JSON`);
    return;
  }
  if (bff.activeKid && !bff.publicKids.includes(bff.activeKid)) {
    findings.push(
      `${label}: BFF_INTERNAL_JWT_ACTIVE_KID="${bff.activeKid}" is not in BFF_INTERNAL_JWT_PUBLIC_KEYS (${bff.publicKids.join(', ') || 'empty'})`,
    );
  }
  if (bff.activeKid && !kongKidSet.has(bff.activeKid)) {
    findings.push(
      `${label}: BFF will mint with kid="${bff.activeKid}" but Kong has no jwt_secrets entry for it — every API request will 401`,
    );
  }
  for (const kid of bff.publicKids) {
    if (!kongKidSet.has(kid)) {
      findings.push(
        `${label}: BFF accepts kid="${kid}" but Kong does not — rotation overlap broken in one direction`,
      );
    }
  }
};
checkBff('workspace .env', wsBff);
checkBff('bff/.env', localBff);

// --- report -----------------------------------------------------------------

console.log('audit-kid-config: state summary');
console.log(`  kong.yml kids        : ${kongKids.map((k) => `${k.kid} → ${k.vaultEnvKey ?? '(inline pem)'}`).join(', ') || '(none)'}`);
console.log(`  docker-compose env   : ${[...composeEnvKeys].join(', ') || '(none)'}`);
if (wsBff) {
  console.log(`  workspace .env       : active=${wsBff.activeKid ?? '?'}, public=[${wsBff.publicKids.join(', ')}]`);
}
if (localBff) {
  console.log(`  bff/.env             : active=${localBff.activeKid ?? '?'}, public=[${localBff.publicKids.join(', ')}]`);
}

if (findings.length === 0) {
  console.log('audit-kid-config: OK — all sources agree');
  process.exit(0);
}

console.error('');
console.error(`audit-kid-config: ${findings.length} finding(s)`);
for (const f of findings) console.error(`  - ${f}`);
process.exit(1);
