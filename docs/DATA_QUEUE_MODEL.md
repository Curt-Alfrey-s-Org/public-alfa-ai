# Data and Queue Model

## Overview

ALFa AI uses:

- **Postgres** for durable execution state.
- **Redis** for asynchronous job queueing and short-lived coordination.

## Postgres Schema

Core tables:

1. `runs`
   - one row per top-level user request
2. `tasks`
   - DAG nodes linked to `runs`
3. `task_dependencies`
   - edges between tasks
4. `artifacts`
   - immutable outputs from tasks
5. `task_attempts`
   - per-attempt execution metadata
6. `events`
   - append-only timeline for observability/audit

### Suggested DDL

See `infra/db/schema.sql` for executable SQL baseline.

## Redis Queue Model

Queue namespace:

- `alfaai:queue:tasks` (pending jobs list/stream)
- `alfaai:queue:inflight` (claimed jobs)
- `alfaai:queue:retry` (delayed retry schedule)

Worker flow:

1. Poll pending queue.
2. Claim job atomically (move to inflight with lease).
3. Execute role task.
4. Persist outcome in Postgres.
5. Ack success or schedule retry.

## Job Payload Contract

```json
{
  "job_id": "uuid",
  "run_id": "uuid",
  "task_id": "uuid",
  "role": "coder",
  "attempt": 1,
  "enqueued_at": "2026-03-03T00:00:00Z"
}
```

## Idempotency and Consistency

- Workers must be idempotent by `(task_id, attempt)`.
- Writes should be transactional: task attempt + status update + events.
- Retry decisions use failure taxonomy (`timeout`, `provider_error`, etc.).
- Stale inflight jobs are requeued after lease expiration.

## Retention

- `events`: 30-90 days in hot storage, archive after.
- `task_attempts`: keep full history for evaluation.
- `artifacts`: keep immutable metadata; large file payloads can move to object storage later.

