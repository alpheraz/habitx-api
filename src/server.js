/**
 * Habit X public API — demo vertical slice.
 * Contract: openapi/habitx-v1.yaml
 *
 * Storage: in-memory Map (TEMP). Replace with Postgres before production.
 * Auth: HABITX_DEV_TOKEN bearer (TEMP until Sign in with Apple + JWT).
 * Bind: 127.0.0.1:4600 — reach from Mac Simulator via SSH tunnel or Tailscale.
 */

import express from 'express';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getSupabaseAdmin, getSupabaseConfig } from './lib/supabase.js';
import { requireAuth, sendError } from './lib/auth.js';
import { qRouter } from './routes/q.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');

const HOST = process.env.HABITX_HOST ?? '127.0.0.1';
const PORT = Number(process.env.HABITX_PORT ?? 4600);
const DEV_TOKEN = process.env.HABITX_DEV_TOKEN ?? 'habitx-dev-demo-token';

/** @typedef {'daily'|'weekly'|'monthly'} HabitFrequency */
/** @typedef {'active'|'archived'} HabitStatus */

/**
 * @typedef {object} Habit
 * @property {string} id
 * @property {string} userId
 * @property {string} name
 * @property {string|null} details
 * @property {string|null} tagName
 * @property {string} colorHex
 * @property {HabitFrequency} frequency
 * @property {number[]} scheduleDays
 * @property {string|null} reminderTime
 * @property {HabitStatus} status
 * @property {string} createdAt
 * @property {string} updatedAt
 */

/**
 * @typedef {object} HabitCompletion
 * @property {string} id
 * @property {string} habitId
 * @property {string} userId
 * @property {string} day
 * @property {boolean} isCompleted
 * @property {number|null} value
 * @property {string} createdAt
 * @property {string} updatedAt
 */

/** @type {Map<string, Habit>} */
const habits = new Map();
/** @type {Map<string, HabitCompletion>} */
const completions = new Map();

const DEMO_USER = {
  id: 'user_demo',
  displayName: 'Jake',
  email: 'jake@habitx.local'
};

function nowIso() {
  return new Date().toISOString();
}

function publicHabit(h) {
  const { userId, ...rest } = h;
  return rest;
}

function publicCompletion(c) {
  const { userId, ...rest } = c;
  return rest;
}

function seedDemoHabits() {
  if (habits.size > 0) return;
  const seed = [
    { name: 'Meditate', tagName: 'Morning', colorHex: '#7C5CFF', frequency: 'daily' },
    { name: 'Drink water', tagName: 'Health', colorHex: '#0D6EFD', frequency: 'daily' },
    { name: 'Read', tagName: 'Growth', colorHex: '#D63384', frequency: 'daily' }
  ];
  for (const s of seed) {
    const id = randomUUID();
    const ts = nowIso();
    habits.set(id, {
      id,
      userId: DEMO_USER.id,
      name: s.name,
      details: null,
      tagName: s.tagName,
      colorHex: s.colorHex,
      frequency: s.frequency,
      scheduleDays: [],
      reminderTime: null,
      status: 'active',
      createdAt: ts,
      updatedAt: ts
    });
  }
}

seedDemoHabits();

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));

app.use((req, res, next) => {
  const requestId = req.header('x-request-id') || randomUUID();
  res.setHeader('x-request-id', requestId);
  req.requestId = requestId;
  next();
});

const DEMO_USER = {
  id: 'user_demo',
  displayName: 'Jake',
  email: 'jake@habitx.local'
};

function isHexColor(v) {
  return typeof v === 'string' && /^#[0-9A-Fa-f]{6}$/.test(v);
}

function isFrequency(v) {
  return v === 'daily' || v === 'weekly' || v === 'monthly';
}

function normalizeDay(day) {
  if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return null;
  return day;
}

function completionKey(userId, habitId, day) {
  return `${userId}:${habitId}:${day}`;
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'habitx-api' });
});

app.get('/ready', async (_req, res) => {
  const sb = getSupabaseConfig();
  let supabase = 'missing';
  if (sb.configured) {
    try {
      const db = getSupabaseAdmin() ?? (await import('./lib/supabase.js')).getSupabaseAnon();
      const { error } = await db.from('profiles').select('id').limit(1);
      supabase = error ? 'error' : 'up';
    } catch {
      supabase = 'error';
    }
  }
  res.json({
    ready: true,
    database: 'stub',
    supabase,
    supabaseServiceRole: sb.hasServiceRole,
    q: '/api/habitx/v1/q/ask'
  });
});

app.get('/openapi/habitx-v1.yaml', (_req, res) => {
  res.type('text/yaml').send(readFileSync(join(root, 'openapi', 'habitx-v1.yaml'), 'utf8'));
});

const v1 = express.Router();
v1.use((req, res, next) => {
  Promise.resolve(requireAuth(req, res, next)).catch(next);
});

v1.get('/me', (req, res) => {
  res.json(req.user);
});

v1.get('/habits', (req, res) => {
  const list = [...habits.values()]
    .filter((h) => h.userId === req.user.id && h.status === 'active')
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    .map(publicHabit);
  res.json({ habits: list });
});

v1.post('/habits', (req, res) => {
  const body = req.body ?? {};
  if (!body.name || typeof body.name !== 'string' || body.name.trim().length === 0) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'name is required', req.requestId);
  }
  if (!isHexColor(body.colorHex ?? '')) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'colorHex must be #RRGGBB', req.requestId);
  }
  if (!isFrequency(body.frequency)) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'frequency must be daily|weekly|monthly', req.requestId);
  }
  const id = randomUUID();
  const ts = nowIso();
  /** @type {Habit} */
  const habit = {
    id,
    userId: req.user.id,
    name: body.name.trim().slice(0, 120),
    details: body.details ? String(body.details).slice(0, 2000) : null,
    tagName: body.tagName ? String(body.tagName).slice(0, 60) : null,
    colorHex: body.colorHex,
    frequency: body.frequency,
    scheduleDays: Array.isArray(body.scheduleDays)
      ? body.scheduleDays.filter((n) => Number.isInteger(n) && n >= 1 && n <= 7)
      : [],
    reminderTime: body.reminderTime ?? null,
    status: 'active',
    createdAt: ts,
    updatedAt: ts
  };
  habits.set(id, habit);
  res.status(201).json(publicHabit(habit));
});

v1.get('/habits/:habitId', (req, res) => {
  const habit = habits.get(req.params.habitId);
  if (!habit || habit.userId !== req.user.id) {
    return sendError(res, 404, 'HABIT_NOT_FOUND', 'Habit not found', req.requestId);
  }
  res.json(publicHabit(habit));
});

v1.patch('/habits/:habitId', (req, res) => {
  const habit = habits.get(req.params.habitId);
  if (!habit || habit.userId !== req.user.id) {
    return sendError(res, 404, 'HABIT_NOT_FOUND', 'Habit not found', req.requestId);
  }
  const body = req.body ?? {};
  if (body.name != null) habit.name = String(body.name).trim().slice(0, 120);
  if (body.details !== undefined) habit.details = body.details == null ? null : String(body.details).slice(0, 2000);
  if (body.tagName !== undefined) habit.tagName = body.tagName == null ? null : String(body.tagName).slice(0, 60);
  if (body.colorHex != null) {
    if (!isHexColor(body.colorHex)) {
      return sendError(res, 400, 'VALIDATION_ERROR', 'colorHex must be #RRGGBB', req.requestId);
    }
    habit.colorHex = body.colorHex;
  }
  if (body.frequency != null) {
    if (!isFrequency(body.frequency)) {
      return sendError(res, 400, 'VALIDATION_ERROR', 'invalid frequency', req.requestId);
    }
    habit.frequency = body.frequency;
  }
  if (Array.isArray(body.scheduleDays)) {
    habit.scheduleDays = body.scheduleDays.filter((n) => Number.isInteger(n) && n >= 1 && n <= 7);
  }
  if (body.reminderTime !== undefined) habit.reminderTime = body.reminderTime;
  if (body.status === 'active' || body.status === 'archived') habit.status = body.status;
  habit.updatedAt = nowIso();
  habits.set(habit.id, habit);
  res.json(publicHabit(habit));
});

v1.delete('/habits/:habitId', (req, res) => {
  const habit = habits.get(req.params.habitId);
  if (!habit || habit.userId !== req.user.id) {
    return sendError(res, 404, 'HABIT_NOT_FOUND', 'Habit not found', req.requestId);
  }
  habit.status = 'archived';
  habit.updatedAt = nowIso();
  habits.set(habit.id, habit);
  res.status(204).end();
});

v1.post('/habits/:habitId/completions', (req, res) => {
  const habit = habits.get(req.params.habitId);
  if (!habit || habit.userId !== req.user.id || habit.status !== 'active') {
    return sendError(res, 404, 'HABIT_NOT_FOUND', 'Habit not found', req.requestId);
  }
  const day = normalizeDay(req.body?.day);
  if (!day) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'day must be YYYY-MM-DD', req.requestId);
  }
  if (typeof req.body?.isCompleted !== 'boolean') {
    return sendError(res, 400, 'VALIDATION_ERROR', 'isCompleted must be boolean', req.requestId);
  }
  const key = completionKey(req.user.id, habit.id, day);
  const existing = completions.get(key);
  const ts = nowIso();
  /** @type {HabitCompletion} */
  const row = existing
    ? {
        ...existing,
        isCompleted: req.body.isCompleted,
        value: req.body.value ?? existing.value,
        updatedAt: ts
      }
    : {
        id: randomUUID(),
        habitId: habit.id,
        userId: req.user.id,
        day,
        isCompleted: req.body.isCompleted,
        value: req.body.value ?? null,
        createdAt: ts,
        updatedAt: ts
      };
  completions.set(key, row);
  res.json(publicCompletion(row));
});

v1.get('/completions', (req, res) => {
  const day = normalizeDay(String(req.query.day ?? ''));
  if (!day) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'day query required as YYYY-MM-DD', req.requestId);
  }
  const list = [...completions.values()]
    .filter((c) => c.userId === req.user.id && c.day === day)
    .map(publicCompletion);
  res.json({ day, completions: list });
});

app.use('/api/habitx/v1/q', qRouter);
app.use('/api/habitx/v1', v1);

app.use((req, res) => {
  sendError(res, 404, 'NOT_FOUND', `No route ${req.method} ${req.path}`, req.requestId);
});

app.listen(PORT, HOST, () => {
  console.log(`habitx-api listening on http://${HOST}:${PORT}`);
  console.log(`openapi: http://${HOST}:${PORT}/openapi/habitx-v1.yaml`);
  const sb = getSupabaseConfig();
  console.log(`supabase configured=${sb.configured} serviceRole=${sb.hasServiceRole}`);
});
