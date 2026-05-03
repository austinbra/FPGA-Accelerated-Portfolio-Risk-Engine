# User Memory Index

This folder is repo-local project memory for the forked portfolio risk engine.

Root `README.md` and `PROJECT_REPORT.md` now present the fork as a hardware-accelerated portfolio/scenario/Greeks project built on the completed FPGA QMC-LSM option pricing kernel.

Recommended reading order:

1. [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) - what exists now and what is still product-scope work.
2. [`ROADMAP.md`](ROADMAP.md) - next implementation phases for portfolio pricing, scenarios, Greeks, and richer payoffs.
3. [`FUTURE_PROJECT.md`](FUTURE_PROJECT.md) - larger product identity and scope guardrails.
4. [`VALIDATION.md`](VALIDATION.md) - gates that keep the inherited kernel trustworthy.
5. [`ACCURACY.md`](ACCURACY.md) - bps accuracy methodology and product accuracy policy.
6. [`FPGA_BUILD.md`](FPGA_BUILD.md) - Vivado build and hardware run notes.
7. [`OBSIDIAN_HANDOFF.md`](OBSIDIAN_HANDOFF.md) - copy-paste summary for external notes.

Private scratch can be kept as `.user/ROADMAP_PRIVATE.md` if needed; it is gitignored and not part of the active project docs.

Current rule of thumb:

- Root docs: fork identity and inherited FPGA kernel foundation.
- `.user`: project memory, roadmap, validation, and product scope.
- `.ai`: AI/session handoff and behavioral rules.
