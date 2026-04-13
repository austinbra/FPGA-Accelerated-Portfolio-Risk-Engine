# Cursor workspace (`.cursor/`)

This folder holds **Cursor-specific** configuration. It is separate from RTL and from your project-facing notes in [`.user/`](../.user/README.md).

## What lives where

| Path | Purpose |
|------|---------|
| [`.cursor/rules/`](rules/) | **Project rules** for the AI: identity, workflows, lessons learned, session handoff. Cursor loads these according to each file’s frontmatter (`alwaysApply`, `globs`, etc.). |
| [`.user/`](../.user/README.md) | **Your** status, roadmap, and validation notes (implementation snapshot, what to run next). |

Do not move rule files out of `rules/` unless you confirm Cursor still picks them up from a new path—**`.cursor/rules/`** is the usual layout.

## Rule files in `rules/` (quick map)

| File | Role |
|------|------|
| `rules.md` | Permanent project identity, architecture, file map, design principles. |
| `primer.md` | Short session handoff (what just finished, what’s next). |
| `hindsight.md` | Behavioral lessons from past bugs (append-only). |
| `log.md` | Long validation / incident history (append-only). |
| `obsidian_sync.md` | When to mirror substantive work to your Obsidian vault. |
| `verification_after_every_change.md` | Verification expectations after edits. |
| `token_budget.mdc` | Token / tool-use efficiency for agents in this workspace. |

To change **when** a rule applies, edit the YAML frontmatter at the top of that file (especially `globs` and `alwaysApply`).

## For collaborators

- **“Where is the project at?”** → [`.user/IMPLEMENTATION_STATUS.md`](../.user/IMPLEMENTATION_STATUS.md)  
- **“What should we do next?”** → [`.user/ROADMAP.md`](../.user/ROADMAP.md)  
- **“How do we verify?”** → [`.user/VALIDATION.md`](../.user/VALIDATION.md)
