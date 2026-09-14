-- =============================================================================
-- HabitX 0003 — journal_entries (synced, private; not used by Q)
-- Idempotent-ish create. Apply in Supabase SQL Editor after 0001 + 0002.
--
-- Product rule:
--   Journals sync so history survives a new phone.
--   Encrypted in transit/at rest by Supabase.
--   Not sent to Q / Claude. Staff do not browse journals for product features.
-- =============================================================================

create table if not exists public.journal_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  local_day   date,
  text        text not null,
  at          timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint journal_entries_text_len check (char_length(text) between 1 and 20000)
);

create index if not exists journal_entries_user_at_idx
  on public.journal_entries (user_id, at desc);
create index if not exists journal_entries_user_day_idx
  on public.journal_entries (user_id, local_day);

drop trigger if exists journal_entries_set_updated_at on public.journal_entries;
create trigger journal_entries_set_updated_at
before update on public.journal_entries
for each row execute function public.set_updated_at();

alter table public.journal_entries enable row level security;
alter table public.journal_entries force row level security;

drop policy if exists journal_entries_all_own on public.journal_entries;
create policy journal_entries_all_own on public.journal_entries
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.journal_entries to authenticated;
grant all on public.journal_entries to service_role;

comment on table public.journal_entries is
  'Synced private journal. Owner RLS only. Do not include in Q/QLE context or Anthropic prompts.';
