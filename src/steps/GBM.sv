timeunit 1ns; timeprecision 1ps;
// GBM step: S_next = S * exp( drift_const + vol_sqrt_dt*z )
// Streaming pipeline: MUL1(diff) -> ADD+EXP -> MUL2(S*exp). ~6 cycle latency.
// Pre-computed: drift_const, vol_sqrt_dt. Uses signed ExpLUT (no fxDiv).
module GBM #(
    parameter int WIDTH       = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT        = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC       = fpga_cfg_pkg::FP_QFRAC,
    parameter int LANE_ID     = 0
)(
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       valid_in,
    output logic                       ready_out,
    output logic                       valid_out,
    input  logic                       ready_in,

    input  logic signed [WIDTH-1:0]    z,
    input  logic signed [WIDTH-1:0]    S,
    input  logic signed [WIDTH-1:0]    drift_const,
    input  logic signed [WIDTH-1:0]    vol_sqrt_dt,
    output logic signed [WIDTH-1:0]    S_next
);
    localparam signed [WIDTH-1:0] MAX_POS = {1'b0, {(WIDTH-1){1'b1}}};
    localparam signed [WIDTH-1:0] MIN_NEG = {1'b1, {(WIDTH-1){1'b0}}};

    // -------------------------------------------------------------------------
    // Inter-stage handshake signals (declared first to avoid forward references)
    // -------------------------------------------------------------------------
    logic                    mul1_vout, mul1_rin, mul1_rout;
    logic signed [WIDTH-1:0] mul1_result;
    logic                    mul1_accept;

    logic                    exp_vin, exp_vout, exp_rin, exp_rout;
    logic signed [WIDTH-1:0] exp_arg, exp_result;
    logic                    exp_accept;

    logic                    mul2_vin, mul2_vout, mul2_rin, mul2_rout;
    logic signed [WIDTH-1:0] mul2_result;

    // -------------------------------------------------------------------------
    // Stage 1: MUL1 = vol_sqrt_dt * z
    // -------------------------------------------------------------------------
    assign ready_out = mul1_rout;
    assign mul1_rin = exp_rout;

    fxMul #(.LATENCY(fpga_cfg_pkg::FP_MUL_LATENCY)) u_mul1 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (valid_in),
        .ready_out(mul1_rout),
        .valid_out(mul1_vout),
        .ready_in (mul1_rin),
        .a(vol_sqrt_dt),
        .b(z),
        .result(mul1_result)
    );

    assign mul1_accept = valid_in && ready_out;

    // S alignment FIFO: push on mul1_accept, pop on exp_vout && mul2_rout
    logic [WIDTH-1:0] s_align_push [0:0];
    logic [WIDTH-1:0] s_align_pop  [0:0];
    logic              s_fifo_full, s_fifo_empty;
    assign s_align_push[0] = S;
    event_align_fifo_arr #(.N(1), .DW(WIDTH), .DEPTH(16)) u_s_align (
        .clk(clk), .rst_n(rst_n),
        .push_en  (mul1_accept),
        .pop_en   (exp_vout && mul2_rout),
        .push_data(s_align_push),
        .pop_data (s_align_pop),
        .full     (s_fifo_full),
        .empty    (s_fifo_empty)
    );
    wire signed [WIDTH-1:0] s_aligned = $signed(s_align_pop[0]);

    // -------------------------------------------------------------------------
    // Stage 2: ADD (combo) + EXP input. exp_arg = drift_const + diff, saturate
    // -------------------------------------------------------------------------
    logic signed [WIDTH-1:0] sum_val;
    always_comb begin
        sum_val = drift_const + mul1_result;
        if (sum_val > MAX_POS)      exp_arg = MAX_POS;
        else if (sum_val < MIN_NEG)  exp_arg = MIN_NEG;
        else                         exp_arg = sum_val;
    end

    fxExpLUT #(
        .LUT_BITS(12),
        .LUT_FILE(mem_paths_pkg::EXP_SIGNED),
        .SIGNED_RANGE(1)
    ) u_exp (
        .clk(clk), .rst_n(rst_n),
        .valid_in (exp_vin),
        .ready_out(exp_rout),
        .valid_out(exp_vout),
        .ready_in (exp_rin),
        .a(exp_arg),
        .result(exp_result)
    );

    assign exp_accept = mul1_vout && exp_rout;
    assign exp_vin    = exp_accept;

    // -------------------------------------------------------------------------
    // Stage 3: MUL2 = S * exp_val
    // -------------------------------------------------------------------------
    fxMul #(.LATENCY(fpga_cfg_pkg::FP_MUL_LATENCY)) u_mul2 (
        .clk(clk), .rst_n(rst_n),
        .valid_in (mul2_vin),
        .ready_out(mul2_rout),
        .valid_out(mul2_vout),
        .ready_in (mul2_rin),
        .a(s_aligned),
        .b(exp_result),
        .result(mul2_result)
    );

    assign mul2_vin = exp_vout && mul2_rout;
    assign mul2_rin = ready_in;

    // Output
    assign valid_out = mul2_vout;
    assign S_next    = mul2_result;

    // Backpressure chain
    assign exp_rin = mul2_rout || !exp_vout;

`ifdef ASSERT_STRICT
    assert property (@(posedge clk) disable iff (!rst_n) valid_out && !ready_in |=> $stable(S_next))
        else $error("GBM: Backpressure violation");
    assert property (@(posedge clk) disable iff (!rst_n) !(s_fifo_full && mul1_accept))
        else $error("GBM: S alignment FIFO overflow");
`endif
endmodule
