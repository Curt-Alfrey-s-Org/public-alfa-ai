# Collaboration Runtime Specification

## Goal

Define how specialized programs (`coder`, `debugger`, `doc_maker`, `researcher`) coordinate through one orchestrator to produce compound outcomes.

## Task Graph Model

Each run is a directed acyclic graph (DAG) of tasks.

- **Run**: top-level objective and shared budget.
- **Task**: smallest schedulable unit owned by one role.
- **Edge**: dependency where downstream task consumes upstream artifacts.

Task states:

- `pending`
- `ready`
- `running`
- `blocked`
- `done`
- `failed`
- `cancelled`

## Handoff Protocol

Handoffs are artifact-based and typed.

1. Producer role completes task and emits `artifacts`.
2. Orchestrator records artifact metadata and updates task status.
3. Dependent task becomes `ready` when all required artifact types are present.
4. Consumer role receives only:
   - explicit artifact references
   - summarized context
   - budget and constraints

Rules:

- No direct role-to-role mutable state.
- No raw secret propagation in handoff payloads.
- Every handoff includes `producer_task_id` and `artifact_id`.

## Artifact Model

Artifact types:

- `code_patch`
- `source_file`
- `test_result`
- `debug_report`
- `doc_page`
- `research_note`
- `decision_record`

Required metadata fields:

- `artifact_id`
- `run_id`
- `task_id`
- `artifact_type`
- `path`
- `sha256`
- `created_at`
- `summary`

Optional metadata fields:

- `language`
- `framework`
- `quality_signals` (lint, tests, static checks)
- `references` (URLs or internal docs)

## Planner and Reviewer Behavior

- **Planner**
  - Converts user goal to DAG.
  - Assigns primary role per task.
  - Defines acceptance checks per task.
- **Reviewer**
  - Validates output against acceptance checks.
  - Requests targeted retries if checks fail.
  - Escalates to user when confidence remains low.

## Retry and Budget Policy

Run budget includes:

- `max_steps`
- `max_wall_clock_seconds`
- `max_llm_tokens` (estimated)
- `max_retries_per_task`

Default runtime policy:

- max retries per task: `2`
- backoff: linear (`5s`, `10s`)
- repeated identical failure -> mark task `blocked`

## Failure Taxonomy

- `tool_policy_violation`
- `tool_execution_error`
- `validation_failure`
- `dependency_missing`
- `provider_error`
- `timeout`

This taxonomy is stored with every failed attempt for analytics and evaluation.

