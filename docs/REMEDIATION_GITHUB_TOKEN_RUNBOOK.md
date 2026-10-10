# Remediation GitHub token rotation

Fine-scoped PAT for `ALFA_AI_REMEDIATION_GITHUB_TOKEN` (PR-only apply path).

**Authority:** [GitHub fine-grained PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token)

## Scope (minimum)

| Repository | Permissions |
|------------|-------------|
| `alfa-ai` | Contents: Read and write; Pull requests: Read and write |
| `monitoring` | Contents: Read and write; Pull requests: Read and write |

No `admin`, `workflow`, or org-wide access. Token used only inside `alfa-ai-api` container.

## Rotation runbook

**Step 1 -- GitHub:** create new fine-grained PAT with scopes above; note expiry.

**Step 2 -- From `hub` (operator):** update brain `deploy/.env`:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
```

Edit `ALFA_AI_REMEDIATION_GITHUB_TOKEN=<new>` (file is operator-owned, not in git).

**Step 3 -- From `hub` (operator):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && docker compose up -d --force-recreate alfa-ai-api
```

**Step 4 -- Verify:** admin Monitoring tab → analyze a test incident → Apply only if
`ALFA_AI_REMEDIATION_ENABLED=true`; confirm PR opens on feature branch (never `main`).

**Step 5 -- GitHub:** revoke old PAT after verify.

## Related

- [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md)
- [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md)
