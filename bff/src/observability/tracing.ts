import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { Resource } from '@opentelemetry/resources';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from '@opentelemetry/semantic-conventions';
import type { Env } from '../config/env.js';

// IMPROVEMENT_PLAN §3.1 / item #6 (tracing slice). Bootstrap auto-
// instrumentations BEFORE the application's modules are imported so the
// http/express/axios prototypes are patched in time. index.ts calls
// startTracing() and only then dynamic-imports './app.js'.

let started: NodeSDK | undefined;

export const startTracing = (env: Env): NodeSDK | undefined => {
  if (!env.TRACING_ENABLED) return undefined;
  if (started) return started;

  const sdk = new NodeSDK({
    resource: new Resource({
      [ATTR_SERVICE_NAME]: env.OTEL_SERVICE_NAME,
      [ATTR_SERVICE_VERSION]: env.BUILD_VERSION,
      'deployment.environment': env.NODE_ENV,
      'service.commit': env.BUILD_COMMIT,
    }),
    traceExporter: env.OTEL_EXPORTER_OTLP_ENDPOINT
      ? new OTLPTraceExporter({ url: env.OTEL_EXPORTER_OTLP_ENDPOINT })
      : undefined,
    instrumentations: [
      getNodeAutoInstrumentations({
        // Disable fs auto-instrumentation; it's chatty and not useful for
        // an HTTP/auth service.
        '@opentelemetry/instrumentation-fs': { enabled: false },
      }),
    ],
  });

  sdk.start();
  started = sdk;
  return sdk;
};

export const stopTracing = async (): Promise<void> => {
  if (!started) return;
  await started.shutdown();
  started = undefined;
};
