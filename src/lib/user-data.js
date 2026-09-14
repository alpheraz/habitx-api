import { getSupabaseAdmin, getSupabaseForUser } from './supabase.js';

/**
 * Load only the authenticated user's HabitX rows.
 * Prefers RLS (user JWT). Falls back to service-role + user_id filter.
 */
export async function loadUserContext(userId, accessToken) {
  const scoped = getSupabaseForUser(accessToken);
  const admin = getSupabaseAdmin();
  const db = scoped ?? admin;
  if (!db) {
    return { ok: false, reason: 'supabase_not_configured', context: null };
  }

  const since = new Date();
  since.setUTCDate(since.getUTCDate() - 30);
  const sinceDay = since.toISOString().slice(0, 10);

  const queries = {
    habits: db.from('habits').select('id,name,tag_name,status,lift_weight,target_value,target_unit,created_at')
      .eq('user_id', userId).eq('status', 'active'),
    completions: db.from('habit_completions').select('id,habit_id,day,is_completed,value')
      .eq('user_id', userId).gte('day', sinceDay),
    routines: db.from('routines').select('id,name,status,position')
      .eq('user_id', userId),
    goals: db.from('goals').select('id,title,status,target_date')
      .eq('user_id', userId),
    milestones: db.from('goal_milestones').select('id,goal_id,title,is_completed,due_date,position')
      .eq('user_id', userId),
    moods: db.from('mood_checkins').select('id,local_day,score,label,at')
      .eq('user_id', userId).gte('local_day', sinceDay),
    gratitudes: db.from('gratitude_entries').select('id,mood_checkin_id,text,at')
      .eq('user_id', userId).gte('at', since.toISOString()),
    dayScores: db.from('day_scores').select('day,score,algorithm_version,components')
      .eq('user_id', userId).gte('day', sinceDay)
  };

  const entries = await Promise.all(
    Object.entries(queries).map(async ([key, q]) => {
      const { data, error } = await q;
      return [key, error ? { error: error.message, rows: [] } : { error: null, rows: data ?? [] }];
    })
  );

  const bags = Object.fromEntries(entries);
  const firstError = Object.values(bags).find((b) => b.error)?.error ?? null;

  return {
    ok: !firstError || Object.values(bags).some((b) => b.rows.length > 0),
    reason: firstError,
    context: {
      userId,
      windowDays: 30,
      habits: bags.habits.rows,
      completions: bags.completions.rows,
      routines: bags.routines.rows,
      goals: bags.goals.rows,
      milestones: bags.milestones.rows,
      moods: bags.moods.rows,
      gratitudes: bags.gratitudes.rows,
      dayScores: bags.dayScores.rows
    }
  };
}

export function evidenceFromContext(context) {
  const items = [];
  const push = (source_type, metric, value, source_id = null, metadata = {}) => {
    items.push({ source_type, source_id, metric, value, metadata });
  };
  push('habit', 'active_habit_count', context.habits.length);
  push('habit_completion', 'completion_rows_30d', context.completions.length);
  push('routine', 'routine_count', context.routines.length);
  push('goal', 'goal_count', context.goals.length);
  push('milestone', 'milestone_count', context.milestones.length);
  push('mood_checkin', 'mood_checkins_30d', context.moods.length);
  push('gratitude', 'gratitude_entries_30d', context.gratitudes.length);
  push('day_score', 'day_scores_30d', context.dayScores.length);
  return items;
}

export async function persistQResult({ userId, question, answer, evidence, recommendation }) {
  const admin = getSupabaseAdmin();
  if (!admin) {
    return { persisted: false, reason: 'service_role_required' };
  }

  const { data: interaction, error: iErr } = await admin
    .from('q_interactions')
    .insert({
      user_id: userId,
      question,
      answer,
      model: 'habitx-q-v0',
      provider: 'habitx-api',
      analysis_version: 'habitx-q-v0'
    })
    .select('id')
    .single();

  if (iErr || !interaction) {
    return { persisted: false, reason: iErr?.message ?? 'interaction_insert_failed' };
  }

  if (evidence.length) {
    const rows = evidence.map((e) => ({
      user_id: userId,
      q_interaction_id: interaction.id,
      source_type: e.source_type,
      source_id: e.source_id,
      metric: e.metric,
      value: e.value,
      metadata: e.metadata ?? {}
    }));
    await admin.from('q_evidence').insert(rows);
  }

  let rec = null;
  if (recommendation) {
    const { data } = await admin
      .from('q_recommendations')
      .insert({
        user_id: userId,
        q_interaction_id: interaction.id,
        title: recommendation.title,
        action_type: recommendation.action_type ?? 'other',
        action_payload: recommendation.action_payload ?? {},
        status: 'shown'
      })
      .select('id,title,action_type,status')
      .single();
    rec = data;
  }

  return { persisted: true, interactionId: interaction.id, recommendation: rec };
}
