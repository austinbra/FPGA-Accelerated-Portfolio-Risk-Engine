package fpga_cfg_pkg;
    timeunit 1ns;
    timeprecision 1ps;
    
    parameter int FP_WIDTH              = 32;
    parameter int FP_QINT               = 16;
    parameter int FP_QFRAC              = FP_WIDTH - FP_QINT;
    parameter int FP_MUL_LATENCY        = 1; // single-cycle fxMul (reverted from 2; DSP-split was for A7-100T timing, not needed for sim)

    parameter int FP_DIV_LATENCY        = 32; // deeper pipeline: halves div_gen critical path (fMAX gain on A7/S7)
    parameter int FP_SQRT_LATENCY       = 24; // non-restoring sqrt: QINT/2 + QFRAC
endpackage
