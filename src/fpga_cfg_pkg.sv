package fpga_cfg_pkg;
    timeunit 1ns;
    timeprecision 1ps;
    
    parameter int FP_WIDTH              = 32;
    parameter int FP_QINT               = 16;
    parameter int FP_QFRAC              = FP_WIDTH - FP_QINT;
    parameter int FP_MUL_LATENCY        = 1;
    parameter int FP_DIV_LATENCY        = 16; // 16 is safe for fMAX roughly 200 MHz on spartan 7
    parameter int FP_SQRT_LATENCY       = 9; // *** do not change ***
endpackage
