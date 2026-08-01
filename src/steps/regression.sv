timeunit 1ns; timeprecision 1ps;
module regression #(
    parameter int WIDTH = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT  = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC = fpga_cfg_pkg::FP_QFRAC
)(
    input  logic                         clk,
    input  logic                         rst_n,

    // from accumulator
    input  logic                         valid_in,
    output logic                         ready_out,   // accept new matrix
    input  logic                         ready_in,    // downstream ready for beta

    input  logic signed [WIDTH-1:0]      mat_flat [0:11],
    output logic                         valid_out,
    output logic                         singular_err,
    output logic signed [WIDTH-1:0]      beta [0:2]
);
    // Helper abs
    function automatic logic signed [WIDTH-1:0]
        abs_val(input logic signed [WIDTH-1:0] x);
        return x[WIDTH-1] ? -x : x;
    endfunction

    // Skid buffer for 12-element matrix vector
    logic                         skid_s_ready;
    logic                         skid_m_valid;
    logic                         skid_m_ready;
    wire signed [WIDTH-1:0]      skid_s_data [0:11];
    logic signed [WIDTH-1:0]      skid_m_data [0:11];

    // Map array to skid
    genvar gi;
    generate
        for (gi = 0; gi < 12; ++gi) begin : MAP_IN
            assign skid_s_data[gi] = mat_flat[gi];
        end
    endgenerate

    // Fallback mean: trigger when a pivot fails
    logic mean_valid;
    logic mean_ready;
    logic signed [WIDTH-1:0] mean_payoff;

    // Stage regs
    logic v0;
    logic v0a;   // Stage-1a valid: abs_val latched, mat0_d latched
    logic v1;
    logic v2;
    logic v3;
    logic v4;
    logic v5;
    logic v6;
    logic v6b;
    logic v7a;
    logic v7b1;
    logic v7b;
    logic v7c1;
    logic v7c;

    logic signed [WIDTH-1:0] mat0[0:2][0:3];
    logic signed [WIDTH-1:0] mat1[0:2][0:3];
    logic signed [WIDTH-1:0] mat2[0:2][0:3];
    logic signed [WIDTH-1:0] mat3[0:2][0:3];
    logic signed [WIDTH-1:0] mat4[0:2][0:3];
    logic signed [WIDTH-1:0] mat5[0:2][0:3];
    logic signed [WIDTH-1:0] mat6[0:2][0:3];
    logic signed [WIDTH-1:0] mat7[0:2][0:3];

    // Pivots
    logic [1:0] pivot0_row;
    logic [1:0] pivot1_row;

    // Sticky singular flag (per-solve): set on pivot failure, cleared when a new
    // solve starts or when result is committed. We ensure the pipeline only
    // accepts a new solve when either normal path can drain (barriers) or
    // fallback result (mean_valid) is ready, so clearing at v0 is safe.
    wire pivot0_is_zero;
    wire pivot1_is_zero;
    wire pivot2_is_zero;

    // Stage0 inputs latched for fallback mean
    logic signed [WIDTH-1:0] sum1_latched;
    logic signed [WIDTH-1:0] sumy_latched;

    // Skid downstream ready when pipeline can drain to completion (all barriers)
    // OR fallback result is ready (mean_valid). This prevents accepting a new
    // solve before the current result (normal or fallback) can be produced.
    logic in_flight;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) in_flight <= 1'b0;
        else if (skid_m_valid && skid_m_ready) in_flight <= 1'b1;         // accepted a solve
        else if ((v7c && !singular_err && ready_in) || (mean_valid && ready_in))
            in_flight <= 1'b0;                                             // result committed
    end
    assign skid_m_ready = ready_in && !in_flight;

    rv_skid_arr_gate #(.N(12), .DW(WIDTH)) u_skid (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_valid     (valid_in),
        .s_ready     (skid_s_ready),
        .s_data      (skid_s_data),
        .gate_accept (1'b1),
        .m_valid     (skid_m_valid),
        .m_ready     (skid_m_ready),
        .m_data      (skid_m_data)
    );
    assign ready_out = skid_s_ready;

    // Stage 0
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0           <= 1'b0;
        end else begin
            v0 <= skid_m_valid && skid_m_ready;

            if (skid_m_valid && skid_m_ready) begin
                for (int i = 0; i < 3; i++) begin
                    mat0[i][0] <= skid_m_data[i*4+0];
                    mat0[i][1] <= skid_m_data[i*4+1];
                    mat0[i][2] <= skid_m_data[i*4+2];
                    mat0[i][3] <= skid_m_data[i*4+3];
                end
                sum1_latched <= skid_m_data[0];
                sumy_latched <= skid_m_data[3];
            end
        end
    end

    // Stage-1a : latch abs_val(mat0[i][0]) and a delayed mat0_d copy.
    //   Breaks the previous 12-CARRY4 / 20-logic-level critical path (mat0 ->
    //   abs+compare cascade -> pivot0_row -> row mux -> mat1) into two shorter
    //   stages. +1 pipeline cycle per solve, ~negligible vs solve latency.
    logic signed [WIDTH-1:0] a0_col0 [0:2];
    logic signed [WIDTH-1:0] mat0_d  [0:2][0:3];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0a <= 1'b0;
        end else begin
            v0a        <= v0;
            a0_col0[0] <= abs_val(mat0[0][0]);
            a0_col0[1] <= abs_val(mat0[1][0]);
            a0_col0[2] <= abs_val(mat0[2][0]);
            for (int r = 0; r < 3; r++) begin
                for (int c = 0; c < 4; c++) begin
                    mat0_d[r][c] <= mat0[r][c];
                end
            end
        end
    end

    // Stage-1b : pivot row 0 from registered absolutes + row mux into mat1.
    always_comb begin
        pivot0_row = 2'd0;
        if (a0_col0[1] > a0_col0[0])          pivot0_row = 2'd1;
        if (a0_col0[2] > a0_col0[pivot0_row]) pivot0_row = 2'd2;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v1 <= 1'b0;
        else begin
            v1          <= v0a;
            mat1[0][0]  <= mat0_d[pivot0_row][0];
            mat1[0][1]  <= mat0_d[pivot0_row][1];
            mat1[0][2]  <= mat0_d[pivot0_row][2];
            mat1[0][3]  <= mat0_d[pivot0_row][3];
            mat1[1][0]  <= (2'd1 == pivot0_row) ? mat0_d[0][0] : mat0_d[1][0];
            mat1[1][1]  <= (2'd1 == pivot0_row) ? mat0_d[0][1] : mat0_d[1][1];
            mat1[1][2]  <= (2'd1 == pivot0_row) ? mat0_d[0][2] : mat0_d[1][2];
            mat1[1][3]  <= (2'd1 == pivot0_row) ? mat0_d[0][3] : mat0_d[1][3];
            mat1[2][0]  <= (2'd2 == pivot0_row) ? mat0_d[0][0] : mat0_d[2][0];
            mat1[2][1]  <= (2'd2 == pivot0_row) ? mat0_d[0][1] : mat0_d[2][1];
            mat1[2][2]  <= (2'd2 == pivot0_row) ? mat0_d[0][2] : mat0_d[2][2];
            mat1[2][3]  <= (2'd2 == pivot0_row) ? mat0_d[0][3] : mat0_d[2][3];
        end
    end

    // ============================================================================
    // Stage 2 / 5 / 6B : SHARED solver divider (Plan A)
    //   Replaces 10 parallel fxDiv (DIV0 x4, DIV1 x3, DIV2 x3) with 1 shared
    //   fxDiv + a scheduler. Groups are time-separated by the main pipeline (v1,
    //   v4, v6 pulses) and in_flight blocks solve-overlap, so only one group is
    //   ever active. Numerators are fed one per cycle; results collected into
    //   div{0,1,2}_res[] arrays; g{0,1,2}_all_done pulses mirror the old
    //   &div{0,1,2}_done semantics for the downstream latch code.
    // ============================================================================
    logic signed [WIDTH-1:0] div0_res [0:3];
    logic signed [WIDTH-1:0] div1_res [0:2];
    logic signed [WIDTH-1:0] div2_res [0:2];

    logic g0_all_done;
    logic g1_all_done;
    logic g2_all_done;

    assign pivot0_is_zero = v1 && (mat1[0][0] == '0);
    assign pivot1_is_zero = v4 && (mat4[1][1] == '0);
    assign pivot2_is_zero = (mat6[2][2] == '0);

    // Shared divider handshake
    logic                     sh_valid_in;
    logic                     sh_ready_out;
    logic                     sh_valid_out;
    logic signed [WIDTH-1:0]  sh_num;
    logic signed [WIDTH-1:0]  sh_den;
    logic signed [WIDTH-1:0]  sh_res;

    fxDiv #() u_solver_div (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (sh_valid_in),
        .ready_out   (sh_ready_out),
        .ready_in    (1'b1),
        .valid_out   (sh_valid_out),
        .numerator   (sh_num),
        .denominator (sh_den),
        .result      (sh_res)
    );

    // Per-group numerators (combinational; sources remain stable during a group)
    logic signed [WIDTH-1:0] g0_num [0:3];
    logic signed [WIDTH-1:0] g1_num [0:2];
    logic signed [WIDTH-1:0] g2_num [0:2];

    generate
        for (genvar gN0 = 0; gN0 < 4; gN0++) begin : NUM0_COMB
            logic signed [2*WIDTH-1:0] ext;
            assign ext         = $signed({{WIDTH{mat1[0][gN0][WIDTH-1]}}, mat1[0][gN0]}) <<< QFRAC;
            assign g0_num[gN0] = ext[WIDTH+QFRAC-1 : QFRAC];
        end
        for (genvar gN1 = 0; gN1 < 3; gN1++) begin : NUM1_COMB
            logic signed [2*WIDTH-1:0] ext;
            assign ext         = $signed({{WIDTH{mat4[1][gN1+1][WIDTH-1]}}, mat4[1][gN1+1]}) <<< QFRAC;
            assign g1_num[gN1] = ext[WIDTH+QFRAC-1 : QFRAC];
        end
        for (genvar gN2 = 0; gN2 < 3; gN2++) begin : NUM2_COMB
            logic signed [2*WIDTH-1:0] ext;
            assign ext         = $signed({{WIDTH{mat6[2][gN2+1][WIDTH-1]}}, mat6[2][gN2+1]}) <<< QFRAC;
            assign g2_num[gN2] = ext[WIDTH+QFRAC-1 : QFRAC];
        end
    endgenerate

    // Scheduler FSM
    typedef enum logic [1:0] { D_IDLE, D_G0, D_G1, D_G2 } d_state_e;
    d_state_e ds;
    logic [2:0] iss_cnt;
    logic [2:0] rx_cnt;

    wire [2:0] grp_n = (ds == D_G0) ? 3'd4 :
                       (ds == D_G1) ? 3'd3 :
                       (ds == D_G2) ? 3'd3 : 3'd0;

    always_comb begin
        sh_num      = '0;
        sh_den      = '0;
        sh_valid_in = 1'b0;
        unique case (ds)
            D_G0: begin
                sh_num      = g0_num[iss_cnt[1:0]];
                sh_den      = mat1[0][0];
                sh_valid_in = (iss_cnt < 3'd4);
            end
            D_G1: begin
                sh_num      = g1_num[iss_cnt[1:0]];
                sh_den      = mat4[1][1];
                sh_valid_in = (iss_cnt < 3'd3);
            end
            D_G2: begin
                sh_num      = g2_num[iss_cnt[1:0]];
                sh_den      = mat6[2][2];
                sh_valid_in = (iss_cnt < 3'd3);
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds          <= D_IDLE;
            iss_cnt     <= '0;
            rx_cnt      <= '0;
            g0_all_done <= 1'b0;
            g1_all_done <= 1'b0;
            g2_all_done <= 1'b0;
            for (int i = 0; i < 4; i++) div0_res[i] <= '0;
            for (int i = 0; i < 3; i++) div1_res[i] <= '0;
            for (int i = 0; i < 3; i++) div2_res[i] <= '0;
        end else begin
            g0_all_done <= 1'b0;
            g1_all_done <= 1'b0;
            g2_all_done <= 1'b0;

            // issue one numerator per cycle when the core can accept it
            if ((ds == D_G0 || ds == D_G1 || ds == D_G2) &&
                sh_valid_in && sh_ready_out) begin
                iss_cnt <= iss_cnt + 1'b1;
            end

            // collect one result per cycle as it arrives
            if (sh_valid_out) begin
                unique case (ds)
                    D_G0:    div0_res[rx_cnt[1:0]] <= sh_res;
                    D_G1:    div1_res[rx_cnt[1:0]] <= sh_res;
                    D_G2:    div2_res[rx_cnt[1:0]] <= sh_res;
                    default: ;
                endcase
                rx_cnt <= rx_cnt + 1'b1;

                if (rx_cnt + 3'd1 == grp_n) begin
                    unique case (ds)
                        D_G0:    g0_all_done <= 1'b1;
                        D_G1:    g1_all_done <= 1'b1;
                        D_G2:    g2_all_done <= 1'b1;
                        default: ;
                    endcase
                    ds      <= D_IDLE;
                    iss_cnt <= '0;
                    rx_cnt  <= '0;
                end
            end

            // IDLE: pick up the next group trigger (mutually exclusive by pipeline order)
            if (ds == D_IDLE) begin
                if      (v1 && !pivot0_is_zero) ds <= D_G0;
                else if (v4 && !pivot1_is_zero) ds <= D_G1;
                else if (v6 && !pivot2_is_zero) ds <= D_G2;
            end
        end
    end

    // Stage 2 latch : mat1 row 0 normalized -> mat2
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2 <= 1'b0;
            for (int r=0; r<3; r++)
            for (int c=0; c<4; c++)
                mat2[r][c] <= '0;
        end else begin
            v2          <= g0_all_done;
            mat2[0][0]  <= div0_res[0];
            mat2[0][1]  <= div0_res[1];
            mat2[0][2]  <= div0_res[2];
            mat2[0][3]  <= div0_res[3];

            mat2[1][0]  <= mat1[1][0];
            mat2[1][1]  <= mat1[1][1];
            mat2[1][2]  <= mat1[1][2];
            mat2[1][3]  <= mat1[1][3];
            
            mat2[2][0]  <= mat1[2][0];
            mat2[2][1]  <= mat1[2][1];
            mat2[2][2]  <= mat1[2][2];
            mat2[2][3]  <= mat1[2][3];
        end
    end

    // Stage 3 : eliminate col‑0 (8 mul)
    logic signed [WIDTH-1:0] mul0_r0[0:3];
    logic signed [WIDTH-1:0] mul0_r1[0:3];
    logic [3:0]              mul0_done_r0;
    logic [3:0]              mul0_done_r1;
    logic [3:0]              mul0_ready_r0;
    logic [3:0]              mul0_ready_r1;


    generate
        for (genvar c = 0; c < 4; c++) begin : MUL0
            fxMul #() m0 (
                .clk       (clk),
                .rst_n     (rst_n),
                .valid_in  (v2),
                .ready_out (mul0_ready_r0[c]),
                .ready_in  (1'b1),
                .valid_out (mul0_done_r0[c]),
                .a         (mat2[1][0]),
                .b         (mat2[0][c]),
                .result    (mul0_r0[c])
            );
            fxMul #() m1 (
                .clk       (clk),
                .rst_n     (rst_n),
                .valid_in  (v2),
                .ready_out (mul0_ready_r1[c]),
                .ready_in  (1'b1),
                .valid_out (mul0_done_r1[c]),
                .a         (mat2[2][0]),
                .b         (mat2[0][c]),
                .result    (mul0_r1[c])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3 <= 1'b0;
            for (int j = 0; j < 4; ++j) begin
                mat3[0][j] <= '0;
                mat3[1][j] <= '0;
                mat3[2][j] <= '0;
            end
        end else begin
            // v2 is 1-cycle pulse; mul0_done fires 1 cycle later — drop && v2 to avoid deadlock
            v3 <= (&mul0_done_r0) && (&mul0_done_r1);
            for (int j = 0; j < 4; ++j) begin
                mat3[0][j] <= mat2[0][j];
                mat3[1][j] <= mat2[1][j] - mul0_r0[j];
                mat3[2][j] <= mat2[2][j] - mul0_r1[j];
            end
        end
    end

    // Stage‑4 : pivot row‑1
    always_comb begin
        pivot1_row = 2'd1;
        if (abs_val(mat3[2][1]) > abs_val(mat3[1][1])) pivot1_row = 2'd2;
    end

    always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) v4 <= 1'b0;
    else begin
        v4 <= v3;

        // Row 0 unchanged
        for (int j = 0; j < 4; j++) begin
            mat4[0][j] <= mat3[0][j];
        end

        // Pivoted row 1
        for (int j = 0; j < 4; j++) begin
            mat4[1][j] <= mat3[pivot1_row][j];
        end

        // Remaining row 2
        for (int j = 0; j < 4; j++) begin
            mat4[2][j] <= (pivot1_row == 2'd2) ? mat3[1][j] : mat3[2][j];
        end
    end
end

    // Stage 5 : normalize row‑1 (3 div) — served by the shared solver divider
    //          (div1_res / pivot1_is_zero / g1_all_done declared above).

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v5 <= 1'b0;
        else begin
            v5          <= g1_all_done;
            mat5[0][0]  <= mat4[0][0];
            mat5[0][1]  <= mat4[0][1];
            mat5[0][2]  <= mat4[0][2];
            mat5[0][3]  <= mat4[0][3];
            mat5[1][0]  <= mat4[1][0];
            mat5[1][1]  <= div1_res[0];
            mat5[1][2]  <= div1_res[1];
            mat5[1][3]  <= div1_res[2];
            mat5[2][0]  <= mat4[2][0];
            mat5[2][1]  <= mat4[2][1];
            mat5[2][2]  <= mat4[2][2];
            mat5[2][3]  <= mat4[2][3];
        end
    end

    // Stage‑6 : eliminate col‑1 in row‑2
    logic signed [WIDTH-1:0] mul_elim_res[3];
    logic [2:0]              mul_elim_valid;
    logic [2:0]              mul_elim_ready;


    generate
        for (genvar j = 1; j < 4; j++) begin : ELIM_MUL
            logic signed [WIDTH-1:0] mul_res;
            fxMul #() mul_elim (
                .clk       (clk),
                .rst_n     (rst_n),
                .valid_in  (v5),
                .ready_out (mul_elim_ready[j-1]),
                .ready_in  (1'b1),
                .valid_out (mul_elim_valid[j-1]),
                .a         (mat5[2][1]),
                .b         (mat5[1][j]),
                .result    (mul_res)
            );
            assign mul_elim_res[j-1] = mul_res;
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v6 <= 1'b0;
            for (int j = 0; j < 4; ++j) begin
                mat6[0][j] <= '0;
                mat6[1][j] <= '0;
                mat6[2][j] <= '0;
            end
        end else begin
            // v5 pulse kicked all multipliers; wait until they all done
            if (&mul_elim_valid) begin
                v6 <= 1'b1;

                for (int j2 = 0; j2 < 4; ++j2) begin
                    mat6[0][j2] <= mat5[0][j2];
                    mat6[1][j2] <= mat5[1][j2];
                end

                mat6[2][0] <= mat5[2][0];
                for (int j3 = 1; j3 < 4; ++j3) begin
                    mat6[2][j3] <= mat5[2][j3] - mul_elim_res[j3-1];
                end
            end else begin
                v6 <= 1'b0;
                // leave mat6 as-is
            end
        end
    end

    // Stage-6B : normalize row‑2 — served by the shared solver divider
    //          (div2_res / pivot2_is_zero / g2_all_done declared above).


    // Stage‑7 : back‑substitution
    logic signed [WIDTH-1:0] bt2;
    logic signed [WIDTH-1:0] bt1;
    logic signed [WIDTH-1:0] bt0;
    logic signed [WIDTH-1:0] bt2_latched;
    logic signed [WIDTH-1:0] bt1_latched;
    logic                     div_b2_ready;
    logic                     mul12_ready;
    logic                     div_b1_ready;
    logic                     mul01_ready;
    logic                     mul02_ready;
    logic                     div_b0_ready;


    // bt2 and bt1 are AXI-stream values: they are guaranteed only while their
    // valid signals are asserted. Preserve each accepted quotient for the
    // later multiply and final coefficient commit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bt2_latched <= '0;
            bt1_latched <= '0;
        end else begin
            if (v7a && mul12_ready)
                bt2_latched <= bt2;
            if (v7b && mul01_ready)
                bt1_latched <= bt1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            singular_err <= 1'b0;
        end else if (skid_m_valid && skid_m_ready) begin
            // new solve starts
            singular_err <= 1'b0;
        end         else if ((v1 && pivot0_is_zero) ||
                     (v4 && pivot1_is_zero) ||
                     (v6  && pivot2_is_zero)) begin
            singular_err <= 1'b1;
        end else if ((v7c && !singular_err && ready_in) ||
                    (mean_valid && ready_in)) begin
            // result committed (normal or fallback)
            singular_err <= 1'b0;
        end
    end

    integer j4;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v6b <= 1'b0;
            // clear mat7
            for (int j4 = 0; j4 < 4; ++j4) begin
                mat7[0][j4] <= '0;
                mat7[1][j4] <= '0;
            end
            mat7[2][0] <= '0;
            mat7[2][1] <= '0;
            mat7[2][2] <= '0;
            mat7[2][3] <= '0;
        end else begin
            // pulsed when all 3 divides for this group finished and pivot was non-zero
            v6b <= g2_all_done;

            if (g2_all_done) begin
                // copy rows 0 and 1
                for (int j4 = 0; j4 < 4; ++j4) begin
                    mat7[0][j4] <= mat6[0][j4];
                    mat7[1][j4] <= mat6[1][j4];
                end
                // row 2: col0 ~ 0, col1..3 normalized
                mat7[2][0] <= mat6[2][0];
                mat7[2][1] <= div2_res[0];
                mat7[2][2] <= div2_res[1];
                mat7[2][3] <= div2_res[2];
            end
            // else: leave mat7 unchanged (we only care when v6b == 1)
        end
    end

    // bt2 = mat7[2][3] / mat7[2][2]
    logic signed [2*WIDTH-1:0] num64_b2;
    assign num64_b2 = $signed({{WIDTH{mat7[2][3][WIDTH-1]}}, mat7[2][3]}) <<< QFRAC;
    fxDiv #() div_b2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (v6b && !pivot2_is_zero),
        .ready_out  (div_b2_ready),
        .ready_in   (mul12_ready),
        .valid_out  (v7a),
        .numerator  (num64_b2[WIDTH+QFRAC-1 : QFRAC]),
        .denominator(mat7[2][2]),
        .result     (bt2)
    );

    logic signed [WIDTH-1:0] prod12;
    logic signed [WIDTH-1:0] prod01;
    logic signed [WIDTH-1:0] prod02;

    fxMul #() mul12 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v7a),
        .ready_out (mul12_ready),
        .ready_in  (div_b1_ready),
        .valid_out (v7b1),
        .a         (mat7[1][2]),
        .b         (bt2),
        .result    (prod12)
    );

    // bt1 = (mat7[1][3] - mat7[1][2]*bt2) / mat7[1][1]
    logic signed [WIDTH-1:0] rhs1;
    logic signed [2*WIDTH-1:0] num64_b1;
    assign rhs1      = $signed(mat7[1][3]) - prod12;
    assign num64_b1  = $signed({{WIDTH{rhs1[WIDTH-1]}}, rhs1}) <<< QFRAC;

    fxDiv #() div_b1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (v7b1),
        .ready_out  (div_b1_ready),
        .ready_in   (mul01_ready),
        .valid_out  (v7b),
        .numerator  (num64_b1[WIDTH+QFRAC-1 : QFRAC]),
        .denominator(mat7[1][1]),
        .result     (bt1)
    );

    fxMul #() mul01 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v7b),
        .ready_out (mul01_ready),
        .ready_in  (mul02_ready),
        .valid_out (v7c1),
        .a         (mat7[0][1]),
        .b         (bt1),
        .result    (prod01)
    );

    logic                    v7c2;
    fxMul #() mul02 (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (v7c1),
        .ready_out (mul02_ready),
        .ready_in  (div_b0_ready),
        .valid_out (v7c2),
        .a         (mat7[0][2]),
        .b         (bt2_latched),
        .result    (prod02)
    );

    // bt0 = (mat7[0][3] - mat7[0][1]*bt1 - mat7[0][2]*bt2) / mat7[0][0]
    logic signed [WIDTH-1:0]   rhs0;
    logic signed [2*WIDTH-1:0] num64_b0;
    assign rhs0     = $signed(mat7[0][3]) - prod01 - prod02;
    assign num64_b0 = $signed({{WIDTH{rhs0[WIDTH-1]}}, rhs0}) <<< QFRAC;

    fxDiv #() div_b0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (v7c2),
        .ready_out  (div_b0_ready),
        .ready_in   (ready_in),
        .valid_out  (v7c),
        .numerator  (num64_b0[WIDTH+QFRAC-1 : QFRAC]),
        .denominator(mat7[0][0]),
        .result     (bt0)
    );


    // Fallback mean: trigger when a pivot fails
    wire fallback_req;
    logic signed [2*WIDTH-1:0] num64_mean;

    // Use v6 (not v6b) for pivot2: v6b = (&div2_done) && !pivot2_is_zero, so when
    // pivot2_is_zero v6b never fires. Fallback must trigger when we reach v6 and pivot2 is zero.
    assign fallback_req = (v1  && pivot0_is_zero) ||
                          (v4  && pivot1_is_zero) ||
                          (v6  && pivot2_is_zero);

    assign num64_mean = $signed({{WIDTH{sumy_latched[WIDTH-1]}}, sumy_latched}) <<< QFRAC;

    fxDiv #() div_mean (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (fallback_req),
        .ready_out  (mean_ready),
        .ready_in   (1'b1),
        .valid_out  (mean_valid),
        .numerator  (num64_mean[WIDTH+QFRAC-1 : QFRAC]),
        .denominator(sum1_latched),
        .result     (mean_payoff)
    );

    // Output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            beta[0]   <= '0;
            beta[1]   <= '0;
            beta[2]   <= '0;
        end else begin
            valid_out <= 1'b0;
            // normal path
            if (v7c && !singular_err && ready_in) begin
                beta[2]   <= bt2_latched;
                beta[1]   <= bt1_latched;
                beta[0]   <= bt0;
                valid_out <= 1'b1;
            end
            // fallback path
            else if (mean_valid && ready_in) begin
                beta[2]   <= '0;
                beta[1]   <= '0;
                beta[0]   <= mean_payoff;
                valid_out <= 1'b1;
            end
        end
    end
`ifdef REG_DEBUG
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        end else begin
            if (v0 || v1 || v2 || v3 || v4 || v5 || v6 || v6b ||
                v7a || v7b1 || v7b || v7c || mean_valid) begin
                $display("%t [REG] v0=%0b v1=%0b v2=%0b v3=%0b v4=%0b v5=%0b v6=%0b v6b=%0b v7a=%0b v7b1=%0b v7b=%0b v7c=%0b mean_valid=%0b sing_err=%0b",
                        $time, v0, v1, v2, v3, v4, v5, v6, v6b,
                        v7a, v7b1, v7b, v7c, mean_valid, singular_err);
                $display("%t [REG] pivots: p0_zero=%0b p1_zero=%0b p2_zero=%0b",
                        $time, pivot0_is_zero, pivot1_is_zero, pivot2_is_zero);
            end
            if (v6b)
                $display("%t [REG-DATA] v6b mat7_13=%h mat7_12=%h mat7_02=%h mat7_01=%h mat7_03=%h",
                         $time, mat7[1][3], mat7[1][2], mat7[0][2], mat7[0][1], mat7[0][3]);
            if (v7a)
                $display("%t [REG-DATA] v7a bt2=%h", $time, bt2);
            if (v7b1)
                $display("%t [REG-DATA] v7b1 prod12=%h rhs1=%h", $time, prod12, rhs1);
            if (v7b)
                $display("%t [REG-DATA] v7b bt1=%h", $time, bt1);
            if (v7c1)
                $display("%t [REG-DATA] v7c1 prod01=%h", $time, prod01);
            if (v7c2)
                $display("%t [REG-DATA] v7c2 prod01=%h prod02=%h rhs0=%h",
                         $time, prod01, prod02, rhs0);
            if (v7c)
                $display("%t [REG-DATA] v7c bt0=%h bt1_latched=%h bt2_latched=%h singular=%0b ready=%0b",
                         $time, bt0, bt1_latched, bt2_latched, singular_err, ready_in);
            if (mean_valid)
                $display("%t [REG-DATA] mean_valid payoff=%h singular=%0b ready=%0b",
                         $time, mean_payoff, singular_err, ready_in);
            if (valid_out)
                $display("%t [REG] valid_out=1, beta0=%h beta1=%h beta2=%h",
                        $time, beta[0], beta[1], beta[2]);
        end
    end
`endif

    // Assertions
    // capture previous samples
    logic signed [WIDTH-1:0] skid_m_data_q [0:11];
    logic signed [WIDTH-1:0] beta_q        [0:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i=0;i<12;i++) skid_m_data_q[i] <= '0;
            for (int j=0;j<3;j++)  beta_q[j]        <= '0;
        end else begin
            // update refs only when not stalling
            if (!(skid_m_valid && !skid_m_ready))
            for (int i=0;i<12;i++) skid_m_data_q[i] <= skid_m_data[i];
            if (!(valid_out && !ready_in))
            for (int j=0;j<3;j++)  beta_q[j]        <= beta[j];
        end
    end

    // sustained stall -> must match previous sample
    logic skid_bp, skid_bp_prev, out_bp, out_bp_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_bp_prev <= 1'b0; skid_bp <= 1'b0;
            out_bp_prev  <= 1'b0; out_bp  <= 1'b0;
        end else begin
            skid_bp_prev <= skid_bp;
            skid_bp      <= skid_m_valid && !skid_m_ready;
            if (skid_bp_prev && skid_bp)
            for (int i=0;i<12;i++) assert (skid_m_data[i] == skid_m_data_q[i])
                else $error("Regression: skid output changed under backpressure");

            out_bp_prev  <= out_bp;
            out_bp       <= valid_out && !ready_in;
            if (out_bp_prev && out_bp)
            for (int j=0;j<3;j++)  assert (beta[j] == beta_q[j])
                else $error("Regression: output stall overwrite");
        end
    end


    // Implement the sticky check with a one-cycle flag
    logic singular_sticky_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            singular_sticky_prev <= 1'b0;
        end else begin
            // A committed normal/fallback result is the defined end of the
            // solve, so clearing singular_err on that edge is legal.
            singular_sticky_prev <= singular_err &&
                !(skid_m_valid && skid_m_ready) &&
                !((v7c && !singular_err && ready_in) ||
                  (mean_valid && ready_in));
            if (singular_sticky_prev)
            assert (singular_err)
                else $error("Regression: singular_err not sticky within solve");
        end
    end

    // Stage2 desync guard: when accepting barrier+v2, mat2 must not change vs previous sample
    logic signed [WIDTH-1:0] mat2_q [0:2][0:3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r=0;r<3;r++) for (int c=0;c<4;c++) mat2_q[r][c] <= '0;
        end else if (!(v2)) begin
            for (int r=0;r<3;r++) for (int c=0;c<4;c++) mat2_q[r][c] <= mat2[r][c];
        end
    end

    logic hold_s2_prev, hold_s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_s2_prev <= 1'b0; hold_s2 <= 1'b0;
        end else begin
            hold_s2_prev <= hold_s2;
            hold_s2      <= v2;
            if (hold_s2_prev && hold_s2)
            for (int r=0;r<3;r++) for (int c=0;c<4;c++)
                assert (mat2[r][c] == mat2_q[r][c])
                else $error("Regression: stage2 desync on stall");
        end
    end

endmodule
