// Board wrapper for Digilent Arty S7-50: 100 MHz input, generated core clock,
// USB-UART, and active-high reset button BTN0.
// Port names align with Digilent master XDC (see constraints/arty_s7_50.xdc).
timeunit 1ns;
timeprecision 1ps;

// These are safe fallback elaboration defaults. The Vivado build script
// overrides the mode, lane count, and generated core period for each build.
module arty_s7_option_pricer_top #(
    parameter bit MULTI_EXERCISE = 1'b0,
    parameter int unsigned NUM_LANES = 1,
    parameter int unsigned MULTI_CORE_MAX_CYCLES = 32'd1_000_000_000,
    parameter real CORE_CLKOUT_DIVIDE_F = 10.000,
    parameter int CORE_CLK_FREQ_HZ = 100_000_000
)(
    input  logic CLK100MHZ,
    input  logic btn0,
    input  logic uart_txd_in,
    output logic uart_rxd_out
);
    wire mmcm_clkfb;
    wire mmcm_clkfb_buf;
    wire core_clk_unbuffered;
    wire core_clk;
    wire mmcm_locked;

    // The board oscillator remains 100 MHz. With a 1 GHz VCO, the fractional
    // output divider value is numerically equal to the core period in ns.
    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (10.000),
        .CLKFBOUT_PHASE     (0.000),
        .CLKIN1_PERIOD      (10.000),
        .CLKOUT0_DIVIDE_F   (CORE_CLKOUT_DIVIDE_F),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .DIVCLK_DIVIDE      (1),
        .STARTUP_WAIT       ("FALSE")
    ) u_core_clock (
        .CLKIN1   (CLK100MHZ),
        .CLKFBIN  (mmcm_clkfb_buf),
        .RST      (btn0),
        .PWRDWN   (1'b0),
        .CLKFBOUT (mmcm_clkfb),
        .CLKOUT0  (core_clk_unbuffered),
        .LOCKED   (mmcm_locked)
    );

    BUFG u_core_clock_feedback_buf (
        .I (mmcm_clkfb),
        .O (mmcm_clkfb_buf)
    );

    BUFG u_core_clock_output_buf (
        .I (core_clk_unbuffered),
        .O (core_clk)
    );

    // Assert reset immediately on BTN0 or lost lock, then release it only on
    // core-clock edges after the MMCM has locked.
    wire core_reset_async = btn0 | ~mmcm_locked;
    logic [1:0] core_reset_sync;
    always_ff @(posedge core_clk or posedge core_reset_async) begin
        if (core_reset_async)
            core_reset_sync <= 2'b00;
        else
            core_reset_sync <= {core_reset_sync[0], 1'b1};
    end
    wire rst_n_unbuffered = core_reset_sync[1];
    wire rst_n;

    // The design uses asynchronous reset pins throughout the pricing core.
    // Buffer the synchronized deassertion on a global network so it does not
    // become a multi-nanosecond, thousands-of-load fabric route.
    BUFG u_core_reset_buf (
        .I (rst_n_unbuffered),
        .O (rst_n)
    );

    top_mc_option_pricer #(
        .CLK_FREQ_HZ(CORE_CLK_FREQ_HZ),
        .MULTI_EXERCISE(MULTI_EXERCISE),
        .NUM_LANES(NUM_LANES),
        .MULTI_CORE_MAX_CYCLES(MULTI_CORE_MAX_CYCLES)
    ) u_top (
        .clk_100   (core_clk),
        .rst_btn_n (rst_n),
        .uart_rxd  (uart_txd_in),
        .uart_txd  (uart_rxd_out)
    );
endmodule
