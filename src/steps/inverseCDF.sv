timeunit 1ns; timeprecision 1ps;
module inverseCDF #(
    parameter int WIDTH              = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT               = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC              = fpga_cfg_pkg::FP_QFRAC,
    parameter int LANE_ID            = 0
)(
    input logic clk,
    input logic rst_n,

    input logic valid_in,
    output logic ready_out,

    input logic signed [WIDTH-1:0] u_in,

    output logic valid_out,
    input logic ready_in,

    output logic signed [WIDTH-1:0] z_out
);

    localparam signed [WIDTH-1:0] NEG_TWO = -(2 << QFRAC);

    // Serial pipeline: fold -> lnLUT -> mul -> sqrt -> rational.
    // Each stage's ready_out feeds the previous stage's ready_in.
    // No wide barrier needed: back-pressure propagates naturally.

    // Stage wires
    logic v1, v2a, v2b, v3;
    logic fold_ready, ln_ready, mul_ready, sqrt_ready, rational_ready;

    logic [WIDTH-1:0] x;
    logic negate;
    logic [WIDTH-1:0] ln_x;
    logic [WIDTH-1:0] neg2_ln_x;
    logic [WIDTH-1:0] t_val;

    // Upstream ready = fold stage can accept
    assign ready_out = fold_ready;

    // Step 1: fold U(0,1) into (0,0.5] + negate flag
    inverseCDF_fold #() fold_stage (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .valid_out(v1),
        .ready_in(ln_ready),
        .ready_out(fold_ready),
        .u(u_in),
        .x(x),
        .negate(negate)
    );

    // Step 2a: ln(x) via LUT
    fxlnLUT #() loglut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(v1),
        .valid_out(v2a),
        .ready_in(mul_ready),
        .ready_out(ln_ready),
        .a(x),
        .result(ln_x)
    );

    // Step 2b: -2 * ln(x)
    fxMul #() mul_neg2(
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(v2a),
        .valid_out(v2b),
        .ready_in(sqrt_ready),
        .ready_out(mul_ready),
        .a(ln_x),
        .b(NEG_TWO),
        .result(neg2_ln_x)
    );

    // Step 2c: sqrt(-2*ln(x))
    fxSqrt #() sqrt_unit (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(v2b),
        .valid_out(v3),
        .ready_in(rational_ready),
        .ready_out(sqrt_ready),
        .a(neg2_ln_x),
        .result(t_val)
    );

    // Negate alignment FIFO: push on fold output, pop on sqrt output.
    // Keeps the negate flag in sync with data flowing through ln -> mul -> sqrt.
    logic [0:0] neg_push [0:0];
    logic [0:0] neg_pop  [0:0];
    logic       neg_fifo_full, neg_fifo_empty;

    assign neg_push[0] = negate;

    event_align_fifo_arr #(.N(1), .DW(1), .DEPTH(4)) u_negate_align (
        .clk       (clk),
        .rst_n     (rst_n),
        .push_en   (v1),
        .push_data (neg_push),
        .pop_en    (v3 && rational_ready),
        .pop_data  (neg_pop),
        .full      (neg_fifo_full),
        .empty     (neg_fifo_empty)
    );

    wire negate_aligned = neg_pop[0];

    // Step 3: Zelen & Severo rational approximation
    fxInvCDF_ZS #(.WIDTH(WIDTH), .QINT(QINT)) rational (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(v3),
        .valid_out(valid_out),
        .ready_in(ready_in),
        .ready_out(rational_ready),
        .t(t_val),
        .negate(negate_aligned),
        .z(z_out)
    );

    assert property (@(posedge clk) disable iff (!rst_n) valid_out && !ready_in |=> $stable(z_out))
        else $error("InvCDF: Stall overwrite");
endmodule
