import { Router } from 'express';
import { requireSupabaseUser, sendError } from '../lib/auth.js';
import { evidenceFromContext, loadUserContext, persistQResult } from '../lib/user-data.js';
import { getSupabaseAdmin } from '../lib/supabase.js';

export const qRouter = Router();
qRouter.use(requireSupabaseUser);

function buildAnswer(question, context) {
  const evidenceLines = [
    `${context.habits.length} active habits`,
    `${context.completions.length} completions (30d)`,
    `${context.routines.length} routines`,
    `${context.goals.length} goals`,
    `${context.milestones.length} milestones`,
    `${context.moods.length} mood check-ins (30d)`,
    `${context.gratitudes.length} gratitudes (30d)`,
    `${context.dayScores.length} day scores (30d)`
  ];

  const completed = context.completions.filter((c) => c.is_completed).length;
  const parts = [
    `Q read authorized HabitX data for this user only.`,
    `Evidence: ${evidenceLines.join(', ')}.`,
    completed
      ? `${completed} of ${context.completions.length} recent completion rows are marked done.`
      : 'No completions in the last 30 days yet — Day Score / QLE ranking has nothing to correlate.',
    'This is habitx-q-v0: structured evidence + persistence. Full QLE ranking is not claimed yet.'
  ];

  return {
    answer: parts.join(' '),
    evidenceLines,
    recommendation: context.habits.length === 0
      ? {
          title: 'Create your first habit so Q has something to read',
          action_type: 'add_habit',
          action_payload: { reason: 'empty_habit_set' }
        }
      : null
  };
}

qRouter.post('/ask', async (req, res) => {
  const question = String(req.body?.question ?? '').trim();
  if (!question || question.length > 4000) {
    return sendError(res, 400, 'VALIDATION_ERROR', 'question is required', req.requestId);
  }

  // Ignore any client-supplied user_id.
  const userId = req.user.id;
  const loaded = await loadUserContext(userId, req.accessToken);
  if (!loaded.context) {
    return sendError(res, 503, 'SUPABASE_UNAVAILABLE', loaded.reason ?? 'Supabase not ready', req.requestId);
  }

  const built = buildAnswer(question, loaded.context);
  const evidence = evidenceFromContext(loaded.context);
  const persist = await persistQResult({
    userId,
    question,
    answer: built.answer,
    evidence,
    recommendation: built.recommendation
  });

  res.json({
    question,
    answer: built.answer,
    analysisVersion: 'habitx-q-v0',
    evidence: evidence.map((e) => ({
      sourceType: e.source_type,
      metric: e.metric,
      value: e.value
    })),
    recommendation: persist.recommendation ?? built.recommendation,
    persisted: persist.persisted,
    persistReason: persist.reason ?? null,
    interactionId: persist.interactionId ?? null
  });
});

qRouter.get('/interactions', async (req, res) => {
  const admin = getSupabaseAdmin();
  if (!admin) {
    return sendError(res, 503, 'SERVICE_ROLE_REQUIRED', 'Q history requires SUPABASE_SECRET_KEY (service_role)', req.requestId);
  }
  const { data, error } = await admin
    .from('q_interactions')
    .select('id,question,answer,analysis_version,created_at')
    .eq('user_id', req.user.id)
    .order('created_at', { ascending: false })
    .limit(20);
  if (error) {
    return sendError(res, 500, 'QUERY_FAILED', error.message, req.requestId);
  }
  res.json({ interactions: data ?? [] });
});
