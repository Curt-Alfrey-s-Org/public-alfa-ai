# Evaluation Framework

## Goal

Measure whether ALFa AI roles produce reliable outputs and improve over time without regressions.

## Benchmark Suites

### coder suite
- Implement feature from spec.
- Refactor module with tests preserved.
- Add API endpoint + tests.

Metrics:

- `build_pass_rate`
- `test_pass_rate`
- `lint_pass_rate`
- `time_to_complete_seconds`

### debugger suite
- Fix deterministic failing test.
- Resolve runtime exception from stack trace.
- Correct performance regression with measurable improvement.

Metrics:

- `bug_fix_success_rate`
- `reproduction_accuracy_rate`
- `mean_attempts_to_fix`
- `post_fix_regression_rate`

### doc_maker suite
- Generate README from codebase snapshot.
- Produce API reference from routes.
- Create troubleshooting runbook from incident log.

Metrics:

- `coverage_score` (required sections present)
- `factual_consistency_score`
- `citation_ratio` (claims tied to artifacts)
- `readability_score`

### researcher suite
- Compare technical options under constraints.
- Produce decision memo with assumptions.
- Gather migration risks and mitigation steps.

Metrics:

- `source_relevance_score`
- `decision_quality_score`
- `assumption_clarity_score`
- `recommendation_accept_rate`

## Cross-Role Metrics

- `end_to_end_task_success_rate`
- `artifact_reuse_rate`
- `handoff_failure_rate`
- `cost_per_successful_run`
- `p95_run_latency_seconds`

## Quality Gates

Release is blocked if any critical threshold fails:

- coder `test_pass_rate < 0.95`
- debugger `bug_fix_success_rate < 0.80`
- doc_maker `factual_consistency_score < 0.90`
- researcher `decision_quality_score < 0.85`
- cross-role `end_to_end_task_success_rate < 0.75`

## Evaluation Dataset Strategy

- Keep a fixed gold set for comparability.
- Add a rolling set of recent real-world tasks.
- Tag tasks by language, framework, and difficulty.
- Version datasets and prompts for reproducibility.

## Reporting

Each evaluation run stores:

- git revision / release tag
- prompt/profile version
- per-task metrics
- aggregate metrics
- pass/fail gate decision

## Learning-loop integration (Priority #7)

Offline **eval smoke** (≥10 gold tasks) is Phase **L0.6** of
[.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).
Judge calibration set (20 labeled samples) is Phase **L1.7**. Promotion of any
trained adapter (alfa-train) requires win rate against this framework’s gates
before LiteLLM route changes.

