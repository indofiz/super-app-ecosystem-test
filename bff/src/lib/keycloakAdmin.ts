import http from 'node:http';
import https from 'node:https';
import axios, { type AxiosInstance } from 'axios';
import { z } from 'zod';
import { upstream } from './errors.js';
import type { KeycloakClient } from './keycloak.js';
import type { Logger } from './logger.js';

/**
 * Minimal Keycloak Admin REST client for the verification handlers.
 *
 * Uses the `super-app-bff` confidential client's service account
 * (`serviceAccountsEnabled=true` in the realm export) to mint an admin
 * access_token via the client-credentials grant, then calls
 * `PUT /admin/realms/{realm}/users/{id}` to flip `emailVerified` or the
 * `phoneNumber` / `phoneNumberVerified` attributes.
 *
 * The service account must hold the realm roles `manage-users` and
 * `view-users` from the `realm-management` client. See Phase 0.1 in the
 * verification plan.
 *
 * Token caching: we cache the admin access_token in memory until
 * `exp - 30s` so a burst of OTP verifies doesn't hammer KC's token
 * endpoint.
 */
export interface KeycloakAdminClient {
  setEmailVerified(sub: string): Promise<void>;
  setPhoneVerified(sub: string, phone: string): Promise<void>;
}

const TokenResponseZ = z.object({
  access_token: z.string().min(1),
  expires_in: z.number().int().nonnegative(),
  token_type: z.string().min(1),
});

const HTTP_TIMEOUT_MS = 10_000;
const MAX_BODY = 64 * 1024;
const TOKEN_REFRESH_SKEW_S = 30;

interface AdminOpts {
  keycloak: KeycloakClient;
  /** Realm name. Parsed from KC_ISSUER (last path segment). */
  realm: string;
  /** Admin REST base, e.g. `https://sso.example.id`. Parsed from KC_ISSUER. */
  baseUrl: string;
  /** Client id / secret of a confidential client with `manage-users`. */
  clientId: string;
  clientSecret: string;
  log: Logger;
  http?: AxiosInstance;
}

interface CachedToken {
  token: string;
  expiresAt: number; // epoch seconds
}

export const buildKeycloakAdmin = (opts: AdminOpts): KeycloakAdminClient => {
  const client =
    opts.http ??
    axios.create({
      timeout: HTTP_TIMEOUT_MS,
      maxContentLength: MAX_BODY,
      maxBodyLength: MAX_BODY,
      headers: { Accept: 'application/json' },
      httpAgent: new http.Agent({ keepAlive: true, maxSockets: 25 }),
      httpsAgent: new https.Agent({ keepAlive: true, maxSockets: 25 }),
    });

  let cached: CachedToken | undefined;
  let inflight: Promise<string> | undefined;

  const fetchToken = async (): Promise<string> => {
    const disc = await opts.keycloak.getDiscovery();
    const body = new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: opts.clientId,
      client_secret: opts.clientSecret,
    });
    try {
      const res = await client.post<unknown>(disc.token_endpoint, body, {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      });
      const parsed = TokenResponseZ.safeParse(res.data);
      if (!parsed.success) {
        throw upstream(
          'keycloak_admin_token_invalid',
          'Admin token response failed schema check',
          parsed.error,
        );
      }
      cached = {
        token: parsed.data.access_token,
        expiresAt: Math.floor(Date.now() / 1000) + parsed.data.expires_in,
      };
      return parsed.data.access_token;
    } catch (err) {
      throw upstream(
        'keycloak_admin_token_failed',
        'Admin token request to Keycloak failed',
        err instanceof Error ? err.message : err,
      );
    }
  };

  const getToken = async (): Promise<string> => {
    const now = Math.floor(Date.now() / 1000);
    if (cached && cached.expiresAt - TOKEN_REFRESH_SKEW_S > now) return cached.token;
    // De-dupe concurrent first-callers / refreshes so we never fire two
    // token requests in parallel.
    if (!inflight) {
      inflight = fetchToken().finally(() => {
        inflight = undefined;
      });
    }
    return inflight;
  };

  const usersBase = `${opts.baseUrl.replace(/\/$/, '')}/admin/realms/${encodeURIComponent(opts.realm)}/users`;

  const putUser = async (sub: string, payload: Record<string, unknown>): Promise<void> => {
    // Two-shot: if a token expired between cache-check and the call, KC
    // returns 401 → invalidate cache and retry once with a fresh token.
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await getToken();
      try {
        await client.put(`${usersBase}/${encodeURIComponent(sub)}`, payload, {
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
        });
        return;
      } catch (err) {
        if (axios.isAxiosError(err) && err.response?.status === 401 && attempt === 0) {
          cached = undefined;
          continue;
        }
        const detail =
          axios.isAxiosError(err) && err.response?.data
            ? typeof err.response.data === 'object'
              ? JSON.stringify(err.response.data)
              : String(err.response.data)
            : err instanceof Error
              ? err.message
              : String(err);
        throw upstream(
          'keycloak_admin_put_failed',
          `Admin PUT /users/${sub.substring(0, 8)}… failed: ${detail}`,
          err,
        );
      }
    }
  };

  /**
   * KC's user representation requires merging attributes carefully —
   * a bare PUT with `{attributes:{phoneNumber:[...]}}` overwrites the
   * whole attribute map (including `nik`). We GET the user first, merge
   * locally, then PUT the full representation.
   */
  const mergeAttributes = async (
    sub: string,
    update: Record<string, string[]>,
  ): Promise<void> => {
    const token = await getToken();
    let current: { attributes?: Record<string, string[]> } & Record<string, unknown> = {};
    try {
      const res = await client.get<Record<string, unknown>>(
        `${usersBase}/${encodeURIComponent(sub)}`,
        { headers: { Authorization: `Bearer ${token}` } },
      );
      current = res.data ?? {};
    } catch (err) {
      throw upstream(
        'keycloak_admin_get_failed',
        `Admin GET /users/${sub.substring(0, 8)}… failed`,
        err instanceof Error ? err.message : err,
      );
    }
    const mergedAttributes = { ...(current.attributes ?? {}), ...update };
    await putUser(sub, { ...current, attributes: mergedAttributes });
  };

  return {
    async setEmailVerified(sub: string): Promise<void> {
      // emailVerified is a top-level field on UserRepresentation, not an
      // attribute. We still GET-then-PUT to avoid clobbering other fields.
      const token = await getToken();
      let current: Record<string, unknown> = {};
      try {
        const res = await client.get<Record<string, unknown>>(
          `${usersBase}/${encodeURIComponent(sub)}`,
          { headers: { Authorization: `Bearer ${token}` } },
        );
        current = res.data ?? {};
      } catch (err) {
        throw upstream(
          'keycloak_admin_get_failed',
          `Admin GET /users/${sub.substring(0, 8)}… failed`,
          err instanceof Error ? err.message : err,
        );
      }
      await putUser(sub, { ...current, emailVerified: true });
    },

    async setPhoneVerified(sub: string, phone: string): Promise<void> {
      await mergeAttributes(sub, {
        phoneNumber: [phone],
        phoneNumberVerified: ['true'],
      });
    },
  };
};

/** Derive the realm name and admin base URL from KC_ISSUER. KC issuers
 *  always have the shape `<base>/realms/<realm>`. */
export const parseRealmFromIssuer = (issuer: string): { realm: string; baseUrl: string } => {
  const url = new URL(issuer);
  const m = url.pathname.match(/^\/realms\/([^/]+)\/?$/);
  if (!m) {
    throw new Error(
      `Cannot derive realm from KC_ISSUER="${issuer}" (expected ".../realms/<name>")`,
    );
  }
  return {
    realm: decodeURIComponent(m[1]!),
    baseUrl: `${url.origin}`,
  };
};
