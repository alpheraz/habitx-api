# Habit X API (`habitx-api`)

Public application API / BFF for Habit X (online-first).

| Item | Value |
|------|--------|
| Path | `/home/alpheraz/habitx-api` |
| Port | `4600` (bind `127.0.0.1`) |
| Contract | [`openapi/habitx-v1.yaml`](./openapi/habitx-v1.yaml) |
| Status | **PARTIAL** — OpenAPI LIVE; domain handlers not implemented yet |

## Boundaries

- iOS talks **only** to this API (never Clawbot `:4500`).
- Clawbot is used later for intelligence (weekly review), not CRUD.
- Postgres is the intended product DB (not installed on VPS yet).

## Run

```bash
cd /home/alpheraz/habitx-api
cp .env.example .env
npm install
npm run start
curl -s http://127.0.0.1:4600/health
curl -s http://127.0.0.1:4600/openapi/habitx-v1.yaml | head
```

## iOS sync point

Mac generates DTOs + `LiveHabitRepository` from `openapi/habitx-v1.yaml`.
Keep `MockHabitRepository` until HABIT CORE is wired end-to-end.
