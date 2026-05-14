import { Counter, Histogram, Registry, collectDefaultMetrics } from 'prom-client';

// Closes IMPROVEMENT_PLAN §3.1 / item #6: gives SRE alertable signal.
//
// We use a dedicated Registry rather than the global default so vitest
// runs (and any future multi-app-in-one-process scenario) can construct
// fresh metrics state without leaking counters between cases.

export interface MetricsBundle {
  registry: Registry;
  httpRequestsTotal: Counter<'route' | 'method' | 'status'>;
  httpRequestDurationSeconds: Histogram<'route' | 'method'>;
  keycloakRequestDurationSeconds: Histogram<'op' | 'outcome'>;
  authTokenMintTotal: Counter<'kind'>;
  authFailedTotal: Counter<'reason'>;
}

export const buildMetrics = (): MetricsBundle => {
  const registry = new Registry();
  // Process CPU/memory/event-loop lag — gives /metrics something useful
  // even before our own counters fire.
  collectDefaultMetrics({ register: registry });

  const httpRequestsTotal = new Counter({
    name: 'http_requests_total',
    help: 'HTTP requests served, labeled by route, method, status code.',
    labelNames: ['route', 'method', 'status'] as const,
    registers: [registry],
  });

  const httpRequestDurationSeconds = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds.',
    labelNames: ['route', 'method'] as const,
    // Buckets sized for an auth BFF: most calls < 1s, a few up to a couple
    // of seconds when KC is slow. 10s is the http timeout ceiling.
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    registers: [registry],
  });

  const keycloakRequestDurationSeconds = new Histogram({
    name: 'keycloak_request_duration_seconds',
    help: 'Outbound Keycloak request duration in seconds.',
    labelNames: ['op', 'outcome'] as const,
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    registers: [registry],
  });

  const authTokenMintTotal = new Counter({
    name: 'auth_token_mint_total',
    help: 'Internal JWTs minted, labeled by kind (token | refresh).',
    labelNames: ['kind'] as const,
    registers: [registry],
  });

  const authFailedTotal = new Counter({
    name: 'auth_failed_total',
    help: 'Auth failures, labeled by reason. Useful for brute-force alerts.',
    labelNames: ['reason'] as const,
    registers: [registry],
  });

  return {
    registry,
    httpRequestsTotal,
    httpRequestDurationSeconds,
    keycloakRequestDurationSeconds,
    authTokenMintTotal,
    authFailedTotal,
  };
};

// Whitelist of routes we expose as metric labels. Anything else collapses
// to "other" — protects Prometheus from cardinality explosion if a new
// path lands without a label-allowlist update.
const ROUTE_ALLOWLIST = new Set<string>([
  '/auth/authorize',
  '/auth/callback',
  '/auth/token',
  '/auth/refresh',
  '/auth/logout',
  '/auth/me',
  '/auth/email/send-otp',
  '/auth/email/verify-otp',
  '/auth/phone/send-otp',
  '/auth/phone/verify-otp',
  '/healthz',
  '/readyz',
  '/livez',
  '/metrics',
  '/.well-known/jwks.json',
]);

export const normalizeRoute = (path: string | undefined): string => {
  if (!path) return 'other';
  // Strip query string + trailing slash for matching.
  const stripped = path.split('?')[0]?.replace(/\/$/, '') ?? '';
  return ROUTE_ALLOWLIST.has(stripped) ? stripped : 'other';
};
