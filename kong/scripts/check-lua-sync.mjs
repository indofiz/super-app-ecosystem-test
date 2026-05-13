#!/usr/bin/env node
// AUDIT M-2 drift gate.
//
// The pre-function identity-injection script exists in two places:
//   - kong/lua/identity_inject.lua  (canonical source, reviewable as code)
//   - kong/kong.yml                 (inlined under pre-function.config.access;
//                                    what Kong actually executes)
//
// Kong 3.x's bundled pre-function plugin has no file-reference syntax and the
// Lua sandbox blocks io.open/dofile, so duplication is unavoidable. This
// script catches drift between the two. Run on demand or in CI.
//
// Exits 0 if in sync, 1 with a diff-style summary if not.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const canonicalPath = join(repoRoot, 'kong', 'lua', 'identity_inject.lua');
const kongYmlPath = join(repoRoot, 'kong', 'kong.yml');

const canonicalRaw = readFileSync(canonicalPath, 'utf8');
const kongYmlRaw = readFileSync(kongYmlPath, 'utf8');

// Strip the canonical file's leading header — the comment block explaining
// the mirror arrangement is *not* duplicated into kong.yml. The sentinel
// `-- @canonical-body-start` marks the boundary; we skip the sentinel itself
// and any continuation comment lines that describe it, then consume the one
// blank line that separates the sentinel block from the body. Everything
// after that blank line is the body — even if it starts with a `-- step 1:`
// comment, since comments inside the body are part of what gets inlined.
const SENTINEL = '-- @canonical-body-start';
const stripCanonicalHeader = (src) => {
  const lines = src.split(/\r?\n/);
  const idx = lines.findIndex((l) => l.startsWith(SENTINEL));
  if (idx < 0) {
    throw new Error(
      `kong/lua/identity_inject.lua: missing sentinel "${SENTINEL}" — cannot locate body start`,
    );
  }
  // Walk forward past the sentinel + its description comments until the first
  // blank line; the body begins on the line immediately after that.
  let i = idx;
  while (i < lines.length && lines[i].trim() !== '') i++;
  // i is now on the blank line (or past end). Body starts at i + 1.
  return lines.slice(i + 1).join('\n').trimEnd();
};

// Extract the inlined Lua from kong.yml. We look for the line
// `- name: pre-function` and then the `access:` block-scalar following it.
// YAML `|` preserves newlines and trims trailing blank lines; we just need
// to dedent uniformly.
const extractInlineLua = (yaml) => {
  const lines = yaml.split(/\r?\n/);

  const preFnIdx = lines.findIndex((l) => /^\s*-\s*name:\s*pre-function\s*$/.test(l));
  if (preFnIdx < 0) {
    throw new Error('kong.yml: could not find `- name: pre-function` entry');
  }

  // Find `access:` after pre-function, then the `- |` marker that opens the
  // block scalar, then collect indented continuation lines.
  let i = preFnIdx + 1;
  while (i < lines.length && !/^\s*access:\s*$/.test(lines[i])) i++;
  if (i >= lines.length) {
    throw new Error('kong.yml: pre-function has no `access:` key');
  }
  // Next non-blank line should be `<indent>- |`
  i++;
  while (i < lines.length && lines[i].trim() === '') i++;
  const blockOpener = lines[i];
  const openerMatch = blockOpener && blockOpener.match(/^(\s+)-\s*\|\s*$/);
  if (!openerMatch) {
    throw new Error(
      `kong.yml: expected \`- |\` opener after access:, got ${JSON.stringify(blockOpener)}`,
    );
  }
  // YAML block-scalar content is indented MORE than the `-` marker. We grab
  // every following line whose indent is strictly greater than the opener's,
  // stopping at the first line that is non-blank and dedented to/under the
  // opener.
  const openerIndent = openerMatch[1].length;
  const contentIndentSentinel = openerIndent + 1;
  const content = [];
  i++;
  for (; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '') {
      content.push(line);
      continue;
    }
    const leading = line.match(/^(\s*)/)[1].length;
    if (leading < contentIndentSentinel) break;
    content.push(line);
  }

  // Determine the common indent across non-blank lines and strip it.
  const commonIndent = content
    .filter((l) => l.trim() !== '')
    .reduce((min, l) => Math.min(min, l.match(/^(\s*)/)[1].length), Infinity);
  return content
    .map((l) => (l.trim() === '' ? '' : l.slice(commonIndent)))
    .join('\n')
    .trimEnd();
};

const canonicalBody = stripCanonicalHeader(canonicalRaw);
const inlineBody = extractInlineLua(kongYmlRaw);

if (canonicalBody === inlineBody) {
  console.log('check-lua-sync: kong.yml inline Lua matches kong/lua/identity_inject.lua');
  process.exit(0);
}

// Print a minimal diff: line-by-line, first divergence wins.
const a = canonicalBody.split('\n');
const b = inlineBody.split('\n');
const limit = Math.max(a.length, b.length);
let firstDiff = -1;
for (let i = 0; i < limit; i++) {
  if (a[i] !== b[i]) {
    firstDiff = i;
    break;
  }
}

console.error('check-lua-sync: DRIFT detected between kong/lua/identity_inject.lua and kong/kong.yml');
console.error(`  canonical lines : ${a.length}`);
console.error(`  inlined  lines  : ${b.length}`);
if (firstDiff >= 0) {
  const ctx = (arr, idx) => arr[idx] === undefined ? '<missing>' : arr[idx];
  console.error(`  first diverging line: ${firstDiff + 1}`);
  console.error(`    canonical: ${JSON.stringify(ctx(a, firstDiff))}`);
  console.error(`    inlined  : ${JSON.stringify(ctx(b, firstDiff))}`);
}
console.error('');
console.error('Edit both files together, then re-run this script.');
process.exit(1);
