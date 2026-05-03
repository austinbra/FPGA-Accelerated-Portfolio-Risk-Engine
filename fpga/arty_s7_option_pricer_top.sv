// Board wrapper for Digilent Arty S7-50: 100 MHz clock, USB-UART, active-low reset from BTN0.
// Port names align with Digilent master XDC (see constraints/arty_s7_50.xdc).
timeunit 1ns;
timeprecision 1ps;

module arty_s7_option_pricer_top #(
    parameter bit MULTI_EXERCISE = 1'b0,
    parameter int unsigned MULTI_CORE_MAX_CYCLES = 32'd1_000_000_000
)(
    input  logic CLK100MHZ,
    input  logic btn0,
    input  logic uart_txd_in,
    output logic uart_rxd_out
);
    // BTN0 pressed = logic 1 on Arty; core uses active-low reset.
    wire rst_n = ~btn0;

    top_mc_option_pricer #(
        .MULTI_EXERCISE(MULTI_EXERCISE),
        .MULTI_CORE_MAX_CYCLES(MULTI_CORE_MAX_CYCLES)
    ) u_top (
        .clk_100   (CLK100MHZ),
        .rst_btn_n (rst_n),
        .uart_rxd  (uart_txd_in),
        .uart_txd  (uart_rxd_out)
    );
endmodule
