---
description: Keep project Obsidian notes in sync after substantive implementation changes.
globs: ["**/*.sv", "**/*.py", "**/*.ps1", "**/*.tcl", "**/*.md"]
alwaysApply: true
---

# Obsidian Vault Sync Rule

Vault location: `%USERPROFILE%\Documents\Obsidian`.

For this repo, long-form notes live under `Documents\Obsidian\Options-Pricer-vault\` unless the user gives a different active vault.

After any substantial implementation change or completed phase:

1. Open `.user/OBSIDIAN_HANDOFF.md`; it holds a copy-paste block with dated checkpoint, learnings, next steps, and commands.
2. Update the project Obsidian vault notes in the same working session.
3. Include what changed, verification commands and outcomes, and next planned step.
4. If a phase checkpoint commit is created, also mirror the commit hash and message in the vault note.

If that folder does not exist or is not the active vault, ask the user for the exact path before finishing.
