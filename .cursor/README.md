# Cursor Workspace

This folder is AI/session memory. It is separate from the public root documentation and the user's `.user` project notes.

## Current Handoff

The FPGA QMC-LSM thesis kernel is complete. Root docs should be treated as the finished artifact:

- `README.md`
- `PROJECT_REPORT.md`

Future sessions should start from:

- `.user/FUTURE_PROJECT.md`
- `.user/ROADMAP.md`
- `.cursor/rules/primer.md`

The next work is the portfolio/scenario/Greeks product story, not more vanilla kernel polish unless validation breaks.

## Rule Files

| File | Purpose |
|------|---------|
| `rules/rules.md` | Permanent architecture, constraints, and project behavior |
| `rules/primer.md` | Current session handoff |
| `rules/hindsight.md` | Lessons learned from bugs and implementation traps |
| `rules/log.md` | Long validation/incidence history |
| `rules/obsidian_sync.md` | External note sync reminder |
| `rules/verification_after_every_change.md` | Required verification behavior |
| `rules/token_budget.mdc` | Agent efficiency guidance |

## Documentation Split

- Root docs: completed thesis artifact.
- `.user`: private continuation memory and roadmap.
- `.cursor`: AI operating memory.

Do not move project-facing validation docs into `.cursor`; keep them in `.user`.
