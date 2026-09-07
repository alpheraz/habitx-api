/**
 * Habit X public API — Phase 2 foundation.
 * Contract: openapi/habitx-v1.yaml
 *
 * This process binds localhost only. Domain CRUD will use Postgres.
 * Auth (Sign in with Apple → JWT) lands after health/ready + schema.
 */

import express from 'express';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');

const HOST = process.env.HABITX_HOST ?? '127.0.0.1';
const PORT = Number(process.env.HABITX_PORT ?? 4600);

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));

app.use((req, res, next) => {
  const requestId = req.header('x-request-id') || randomUUID();
  res.setHeader('x-request-id', requestId);
  req.requestId = requestId;
  next();
});

function sendError(res, status, code, message, requestId) {
  res.status(status).json({
    error: { code, message, requestId }
  });
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'habitx-api' });
});

app.get('/ready', (_req, res) => {
  // Postgres not installed/wired yet — report stub readiness for contract consumers.
  const database = process.env.DATABASE_URL ? 'down' : 'stub';
  const ready = database === 'stub' || database === 'up';
  res.status(ready ? 200 : 503).json({ ready, database });
});

app.get('/openapi/habitx-v1.yaml', (_req, res) => {
  const path = join(root, 'openapi', 'habitx-v1.yaml');
  res.type('text/yaml').send(readFileSync(path, 'utf8'));
});

// Versioned API mount — handlers land with auth + Postgres.
const v1 = express.Router();

v1.use((req, res, next) => {
  // Temporary gate until Apple/JWT lands. Reject anonymous domain calls.
  const auth = req.header('authorization') || '';
  const dev = process.env.HABITX_DEV_TOKEN;
  if (dev && auth === `Bearer ${dev}`) return next();
  return sendError(res, 401, 'UNAUTHORIZED', 'Authentication required', req.requestId);
});

v1.get('/me', (req, res) => {
  sendError(res, 501, 'NOT_IMPLEMENTED', 'GET /me not implemented yet', req.requestId);
});

v1.get('/habits', (req, res) => {
  sendError(res, 501, 'NOT_IMPLEMENTED', 'GET /habits not implemented yet', req.requestId);
});

v1.post('/habits', (req, res) => {
  sendError(res, 501, 'NOT_IMPLEMENTED', 'POST /habits not implemented yet', req.requestId);
});

app.use('/api/habitx/v1', v1);

app.use((req, res) => {
  sendError(res, 404, 'NOT_FOUND', `No route ${req.method} ${req.path}`, req.requestId);
});

app.listen(PORT, HOST, () => {
  console.log(`habitx-api listening on http://${HOST}:${PORT}`);
  console.log(`openapi: http://${HOST}:${PORT}/openapi/habitx-v1.yaml`);
});
