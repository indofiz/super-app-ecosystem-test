import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.ts'],
    globals: false,
    reporters: 'default',
    coverage: {
      // AUDIT §4.6 / M-7: enforce a floor on coverage so a regression
      // surfaces in CI. Numbers chosen to roughly match today's reality;
      // tighten as the suite grows.
      provider: 'v8',
      reporter: ['text', 'html', 'lcov'],
      include: ['src/**/*.ts'],
      exclude: [
        'src/observability/tracing.ts', // wraps OTEL SDK; only exercised in prod
        'src/index.ts', // bootstrap glue
        'src/lib/redis.ts', // ioredis factory; tests use ioredis-mock directly
        'src/types/**', // .d.ts module augmentation only
      ],
      thresholds: {
        lines: 80,
        statements: 80,
        functions: 80,
        branches: 70,
      },
    },
  },
});
