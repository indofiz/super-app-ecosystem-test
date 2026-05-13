import express, { type Request } from 'express';

const PORT = Number(process.env['PORT'] ?? 3001);

const identityFromHeaders = (req: Request) => ({
  // Kong's pre-function plugin (kong/kong.yml §2.13) verifies the JWT and
  // sets these from the trusted claims. Inbound copies are stripped first,
  // so the upstream can trust them as authoritative.
  userId: (req.headers['x-user-id'] as string | undefined) ?? null,
  sessionId: (req.headers['x-session-id'] as string | undefined) ?? null,
  roles: ((req.headers['x-roles'] as string | undefined) ?? '')
    .split(',')
    .map((r) => r.trim())
    .filter(Boolean),
});

const app = express();
app.disable('x-powered-by');

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'sample-service' });
});

app.get('/whoami', (req, res) => {
  // Pure header-based identity readout. Reference target for new modules.
  res.json({
    service: 'sample-service',
    ...identityFromHeaders(req),
    requestId: req.headers['x-request-id'] ?? null,
  });
});

app.get('/', (req, res) => {
  res.json({
    service: 'sample-service',
    requestId: req.headers['x-request-id'] ?? null,
    validatedBy: 'kong (bundled jwt plugin) — internal JWT minted by BFF',
    identity: identityFromHeaders(req),
    ts: new Date().toISOString(),
  });
});

app.listen(PORT, () => {
  console.log(`sample-service listening on ${PORT}`);
});
