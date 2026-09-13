-- =============================================================================
-- HabitX 0002 — security hardening (safe to run AFTER 0001_init.sql)
-- Idempotent. Does not drop tables or user data.
--
-- If you already applied 0001, run THIS file in the SQL Editor.
-- Do not re-run 0001 (it is a one-time create).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 11–12. Functions: safe search_path; revoke PUBLIC execute
-- handle_new_user remains the only SECURITY DEFINER (signup profile insert).
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.is_own(_user_id uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select _user_id = auth.uid();
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
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
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.is_own(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.is_own(uuid) to authenticated, service_role;
-- Trigger functions run as table owner; PUBLIC execute is revoked.

-- Subtask completion habit_id must match the subtask's habit (integrity).
create or replace function public.enforce_subtask_habit_match()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.habit_subtasks s
    where s.id = new.subtask_id
      and s.habit_id = new.habit_id
      and s.user_id = new.user_id
  ) then
    raise exception 'habit_subtask_completions.habit_id must match habit_subtasks';
  end if;
  return new;
end;
$$;

drop trigger if exists habit_subtask_completions_habit_match on public.habit_subtask_completions;
create trigger habit_subtask_completions_habit_match
before insert or update on public.habit_subtask_completions
for each row execute function public.enforce_subtask_habit_match();

revoke all on function public.enforce_subtask_habit_match() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1. Force RLS so table-owner sessions still apply policies
--    (service_role keeps BYPASSRLS)
-- -----------------------------------------------------------------------------

alter table public.profiles force row level security;
alter table public.habits force row level security;
alter table public.habit_schedules force row level security;
alter table public.habit_subtasks force row level security;
alter table public.habit_completions force row level security;
alter table public.habit_subtask_completions force row level security;
alter table public.habit_events force row level security;
alter table public.routines force row level security;
alter table public.routine_habits force row level security;
alter table public.goals force row level security;
alter table public.goal_habits force row level security;
alter table public.goal_routines force row level security;
alter table public.goal_milestones force row level security;
alter table public.mood_checkins force row level security;
alter table public.gratitude_entries force row level security;
alter table public.day_scores force row level security;
alter table public.q_interactions force row level security;
alter table public.q_evidence force row level security;
alter table public.q_recommendations force row level security;

-- -----------------------------------------------------------------------------
-- 9. Tighten recommendation updates: client may only accept/reject
-- -----------------------------------------------------------------------------

drop policy if exists q_recommendations_update_status_own on public.q_recommendations;
create policy q_recommendations_update_status_own on public.q_recommendations
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and status in ('accepted', 'rejected')
  );

-- -----------------------------------------------------------------------------
-- 2–3, 13. Exact grants. anon: none. No default auto-expose.
-- -----------------------------------------------------------------------------

revoke usage on schema public from anon;
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on tables from public;
alter default privileges in schema public revoke all on sequences from public;
alter default privileges in schema public revoke all on functions from public;

revoke all on all tables in schema public from authenticated;
revoke all on all sequences in schema public from authenticated;

grant usage on schema public to authenticated, service_role;

-- profiles: read/update own only (insert via signup trigger)
grant select, update on public.profiles to authenticated;

grant select, insert, update, delete on
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

grant update (status, accepted_at, rejected_at)
  on public.q_recommendations to authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;

alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
