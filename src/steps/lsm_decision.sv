timeunit 1ns; timeprecision 1ps;
module lsm_decision #(
    parameter int WIDTH     = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT      = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC     = fpga_cfg_pkg::FP_QFRAC,
    parameter int LANE_ID   = 0
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     valid_in,
    output logic                     valid_out,
    input  logic                     ready_in,
    output logic                     ready_out,

    input  logic signed [WIDTH-1:0]  S_t,
    input  logic signed [WIDTH-1:0]  s_norm,     // S_t / K  (moneyness, ~1.0 for ATM)
    input  logic signed [WIDTH-1:0]  beta[0:2],
    input  logic signed [WIDTH-1:0]  strike,
    input  logic signed [WIDTH-1:0]  cont_value,
    input  logic                     option_type,  // 0=CALL max(S-K,0), 1=PUT max(K-S,0)

    output logic signed [WIDTH-1:0]  PV
`ifdef TOP_NUM_DEBUG
    ,
    output logic signed [WIDTH-1:0]  debug_immediate,
    output logic signed [WIDTH-1:0]  debug_cont_est
`endif
);
    // ---------------------------------------------------------------
    // Input latch + busy flag
    // ---------------------------------------------------------------
    typedef struct packed {
        logic signed [WIDTH-1:0] S_t;
        logic signed [WIDTH-1:0] s_norm;
        logic signed [WIDTH-1:0] strike;
        logic signed [WIDTH-1:0] cont_value;
    } input_t;

    input_t in_buf;
    logic signed [WIDTH-1:0] beta_reg[0:2];

    logic busy;
    logic started;

    assign ready_out = !busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_buf  <= '{0, 0, 0, 0};
            for (int i = 0; i < 3; i++) beta_reg[i] <= '0;
            busy    <= 1'b0;
            started <= 1'b0;
        end else begin
            started <= 1'b0;
            if (valid_in && !busy) begin
                in_buf  <= '{S_t, s_norm, strike, cont_value};
                for (int i = 0; i < 3; i++) beta_reg[i] <= beta[i];
                busy    <= 1'b1;
                started <= 1'b1;
            end else if (valid_out && ready_in) begin
                busy <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------
    // Continuation estimate using normalized S (s_norm = S/K):
    //   C = beta[0] + beta[1]*s_norm + beta[2]*s_norm^2
    //   Uses s_norm (~1.0) to avoid Q16.16 overflow in higher powers.
    // ---------------------------------------------------------------
    logic v1, v2;
    logic signed [WIDTH-1:0] sn_sq, b1sn, b2sn2;

    fxMul #() mul_sn_sn (
        .clk(clk), .rst_n(rst_n),
        .valid_in   (started),
        .valid_out  (v1),
        .ready_in   (1'b1),
        .ready_out  (),
        .a          (in_buf.s_norm),
        .b          (in_buf.s_norm),
        .result     (sn_sq)
    );

    fxMul #() mul_b1sn (
        .clk(clk), .rst_n(rst_n),
        .valid_in   (started),
        .valid_out  (),
        .ready_in   (1'b1),
        .ready_out  (),
        .a          (beta_reg[1]),
        .b          (in_buf.s_norm),
        .result     (b1sn)
    );

    fxMul #() mul_b2sn2 (
        .clk(clk), .rst_n(rst_n),
        .valid_in   (v1),
        .valid_out  (v2),
        .ready_in   (1'b1),
        .ready_out  (),
        .a          (beta_reg[2]),
        .b          (sn_sq),
        .result     (b2sn2)
    );

    logic signed [WIDTH-1:0] c_val_next;
    assign c_val_next = beta_reg[0] + b1sn + b2sn2;

    // ---------------------------------------------------------------
    // Immediate exercise payoff: CALL max(S-K,0), PUT max(K-S,0)
    // ---------------------------------------------------------------
    logic signed [WIDTH-1:0] payoff;

    always_comb begin
        if (option_type)
            payoff = (in_buf.strike > in_buf.S_t) ? (in_buf.strike - in_buf.S_t) : '0;
        else
            payoff = (in_buf.S_t > in_buf.strike) ? (in_buf.S_t - in_buf.strike) : '0;
    end

    // ---------------------------------------------------------------
    // Output: capture decision when v2 fires
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            PV        <= '0;
            valid_out <= 1'b0;
`ifdef TOP_NUM_DEBUG
            debug_immediate <= '0;
            debug_cont_est  <= '0;
`endif
        end else begin
            if (v2 && !valid_out) begin
                PV        <= (payoff >= c_val_next) ? payoff : in_buf.cont_value;
`ifdef TOP_NUM_DEBUG
                debug_immediate <= payoff;
                debug_cont_est  <= c_val_next;
`endif
                valid_out <= 1'b1;
            end else if (valid_out && ready_in) begin
                valid_out <= 1'b0;
            end
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n) valid_out && !ready_in |=> $stable(PV))
        else $error("Decision: Stall violation");
endmodule
