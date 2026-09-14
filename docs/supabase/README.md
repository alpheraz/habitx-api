# HabitX Supabase — production schema

Canonical migration: [`0001_init.sql`](./0001_init.sql)

## Apply

1. Create a Supabase project.
2. SQL Editor → run [`0001_init.sql`](./0001_init.sql) **once**.
3. SQL Editor → run [`0002_security_hardening.sql`](./0002_security_hardening.sql) (idempotent; required if 0001 already ran).
4. SQL Editor → run [`0003_journal_entries.sql`](./0003_journal_entries.sql) (synced private journals; excluded from Q).
5. Confirm tables exist under Table Editor.

Do **not** re-run 0001 after tables exist. Do **not** apply this to Clawbot.

## Credentials

| Who | Values | Where |
|-----|--------|--------|
| iOS | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | Xcode xcconfig / Info (public) |
| VPS | `SUPABASE_URL`, `SUPABASE_SECRET_KEY` (service role) | `/home/alpheraz/habitx-api/.env` `chmod 600` |

Never put the service role key in Swift, Git, or Claude prompts.

## What clients can do vs VPS

| Table | iOS (RLS) | VPS service role |
|-------|-----------|------------------|
| profiles, habits, schedules, subtasks, completions, routines, goals, milestones, mood, gratitude, journal | CRUD own rows | Full (journals never fed to Q) |
| habit_events | insert + select own | Full |
| day_scores | **select only** | compute + upsert |
| q_interactions, q_evidence | **select only** | write |
| q_recommendations | select + update status | create |

## Next (do not do in this file)

Phase 2: supabase-swift + SIWA + repositories  
Phase 3: domain verification  
Phase 4: VPS JWT verify + Q — shipped in habitx-api (`POST /api/habitx/v1/q/ask`)  
Phase 5: A/B isolation tests  
