# UART Waveform Debugging

This repository uses two waveform tools for two different boundaries:

- **GTKWave** reads simulation VCD files. It is bundled with the installed
  Icarus Verilog distribution at
  `C:\Program Files\iverilog\gtkwave\bin\gtkwave.exe`.
- **Vivado Integrated Logic Analyzer (ILA)** captures internal signals from a
  programmed FPGA. GTKWave cannot observe a physical FPGA by itself.

## Run the UART waveform lab

From the repository root:

```powershell
.\scripts\run_uart_waveform.ps1
```

The script compiles the byte and 32-bit UART receivers with Icarus Verilog,
writes `.tmp\waveforms\uart_rx_lab\uart_rx_lab.vcd`, and opens that VCD in
GTKWave. Use `-NoGui` to generate and verify the waveform without opening a
window:

```powershell
.\scripts\run_uart_waveform.ps1 -NoGui
```

The `phase` signal labels three experiments:

| Phase | Experiment | Expected result |
|---:|---|---|
| 1 | Eight request words sent as 32 back-to-back bytes | Passes under ideal simulation timing |
| 2 | One byte with a deliberately low stop bit | Corrected receiver rejects the byte |
| 3 | Four bytes per word with 2 ms idle between words | Legacy pacing comparison; not required by UART |

Useful receiver states are `0=IDLE`, `1=START`, `2=DATA`, and `3=STOP`. Zoom
into one UART frame to see the start, data, and stop intervals;
zoom out to compare the continuous and guarded requests.

The VCD is text-based and can be inspected by scripts or other waveform tools,
so the same artifact is readable by both a person in GTKWave and an automated
analysis workflow.

## What this lab does not prove

The simulation drives mathematically clean UART transitions. The physical
investigation later showed that the apparent burst corruption was host-side:
`_read_exact()` reassigned pyserial's `timeout` immediately after `write()`,
which reconfigured the Windows COM handle while FTDI transmit could still be
active. Removing that mutation produced 100/100 zero-gap full-design jobs and
1,000/1,000 zero-gap minimal-UART jobs on the same cable.

To identify the initiating physical edge, create a separate debug bitstream
with a Vivado ILA probing at least:

- synchronized UART RX,
- receiver state and clock counter,
- byte data and byte-valid,
- 32-bit word data and word-valid,
- request word count.

Trigger on the first UART start bit or on an invalid stop condition. Because an
ILA consumes FPGA resources and can change routing, keep it out of the measured
performance bitstream and label the result as a debug build.
