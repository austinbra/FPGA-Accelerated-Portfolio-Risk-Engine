---
description: Mandatory verification after every code/documentation change.
globs: ["**/*.sv", "**/*.py", "**/*.ps1", "**/*.tcl", "**/*.md"]
alwaysApply: true
---

# Verify After Every Change

For every change, verification is required before task completion.

## Required Process

1. Run appropriate checks for touched scope:
   - documentation changes: `git diff --check`,
   - RTL changes: compile and elaboration at minimum,
   - script/host changes: syntax/lint plus relevant smoke run,
   - behavior-impacting changes: closest available functional testbench or validation script.
2. Confirm results explicitly:
   - commands run,
   - pass/fail outcome,
   - limitations or untested areas.
3. If verification fails:
   - fix the issue,
   - rerun checks,
   - do not mark complete until checks pass or the user approves a known gap.

No "done" message without verification evidence.
