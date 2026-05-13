import { monitorEventLoopDelay } from 'node:perf_hooks';
import { Router } from 'express';
import type { Redis } from 'ioredis';
import type { Env } from '../config/env.js';
import type { KeycloakClient } from '../lib/keycloak.js';

// IMPROVEMENT_PLAN §3.1 / item #6 (health probes side):
//
//   /healthz  — process is alive. No I/O. Cheap. K8s startup probe.
//   /readyz   — Redis ping + KC discovery (each with 1s timeout). 503 on
//               failure. K8s readiness probe.
//   /livez    — event-loop lag check. 503 if the loop has been wedged
//               (>1s p99 over the rolling window). K8s liveness probe.

export interface HealthDeps {
  redis: Redis;
  keycloak?: KeycloakClient;
  env: Env;
}

const withTimeout = async <T>(p: Promise<T>, ms: number, label: string): Promise<T> => {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
  });
  try {
    return await Promise.race([p, timeout]);
  } finally {
    if (timer) clearTimeout(timer);
  }
};

export const buildHealthRouter = ({ redis, keycloak, env }: HealthDeps): Router => {
  const router = Router();

  // Event-loop delay histogram. Started at router construction so the
  // window grows during the lifetime of the process. resolution=10ms is a
  // sensible default — finer is wasted granularity for liveness purposes.
  const loopHist = monitorEventLoopDelay({ resolution: 10 });
  loopHist.enable();

  const baseInfo = () => ({
    version: env.BUILD_VERSION,
    commit: env.BUILD_COMMIT,
    uptime_s: Math.round(process.uptime()),
  });

  router.get('/healthz', (_req, res) => {
    res.json({ status: 'ok', ...baseInfo() });
  });

  router.get('/readyz', async (_req, res) => {
    const checks: Record<string, string> = {};
    let healthy = true;

    try {
      const reply = await withTimeout(redis.ping(), 1000, 'redis.ping');
      if (reply !== 'PONG') throw new Error(`unexpected redis reply: ${String(reply)}`);
      checks.redis = 'ok';
    } catch (err) {
      checks.redis = err instanceof Error ? `fail: ${err.message}` : 'fail';
      healthy = false;
    }

    if (keycloak) {
      try {
        await withTimeout(keycloak.getDiscovery(), 1000, 'keycloak.discovery');
        checks.keycloak = 'ok';
      } catch (err) {
        checks.keycloak = err instanceof Error ? `fail: ${err.message}` : 'fail';
        healthy = false;
      }
    }

    res.status(healthy ? 200 : 503).json({
      status: healthy ? 'ok' : 'unavailable',
      checks,
      ...baseInfo(),
    });
  });

  router.get('/livez', (_req, res) => {
    // p99 in nanoseconds; convert to ms. Threshold of 1s is the
    // documented recommendation in IMPROVEMENT_PLAN §3.1.
    const p99Ms = loopHist.percentile(99) / 1e6;
    const wedged = p99Ms > 1000;
    res.status(wedged ? 503 : 200).json({
      status: wedged ? 'wedged' : 'ok',
      event_loop_p99_ms: Math.round(p99Ms),
      ...baseInfo(),
    });
  });

  return router;
};
