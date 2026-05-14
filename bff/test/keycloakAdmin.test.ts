import type { AxiosInstance } from 'axios';
import pino from 'pino';
import { describe, expect, it } from 'vitest';
import { buildKeycloakAdmin, parseRealmFromIssuer } from '../src/lib/keycloakAdmin.js';
import type { KeycloakClient } from '../src/lib/keycloak.js';

const silentLog = pino({ level: 'silent' });

const fakeKeycloak: KeycloakClient = {
  getDiscovery: async () => ({
    issuer: 'https://kc.example.test/realms/pangkalpinang',
    authorization_endpoint: 'https://kc.example.test/auth',
    token_endpoint: 'https://kc.example.test/token',
  }),
} as unknown as KeycloakClient;

interface RecordedCall {
  method: 'GET' | 'POST' | 'PUT';
  url: string;
  data?: unknown;
  headers: Record<string, string>;
}

/**
 * Axios stub that drives the admin client through a scripted sequence
 * of responses keyed by `${method} ${url}`. Each call is recorded.
 */
const stubAxios = (
  routes: Record<string, () => { status: number; data?: unknown }>,
): { http: AxiosInstance; calls: RecordedCall[] } => {
  const calls: RecordedCall[] = [];
  const route = (
    method: 'GET' | 'POST' | 'PUT',
    url: string,
    data: unknown,
    opts: { headers?: Record<string, string> } | undefined,
  ) => {
    const key = `${method} ${url}`;
    const handler = routes[key];
    calls.push({ method, url, data, headers: opts?.headers ?? {} });
    if (!handler) {
      const err = new Error(`No stub route for ${key}`);
      Object.assign(err, {
        isAxiosError: true,
        response: { status: 404, data: { error: 'not_found', key } },
      });
      throw err;
    }
    const res = handler();
    if (res.status >= 200 && res.status < 300) {
      return { status: res.status, data: res.data };
    }
    const err = new Error(`Request failed with status code ${res.status}`);
    Object.assign(err, {
      isAxiosError: true,
      response: { status: res.status, data: res.data },
    });
    throw err;
  };
  const http = {
    get: async (url: string, opts?: { headers?: Record<string, string> }) =>
      route('GET', url, undefined, opts),
    post: async (
      url: string,
      data: unknown,
      opts?: { headers?: Record<string, string> },
    ) => route('POST', url, data, opts),
    put: async (
      url: string,
      data: unknown,
      opts?: { headers?: Record<string, string> },
    ) => route('PUT', url, data, opts),
  } as unknown as AxiosInstance;
  return { http, calls };
};

describe('parseRealmFromIssuer', () => {
  it('extracts realm + baseUrl from a valid KC issuer', () => {
    const r = parseRealmFromIssuer('https://sso.example.test/realms/pangkalpinang');
    expect(r.realm).toBe('pangkalpinang');
    expect(r.baseUrl).toBe('https://sso.example.test');
  });

  it('throws on a non-KC-shaped URL', () => {
    expect(() => parseRealmFromIssuer('https://example.com/oauth')).toThrow(
      /Cannot derive realm/,
    );
  });
});

describe('KeycloakAdminClient', () => {
  it('setEmailVerified: client_credentials → GET user → PUT user.emailVerified', async () => {
    const { http, calls } = stubAxios({
      'POST https://kc.example.test/token': () => ({
        status: 200,
        data: {
          access_token: 'admin-tk-1',
          expires_in: 60,
          token_type: 'Bearer',
        },
      }),
      'GET https://kc.example.test/admin/realms/pangkalpinang/users/user-1': () => ({
        status: 200,
        data: {
          id: 'user-1',
          email: 'andi@example.test',
          emailVerified: false,
          attributes: { nik: ['1971010101010001'] },
        },
      }),
      'PUT https://kc.example.test/admin/realms/pangkalpinang/users/user-1': () => ({
        status: 204,
      }),
    });
    const admin = buildKeycloakAdmin({
      keycloak: fakeKeycloak,
      realm: 'pangkalpinang',
      baseUrl: 'https://kc.example.test',
      clientId: 'super-app-bff',
      clientSecret: 'shh',
      log: silentLog,
      http,
    });

    const verifiedAt = '2026-05-14T12:34:56.000Z';
    await admin.setEmailVerified('user-1', verifiedAt);

    // 3 calls: token grant + GET user + PUT user
    expect(calls).toHaveLength(3);
    const put = calls[2]!;
    expect(put.method).toBe('PUT');
    // Existing fields preserved + emailVerified flipped + timestamp merged
    // into attributes without clobbering nik.
    const body = put.data as { attributes: Record<string, string[]> } & Record<string, unknown>;
    expect(body.emailVerified).toBe(true);
    expect(body.email).toBe('andi@example.test');
    expect(body.attributes.nik).toEqual(['1971010101010001']);
    expect(body.attributes.emailVerifiedAt).toEqual([verifiedAt]);
    expect(put.headers['Authorization']).toBe('Bearer admin-tk-1');
  });

  it('setPhoneVerified: merges into existing attributes without clobbering nik', async () => {
    const { http, calls } = stubAxios({
      'POST https://kc.example.test/token': () => ({
        status: 200,
        data: { access_token: 'admin-tk-2', expires_in: 60, token_type: 'Bearer' },
      }),
      'GET https://kc.example.test/admin/realms/pangkalpinang/users/user-2': () => ({
        status: 200,
        data: {
          id: 'user-2',
          email: 'b@x',
          attributes: {
            nik: ['1971010101010001'],
            something_else: ['keep me'],
          },
        },
      }),
      'PUT https://kc.example.test/admin/realms/pangkalpinang/users/user-2': () => ({
        status: 204,
      }),
    });
    const admin = buildKeycloakAdmin({
      keycloak: fakeKeycloak,
      realm: 'pangkalpinang',
      baseUrl: 'https://kc.example.test',
      clientId: 'super-app-bff',
      clientSecret: 'shh',
      log: silentLog,
      http,
    });

    const verifiedAt = '2026-05-14T12:34:56.000Z';
    await admin.setPhoneVerified('user-2', '+6281234567890', verifiedAt);

    const put = calls.find((c) => c.method === 'PUT')!;
    const body = put.data as { attributes: Record<string, string[]> };
    expect(body.attributes.nik).toEqual(['1971010101010001']);
    expect(body.attributes['something_else']).toEqual(['keep me']);
    expect(body.attributes.phoneNumber).toEqual(['+6281234567890']);
    expect(body.attributes.phoneNumberVerified).toEqual(['true']);
    expect(body.attributes.phoneVerifiedAt).toEqual([verifiedAt]);
  });

  it('caches the admin token across calls (one token grant for two writes)', async () => {
    let tokenGrants = 0;
    const { http, calls } = stubAxios({
      'POST https://kc.example.test/token': () => {
        tokenGrants++;
        return {
          status: 200,
          data: {
            // 5 minutes — well outside the 30s refresh skew.
            access_token: `admin-tk-${tokenGrants}`,
            expires_in: 300,
            token_type: 'Bearer',
          },
        };
      },
      'GET https://kc.example.test/admin/realms/pangkalpinang/users/u': () => ({
        status: 200,
        data: { id: 'u' },
      }),
      'PUT https://kc.example.test/admin/realms/pangkalpinang/users/u': () => ({
        status: 204,
      }),
    });
    const admin = buildKeycloakAdmin({
      keycloak: fakeKeycloak,
      realm: 'pangkalpinang',
      baseUrl: 'https://kc.example.test',
      clientId: 'super-app-bff',
      clientSecret: 'shh',
      log: silentLog,
      http,
    });
    await admin.setEmailVerified('u', '2026-05-14T00:00:00.000Z');
    await admin.setEmailVerified('u', '2026-05-14T00:00:01.000Z');
    expect(tokenGrants).toBe(1);
    // Verify the second call reused the cached token.
    const puts = calls.filter((c) => c.method === 'PUT');
    expect(puts[0]?.headers['Authorization']).toBe('Bearer admin-tk-1');
    expect(puts[1]?.headers['Authorization']).toBe('Bearer admin-tk-1');
  });

  it('wraps admin-side failures as keycloak_admin_put_failed', async () => {
    const { http } = stubAxios({
      'POST https://kc.example.test/token': () => ({
        status: 200,
        data: { access_token: 'tk', expires_in: 300, token_type: 'Bearer' },
      }),
      'GET https://kc.example.test/admin/realms/pangkalpinang/users/u': () => ({
        status: 200,
        data: { id: 'u' },
      }),
      'PUT https://kc.example.test/admin/realms/pangkalpinang/users/u': () => ({
        status: 403,
        data: { error: 'Forbidden' },
      }),
    });
    const admin = buildKeycloakAdmin({
      keycloak: fakeKeycloak,
      realm: 'pangkalpinang',
      baseUrl: 'https://kc.example.test',
      clientId: 'super-app-bff',
      clientSecret: 'shh',
      log: silentLog,
      http,
    });
    await expect(admin.setEmailVerified('u', '2026-05-14T00:00:00.000Z')).rejects.toMatchObject({
      code: 'keycloak_admin_put_failed',
      status: 502,
    });
  });
});
