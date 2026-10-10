# ALFa AI architecture and role contracts

## Purpose

ALFa AI is a self-hosted coding assistant platform designed to evolve from one reliable agent into a set of collaborating specialist roles:

- `coder`
- `debugger`
- `doc_maker`
- `researcher`

The orchestrator owns planning, execution budgets, persistence, and safety controls.

## System Components

1. **Orchestrator (FastAPI/CLI host)**
   - Receives user goals.
   - Creates and tracks runs.
   - Breaks a goal into tasks.
   - Assigns tasks to specialist roles.
2. **Planner**
   - Produces a task graph for a run.
   - Selects role assignments for each task.
3. **Role Workers**
   - Execute scoped work based on a strict contract.
   - Return artifacts and structured status.
4. **Tool Executor**
   - Executes approved filesystem and shell tools.
   - Enforces workspace sandbox and command policy.
5. **Storage**
   - Postgres for durable run/task/artifact records.
   - Redis for queueing and ephemeral coordination.

## Role Contract (shared schema)

All roles follow a normalized request/response contract.

### RoleRequest

- `run_id: str`
- `task_id: str`
- `role: str`
- `goal: str`
- `inputs: dict[str, object]`
- `context: dict[str, object]`
- `constraints: dict[str, object]`
- `budget: dict[str, object]` (step/token/time limits)

### RoleResponse

- `status: "success" | "needs_input" | "blocked" | "failed"`
- `summary: str`
- `artifacts: list[ArtifactRef]`
- `tool_events: list[ToolEvent]`
- `metrics: dict[str, object]`
- `next_actions: list[str]`

### ArtifactRef

- `artifact_id: str`
- `artifact_type: str` (`code`, `doc`, `test`, `research_note`, etc.)
- `path: str`
- `sha256: str`
- `metadata: dict[str, object]`

### ToolEvent

- `tool_name: str`
- `ok: bool`
- `started_at: str`
- `duration_ms: int`
- `details: dict[str, object]`

## Role Responsibilities

### coder
- Produces or updates code and tests.
- Must provide implementation notes and touched paths.

### debugger
- Reproduces failures, isolates root cause, and proposes minimal fixes.
- Must provide reproduction steps and confidence.

### doc_maker
- Generates technical docs, runbooks, and API descriptions from artifacts.
- Must cite source artifacts used.

### researcher
- Gathers external/internal references, compares options, and produces recommendations.
- Must provide assumptions and decision criteria.
- **v1 implementation:** runs the agent tool loop (`grep_repo`, `glob_files`, `fetch_url`,
  `read_file`) via [`src/agent/loop.py`](../src/agent/loop.py); writes `research.md`
  artifact with cited repo paths and allowlisted vendor-doc URLs.
- **Model:** `ALFA_AI_AGENT_MODEL` (default `frontier-code`, 27B RPC) with one-step
  fallback to `ALFA_AI_AGENT_FALLBACK_MODEL` (`agent`, 35B MoE) on retryable LLM errors.
- **Operator-only:** not wired to guest chat. See [AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md).

### contracts
- Federal contracting document analysis for **contracts-bot** (HTTP consumer on `apps`).
- Reads uploaded input files from `runs/{run_id}/input/` inside the workspace sandbox.
- Writes one or more deliverables under `.alfa_ai/artifacts/{run_id}/{task_id}/` using
  `list_dir`, `read_file`, and `create_file` (no `run_cmd`).
- **Trigger:** `POST /api/runs` with `role=contracts` and `input_files[]` (see
  [AGENT_FILE_RUNS.md](AGENT_FILE_RUNS.md)).
- **Model:** same agent model pair as researcher/coder (`ALFA_AI_AGENT_MODEL`).

## Orchestration Rules

- Every task is role-owned by exactly one primary role.
- Cross-role handoff must reference artifact IDs, not raw copies.
- Retries are bounded by run budget.
- Tool execution is always mediated by Tool Executor.
- Unsafe tool requests are rejected with a policy reason.

## Safety Baseline

- Filesystem access limited to configured workspace root.
- Destructive shell commands are blocked by policy.
- Command execution has strict timeout.
- Secrets are read from environment only; never persisted in artifacts.

## Agent and operator workflow

Cursor agents and operators follow the rule stack in
**[`.cursor/rules/RULES.md`](../.cursor/rules/RULES.md)**:

1. **Official vendor docs online** define correct tool/API behavior (RULE #1).
2. **Repo `docs/` are updated before code**; code must match docs after every change (RULE #2).
3. **Multi-host changes** — Edit, commit, and push on the **host that owns the clone**; then pull every other consumer; hub on `hub` before workers; deploy in topology order ([`git-per-host-clone.mdc`](../.cursor/rules/git-per-host-clone.mdc), [`cluster-sync-order.mdc`](../.cursor/rules/cluster-sync-order.mdc)).

Cluster topology and ports in this doc and [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) are authoritative for *layout*; vendor manuals are authoritative for *implementation*.
