import http from 'node:http';
import https from 'node:https';
import axios, { type AxiosError, type AxiosInstance } from 'axios';
import { z } from 'zod';
import { upstream } from './errors.js';
import type { Logger } from './logger.js';
import type { MetricsBundle } from './metrics.js';
import { getCurrentRequestId } from './requestContext.js';

/**
 * Thrown by `refresh()` when Keycloak returns OAuth `invalid_grant` —
 * meaning the refresh token is dead (revoked, super-session ended, realm
 * change). The /refresh handler catches this to purge the local session.
 * See IMPROVEMENT_PLAN §5.3.
 */
export class InvalidGrantError extends Error {
  constructor(detail?: string) {
    super(detail ?? 'invalid_grant');
    this.name = 'InvalidGrantError';
  }
}

export interface OidcDiscovery {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  end_session_endpoint?: string;
  userinfo_endpoint?: string;
  jwks_uri?: string;
}

export interface KeycloakTokens {
  access_token: string;
  refresh_token?: string;
  id_token?: string;
  token_type: string;
  expires_in: number;
  refresh_expires_in?: number;
  scope?: string;
}

// AUDIT PR-3: zod-validate the KC token response before trusting any of
// its fields. Without this a malformed upstream response surfaces as a
// `TypeError: Cannot read properties of undefined` deep in a handler.
const KcTokenResponseZ = z.object({
  access_token: z.string().min(1),
  id_token: z.string().min(1).optional(),
  refresh_token: z.string().min(1).optional(),
  token_type: z.string().min(1),
  expires_in: z.number().int().nonnegative(),
  refresh_expires_in: z.number().int().nonnegative().optional(),
  scope: z.string().optional(),
});

const KcDiscoveryZ = z.object({
  issuer: z.string().min(1),
  authorization_endpoint: z.string().url(),
  token_endpoint: z.string().url(),
  end_session_endpoint: z.string().url().optional(),
  userinfo_endpoint: z.string().url().optional(),
  jwks_uri: z.string().url().optional(),
});

export type KeycloakOp = 'discovery' | 'exchange' | 'refresh' | 'end_session';

export interface KeycloakClientOptions {
  issuer: string;
  clientId: string;
  clientSecret: string;
  log: Logger;
  http?: AxiosInstance;
  metrics?: MetricsBundle;
  /** AUDIT S-4: max age of cached discovery before a background refresh. */
  discoveryTtlMs?: number;
}

const DEFAULT_DISCOVERY_TTL_MS = 60 * 60 * 1000; // 1h
const KC_HTTP_TIMEOUT_MS = 10_000;
const KC_MAX_CONTENT_LENGTH = 64 * 1024; // 64 KB — auth bodies are tiny

interface DiscoveryCache {
  value: OidcDiscovery;
  fetchedAt: number;
  refreshing: Promise<OidcDiscovery> | null;
}

export class KeycloakClient {
  private readonly http: AxiosInstance;
  private discovery: DiscoveryCache | undefined;
  private readonly discoveryTtlMs: number;

  constructor(private readonly opts: KeycloakClientOptions) {
    // AUDIT P-3: keepalive agents so TLS handshakes amortize across many
    // calls. axios's default agent reconnects per request.
    this.http =
      opts.http ??
      axios.create({
        timeout: KC_HTTP_TIMEOUT_MS,
        // AUDIT PR-3: bound response size so a runaway KC can't OOM us.
        maxContentLength: KC_MAX_CONTENT_LENGTH,
        maxBodyLength: KC_MAX_CONTENT_LENGTH,
        headers: { Accept: 'application/json' },
        httpAgent: new http.Agent({ keepAlive: true, maxSockets: 50 }),
        httpsAgent: new https.Agent({ keepAlive: true, maxSockets: 50 }),
      });
    this.discoveryTtlMs = opts.discoveryTtlMs ?? DEFAULT_DISCOVERY_TTL_MS;
  }

  // Records keycloak_request_duration_seconds for every outbound call. The
  // outcome label is "ok" for any return path, "invalid_grant" for the
  // typed §5.3 throw, and "error" for everything else.
  private async time<T>(op: KeycloakOp, fn: () => Promise<T>): Promise<T> {
    const start = process.hrtime.bigint();
    try {
      const out = await fn();
      this.observe(op, 'ok', start);
      return out;
    } catch (err) {
      const outcome = err instanceof InvalidGrantError ? 'invalid_grant' : 'error';
      this.observe(op, outcome, start);
      throw err;
    }
  }

  private observe(op: KeycloakOp, outcome: string, start: bigint): void {
    if (!this.opts.metrics) return;
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    this.opts.metrics.keycloakRequestDurationSeconds.observe({ op, outcome }, seconds);
  }

  /**
   * AUDIT PR-3: outbound headers carry the inbound x-request-id (from ALS)
   * and Authorization for confidential clients. RFC 6749 §2.3.1 prefers
   * HTTP Basic over `client_secret_post`; we use Basic.
   */
  private requestHeaders(extra: Record<string, string> = {}): Record<string, string> {
    const headers: Record<string, string> = { ...extra };
    const reqId = getCurrentRequestId();
    if (reqId) headers['x-request-id'] = reqId;
    return headers;
  }

  /** HTTP Basic auth header per RFC 6749 §2.3.1. */
  private basicAuthHeader(): string {
    const raw = `${this.opts.clientId}:${this.opts.clientSecret}`;
    return `Basic ${Buffer.from(raw, 'utf8').toString('base64')}`;
  }

  /**
   * AUDIT S-4 + P-1: returns cached discovery if present and fresh.
   * Returns cached-but-stale immediately and kicks off a single
   * background refresh; concurrent first-callers share the refresh
   * promise so we never fire two discovery fetches in parallel.
   */
  async getDiscovery(): Promise<OidcDiscovery> {
    if (this.discovery) {
      const age = Date.now() - this.discovery.fetchedAt;
      if (age > this.discoveryTtlMs && !this.discovery.refreshing) {
        // Stale-while-revalidate: serve cached, refresh in background.
        const refreshing = this.fetchDiscoveryWithRetries().then(
          (next) => {
            this.discovery = { value: next, fetchedAt: Date.now(), refreshing: null };
            return next;
          },
          (err) => {
            // Keep serving the stale value; surface the error in logs.
            if (this.discovery) this.discovery.refreshing = null;
            this.opts.log.warn({ err }, 'keycloak background discovery refresh failed');
            return this.discovery!.value;
          },
        );
        this.discovery.refreshing = refreshing;
      }
      return this.discovery.value;
    }
    // First call: cold fetch. Concurrent callers see the same in-flight promise.
    if (!this.coldDiscoveryPromise) {
      this.coldDiscoveryPromise = this.fetchDiscoveryWithRetries()
        .then((value) => {
          this.discovery = { value, fetchedAt: Date.now(), refreshing: null };
          return value;
        })
        .finally(() => {
          this.coldDiscoveryPromise = undefined;
        });
    }
    return this.coldDiscoveryPromise;
  }

  private coldDiscoveryPromise: Promise<OidcDiscovery> | undefined;

  /**
   * AUDIT S-4: invalidate cached discovery so the next read forces a
   * fresh fetch. Called from keycloakJwt when a `kid` arrives that the
   * cached JWKS doesn't know — usually a sign KC has rotated keys.
   */
  invalidateDiscovery(): void {
    this.discovery = undefined;
  }

  private async fetchDiscoveryWithRetries(): Promise<OidcDiscovery> {
    const url = `${this.opts.issuer.replace(/\/$/, '')}/.well-known/openid-configuration`;
    // AUDIT PR-3: 3 attempts with jittered backoff inside a 5s budget. Only
    // discovery is retried — token endpoints are NOT safe to retry because
    // an OAuth2 code is single-use server-side.
    const start = Date.now();
    const maxBudgetMs = 5_000;
    let lastErr: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        return await this.time('discovery', async () => {
          const res = await this.http.get<unknown>(url, { headers: this.requestHeaders() });
          const parsed = KcDiscoveryZ.safeParse(res.data);
          if (!parsed.success) {
            throw upstream(
              'keycloak_discovery_invalid',
              `Discovery payload from ${url} failed schema check`,
            );
          }
          this.opts.log.info(
            { authorization_endpoint: parsed.data.authorization_endpoint, attempt },
            'keycloak discovery loaded',
          );
          return parsed.data;
        });
      } catch (err) {
        lastErr = err;
        if (Date.now() - start > maxBudgetMs) break;
        // 100ms, 300ms with up to 50% jitter
        const base = attempt === 0 ? 100 : 300;
        const jitter = Math.floor(Math.random() * (base / 2));
        await new Promise((r) => setTimeout(r, base + jitter));
      }
    }
    throw upstream(
      'keycloak_discovery_failed',
      `Failed to load OIDC discovery from ${url}`,
      lastErr,
    );
  }

  async exchangeCode(params: {
    code: string;
    redirectUri: string;
    codeVerifier?: string;
  }): Promise<KeycloakTokens> {
    const disc = await this.getDiscovery();
    const body = new URLSearchParams({
      grant_type: 'authorization_code',
      code: params.code,
      redirect_uri: params.redirectUri,
      client_id: this.opts.clientId,
    });
    if (params.codeVerifier) body.set('code_verifier', params.codeVerifier);
    return this.time('exchange', () => this.postToken(disc.token_endpoint, body));
  }

  async refresh(refreshToken: string): Promise<KeycloakTokens> {
    const disc = await this.getDiscovery();
    const body = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: this.opts.clientId,
    });
    return this.time('refresh', async () => {
      // Probe directly so we can pattern-match invalid_grant before postToken
      // wraps the failure as a generic upstream HttpError. See §5.3.
      try {
        const res = await this.http.post<unknown>(disc.token_endpoint, body, {
          headers: this.requestHeaders({
            'Content-Type': 'application/x-www-form-urlencoded',
            Authorization: this.basicAuthHeader(),
          }),
        });
        return this.parseTokenResponse(res.data);
      } catch (err) {
        if (
          axios.isAxiosError(err) &&
          (err.response?.data as { error?: string } | undefined)?.error === 'invalid_grant'
        ) {
          const detail = (err.response?.data as { error_description?: string } | undefined)
            ?.error_description;
          throw new InvalidGrantError(detail);
        }
        const ax = err as AxiosError<{ error?: string; error_description?: string }>;
        const detail =
          ax.response?.data?.error_description ?? ax.response?.data?.error ?? ax.message;
        throw upstream('keycloak_token_failed', `Keycloak token request failed: ${detail}`, err);
      }
    });
  }

  async endSession(refreshToken: string): Promise<void> {
    const disc = await this.getDiscovery();
    if (!disc.end_session_endpoint) {
      this.opts.log.warn('keycloak discovery has no end_session_endpoint; skipping');
      return;
    }
    const body = new URLSearchParams({
      client_id: this.opts.clientId,
      refresh_token: refreshToken,
    });
    // Best-effort: caller already plans to wipe the local session even on
    // failure. We rethrow inside time() so the metric's outcome label is
    // correct, then swallow outside so the handler keeps going.
    try {
      await this.time('end_session', async () => {
        try {
          await this.http.post(disc.end_session_endpoint!, body, {
            headers: this.requestHeaders({
              'Content-Type': 'application/x-www-form-urlencoded',
              Authorization: this.basicAuthHeader(),
            }),
          });
        } catch (err) {
          this.opts.log.warn({ err }, 'keycloak end_session call failed');
          throw err;
        }
      });
    } catch {
      /* swallowed: outcome=error already recorded */
    }
  }

  private parseTokenResponse(raw: unknown): KeycloakTokens {
    const parsed = KcTokenResponseZ.safeParse(raw);
    if (!parsed.success) {
      throw upstream(
        'keycloak_token_invalid',
        'Keycloak token response failed schema check',
        parsed.error,
      );
    }
    return parsed.data;
  }

  private async postToken(url: string, body: URLSearchParams): Promise<KeycloakTokens> {
    try {
      const res = await this.http.post<unknown>(url, body, {
        headers: this.requestHeaders({
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: this.basicAuthHeader(),
        }),
      });
      return this.parseTokenResponse(res.data);
    } catch (err) {
      const ax = err as AxiosError<{ error?: string; error_description?: string }>;
      const detail = ax.response?.data?.error_description ?? ax.response?.data?.error ?? ax.message;
      throw upstream('keycloak_token_failed', `Keycloak token request failed: ${detail}`, err);
    }
  }
}
