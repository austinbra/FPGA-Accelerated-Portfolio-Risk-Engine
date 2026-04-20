# FPGA build — Arty boards (hardware test prep)

## Arty A7-100T (primary — full bitstream + STA)

**Top:** [`fpga/arty_a7_option_pricer_top.sv`](../fpga/arty_a7_option_pricer_top.sv)  
**Constraints:** [`constraints/arty_a7_100.xdc`](../constraints/arty_a7_100.xdc) — `sys_clk` is currently **12 ns** (**83.333 MHz**) on `CLK100MHZ` for timing closure (see comment in XDC about MMCM if you need a different on-chip frequency from the 100 MHz crystal).

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400
```

**Artifacts:** `vivado_build/arty_a7_100/` — `timing_post_route.rpt`, `utilization.rpt`, `arty_a7_qmc.bit`.

**Experiment (does not fit):** Arty A7-35T — `.\scripts\run_vivado_build_arty_a7_35.ps1` — expect **LUT DRC** until Plan B or smaller config.

---

## Arty S7-50 (XC7S50)

**Top for implementation:** `arty_s7_option_pricer_top` in [`fpga/arty_s7_option_pricer_top.sv`](../fpga/arty_s7_option_pricer_top.sv) (wraps `top_mc_option_pricer` with Digilent clock / UART / BTN0 reset).

**Constraints:** [`constraints/arty_s7_50.xdc`](../constraints/arty_s7_50.xdc) — 100 MHz **R2** (SSTL135), USB-UART **V12/R12**, **BTN0 G15**.

**Divider IP:** `scripts/vivado_build_arty_s7.tcl` creates **Xilinx `div_gen` v5.1** as `fxDiv_core` under `vivado_build/arty_s7_50/generated_ip/` (48-bit dividend path, 32-bit divisor, signed, blocking AXI, manual latency 16, `aresetn` + `m_axis_dout_tready` enabled). RTL in [`src/math/fxDiv.sv`](../src/math/fxDiv.sv) uses **80-bit** `m_axis_dout_tdata` to match the IP; the simulation stub matches that width.

## Commands (Windows, Vivado on PATH)

```powershell
# Quick check: synthesis only (~few minutes to tens of minutes depending on machine)
$env:VIVADO_SYNTH_ONLY = "1"
.\scripts\run_vivado_build_arty_s7.ps1 -SynthOnly
Remove-Item Env:VIVADO_SYNTH_ONLY -ErrorAction SilentlyContinue

# Full place & route + bitstream (long run; default timeout 2 h, increase if needed)
.\scripts\run_vivado_build_arty_s7.ps1 -TimeoutSeconds 14400
```

**Outputs (default paths):**

| Artifact | Location |
|----------|----------|
| Vivado project | `vivado_build/arty_s7_50/` |
| Timing summary | `vivado_build/arty_s7_50/timing_post_route.rpt` |
| Utilization | `vivado_build/arty_s7_50/utilization.rpt` |
| Bitstream | `vivado_build/arty_s7_50/arty_s7_qmc.bit` |

## Program the board

Use Vivado Hardware Manager or `open_hw_manager` / `program_hw_devices` from a small Tcl, or Digilent Adept — point the bit file at `arty_s7_qmc.bit`.

## Host test (after programming)

```powershell
python src/uart_host.py --mode benchmark --target fpga --port COM4 --param-file baseline/cpp_fixed/params_example.txt
```

Adjust `--port` to the USB-UART COM port from Device Manager.

## Preconditions

1. **Vivado** (tested flow on 2025.1; other versions should be similar).
2. **`$readmemh` paths:** `vivado_build_arty_s7.tcl` emits `vivado_build/arty_s7_50/generated/mem_paths_pkg.sv` with an absolute repo prefix. RTL defaults use `mem_paths_pkg::*` (`fpga/mem_paths_pkg.sv` for sim with `REPO=""`).
3. **Board rev:** XDC follows Digilent **Arty S7-50 Rev. E** master template; confirm against your silk / [digilent-xdc](https://github.com/Digilent/digilent-xdc).

## Synthesis status (RTL)

**Resolved (2026-04-15):** `fxlnLUT` and `fxSqrt` are synthesizable (no `real` / `$ln` / `$sqrt` in sequential logic). **`synth_design`** for `arty_s7_option_pricer_top` completes with **0 errors** using:

```powershell
$env:VIVADO_SYNTH_ONLY = "1"
.\scripts\run_vivado_build_arty_s7.ps1 -SynthOnly
```

**Regression gate:** `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` → price **`0x000b93cd`** (default TB params).

**LN table:** `src/gen/ln_lut_4096.mem` must encode **`ln(x)`** at the **left edge** of each fractional bin (see `scripts/gen_ln_lut_4096.py`). An older placeholder matched **`ln(1+i/4096)`** and broke numerical parity until regenerated.

## If synthesis fails

- Open `vivado_build/arty_s7_50/vivado.log` and `arty_s7_qmc.runs/synth_1/runme.log`.
- Common issues: missing mem file path (run from repo via script), part typo, IP version mismatch (`div_gen` 5.1).

See also: [`.user/ROADMAP.md`](ROADMAP.md) (Priority 1 hardware test), [`.cursor/rules/rules.md`](../.cursor/rules/rules.md) (Arty pin table).
