-- Canonical source for the `pre-function` access-phase script that
-- enforces iss/aud and injects identity headers in kong.yml.
--
-- !!! MIRROR NOTICE !!!
-- This file's content is the *single source of truth* for the inline Lua
-- in `kong/kong.yml` under `pre-function.config.access`. The kong.yml copy
-- is what Kong actually executes — pre-function plugin has no `_path` /
-- file-reference syntax in stock Kong 3.x, and the Lua sandbox blocks
-- io.open / dofile, so we cannot avoid the YAML inline.
--
-- `kong/scripts/check-lua-sync.mjs` (run on demand or in CI) fails if
-- kong.yml's inlined version drifts from this file. Edit BOTH together,
-- then re-run `node kong/scripts/check-lua-sync.mjs` to confirm.
--
-- This file is not directly executable — it depends on Kong's `kong.*`
-- and OpenResty's `ngx.*` globals that only exist inside the gateway.
--
-- ============================================================================
-- ORDERING / TRUST MODEL — read before editing
-- ============================================================================
-- Kong's bundled pre-function plugin has priority 1,000,000 — it runs BEFORE
-- every other plugin in the access phase (jwt at 1450, rate-limiting at 910).
-- A previous version of this file claimed pre-function was priority 1000 and
-- ran AFTER jwt; that was wrong, and step 4 here used to `clear_header`
-- "authorization" — which produced a 401 from the jwt plugin on every /api/*
-- request because the bearer was gone before jwt got a chance to verify it.
--
-- Current split:
--   pre-function (1,000,000, this file):
--     1. strip caller-supplied X-User-Id / X-Roles / X-Session-Id (spoof defense)
--     2. decode the JWT payload (no signature check yet) and enforce iss/aud
--     3. set X-User-Id / X-Session-Id / X-Roles from the claims, so the
--        rate-limiting plugin at priority 910 can limit per user
--   jwt (1450, bundled):
--     verifies the RS256 signature against the consumer's kid-matched public
--     key. If the signature is bad — even if iss/aud passed pre-function and
--     X-* headers were already injected — jwt returns 401 and Kong NEVER
--     proxies upstream. So a forged token cannot exfiltrate spoofed identity
--     to the service; the X-* headers only reach upstream after jwt accepted.
--   rate-limiting (910): reads X-User-Id we just set.
--   post-function (-1000, separate plugin in kong.yml):
--     clears the Authorization header so the raw bearer does not reach
--     upstream (AUDIT S-3). Cannot be done here — clearing it before jwt
--     causes the 401 described above.
--
-- Editing this file: changes to step 1/2/3 belong here. The bearer-stripping
-- (formerly step 4) lives in kong.yml's `post-function` plugin block; do not
-- re-introduce a `clear_header("authorization")` call in this file.
--
-- @canonical-body-start  -- everything below this line must equal the
-- inlined Lua in kong.yml under pre-function.config.access. The drift
-- detector keys off this sentinel; do not remove it.

-- step 1: strip caller-supplied identity headers
kong.service.request.clear_header("X-User-Id")
kong.service.request.clear_header("X-Roles")
kong.service.request.clear_header("X-Session-Id")

local auth = kong.request.get_header("authorization")
if not auth then return end
local token = string.match(auth, "^[Bb]earer%s+(.+)$")
if not token then return end

-- Pull the payload out of the JWT. We decode WITHOUT verifying the signature
-- here: jwt plugin (priority 1450) runs after us and rejects the request if
-- the signature is bad, so any X-* headers we set on a forged token never
-- reach upstream (Kong 401s before proxying). We need to set X-User-Id
-- before priority 910 so rate-limiting can limit per user — that is the
-- whole reason this work is in pre-function and not post-function.
--
-- AUDIT S-9: all three captures use `+` (one-or-more) rather than the
-- previous permissive `*` (zero-or-more) on the signature segment. Belt-
-- and-braces: stops a malformed-but-decodable token from sliding through.
local _, payload_b64 = string.match(token, "([^%.]+)%.([^%.]+)%.([^%.]+)")
if not payload_b64 then return end
local p = payload_b64:gsub("-", "+"):gsub("_", "/")
local pad = #p % 4
if pad > 0 then p = p .. string.rep("=", 4 - pad) end
local raw = ngx.decode_base64(p)
if not raw then return end

local cjson = require "cjson.safe"
local claims = cjson.decode(raw)
if type(claims) ~= "table" then return end

-- step 2: enforce iss/aud (AUDIT S-1).
-- Hardcoded to match BFF_INTERNAL_JWT_ISSUER / _AUDIENCE defaults in
-- .env.example. The PEM moved to env-vault under AUDIT S-5; these two
-- strings could follow the same pattern but the Lua sandbox blocks
-- `os.getenv` directly so it would mean either extending
-- KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES or threading them through Kong's
-- vault API. Deferred — iss/aud change far less often than keys.
local expected_iss = "super-app-bff"
local expected_aud = "super-app-services"
if claims.iss ~= expected_iss then
  return kong.response.exit(401, { message = "invalid issuer" })
end
local aud_ok = false
if type(claims.aud) == "string" then
  aud_ok = claims.aud == expected_aud
elseif type(claims.aud) == "table" then
  for _, a in ipairs(claims.aud) do
    if a == expected_aud then aud_ok = true; break end
  end
end
if not aud_ok then
  return kong.response.exit(401, { message = "invalid audience" })
end

-- step 3: re-set headers from claims. jwt plugin verifies signature after
-- us; if verification fails, Kong 401s before proxying so these never
-- reach the upstream service.
if claims.sub then
  kong.service.request.set_header("X-User-Id", tostring(claims.sub))
end
if claims.sid then
  kong.service.request.set_header("X-Session-Id", tostring(claims.sid))
end
if type(claims.roles) == "table" then
  local r = {}
  for i, v in ipairs(claims.roles) do
    r[i] = tostring(v)
  end
  if #r > 0 then
    kong.service.request.set_header("X-Roles", table.concat(r, ","))
  end
end

-- NOTE: Authorization-header stripping lives in the `post-function` plugin
-- in kong.yml (priority -1000), which runs after jwt has verified the
-- signature. Do not add `kong.service.request.clear_header("authorization")`
-- here — doing so causes jwt to see no bearer and 401 every request.
