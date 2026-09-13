-- =============================================================================
-- HabitX production schema — 0001_init.sql
-- Target: Supabase (Postgres 15+)
--
-- Apply in Supabase SQL Editor (or supabase db push) AFTER creating the project.
-- Do not apply against Clawbot JsonStore. Do not embed secrets here.
--
-- Architecture:
--   iOS  → Supabase Auth + Postgres + RLS   (canonical consumer data)
--   iOS  → HabitX API (VPS) with Supabase JWT → Clawbot / Q / QLE
--   VPS  → writes day_scores + Q tables using service role
--
-- Intentionally NOT implemented: organizations, teams, memberships, SSO.
-- All entities use UUID + explicit user_id so workspaces can be added later.
-- =============================================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

-- -----------------------------------------------------------------------------
-- Shared helpers
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Profiles (1:1 with auth.users)
-- -----------------------------------------------------------------------------

create table public.profiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  display_name    text,
  email           citext,
  timezone        text not null default 'America/Chicago',
  apple_user_id   text,
  onboarding_completed_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint profiles_timezone_len check (char_length(timezone) between 1 and 64),
  constraint profiles_display_name_len check (
    display_name is null or char_length(display_name) between 1 and 120
  )
);

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, email, apple_user_id)
  values (
    new.id,
    nullif(
      coalesce(
        new.raw_user_meta_data->>'full_name',
        new.raw_user_meta_data->>'name',
        new.raw_user_meta_data->>'given_name'
      ),
      ''
    ),
    new.email,
    new.raw_user_meta_data->>'provider_id'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Habits
-- -----------------------------------------------------------------------------

create table public.habits (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name            text not null,
  details         text,
  tag_name        text,
  color_hex       text not null default '#7C5CFF',
  icon            text,
  status          text not null default 'active',
  -- Day Score weight / LIFT importance. Algorithm reads this; UI may edit later.
  lift_weight     numeric not null default 1,
  target_value    numeric,
  target_unit     text,
  start_date      date,
  archived_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint habits_name_len check (char_length(name) between 1 and 120),
  constraint habits_details_len check (details is null or char_length(details) <= 2000),
  constraint habits_tag_len check (tag_name is null or char_length(tag_name) <= 60),
  constraint habits_color_hex check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  constraint habits_status check (status in ('active', 'archived')),
  constraint habits_lift_weight check (lift_weight > 0 and lift_weight <= 100),
  constraint habits_target_unit_len check (target_unit is null or char_length(target_unit) <= 32)
);

create index habits_user_status_idx on public.habits (user_id, status);
create index habits_user_created_idx on public.habits (user_id, created_at);

create trigger habits_set_updated_at
before update on public.habits
for each row execute function public.set_updated_at();

-- First-class schedule (not JSONB). One current schedule per habit.
create table public.habit_schedules (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  frequency       text not null default 'daily',
  -- 1 = Sunday … 7 = Saturday (matches existing iOS Habit.scheduleDays)
  weekdays        smallint[] not null default '{}',
  month_day       smallint,
  reminder_time   time,
  timezone        text,
  starts_on       date,
  ends_on         date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint habit_schedules_habit_unique unique (habit_id),
  constraint habit_schedules_frequency check (frequency in ('daily', 'weekly', 'monthly')),
  constraint habit_schedules_month_day check (month_day is null or month_day between 1 and 31),
  constraint habit_schedules_weekdays check (
    weekdays <@ array[1,2,3,4,5,6,7]::smallint[]
  )
);

create index habit_schedules_user_idx on public.habit_schedules (user_id);

create trigger habit_schedules_set_updated_at
before update on public.habit_schedules
for each row execute function public.set_updated_at();

-- Definition of a subtask (not a daily completion).
create table public.habit_subtasks (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  title           text not null,
  position        int not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint habit_subtasks_title_len check (char_length(title) between 1 and 160)
);

create index habit_subtasks_habit_pos_idx on public.habit_subtasks (habit_id, position);
create index habit_subtasks_user_idx on public.habit_subtasks (user_id);

create trigger habit_subtasks_set_updated_at
before update on public.habit_subtasks
for each row execute function public.set_updated_at();

-- Per-day completion of a habit (binary + optional quantity).
create table public.habit_completions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  day             date not null,
  is_completed    boolean not null default true,
  value           numeric,
  timezone        text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint habit_completions_unique unique (user_id, habit_id, day)
);

create index habit_completions_user_day_idx on public.habit_completions (user_id, day);
create index habit_completions_habit_day_idx on public.habit_completions (habit_id, day);

create trigger habit_completions_set_updated_at
before update on public.habit_completions
for each row execute function public.set_updated_at();

-- Per-day completion of a subtask (separate from the subtask definition).
create table public.habit_subtask_completions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  subtask_id      uuid not null references public.habit_subtasks (id) on delete cascade,
  day             date not null,
  is_completed    boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint habit_subtask_completions_unique unique (user_id, subtask_id, day)
);

create index habit_subtask_completions_user_day_idx
  on public.habit_subtask_completions (user_id, day);
create index habit_subtask_completions_habit_day_idx
  on public.habit_subtask_completions (habit_id, day);

create trigger habit_subtask_completions_set_updated_at
before update on public.habit_subtask_completions
for each row execute function public.set_updated_at();

-- Append-only-ish history for Q. Updates are allowed for metadata correction
-- but product code should insert new events, not overwrite history.
create table public.habit_events (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  event_type      text not null,
  occurred_at     timestamptz not null default now(),
  local_day       date not null,
  value           numeric,
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  constraint habit_events_type check (event_type in (
    'scheduled',
    'started',
    'completed',
    'skipped',
    'missed',
    'rescheduled',
    'target_updated',
    'archived',
    'restored'
  ))
);

create index habit_events_user_occurred_idx on public.habit_events (user_id, occurred_at desc);
create index habit_events_habit_day_idx on public.habit_events (habit_id, local_day);
create index habit_events_user_type_day_idx on public.habit_events (user_id, event_type, local_day);

-- -----------------------------------------------------------------------------
-- Routines
-- -----------------------------------------------------------------------------

create table public.routines (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name            text not null,
  details         text,
  color_hex       text not null default '#0D6EFD',
  icon            text,
  position        int not null default 0,
  status          text not null default 'active',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint routines_name_len check (char_length(name) between 1 and 120),
  constraint routines_details_len check (details is null or char_length(details) <= 2000),
  constraint routines_color_hex check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  constraint routines_status check (status in ('active', 'archived'))
);

create index routines_user_pos_idx on public.routines (user_id, position);

create trigger routines_set_updated_at
before update on public.routines
for each row execute function public.set_updated_at();

create table public.routine_habits (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  routine_id      uuid not null references public.routines (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  position        int not null default 0,
  created_at      timestamptz not null default now(),
  constraint routine_habits_unique unique (routine_id, habit_id)
);

create index routine_habits_user_idx on public.routine_habits (user_id);
create index routine_habits_routine_pos_idx on public.routine_habits (routine_id, position);

-- -----------------------------------------------------------------------------
-- Goals + milestones
-- -----------------------------------------------------------------------------

create table public.goals (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title           text not null,
  details         text,
  target_date     date,
  status          text not null default 'active',
  color_hex       text not null default '#D63384',
  position        int not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint goals_title_len check (char_length(title) between 1 and 160),
  constraint goals_details_len check (details is null or char_length(details) <= 4000),
  constraint goals_status check (status in ('active', 'paused', 'completed', 'archived')),
  constraint goals_color_hex check (color_hex ~ '^#[0-9A-Fa-f]{6}$')
);

create index goals_user_status_idx on public.goals (user_id, status);
create index goals_user_pos_idx on public.goals (user_id, position);

create trigger goals_set_updated_at
before update on public.goals
for each row execute function public.set_updated_at();

create table public.goal_habits (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  goal_id         uuid not null references public.goals (id) on delete cascade,
  habit_id        uuid not null references public.habits (id) on delete cascade,
  weight          numeric not null default 1,
  created_at      timestamptz not null default now(),
  constraint goal_habits_unique unique (goal_id, habit_id),
  constraint goal_habits_weight check (weight > 0)
);

create index goal_habits_user_idx on public.goal_habits (user_id);

create table public.goal_routines (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  goal_id         uuid not null references public.goals (id) on delete cascade,
  routine_id      uuid not null references public.routines (id) on delete cascade,
  created_at      timestamptz not null default now(),
  constraint goal_routines_unique unique (goal_id, routine_id)
);

create index goal_routines_user_idx on public.goal_routines (user_id);

create table public.goal_milestones (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  goal_id         uuid not null references public.goals (id) on delete cascade,
  title           text not null,
  details         text,
  due_date        date,
  position        int not null default 0,
  is_completed    boolean not null default false,
  completed_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint goal_milestones_title_len check (char_length(title) between 1 and 160),
  constraint goal_milestones_details_len check (details is null or char_length(details) <= 2000)
);

create index goal_milestones_goal_pos_idx on public.goal_milestones (goal_id, position);
create index goal_milestones_user_idx on public.goal_milestones (user_id);

create trigger goal_milestones_set_updated_at
before update on public.goal_milestones
for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Mood + gratitude (synced — not device-only)
-- -----------------------------------------------------------------------------

create table public.mood_checkins (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  local_day       date not null,
  at              timestamptz not null default now(),
  -- 1–5 valence. Labels stay product-owned; score is what Q/Day Score can use.
  score           smallint not null,
  label           text,
  energy          smallint,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint mood_checkins_score check (score between 1 and 5),
  constraint mood_checkins_energy check (energy is null or energy between 1 and 5),
  constraint mood_checkins_label_len check (label is null or char_length(label) <= 60),
  constraint mood_checkins_notes_len check (notes is null or char_length(notes) <= 2000)
);

create index mood_checkins_user_day_idx on public.mood_checkins (user_id, local_day);
create index mood_checkins_user_at_idx on public.mood_checkins (user_id, at desc);

create trigger mood_checkins_set_updated_at
before update on public.mood_checkins
for each row execute function public.set_updated_at();

create table public.gratitude_entries (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mood_checkin_id uuid references public.mood_checkins (id) on delete set null,
  text            text not null,
  at              timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint gratitude_entries_text_len check (char_length(text) between 1 and 1000)
);

create index gratitude_entries_user_at_idx on public.gratitude_entries (user_id, at desc);
create index gratitude_entries_mood_idx on public.gratitude_entries (mood_checkin_id);

create trigger gratitude_entries_set_updated_at
before update on public.gratitude_entries
for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Day Score — persisted derived result. NOT a completion-percentage view.
-- Written by VPS / scoring job. iOS may read. Algorithm can evolve.
-- -----------------------------------------------------------------------------

create table public.day_scores (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  day               date not null,
  score             numeric not null,
  algorithm_version text not null,
  components        jsonb not null default '{}'::jsonb,
  computed_at       timestamptz not null default now(),
  constraint day_scores_unique unique (user_id, day),
  constraint day_scores_score_range check (score >= 0 and score <= 100),
  constraint day_scores_algo_len check (char_length(algorithm_version) between 1 and 64)
);

create index day_scores_user_day_idx on public.day_scores (user_id, day desc);

comment on table public.day_scores is
  'Derived HabitX Day Score. Do not replace with completion-percentage SQL. '
  'components jsonb holds habitCompletion, targetProgress, moodContribution, '
  'routineContribution, goalContribution, historicalBaseline, etc. '
  'algorithm_version examples: habitx-score-v1, qle-score-v1.';

-- -----------------------------------------------------------------------------
-- Q / QLE structured storage (server-written; client reads + rec status)
-- -----------------------------------------------------------------------------

create table public.q_interactions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  question          text not null,
  answer            text,
  model             text,
  provider          text,
  analysis_version  text,
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  constraint q_interactions_question_len check (char_length(question) between 1 and 4000)
);

create index q_interactions_user_created_idx on public.q_interactions (user_id, created_at desc);

create table public.q_evidence (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  q_interaction_id  uuid not null references public.q_interactions (id) on delete cascade,
  source_type       text not null,
  source_id         uuid,
  metric            text,
  value             numeric,
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  constraint q_evidence_source_type check (source_type in (
    'habit',
    'habit_completion',
    'habit_event',
    'routine',
    'goal',
    'milestone',
    'mood_checkin',
    'gratitude',
    'day_score',
    'profile'
  ))
);

create index q_evidence_interaction_idx on public.q_evidence (q_interaction_id);
create index q_evidence_user_idx on public.q_evidence (user_id);

create table public.q_recommendations (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  q_interaction_id      uuid not null references public.q_interactions (id) on delete cascade,
  title                 text not null,
  action_type           text not null,
  action_payload        jsonb not null default '{}'::jsonb,
  status                text not null default 'shown',
  created_at            timestamptz not null default now(),
  accepted_at           timestamptz,
  rejected_at           timestamptz,
  applied_at            timestamptz,
  outcome_evaluated_at  timestamptz,
  constraint q_recommendations_title_len check (char_length(title) between 1 and 200),
  constraint q_recommendations_status check (status in (
    'shown',
    'accepted',
    'rejected',
    'applied',
    'expired',
    'evaluated'
  )),
  constraint q_recommendations_action_type check (action_type in (
    'reschedule_habit',
    'adjust_target',
    'add_habit',
    'archive_habit',
    'adjust_routine',
    'focus_goal',
    'other'
  ))
);

create index q_recommendations_user_status_idx on public.q_recommendations (user_id, status);
create index q_recommendations_interaction_idx on public.q_recommendations (q_interaction_id);

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.habits enable row level security;
alter table public.habit_schedules enable row level security;
alter table public.habit_subtasks enable row level security;
alter table public.habit_completions enable row level security;
alter table public.habit_subtask_completions enable row level security;
alter table public.habit_events enable row level security;
alter table public.routines enable row level security;
alter table public.routine_habits enable row level security;
alter table public.goals enable row level security;
alter table public.goal_habits enable row level security;
alter table public.goal_routines enable row level security;
alter table public.goal_milestones enable row level security;
alter table public.mood_checkins enable row level security;
alter table public.gratitude_entries enable row level security;
alter table public.day_scores enable row level security;
alter table public.q_interactions enable row level security;
alter table public.q_evidence enable row level security;
alter table public.q_recommendations enable row level security;

-- Owner-only helpers (stable; used by relationship policies)
create or replace function public.is_own(_user_id uuid)
returns boolean
language sql
stable
as $$
  select _user_id = auth.uid();
$$;

-- Profiles
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
-- insert is via trigger (security definer); no client insert needed

-- Generic owner CRUD for first-class user tables
create policy habits_all_own on public.habits
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy habit_schedules_all_own on public.habit_schedules
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );

create policy habit_subtasks_all_own on public.habit_subtasks
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );

create policy habit_completions_all_own on public.habit_completions
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );

create policy habit_subtask_completions_all_own on public.habit_subtask_completions
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
    and exists (select 1 from public.habit_subtasks s where s.id = subtask_id and s.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
    and exists (select 1 from public.habit_subtasks s where s.id = subtask_id and s.user_id = auth.uid())
  );

create policy habit_events_select_own on public.habit_events
  for select to authenticated using (user_id = auth.uid());
create policy habit_events_insert_own on public.habit_events
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );
-- no client update/delete on events (history integrity)

create policy routines_all_own on public.routines
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy routine_habits_all_own on public.routine_habits
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.routines r where r.id = routine_id and r.user_id = auth.uid())
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.routines r where r.id = routine_id and r.user_id = auth.uid())
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );

create policy goals_all_own on public.goals
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy goal_habits_all_own on public.goal_habits
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
    and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid())
  );

create policy goal_routines_all_own on public.goal_routines
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
    and exists (select 1 from public.routines r where r.id = routine_id and r.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
    and exists (select 1 from public.routines r where r.id = routine_id and r.user_id = auth.uid())
  );

create policy goal_milestones_all_own on public.goal_milestones
  for all to authenticated
  using (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
  )
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
  );

create policy mood_checkins_all_own on public.mood_checkins
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy gratitude_entries_all_own on public.gratitude_entries
  for all to authenticated
  using (
    user_id = auth.uid()
    and (
      mood_checkin_id is null
      or exists (
        select 1 from public.mood_checkins m
        where m.id = mood_checkin_id and m.user_id = auth.uid()
      )
    )
  )
  with check (
    user_id = auth.uid()
    and (
      mood_checkin_id is null
      or exists (
        select 1 from public.mood_checkins m
        where m.id = mood_checkin_id and m.user_id = auth.uid()
      )
    )
  );

-- Day scores + Q: clients read; writes are service_role (VPS).
create policy day_scores_select_own on public.day_scores
  for select to authenticated using (user_id = auth.uid());

create policy q_interactions_select_own on public.q_interactions
  for select to authenticated using (user_id = auth.uid());

create policy q_evidence_select_own on public.q_evidence
  for select to authenticated using (user_id = auth.uid());

create policy q_recommendations_select_own on public.q_recommendations
  for select to authenticated using (user_id = auth.uid());

-- Client may accept/reject a recommendation they own. Cannot mint new ones.
create policy q_recommendations_update_status_own on public.q_recommendations
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and status in ('shown', 'accepted', 'rejected', 'applied', 'expired', 'evaluated')
  );

-- -----------------------------------------------------------------------------
-- Grants
-- anon: nothing on user tables
-- authenticated: as RLS allows
-- service_role: full (bypasses RLS) — VPS only
-- -----------------------------------------------------------------------------

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

grant usage on schema public to authenticated, service_role;

grant select, insert, update, delete on
  public.profiles,
  public.habits,
  public.habit_schedules,
  public.habit_subtasks,
  public.habit_completions,
  public.habit_subtask_completions,
  public.routines,
  public.routine_habits,
  public.goals,
  public.goal_habits,
  public.goal_routines,
  public.goal_milestones,
  public.mood_checkins,
  public.gratitude_entries
to authenticated;

grant select, insert on public.habit_events to authenticated;

grant select on
  public.day_scores,
  public.q_interactions,
  public.q_evidence,
  public.q_recommendations
to authenticated;

grant update (status, accepted_at, rejected_at, applied_at, outcome_evaluated_at)
  on public.q_recommendations to authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
