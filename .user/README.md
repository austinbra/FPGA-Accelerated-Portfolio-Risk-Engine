# User Notes

This folder contains the user-facing project memory files:

- `IMPLEMENTATION_STATUS.md`: what is implemented today
- `ROADMAP.md`: what to work on next and where to look
- `VALIDATION.md`: how to verify changes
- `FPGA_BUILD.md`: Arty S7-50 Vivado bitstream flow (synth / impl / program / host); **`synth_design` now clean** after synthesizable `fxlnLUT`/`fxSqrt` (see that doc for commands). **Arty A7-100T** flow: same doc § Arty A7-100T + `scripts/run_vivado_build_arty_a7.ps1`.
- `OBSIDIAN_HANDOFF.md`: dated checkpoint text to **paste into Obsidian** (vault lives outside the repo; see `.cursor/rules/obsidian_sync.md`).
- `../scripts/gen_ln_lut_4096.py`: regenerates `src/gen/ln_lut_4096.mem` (must match hardware binning).

Recommended reading order:

1. `IMPLEMENTATION_STATUS.md`
2. `ROADMAP.md`
3. `VALIDATION.md`
4. `FPGA_BUILD.md` (when doing hardware bring-up)

Cursor / AI workspace layout (rules vs your notes): [`.cursor/README.md`](../.cursor/README.md).
