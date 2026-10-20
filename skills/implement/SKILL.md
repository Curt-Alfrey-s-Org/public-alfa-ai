---
name: implement
description: Implement a coding goal with minimal, focused changes.
when-to-use: coder role or skill=implement
---

# Implement

## Rules

- Read before writing: grep and read relevant files first.
- Prefer `edit_file` for changes to existing files; use `create_file` only for new files.
- One logical change set per mission; avoid drive-by refactors.
- Do not run destructive shell commands.

## Output

Final answer must list:

1. **Files changed** — path and one-line summary per file
2. **Testing** — what you ran or what the operator should run
3. **Risks** — anything uncertain or left for human review