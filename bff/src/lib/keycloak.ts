import axios, { type AxiosError, type AxiosInstance } from 'axios';
import { upstream } from './errors.js';
import type { Logger } from './logger.js';
import type { MetricsBundle } from './metrics.js';

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

export type KeycloakOp = 'discovery' | 'exchange' | 'refresh' | 'end_session';

export interface KeycloakClientOptions {
  issuer: string;
  clientId: string;
  clientSecret: string;
  log: Logger;
  http?: AxiosInstance;
  metrics?: MetricsBundle;
}

export class KeycloakClient {
  private readonly http: AxiosInstance;
  private discovery: OidcDiscovery | undefined;

  constructor(private readonly opts: KeycloakClientOptions) {
    this.http =
      opts.http ??
      axios.create({
        timeout: 10_000,
        headers: { Accept: 'application/json' },
      });
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

  async getDiscovery(): Promise<OidcDiscovery> {
    if (this.discovery) return this.discovery;
    const url = `${this.opts.issuer.replace(/\/$/, '')}/.well-known/openid-configuration`;
    return this.time('discovery', async () => {
      try {
        const res = await this.http.get<OidcDiscovery>(url);
        this.discovery = res.data;
        this.opts.log.info(
          { authorization_endpoint: this.discovery.authorization_endpoint },
          'keycloak discovery loaded',
        );
        return this.discovery;
      } catch (err) {
        throw upstream(
          'keycloak_discovery_failed',
          `Failed to load OIDC discovery from ${url}`,
          err,
        );
      }
    });
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
      client_secret: this.opts.clientSecret,
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
      client_secret: this.opts.clientSecret,
    });
    return this.time('refresh', async () => {
      // Probe directly so we can pattern-match invalid_grant before postToken
      // wraps the failure as a generic upstream HttpError. See §5.3.
      try {
        const res = await this.http.post<KeycloakTokens>(disc.token_endpoint, body, {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        });
        return res.data;
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
      client_secret: this.opts.clientSecret,
      refresh_token: refreshToken,
    });
    await this.time('end_session', async () => {
      try {
        await this.http.post(disc.end_session_endpoint!, body, {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        });
      } catch (err) {
        // Logout is best-effort: we still wipe the local session.
        this.opts.log.warn({ err }, 'keycloak end_session call failed');
      }
    });
  }

  private async postToken(url: string, body: URLSearchParams): Promise<KeycloakTokens> {
    try {
      const res = await this.http.post<KeycloakTokens>(url, body, {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      });
      return res.data;
    } catch (err) {
      const ax = err as AxiosError<{ error?: string; error_description?: string }>;
      const detail = ax.response?.data?.error_description ?? ax.response?.data?.error ?? ax.message;
      throw upstream('keycloak_token_failed', `Keycloak token request failed: ${detail}`, err);
    }
  }
}
