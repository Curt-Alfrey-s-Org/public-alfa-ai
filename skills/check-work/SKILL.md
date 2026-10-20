---
name: check-work
description: Verify implementation against goal with build/test checks.
when-to-use: debugger role or post-implement verification
---

# Check work

## Rules

- Confirm the stated goal was addressed using repo evidence.
- Run safe verification commands (`python -m pytest`, linters) when appropriate.
- End with exactly `VERDICT: PASS` or `VERDICT: FAIL` on its own line.

## On FAIL

List concrete gaps and the command output that proves the failure.