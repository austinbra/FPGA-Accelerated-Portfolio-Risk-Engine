// Board wrapper for Digilent Arty A7-100T: 100 MHz clock, USB-UART, active-low reset from BTN0.
// Port names align with Digilent Arty-A7-100 master XDC.
timeunit 1ns;
timeprecision 1ps;

module arty_a7_option_pricer_top #(
    parameter bit MULTI_EXERCISE = 1'b0,
    parameter int unsigned NUM_LANES = 1,
    parameter int unsigned MULTI_CORE_MAX_CYCLES = 32'd1_000_000_000
)(
    input  logic CLK100MHZ,
    input  logic btn0,
    input  logic uart_txd_in,
    output logic uart_rxd_out
);
    wire rst_n = ~btn0;

    top_mc_option_pricer #(
        .MULTI_EXERCISE(MULTI_EXERCISE),
        .NUM_LANES(NUM_LANES),
        .MULTI_CORE_MAX_CYCLES(MULTI_CORE_MAX_CYCLES)
    ) u_top (
        .clk_100   (CLK100MHZ),
        .rst_btn_n (rst_n),
        .uart_rxd  (uart_txd_in),
        .uart_txd  (uart_rxd_out)
    );
endmodule
