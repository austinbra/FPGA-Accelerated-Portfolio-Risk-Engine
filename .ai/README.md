# AI Workspace

This folder is repo-local AI/session memory. It replaces the old `.cursor` directory name so the guidance is editor-neutral.

It is separate from the public root documentation and the user's `.user` project notes.

## Current Handoff

This fork is now the FPGA QMC-LSM portfolio risk engine project.

The inherited FPGA option-pricing kernel is complete and stable:

- `README.md`
- `PROJECT_REPORT.md`
- `.user/IMPLEMENTATION_STATUS.md`
- `.user/VALIDATION.md`

Future sessions should start from:

- `.user/ROADMAP.md`
- `.user/FUTURE_PROJECT.md`
- `.ai/rules/primer.md`

The next work is portfolio/scenario/Greeks product infrastructure, not more vanilla-kernel polish unless validation breaks.

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

- Root docs: fork identity and inherited kernel foundation.
- `.user`: project memory, roadmap, validation, and product scope.
- `.ai`: AI/session operating memory.

Do not move project-facing validation docs into `.ai`; keep them in `.user`.
