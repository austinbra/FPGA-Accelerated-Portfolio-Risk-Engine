// Board wrapper for Digilent Arty A7-100T: 100 MHz clock, USB-UART, active-low reset from BTN0.
// Port names align with Digilent Arty-A7-100 master XDC.
timeunit 1ns;
timeprecision 1ps;

module arty_a7_option_pricer_top (
    input  logic CLK100MHZ,
    input  logic btn0,
    input  logic uart_txd_in,
    output logic uart_rxd_out
);
    wire rst_n = ~btn0;

    top_mc_option_pricer u_top (
        .clk_100   (CLK100MHZ),
        .rst_btn_n (rst_n),
        .uart_rxd  (uart_txd_in),
        .uart_txd  (uart_rxd_out)
    );
endmodule
