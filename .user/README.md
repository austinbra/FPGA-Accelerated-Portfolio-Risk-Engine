# User Memory Index

This folder is repo-local project memory for the forked portfolio risk engine.

Root `README.md` and `PROJECT_REPORT.md` now present the fork as a hardware-accelerated portfolio/scenario/Greeks project built on the completed FPGA QMC-LSM option pricing kernel.

Recommended reading order:

1. [`PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md`](PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md) - learning-first implementation manual with exercises, gates, examples, and AI-use boundaries.
2. [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) - what exists now and what is still product-scope work.
3. [`ROADMAP.md`](ROADMAP.md) - concise implementation phases for portfolio pricing, scenarios, Greeks, and richer payoffs.
4. [`FUTURE_PROJECT.md`](FUTURE_PROJECT.md) - larger product identity and scope guardrails.
5. [`VALIDATION.md`](VALIDATION.md) - gates that keep the inherited kernel trustworthy.
6. [`PERFORMANCE_MATRIX.md`](PERFORMANCE_MATRIX.md) - resume evidence, lane/path/date scaling, CPU boundaries, and claim caveats.
7. [`ACCURACY.md`](ACCURACY.md) - bps accuracy methodology and product accuracy policy.
8. [`FPGA_BUILD.md`](FPGA_BUILD.md) - Vivado build and hardware run notes.
9. [`OBSIDIAN_HANDOFF.md`](OBSIDIAN_HANDOFF.md) - copy-paste summary for external notes.

Private scratch can be kept as `.user/ROADMAP_PRIVATE.md` if needed; it is gitignored and not part of the active project docs.

Current rule of thumb:

- Root docs: fork identity and inherited FPGA kernel foundation.
- `.user`: project memory, roadmap, validation, and product scope.
- `.ai`: AI/session handoff and behavioral rules.
