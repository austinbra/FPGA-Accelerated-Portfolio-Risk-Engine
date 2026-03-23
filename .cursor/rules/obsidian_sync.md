---
description: Keep project Obsidian notes in sync after substantive implementation changes.
globs: ["**/*.sv", "**/*.py", "**/*.ps1", "**/*.tcl", "**/*.md"]
alwaysApply: true
---

# Obsidian Vault Sync Rule

After any substantial implementation change or completed phase:

1. Update the project Obsidian vault notes in the same working session.
2. Include:
   - what changed,
   - verification commands and outcomes,
   - next planned step.
3. If a phase checkpoint commit is created, also mirror the commit hash and message in the vault note.

If the vault path is not configured or cannot be found, ask the user for the exact vault path before finishing.
