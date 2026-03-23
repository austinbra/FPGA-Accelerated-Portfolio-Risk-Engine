timeunit 1ns; timeprecision 1ps;
//-----------------------------------------------------------
// Approximates Z score using Zelen & Severo rational polynomial
// z_approx = t - (C0 + C1*t + C2*t^2) / (1 + D1*t + D2*t^2 + D3*t^3)
//-----------------------------------------------------------

module fxInvCDF_ZS #(
    parameter int WIDTH                 = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT                  = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC                 = fpga_cfg_pkg::FP_QFRAC,
    parameter int MUL_LATENCY           = fpga_cfg_pkg::FP_MUL_LATENCY,
    parameter int DIV_LATENCY           = fpga_cfg_pkg::FP_DIV_LATENCY
)(
    input logic clk,
    input logic rst_n,

    input logic valid_in,
    output logic valid_out,
    input logic ready_in,
    output logic ready_out,

    input logic [WIDTH-1:0] t,
    input logic negate,

    output logic signed [WIDTH-1:0] z
);

    // Zelen & Severo constants in Q16.16 (precomputed to avoid 32-bit overflow)
    // z = t - (c0 + c1*t + c2*t^2) / (1 + d1*t + d2*t^2 + d3*t^3)
    localparam signed [WIDTH-1:0] C0 = 32'sd164889;  // 2.515517 * 65536
    localparam signed [WIDTH-1:0] C1 = 32'sd52603;   // 0.802853 * 65536
    localparam signed [WIDTH-1:0] C2 = 32'sd677;     // 0.010328 * 65536
    localparam signed [WIDTH-1:0] D1 = 32'sd93896;   // 1.432788 * 65536
    localparam signed [WIDTH-1:0] D2 = 32'sd12404;   // 0.189269 * 65536
    localparam signed [WIDTH-1:0] D3 = 32'sd86;      // 0.001308 * 65536

    localparam signed [WIDTH-1:0] ONE = 32'sd1 <<< QFRAC;

    // Pipeline processes one sample at a time.
    // in_flight prevents accepting a new sample until the current one completes.
    logic in_flight;
    logic [WIDTH-1:0] t_cap;
    logic             negate_cap;
    logic             launch;

    assign ready_out = !in_flight;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight  <= 1'b0;
            t_cap      <= '0;
            negate_cap <= 1'b0;
            launch     <= 1'b0;
        end else begin
            launch <= 1'b0;
            if (valid_in && ready_out) begin
                t_cap      <= t;
                negate_cap <= negate;
                in_flight  <= 1'b1;
                launch     <= 1'b1;
            end
            if (valid_out && ready_in)
                in_flight <= 1'b0;
        end
    end

    // All multipliers and the divider use t_cap (stable through entire computation)

    // Stage 1: t^2 and t^3
    logic v1a, v1b;
    logic [WIDTH-1:0] t2, t3;

    logic mul_t2_ready, mul_t3_ready;
    logic mul_c1t_ready, mul_c2t2_ready;
    logic mul_d1t_ready, mul_d2t2_ready, mul_d3t3_ready;
    logic div_nd_ready;

    fxMul #() mul_t_t (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (launch),
        .valid_out (v1a),
        .ready_in  (mul_t3_ready && mul_c2t2_ready && mul_d2t2_ready),
        .ready_out (mul_t2_ready),
        .a         (t_cap),
        .b         (t_cap),
        .result    (t2)
    );

    fxMul #() mul_t_t2(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v1a),
        .valid_out (v1b),
        .ready_in  (mul_d3t3_ready),
        .ready_out (mul_t3_ready),
        .a         (t_cap),
        .b         (t2),
        .result    (t3)
    );

    // Numerator: C0 + C1*t + C2*t^2
    logic v2a, v2b;
    logic [WIDTH-1:0] c1t, c2t2;
    logic [WIDTH-1:0] num;

    fxMul #() mul_c1t(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (launch),
        .valid_out (v2a),
        .ready_in  (1'b1),
        .ready_out (mul_c1t_ready),
        .a         (C1),
        .b         (t_cap),
        .result    (c1t)
    );

    fxMul #() mul_c2t2(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v1a),
        .valid_out (v2b),
        .ready_in  (1'b1),
        .ready_out (mul_c2t2_ready),
        .a         (C2),
        .b         (t2),
        .result    (c2t2)
    );

    // Latch numerator when c2t2 is valid (c1t completes earlier, is stable)
    logic num_valid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num       <= '0;
            num_valid <= 1'b0;
        end else begin
            if (valid_out && ready_in)
                num_valid <= 1'b0;
            if (v2b && !num_valid) begin
                num       <= C0 + c1t + c2t2;
                num_valid <= 1'b1;
            end
        end
    end

    // Denominator: 1 + D1*t + D2*t^2 + D3*t^3
    logic v3a, v3b, v3c;
    logic [WIDTH-1:0] d1t, d2t2, d3t3;
    logic [WIDTH-1:0] den;

    fxMul #() mul_d1t(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (launch),
        .valid_out (v3a),
        .ready_in  (1'b1),
        .ready_out (mul_d1t_ready),
        .a         (D1),
        .b         (t_cap),
        .result    (d1t)
    );

    fxMul #() mul_d2t2(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v1a),
        .valid_out (v3b),
        .ready_in  (1'b1),
        .ready_out (mul_d2t2_ready),
        .a         (D2),
        .b         (t2),
        .result    (d2t2)
    );

    fxMul #() mul_d3t3(
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v1b),
        .valid_out (v3c),
        .ready_in  (div_nd_ready),
        .ready_out (mul_d3t3_ready),
        .a         (D3),
        .b         (t3),
        .result    (d3t3)
    );

    // Latch denominator when d3t3 is valid (d1t, d2t2 complete earlier)
    logic den_valid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            den       <= '0;
            den_valid <= 1'b0;
        end else begin
            if (valid_out && ready_in)
                den_valid <= 1'b0;
            if (v3c && !den_valid) begin
                den       <= ONE + d1t + d2t2 + d3t3;
                den_valid <= 1'b1;
            end
        end
    end

    // Divide numerator by denominator
    logic v4;
    logic [WIDTH-1:0] ratio;

    fxDiv #() div_nd (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (num_valid && den_valid),
        .valid_out  (v4),
        .ready_in   (ready_in),
        .ready_out  (div_nd_ready),
        .numerator  (num),
        .denominator(den),
        .result     (ratio)
    );

    // Output: z = negate ? -(t - ratio) : (t - ratio)
    // Uses t_cap (stable) and negate_cap (stable).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z         <= '0;
            valid_out <= 1'b0;
        end else begin
            if (valid_out && ready_in)
                valid_out <= 1'b0;
            if (v4 && !valid_out) begin
                valid_out <= 1'b1;
                z <= negate_cap ? -(t_cap - ratio) : (t_cap - ratio);
            end
        end
    end

`ifdef ASSERT_STRICT
    assert property (@(posedge clk) disable iff (!rst_n) valid_out && !ready_in |=> $stable(z))
        else $error("fxInvCDF_ZS: Output changed under backpressure");
`endif

endmodule
