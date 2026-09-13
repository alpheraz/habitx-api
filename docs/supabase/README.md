# HabitX Supabase — production schema

Canonical migration: [`0001_init.sql`](./0001_init.sql)

## Apply (Phase 1)

1. Create a Supabase project (US or closest region).
2. Authentication → Providers → **Sign in with Apple** (later; not required to apply SQL).
3. SQL Editor → paste `0001_init.sql` → Run.
4. Confirm tables exist under Table Editor.

Do **not** apply this to Clawbot or the in-memory habitx-api store.

## Credentials

| Who | Values | Where |
|-----|--------|--------|
| iOS | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | Xcode xcconfig / Info (public) |
| VPS | `SUPABASE_URL`, `SUPABASE_SECRET_KEY` (service role) | `/home/alpheraz/habitx-api/.env` `chmod 600` |

Never put the service role key in Swift, Git, or Claude prompts.

## What clients can do vs VPS

| Table | iOS (RLS) | VPS service role |
|-------|-----------|------------------|
| profiles, habits, schedules, subtasks, completions, routines, goals, milestones, mood, gratitude | CRUD own rows | Full |
| habit_events | insert + select own | Full |
| day_scores | **select only** | compute + upsert |
| q_interactions, q_evidence | **select only** | write |
| q_recommendations | select + update status | create |

## Next (do not do in this file)

Phase 2: supabase-swift + SIWA + repositories  
Phase 3: domain verification  
Phase 4: VPS JWT verify + Q  
Phase 5: A/B isolation tests  
