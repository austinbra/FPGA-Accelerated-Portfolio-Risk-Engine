# Obsidian handoff ΓÇö paste into your vault

**Purpose:** Mirror of repo state for `Options-Pricer-vault` (or your active vault). Update the dated note in Obsidian when you merge this content.

**Vault path (per `.cursor/rules/obsidian_sync.md`):** `%USERPROFILE%\Documents\Obsidian\Options-Pricer-vault\` ΓÇö e.g. `Arty A7-100 hardware.md` or a single `QMC FPGA status.md`.

---

## 2026-04-19 ΓÇö QMC-LSM FPGA checkpoint

### Done

- **Plan A** shared divider scheduler in `regression.sv`; **`FP_DIV_LATENCY = 32`**; Stage-1 pivot extra register.
- **Arty A7-100T** full route: **`vivado_build/arty_a7_100/arty_a7_qmc.bit`**, **`timing_post_route.rpt`** WNS **+0.173 ns**, TNS **0**, **0** failing endpoints at **`sys_clk` = 12 ns** (**83.333 MHz**).
- **`utilization.rpt`:** ~**22,637** slice LUTs, ~**27,412** FFs, **100** DSP48E1.
- **Simulation:** UART compute mode restored with **`FP_MUL_LATENCY = 1`** (reverted `fxMul` split). Golden price **`0x000b93cd`** (`./scripts/run_tb_top_uart_safe.ps1 -ComputeMode`).

### Learned

- **`fxMul` DSP-output register + `FP_MUL_LATENCY=2`** closed **100 MHz** timing experimentally but **deadlocked / timed out** in sim (`0xDEAD0001`); do not ship without full FSM + UART regression on that variant.
- **Relaxed XDC clock** is a valid way to report **honest fMAX** when multiply cannot be safely pipelined yet.
- **Large `$readmemh` ROMs** still show **0 BRAM tiles** in utilization ΓÇö likely distributed ROM / inference choice; optional follow-up to force BRAM if desired.
- **XC7A35T** build path exists (`run_vivado_build_arty_a7_35.ps1`) but design **exceeds LUT budget** (~24.8k vs ~20.8k) at DRC ΓÇö needs **Plan B** (share `div_b*` + `div_mean`) or reduced lanes / scope.

### Next

1. **Benchmark write-up:** cycles ├ù **12 ns** (or counter from DUT) vs C++ baseline ΓÇö no board strictly required.
2. **Optional:** flash A7-100T, UART benchmark on COM port.
3. **If 100 MHz STA required:** redo multiply pipeline with correct **back-pressure** across all consumers (regression + GBM + host-visible latency).
4. **If 35T required:** Plan B divider merge + re-run impl.
5. **Product:** multi-exercise-date backward induction (see `ROADMAP.md`).

### Verification commands

```powershell
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode
.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400
```

Reports: `vivado_build/arty_a7_100/timing_post_route.rpt`, `utilization.rpt`.
