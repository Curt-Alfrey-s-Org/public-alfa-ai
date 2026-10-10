# Agent file runs (contracts-bot orchestrator path)

HTTP API for stateful agent runs that read uploaded documents and write output files
inside the brain workspace sandbox (`ALFA_AI_WORKSPACE_ROOT`, default `/workspace` in
Docker).

**Consumer:** contracts-bot on `apps` calls this API server-to-server. See
contracts-bot `docs/ALFA_AI_BOUNDARY.md`.

**Official references:**

- FastAPI file responses: https://fastapi.tiangolo.com/advanced/custom-response/
- Workspace sandbox: [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md) Safety Baseline

## Endpoints

| Method | Path | Auth |
|--------|------|------|
| `POST` | `/api/runs` | Bearer `ALFA_AI_API_TOKEN` when `ALFA_AI_REQUIRE_API_AUTH=true` |
| `GET` | `/api/runs/{run_id}` | same |
| `GET` | `/api/runs/{run_id}/artifacts/{artifact_id}/content` | same |

Brain operator console: `http://hub` (LAN + UFW per
[PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md)).

## Create a contracts file run

```json
POST /api/runs
{
  "goal": "Analyze this solicitation and draft a capability statement outline",
  "role": "contracts",
  "input_files": [
    {
      "filename": "solicitation.txt",
      "content": "Section L: Offerors shall..."
    }
  ]
}
```

Response: `{"run_id": "<uuid>"}`.

The API materializes each input file under `runs/{run_id}/input/` **before** the task
is queued so the background worker never races an empty input folder.

## Poll run status

```json
GET /api/runs/{run_id}
{
  "ok": true,
  "run": {"run_id": "...", "status": "done", "goal": "..."},
  "tasks": [...],
  "artifacts": [
    {
      "artifact_id": "...",
      "artifact_type": "contract_deliverable",
      "path": ".alfa_ai/artifacts/{run_id}/{task_id}/analysis.md"
    }
  ]
}
```

Run `status` values: `running`, `done`, `failed`.

## Download artifact content

```json
GET /api/runs/{run_id}/artifacts/{artifact_id}/content
{
  "ok": true,
  "artifact_id": "...",
  "path": ".alfa_ai/artifacts/.../analysis.md",
  "content": "# Analysis\n..."
}
```

## Workspace layout

| Path | Purpose |
|------|---------|
| `runs/{run_id}/input/` | Input documents (written by API from `input_files`) |
| `.alfa_ai/artifacts/{run_id}/{task_id}/` | Agent-written deliverables |

All paths are relative to `ALFA_AI_WORKSPACE_ROOT`. Tool sandbox rules in
`src/agent/tools.py` prevent path traversal outside the workspace.

## Limits (env)

| Variable | Default | Meaning |
|----------|---------|---------|
| `ALFA_AI_RUN_INPUT_MAX_FILE_CHARS` | `200000` | Max UTF-8 chars per uploaded file |
| `ALFA_AI_RUN_INPUT_MAX_FILES` | `10` | Max files per run |

Oversized or invalid filenames return HTTP `400` from `POST /api/runs`.

## Background worker

Runs are processed by `alfa-ai-worker` (`docker compose --profile agent-worker up -d`).
Without the worker, runs stay `running` until something calls `POST /api/runs/process-next`
(operator console) or the worker is started.

## Retention (operator follow-up)

Input and artifact directories accumulate on the `alfa-ai-workspace` Docker volume.
Automated pruning is **not** implemented in this phase. Operators may periodically remove
old `runs/*` and `.alfa_ai/artifacts/*` trees on the brain host.

*Last updated: 2026-07-05*
