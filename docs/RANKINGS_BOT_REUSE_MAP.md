# Rankings-Bot module reuse map for ALFa AI

This map focuses on high-value backend modules from `rankings-bot` that help ALFa AI become a stronger self-hosted coding assistant platform, not just a UI.

## Priority 1 (Week 1)

1. `rankings-bot/api/services/cache_store.py`
   - Reuse for LLM/tool result caching with stale fallback.
   - ALFa AI target: `src/platform/cache_store.py`
   - Effort: low

2. `rankings-bot/api/services/circuit_breaker.py`
   - Reuse for provider-call reliability.
   - ALFa AI target: `src/platform/circuit_breaker.py`
   - Effort: low

3. `rankings-bot/api/services/background_supervisor.py`
   - Reuse for robust worker supervision and retry backoff.
   - ALFa AI target: `src/platform/background_supervisor.py`
   - Effort: low

4. `rankings-bot/api/middleware/request_id.py`
   - Reuse for request correlation and traceability.
   - ALFa AI target: `src/api/middleware/request_id.py`
   - Effort: low

5. `rankings-bot/database/__init__.py`
   - Reuse session/engine pattern for API + worker DB consistency.
   - ALFa AI target: `src/platform/database.py`
   - Effort: low

## Priority 2 (Week 2)

6. `rankings-bot/api/services/health_check.py`
   - Adapt to report DB, Redis, queue, and worker state.
   - ALFa AI target: `src/api/health_checks.py`
   - Effort: medium

7. `rankings-bot/run_comprehensive_tests.py`
   - Adapt into ALFa AI quality gate runner for role workflows.
   - ALFa AI target: `scripts/run_quality_gates.py`
   - Effort: medium

8. `rankings-bot/api/routes/docs.py`
   - Adapt to expose generated operational docs from runtime artifacts.
   - ALFa AI target: `src/api/routes/docs.py`
   - Effort: medium

## Later / Selective Reuse

9. `rankings-bot/api/auth.py`
   - Reuse JWT, password hashing, role guard patterns.
   - Effort: medium (role model alignment needed)

10. `rankings-bot/api/routes/auth.py`
    - Reuse lockout and audit-flow ideas.
    - Effort: high (strong coupling to rankings DB models)

11. `rankings-bot/database/postgres_manager.py`
    - Mine for patterns only; avoid direct copy due to domain coupling.
    - Effort: high

12. `rankings-bot/scripts/full_deploy.sh`
    - Borrow deployment validation steps, not exact script.
    - Effort: high

## Suggested Extraction Order

1. Reliability layer: cache + circuit breaker + background supervisor
2. API observability: request id middleware + error envelope + detailed health
3. Auth and docs routes
4. Full CI quality gate orchestration

