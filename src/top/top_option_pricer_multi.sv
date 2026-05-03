timeunit 1ns;
timeprecision 1ps;

// =============================================================================
// top_mc_option_pricer_multi
//
// Compile-time optional multi-exercise Longstaff-Schwartz engine.
//
// V1 is intentionally single-lane and cashflow-RAM based:
//   * no full S[path][step] path storage
//   * deterministic Sobol/GBM path regeneration for each exercise date
//   * one Q16.16 cashflow word per path
//
// This module mirrors the current C++ --exercise-mode multi contract:
//   PUT: exercise at every simulated step 1..M-1
//   CALL: no early exercise while q=0; terminal payoff discounted by disc^M
//   PUT regression basis: x = S/K - 1, basis [1, x, x^2]
// =============================================================================

module top_mc_option_pricer_multi #(
    parameter int CLK_FREQ_HZ              = 100_000_000,
    parameter int BAUD_RATE                = 115200,
    parameter int unsigned CORE_MAX_CYCLES = 32'd50_000_000,
    parameter int MAX_STEPS                = 50,
    parameter int MAX_PATHS                = 16384
)(
    input  logic clk_100,
    input  logic rst_btn_n,
    input  logic uart_rxd,
    output logic uart_txd
);
    localparam int W  = fpga_cfg_pkg::FP_WIDTH;
    localparam int QF = fpga_cfg_pkg::FP_QFRAC;
    localparam signed [W-1:0] ONE_Q = 32'sd1 <<< QF;
    localparam signed [W-1:0] BETA_ABS_CAP_Q = 32'sd4096 <<< QF;
    localparam int PATH_AW = (MAX_PATHS <= 2) ? 1 : $clog2(MAX_PATHS);

    // =========================================================================
    // UART I/O
    // =========================================================================
    logic        batch_valid, batch_ready;
    logic [31:0] param_paths, param_steps, param_S0, param_K;
    logic [31:0] param_r, param_sigma, param_T;
    logic        param_option_type;
    logic        result_valid;
    logic [31:0] result_price, result_cycles_lo, result_cycles_hi;

    uart_input_handler #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart (
        .clk        (clk_100),
        .rst_n      (rst_btn_n),
        .rx         (uart_rxd),
        .tx         (uart_txd),
        .batch_valid(batch_valid),
        .batch_ready(batch_ready),
        .paths      (param_paths),
        .steps      (param_steps),
        .S0         (param_S0),
        .K          (param_K),
        .r          (param_r),
        .sigma      (param_sigma),
        .T          (param_T),
        .option_type(param_option_type),
        .result_valid    (result_valid),
        .result_price    (result_price),
        .result_cycles_lo(result_cycles_lo),
        .result_cycles_hi(result_cycles_hi)
    );

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_INIT_DT,
        ST_INIT_GBM_CONST,
        ST_INIT_DISC,
        ST_INIT_INV_K,
        ST_INIT_DISC_M,
        ST_TERM_STEP,
        ST_TERM_WRITE,
        ST_BACK_START,
        ST_TRAIN_STEP,
        ST_TRAIN_FEED,
        ST_MEAN_DIV,
        ST_REG_START,
        ST_REG_WAIT,
        ST_DECIDE_STEP,
        ST_DECIDE_FEED,
        ST_FINAL_ACC,
        ST_FINAL_DIV,
        ST_DONE
    } state_t;

    state_t state;

`ifdef TOP_NUM_DEBUG
    function automatic string num_pass_name(input state_t st);
        case (st)
            ST_TERM_STEP, ST_TERM_WRITE: num_pass_name = "terminal";
            ST_TRAIN_STEP, ST_TRAIN_FEED, ST_MEAN_DIV, ST_REG_START, ST_REG_WAIT: num_pass_name = "train";
            ST_DECIDE_STEP, ST_DECIDE_FEED: num_pass_name = "decide";
            ST_FINAL_ACC, ST_FINAL_DIV: num_pass_name = "final";
            default: num_pass_name = "multi";
        endcase
    endfunction

`endif

    // Latched parameters
    logic signed [W-1:0] lat_S0, lat_K, lat_r, lat_sigma, lat_T;
    logic [15:0]         lat_N;
    logic [7:0]          lat_M;
    logic                lat_option_type;  // 0=CALL, 1=PUT

    // Computed constants
    logic signed [W-1:0] dt_reg;
    logic signed [W-1:0] drift_const_reg;
    logic signed [W-1:0] vol_sqrt_dt_reg;
    logic signed [W-1:0] disc_reg;
    logic signed [W-1:0] disc_m_reg;
    logic signed [W-1:0] inv_K_reg;

    // Path generation state
    logic [15:0]         path_idx;
    logic [7:0]          step_idx;
    logic [7:0]          exercise_step;
    logic [7:0]          target_step;
    logic signed [W-1:0] s_curr;
    logic signed [W-1:0] s_target;
    logic                sobol_accepted;
    logic [2:0]          drain_cnt;

    // Cashflow RAM: one Q16.16 value per path.
    (* ram_style = "block" *) logic signed [W-1:0] cashflow_mem [0:MAX_PATHS-1];
    logic signed [W-1:0] cashflow_read;
    logic cashflow_we;
    logic [PATH_AW-1:0] cashflow_waddr;
    logic [PATH_AW-1:0] cashflow_raddr;
    logic signed [W-1:0] cashflow_wdata;
    assign cashflow_raddr = path_idx[PATH_AW-1:0];

    always_ff @(posedge clk_100) begin
        cashflow_read <= cashflow_mem[cashflow_raddr];
        if (cashflow_we)
            cashflow_mem[cashflow_waddr] <= cashflow_wdata;
    end

    // Sums for per-step regression
    typedef logic signed [63:0] acc_t;
    acc_t sum1, sumx, sumx2, sumx3, sumx4, sumy, sumxy, sumx2y;
    logic [15:0] itm_count;
    logic signed [W-1:0] cont_reg;
    logic signed [W-1:0] immediate_reg;
    logic signed [W-1:0] s_norm_reg;
    logic signed [W-1:0] x_basis_reg;
    logic signed [W-1:0] x2_reg;
    logic signed [W-1:0] x3_reg;
    logic signed [W-1:0] x4_reg;
    logic signed [W-1:0] xy_reg;
    logic signed [W-1:0] x2y_reg;
    logic signed [W-1:0] mean_y_reg;

    // Decision temporaries
    logic signed [W-1:0] beta_reg [0:2];
    logic signed [W-1:0] beta1x_reg;
    logic signed [W-1:0] beta2x2_reg;
    logic signed [W-1:0] cont_est_reg;
    logic signed [W-1:0] chosen_reg;

    // Accumulation/final division
    logic signed [63:0]  sum_pv;
    logic [63:0]         final_dividend_abs;
    logic [63:0]         final_div_remainder;
    logic [63:0]         final_div_quotient;
    logic [6:0]          final_div_bit;
    logic                final_div_sign;
    wire [63:0]          final_div_den = (lat_N == 16'd0) ? 64'd1 : {48'd0, lat_N};
    logic [64:0]         final_div_trial_rem;
    logic [63:0]         final_div_remainder_step;
    logic [63:0]         final_div_quotient_step;

    // Sub-phase and init counters
    logic [3:0] sub_phase;
    logic [7:0] disc_pow_cnt;

    // Cycle counter / timeout
    logic [63:0] cycle_counter;
    logic        core_active;
    logic        core_timeout;
    assign core_timeout = core_active && (cycle_counter >= CORE_MAX_CYCLES);

    function automatic acc_t extended(input logic signed [W-1:0] v);
        return {{(64-W){v[W-1]}}, v};
    endfunction

    function automatic logic signed [W-1:0] saturate64(input acc_t val);
        logic signed [W-1:0] max_pos;
        logic signed [W-1:0] min_neg;
        begin
            max_pos = {1'b0, {W-1{1'b1}}};
            min_neg = {1'b1, {W-1{1'b0}}};
            if (val > extended(max_pos))      saturate64 = max_pos;
            else if (val < extended(min_neg)) saturate64 = min_neg;
            else                              saturate64 = val[W-1:0];
        end
    endfunction

    function automatic logic signed [W-1:0] abs32(input logic signed [W-1:0] v);
        return v[W-1] ? -v : v;
    endfunction

    function automatic logic beta_over_cap(input logic signed [W-1:0] b0,
                                           input logic signed [W-1:0] b1,
                                           input logic signed [W-1:0] b2);
        return (abs32(b0) > BETA_ABS_CAP_Q) ||
               (abs32(b1) > BETA_ABS_CAP_Q) ||
               (abs32(b2) > BETA_ABS_CAP_Q);
    endfunction

    function automatic logic signed [W-1:0] payoff_at(input logic signed [W-1:0] S);
        if (lat_option_type)
            payoff_at = (lat_K > S) ? (lat_K - S) : '0;
        else
            payoff_at = (S > lat_K) ? (S - lat_K) : '0;
    endfunction

    function automatic logic signed [W-1:0] final_avg_saturate(input logic [63:0] quotient,
                                                               input logic sign);
        logic signed [W-1:0] max_pos;
        logic signed [W-1:0] min_neg;
        logic [63:0] max_pos_mag;
        logic [63:0] max_neg_mag;
        begin
            max_pos = {1'b0, {W-1{1'b1}}};
            min_neg = {1'b1, {W-1{1'b0}}};
            max_pos_mag = {{(64-W){1'b0}}, max_pos};
            max_neg_mag = {{(64-W){1'b0}}, 1'b1, {W-1{1'b0}}};

            if (sign) begin
                if (quotient >= max_neg_mag)
                    final_avg_saturate = min_neg;
                else
                    final_avg_saturate = -$signed(quotient[W-1:0]);
            end else begin
                if (quotient > max_pos_mag)
                    final_avg_saturate = max_pos;
                else
                    final_avg_saturate = quotient[W-1:0];
            end
        end
    endfunction

    always_comb begin
        final_div_trial_rem      = {final_div_remainder[62:0], final_dividend_abs[final_div_bit]};
        final_div_remainder_step = final_div_trial_rem[63:0];
        final_div_quotient_step  = final_div_quotient;
        if (final_div_trial_rem >= {1'b0, final_div_den}) begin
            final_div_remainder_step = final_div_trial_rem[63:0] - final_div_den;
            final_div_quotient_step[final_div_bit] = 1'b1;
        end
    end

    // =========================================================================
    // Utility math blocks
    // =========================================================================
    logic                 util_mul_vin, util_mul_vout, util_mul_rin, util_mul_rout;
    logic signed [W-1:0] util_mul_a, util_mul_b, util_mul_result;

    fxMul u_util_mul (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_mul_vin), .ready_out(util_mul_rout),
        .valid_out(util_mul_vout), .ready_in(util_mul_rin),
        .a(util_mul_a), .b(util_mul_b), .result(util_mul_result)
    );
    assign util_mul_rin = 1'b1;

    logic                 util_div_vin, util_div_vout, util_div_rin, util_div_rout;
    logic signed [W-1:0] util_div_num, util_div_den_q, util_div_result;

    fxDiv u_util_div (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_div_vin), .ready_out(util_div_rout),
        .valid_out(util_div_vout), .ready_in(util_div_rin),
        .numerator(util_div_num), .denominator(util_div_den_q),
        .result(util_div_result)
    );
    assign util_div_rin = 1'b1;

    logic                 util_exp_vin, util_exp_vout, util_exp_rin, util_exp_rout;
    logic signed [W-1:0] util_exp_a, util_exp_result;

    fxExpLUT u_util_exp (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_exp_vin), .ready_out(util_exp_rout),
        .valid_out(util_exp_vout), .ready_in(util_exp_rin),
        .a(util_exp_a), .result(util_exp_result)
    );
    assign util_exp_rin = 1'b1;

    logic        util_sqrt_vin, util_sqrt_vout, util_sqrt_rin, util_sqrt_rout;
    logic [W-1:0] util_sqrt_a, util_sqrt_result;

    fxSqrt u_util_sqrt (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_sqrt_vin), .ready_out(util_sqrt_rout),
        .valid_out(util_sqrt_vout), .ready_in(util_sqrt_rin),
        .a(util_sqrt_a), .result(util_sqrt_result)
    );
    assign util_sqrt_rin = 1'b1;

    // =========================================================================
    // Sobol -> inverseCDF -> GBM path pipeline
    // =========================================================================
    logic sobol_vin, sobol_rout, sobol_vout;
    logic [W-1:0] sobol_idx;
    logic [$clog2(MAX_STEPS)-1:0] sobol_dim;
    logic [W-1:0] sobol_out;
    logic [W-1:0] sobol_direction [0:MAX_STEPS*W-1];
    logic [15:0] sobol_q16_hi;
    logic signed [W-1:0] sobol_q16;
    logic inv_rout, inv_vout;
    logic signed [W-1:0] inv_z;
    logic gbm_rout, gbm_vout;
    logic signed [W-1:0] gbm_s_next;

    sobol #(.M(MAX_STEPS)) u_sobol (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(sobol_vin), .ready_out(sobol_rout),
        .valid_out(sobol_vout), .ready_in(inv_rout),
        .idx_in(sobol_idx), .dim_in(sobol_dim),
        .sobol_out(sobol_out), .direction(sobol_direction)
    );

    assign sobol_q16_hi = sobol_out[31:16];
    assign sobol_q16 = $signed({16'd0, (sobol_q16_hi == 16'd0) ? 16'd1 : sobol_q16_hi});

    inverseCDF u_inv (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(sobol_vout), .ready_out(inv_rout),
        .u_in(sobol_q16),
        .valid_out(inv_vout), .ready_in(gbm_rout),
        .z_out(inv_z)
    );

    GBM u_gbm (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(inv_vout), .ready_out(gbm_rout),
        .valid_out(gbm_vout), .ready_in(1'b1),
        .z(inv_z), .S(s_curr),
        .drift_const(drift_const_reg),
        .vol_sqrt_dt(vol_sqrt_dt_reg),
        .S_next(gbm_s_next)
    );

`ifdef TOP_NUM_DEBUG
    logic [15:0] dbg_path_q;
    logic [7:0]  dbg_step_q;
    always_ff @(posedge clk_100 or negedge rst_btn_n) begin
        if (!rst_btn_n) begin
            dbg_path_q <= '0;
            dbg_step_q <= '0;
        end else begin
            if (sobol_vin && sobol_rout) begin
                dbg_path_q <= path_idx;
                dbg_step_q <= step_idx + 8'd1;
            end
            if (sobol_vout) begin
                $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=sobol_raw value=0x%08h signed=%0d",
                         num_pass_name(state), dbg_path_q, dbg_step_q, sobol_out, $signed(sobol_out));
                $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=u_q16 value=0x%08h signed=%0d",
                         num_pass_name(state), dbg_path_q, dbg_step_q, sobol_q16, $signed(sobol_q16));
            end
            if (inv_vout) begin
                $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=z value=0x%08h signed=%0d",
                         num_pass_name(state), dbg_path_q, dbg_step_q, inv_z, $signed(inv_z));
            end
            if (u_gbm.exp_vin) begin
                $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=exp_arg value=0x%08h signed=%0d",
                         num_pass_name(state), dbg_path_q, dbg_step_q, u_gbm.exp_arg, $signed(u_gbm.exp_arg));
            end
            if (u_gbm.exp_vout) begin
                $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=exp value=0x%08h signed=%0d",
                         num_pass_name(state), dbg_path_q, dbg_step_q, u_gbm.exp_result, $signed(u_gbm.exp_result));
            end
        end
    end
`endif

    // =========================================================================
    // Regression solver, driven directly by top-level accumulated matrix.
    // =========================================================================
    logic reg_vin, reg_vout, reg_rout, reg_singular;
    logic signed [W-1:0] reg_mat [0:11];
    logic signed [W-1:0] reg_beta [0:2];

    regression u_regression (
        .clk(clk_100),
        .rst_n(rst_btn_n),
        .valid_in(reg_vin),
        .ready_out(reg_rout),
        .ready_in(1'b1),
        .mat_flat(reg_mat),
        .valid_out(reg_vout),
        .singular_err(reg_singular),
        .beta(reg_beta)
    );

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk_100 or negedge rst_btn_n) begin
        if (!rst_btn_n) begin
            state <= ST_IDLE;
            core_active <= 1'b0;
            cycle_counter <= '0;
            result_valid <= 1'b0;
            result_price <= '0;
            batch_ready <= 1'b1;
            path_idx <= '0;
            step_idx <= '0;
            exercise_step <= '0;
            target_step <= '0;
            s_curr <= '0;
            s_target <= '0;
            sobol_accepted <= 1'b0;
            drain_cnt <= '0;
            sum1 <= '0; sumx <= '0; sumx2 <= '0; sumx3 <= '0;
            sumx4 <= '0; sumy <= '0; sumxy <= '0; sumx2y <= '0;
            itm_count <= '0;
            cont_reg <= '0;
            immediate_reg <= '0;
            s_norm_reg <= '0;
            x_basis_reg <= '0;
            x2_reg <= '0;
            x3_reg <= '0;
            x4_reg <= '0;
            xy_reg <= '0;
            x2y_reg <= '0;
            mean_y_reg <= '0;
            for (int i = 0; i < 3; i++) beta_reg[i] <= '0;
            beta1x_reg <= '0;
            beta2x2_reg <= '0;
            cont_est_reg <= '0;
            chosen_reg <= '0;
            sum_pv <= '0;
            final_dividend_abs <= '0;
            final_div_remainder <= '0;
            final_div_quotient <= '0;
            final_div_bit <= '0;
            final_div_sign <= 1'b0;
            sub_phase <= '0;
            disc_pow_cnt <= '0;
            lat_S0 <= '0; lat_K <= '0; lat_r <= '0; lat_sigma <= '0; lat_T <= '0;
            lat_N <= '0; lat_M <= '0; lat_option_type <= 1'b1;
            dt_reg <= '0; drift_const_reg <= '0; vol_sqrt_dt_reg <= '0;
            disc_reg <= '0; disc_m_reg <= '0; inv_K_reg <= '0;
            util_mul_vin <= 1'b0; util_mul_a <= '0; util_mul_b <= '0;
            util_div_vin <= 1'b0; util_div_num <= '0; util_div_den_q <= '0;
            util_exp_vin <= 1'b0; util_exp_a <= '0;
            util_sqrt_vin <= 1'b0; util_sqrt_a <= '0;
            sobol_vin <= 1'b0; sobol_idx <= '0; sobol_dim <= '0;
            reg_vin <= 1'b0;
            cashflow_we <= 1'b0; cashflow_waddr <= '0; cashflow_wdata <= '0;
            for (int j = 0; j < 12; j++) reg_mat[j] <= '0;
        end else begin
            result_valid <= 1'b0;
            util_mul_vin <= 1'b0;
            util_div_vin <= 1'b0;
            util_exp_vin <= 1'b0;
            util_sqrt_vin <= 1'b0;
            sobol_vin <= 1'b0;
            reg_vin <= 1'b0;
            cashflow_we <= 1'b0;

            if (core_active)
                cycle_counter <= cycle_counter + 1'b1;
            if (drain_cnt != 0)
                drain_cnt <= drain_cnt - 1'b1;

            unique case (state)
            ST_IDLE: begin
                batch_ready <= 1'b1;
                if (batch_valid && batch_ready) begin
                    lat_S0 <= $signed(param_S0);
                    lat_K <= $signed(param_K);
                    lat_r <= $signed(param_r);
                    lat_sigma <= $signed(param_sigma);
                    lat_T <= $signed(param_T);
                    lat_N <= param_paths[15:0];
                    lat_M <= param_steps[7:0];
                    lat_option_type <= param_option_type;
                    batch_ready <= 1'b0;
                    core_active <= 1'b1;
                    cycle_counter <= '0;
                    result_price <= '0;
                    sub_phase <= '0;
                    state <= ST_INIT_DT;
                end
            end

            ST_INIT_DT: begin
                if (core_timeout) state <= ST_DONE;
                else if (param_paths > MAX_PATHS || param_steps > MAX_STEPS || param_paths == 0 || param_steps < 1) begin
                    result_price <= 32'hDEAD0002;
                    state <= ST_DONE;
                end else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= lat_T;
                    util_div_den_q <= $signed({24'd0, lat_M}) <<< QF;
                    util_div_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    dt_reg <= util_div_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=dt value=0x%08h signed=%0d", util_div_result, $signed(util_div_result));
`endif
                    sub_phase <= '0;
                    state <= ST_INIT_GBM_CONST;
                end
            end

            ST_INIT_GBM_CONST: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= lat_sigma;
                    util_mul_b <= lat_sigma;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    util_mul_a <= lat_r - (util_mul_result >>> 1);
                    util_mul_b <= dt_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd2;
                end else if (sub_phase == 2 && util_mul_vout) begin
                    drift_const_reg <= util_mul_result;
                    util_sqrt_a <= dt_reg[W-1:0];
                    util_sqrt_vin <= 1'b1;
                    sub_phase <= 4'd3;
                end else if (sub_phase == 3 && util_sqrt_vout) begin
                    util_mul_a <= lat_sigma;
                    util_mul_b <= $signed(util_sqrt_result);
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd4;
                end else if (sub_phase == 4 && util_mul_vout) begin
                    vol_sqrt_dt_reg <= util_mul_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=drift_const value=0x%08h signed=%0d", drift_const_reg, $signed(drift_const_reg));
                    $display("[NUM][INIT] key=vol_sqrt_dt value=0x%08h signed=%0d", util_mul_result, $signed(util_mul_result));
`endif
                    sub_phase <= '0;
                    state <= ST_INIT_DISC;
                end
            end

            ST_INIT_DISC: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= -lat_r;
                    util_mul_b <= dt_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    util_exp_a <= util_mul_result[W-1] ? -util_mul_result : util_mul_result;
                    util_exp_vin <= 1'b1;
                    sub_phase <= 4'd2;
                end else if (sub_phase == 2 && util_exp_vout) begin
                    util_div_num <= ONE_Q;
                    util_div_den_q <= util_exp_result;
                    util_div_vin <= 1'b1;
                    sub_phase <= 4'd3;
                end else if (sub_phase == 3 && util_div_vout) begin
                    disc_reg <= util_div_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=disc value=0x%08h signed=%0d", util_div_result, $signed(util_div_result));
`endif
                    sub_phase <= '0;
                    state <= ST_INIT_INV_K;
                end
            end

            ST_INIT_INV_K: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= ONE_Q;
                    util_div_den_q <= lat_K;
                    util_div_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    inv_K_reg <= util_div_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=inv_K value=0x%08h signed=%0d", util_div_result, $signed(util_div_result));
`endif
                    disc_m_reg <= disc_reg;
                    disc_pow_cnt <= 8'd1;
                    sub_phase <= '0;
                    state <= (lat_M <= 1) ? ST_TERM_STEP : ST_INIT_DISC_M;
                end
            end

            ST_INIT_DISC_M: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= disc_m_reg;
                    util_mul_b <= disc_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    disc_m_reg <= util_mul_result;
                    disc_pow_cnt <= disc_pow_cnt + 1'b1;
                    sub_phase <= '0;
                    if (disc_pow_cnt + 1 >= lat_M) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][INIT] key=disc_total value=0x%08h signed=%0d", util_mul_result, $signed(util_mul_result));
`endif
                        path_idx <= '0;
                        step_idx <= '0;
                        target_step <= lat_M;
                        s_curr <= lat_S0;
                        sobol_accepted <= 1'b0;
                        state <= ST_TERM_STEP;
                    end
                end
            end

            ST_TERM_STEP, ST_TRAIN_STEP, ST_DECIDE_STEP: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (!sobol_accepted && sobol_rout && !gbm_vout && drain_cnt == 0) begin
                    sobol_idx <= {16'd0, path_idx} + W'(1);
                    sobol_dim <= step_idx[$clog2(MAX_STEPS)-1:0];
                    sobol_vin <= 1'b1;
                    sobol_accepted <= 1'b1;
                end else if (sobol_accepted && gbm_vout && drain_cnt == 0) begin
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=0 key=s_next value=0x%08h signed=%0d",
                             num_pass_name(state), path_idx, step_idx + 8'd1, gbm_s_next, $signed(gbm_s_next));
`endif
                    s_curr <= gbm_s_next;
                    step_idx <= step_idx + 1'b1;
                    drain_cnt <= 3'd5;
                    if (step_idx + 1 >= target_step) begin
                        s_target <= gbm_s_next;
                        sobol_accepted <= 1'b0;
                        sub_phase <= '0;
                        if (state == ST_TERM_STEP)
                            state <= ST_TERM_WRITE;
                        else if (state == ST_TRAIN_STEP)
                            state <= ST_TRAIN_FEED;
                        else
                            state <= ST_DECIDE_FEED;
                    end else if (sobol_rout) begin
                        sobol_idx <= {16'd0, path_idx} + W'(1);
                        sobol_dim <= step_idx[$clog2(MAX_STEPS)-1:0] + 1'b1;
                        sobol_vin <= 1'b1;
                        sobol_accepted <= 1'b1;
                    end else begin
                        sobol_accepted <= 1'b0;
                    end
                end
            end

            ST_TERM_WRITE: begin
                cashflow_we <= 1'b1;
                cashflow_waddr <= path_idx[PATH_AW-1:0];
                cashflow_wdata <= payoff_at(s_target);
`ifdef TOP_NUM_DEBUG
                $display("[NUM][ACC-IN] path=%0d step=%0d key=terminal_payoff value=0x%08h signed=%0d",
                         path_idx, lat_M, payoff_at(s_target), $signed(payoff_at(s_target)));
`endif
                if (path_idx + 1 >= lat_N) begin
                    if (!lat_option_type) begin
                        path_idx <= '0;
                        sum_pv <= '0;
                        sub_phase <= '0;
                        state <= ST_FINAL_ACC;
                    end else begin
                        exercise_step <= lat_M - 1'b1;
                        state <= ST_BACK_START;
                    end
                end else begin
                    path_idx <= path_idx + 1'b1;
                    step_idx <= '0;
                    s_curr <= lat_S0;
                    sobol_accepted <= 1'b0;
                    state <= ST_TERM_STEP;
                end
            end

            ST_BACK_START: begin
                if (exercise_step == 0) begin
                    path_idx <= '0;
                    sum_pv <= '0;
                    sub_phase <= '0;
                    state <= ST_FINAL_ACC;
                end else begin
                    path_idx <= '0;
                    step_idx <= '0;
                    target_step <= exercise_step;
                    s_curr <= lat_S0;
                    sobol_accepted <= 1'b0;
                    sum1 <= '0; sumx <= '0; sumx2 <= '0; sumx3 <= '0;
                    sumx4 <= '0; sumy <= '0; sumxy <= '0; sumx2y <= '0;
                    itm_count <= '0;
                    state <= ST_TRAIN_STEP;
                end
            end

            ST_TRAIN_FEED: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (sub_phase == 0 && util_mul_rout) begin
                    immediate_reg <= payoff_at(s_target);
                    if (payoff_at(s_target) <= 0) begin
                        sub_phase <= '0;
                        if (path_idx + 1 >= lat_N) begin
                            state <= ST_MEAN_DIV;
                        end else begin
                            path_idx <= path_idx + 1'b1;
                            step_idx <= '0;
                            s_curr <= lat_S0;
                            sobol_accepted <= 1'b0;
                            state <= ST_TRAIN_STEP;
                        end
                    end else begin
                        util_mul_a <= disc_reg;
                        util_mul_b <= cashflow_read;
                        util_mul_vin <= 1'b1;
                        sub_phase <= 4'd1;
                    end
                end else if (sub_phase == 1 && util_mul_vout) begin
                    cont_reg <= util_mul_result;
                    util_mul_a <= s_target;
                    util_mul_b <= inv_K_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd2;
                end else if (sub_phase == 2 && util_mul_vout) begin
                    s_norm_reg <= util_mul_result;
                    x_basis_reg <= util_mul_result - ONE_Q;
                    util_mul_a <= util_mul_result - ONE_Q;
                    util_mul_b <= util_mul_result - ONE_Q;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd3;
                end else if (sub_phase == 3 && util_mul_vout) begin
                    x2_reg <= util_mul_result;
                    util_mul_a <= util_mul_result;
                    util_mul_b <= x_basis_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd4;
                end else if (sub_phase == 4 && util_mul_vout) begin
                    x3_reg <= util_mul_result;
                    util_mul_a <= x2_reg;
                    util_mul_b <= x2_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd5;
                end else if (sub_phase == 5 && util_mul_vout) begin
                    x4_reg <= util_mul_result;
                    util_mul_a <= x_basis_reg;
                    util_mul_b <= cont_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd6;
                end else if (sub_phase == 6 && util_mul_vout) begin
                    xy_reg <= util_mul_result;
                    util_mul_a <= x2_reg;
                    util_mul_b <= cont_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd7;
                end else if (sub_phase == 7 && util_mul_vout) begin
                    x2y_reg <= util_mul_result;
                    sum1 <= sum1 + (acc_t'(1) <<< QF);
                    sumx <= sumx + extended(x_basis_reg);
                    sumx2 <= sumx2 + extended(x2_reg);
                    sumx3 <= sumx3 + extended(x3_reg);
                    sumx4 <= sumx4 + extended(x4_reg);
                    sumy <= sumy + extended(cont_reg);
                    sumxy <= sumxy + extended(xy_reg);
                    sumx2y <= sumx2y + extended(util_mul_result);
                    itm_count <= itm_count + 1'b1;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][ACC-IN] path=%0d step=%0d key=immediate value=0x%08h signed=%0d",
                             path_idx, exercise_step, immediate_reg, $signed(immediate_reg));
                    $display("[NUM][ACC-IN] path=%0d step=%0d key=cont_y value=0x%08h signed=%0d",
                             path_idx, exercise_step, cont_reg, $signed(cont_reg));
                    $display("[NUM][ACC-IN] path=%0d step=%0d key=s_norm value=0x%08h signed=%0d",
                             path_idx, exercise_step, s_norm_reg, $signed(s_norm_reg));
                    $display("[NUM][ACC-IN] path=%0d step=%0d key=x_basis value=0x%08h signed=%0d",
                             path_idx, exercise_step, x_basis_reg, $signed(x_basis_reg));
`endif
                    sub_phase <= '0;
                    if (path_idx + 1 >= lat_N) begin
                        state <= ST_MEAN_DIV;
                    end else begin
                        path_idx <= path_idx + 1'b1;
                        step_idx <= '0;
                        s_curr <= lat_S0;
                        sobol_accepted <= 1'b0;
                        state <= ST_TRAIN_STEP;
                    end
                end
            end

            ST_MEAN_DIV: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (itm_count == 0) begin
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][ACC-SUM] key=sum1 step=%0d value64=0x%016h signed=%0d", exercise_step, sum1, $signed(sum1));
                    $display("[NUM][ACC-SUM] key=sumx step=%0d value64=0x%016h signed=%0d", exercise_step, sumx, $signed(sumx));
                    $display("[NUM][ACC-SUM] key=sumx2 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2, $signed(sumx2));
                    $display("[NUM][ACC-SUM] key=sumx3 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx3, $signed(sumx3));
                    $display("[NUM][ACC-SUM] key=sumx4 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx4, $signed(sumx4));
                    $display("[NUM][ACC-SUM] key=sumy step=%0d value64=0x%016h signed=%0d", exercise_step, sumy, $signed(sumy));
                    $display("[NUM][ACC-SUM] key=sumxy step=%0d value64=0x%016h signed=%0d", exercise_step, sumxy, $signed(sumxy));
                    $display("[NUM][ACC-SUM] key=sumx2y step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2y, $signed(sumx2y));
`endif
                    beta_reg[0] <= '0;
                    beta_reg[1] <= '0;
                    beta_reg[2] <= '0;
                    path_idx <= '0;
                    step_idx <= '0;
                    target_step <= exercise_step;
                    s_curr <= lat_S0;
                    sobol_accepted <= 1'b0;
                    state <= ST_DECIDE_STEP;
                end else if (sub_phase == 0 && util_div_rout) begin
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][ACC-SUM] key=sum1 step=%0d value64=0x%016h signed=%0d", exercise_step, sum1, $signed(sum1));
                    $display("[NUM][ACC-SUM] key=sumx step=%0d value64=0x%016h signed=%0d", exercise_step, sumx, $signed(sumx));
                    $display("[NUM][ACC-SUM] key=sumx2 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2, $signed(sumx2));
                    $display("[NUM][ACC-SUM] key=sumx3 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx3, $signed(sumx3));
                    $display("[NUM][ACC-SUM] key=sumx4 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx4, $signed(sumx4));
                    $display("[NUM][ACC-SUM] key=sumy step=%0d value64=0x%016h signed=%0d", exercise_step, sumy, $signed(sumy));
                    $display("[NUM][ACC-SUM] key=sumxy step=%0d value64=0x%016h signed=%0d", exercise_step, sumxy, $signed(sumxy));
                    $display("[NUM][ACC-SUM] key=sumx2y step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2y, $signed(sumx2y));
`endif
                    util_div_num <= saturate64(sumy);
                    util_div_den_q <= saturate64(sum1);
                    util_div_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    mean_y_reg <= util_div_result;
                    sub_phase <= '0;
                    if (itm_count < 3) begin
                        beta_reg[0] <= util_div_result;
                        beta_reg[1] <= '0;
                        beta_reg[2] <= '0;
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][BETA] key=beta0 step=%0d value=0x%08h signed=%0d", exercise_step, util_div_result, $signed(util_div_result));
                        $display("[NUM][BETA] key=beta1 step=%0d value=0x%08h signed=0", exercise_step, 32'd0);
                        $display("[NUM][BETA] key=beta2 step=%0d value=0x%08h signed=0", exercise_step, 32'd0);
`endif
                        path_idx <= '0;
                        step_idx <= '0;
                        target_step <= exercise_step;
                        s_curr <= lat_S0;
                        sobol_accepted <= 1'b0;
                        state <= ST_DECIDE_STEP;
                    end else begin
                        state <= ST_REG_START;
                    end
                end
            end

            ST_REG_START: begin
                if (reg_rout) begin
                    reg_mat[0]  <= saturate64(sum1);
                    reg_mat[1]  <= saturate64(sumx);
                    reg_mat[2]  <= saturate64(sumx2);
                    reg_mat[3]  <= saturate64(sumy);
                    reg_mat[4]  <= saturate64(sumx);
                    reg_mat[5]  <= saturate64(sumx2);
                    reg_mat[6]  <= saturate64(sumx3);
                    reg_mat[7]  <= saturate64(sumxy);
                    reg_mat[8]  <= saturate64(sumx2);
                    reg_mat[9]  <= saturate64(sumx3);
                    reg_mat[10] <= saturate64(sumx4);
                    reg_mat[11] <= saturate64(sumx2y);
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][ACC-SUM] key=sum1 step=%0d value64=0x%016h signed=%0d", exercise_step, sum1, $signed(sum1));
                    $display("[NUM][ACC-SUM] key=sumx step=%0d value64=0x%016h signed=%0d", exercise_step, sumx, $signed(sumx));
                    $display("[NUM][ACC-SUM] key=sumx2 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2, $signed(sumx2));
                    $display("[NUM][ACC-SUM] key=sumx3 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx3, $signed(sumx3));
                    $display("[NUM][ACC-SUM] key=sumx4 step=%0d value64=0x%016h signed=%0d", exercise_step, sumx4, $signed(sumx4));
                    $display("[NUM][ACC-SUM] key=sumy step=%0d value64=0x%016h signed=%0d", exercise_step, sumy, $signed(sumy));
                    $display("[NUM][ACC-SUM] key=sumxy step=%0d value64=0x%016h signed=%0d", exercise_step, sumxy, $signed(sumxy));
                    $display("[NUM][ACC-SUM] key=sumx2y step=%0d value64=0x%016h signed=%0d", exercise_step, sumx2y, $signed(sumx2y));
`endif
                    reg_vin <= 1'b1;
                    state <= ST_REG_WAIT;
                end
            end

            ST_REG_WAIT: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (reg_vout) begin
                    if (beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2])) begin
                        beta_reg[0] <= mean_y_reg;
                        beta_reg[1] <= '0;
                        beta_reg[2] <= '0;
                    end else begin
                        beta_reg[0] <= reg_beta[0];
                        beta_reg[1] <= reg_beta[1];
                        beta_reg[2] <= reg_beta[2];
                    end
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][BETA] key=beta0 step=%0d value=0x%08h signed=%0d",
                             exercise_step,
                             beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? mean_y_reg : reg_beta[0],
                             $signed(beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? mean_y_reg : reg_beta[0]));
                    $display("[NUM][BETA] key=beta1 step=%0d value=0x%08h signed=%0d",
                             exercise_step,
                             beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? 32'd0 : reg_beta[1],
                             $signed(beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? 32'd0 : reg_beta[1]));
                    $display("[NUM][BETA] key=beta2 step=%0d value=0x%08h signed=%0d",
                             exercise_step,
                             beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? 32'd0 : reg_beta[2],
                             $signed(beta_over_cap(reg_beta[0], reg_beta[1], reg_beta[2]) ? 32'd0 : reg_beta[2]));
`endif
                    path_idx <= '0;
                    step_idx <= '0;
                    target_step <= exercise_step;
                    s_curr <= lat_S0;
                    sobol_accepted <= 1'b0;
                    state <= ST_DECIDE_STEP;
                end
            end

            ST_DECIDE_FEED: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (sub_phase == 0 && util_mul_rout) begin
                    immediate_reg <= payoff_at(s_target);
                    util_mul_a <= disc_reg;
                    util_mul_b <= cashflow_read;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    cont_reg <= util_mul_result;
                    if (immediate_reg <= 0) begin
                        cashflow_we <= 1'b1;
                        cashflow_waddr <= path_idx[PATH_AW-1:0];
                        cashflow_wdata <= util_mul_result;
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][LSM] path=%0d step=%0d key=immediate value=0x%08h signed=%0d", path_idx, exercise_step, immediate_reg, $signed(immediate_reg));
                        $display("[NUM][LSM] path=%0d step=%0d key=cont_est value=0x%08h signed=%0d", path_idx, exercise_step, util_mul_result, $signed(util_mul_result));
                        $display("[NUM][LSM] path=%0d step=%0d key=chosen value=0x%08h signed=%0d", path_idx, exercise_step, util_mul_result, $signed(util_mul_result));
`endif
                        sub_phase <= '0;
                        if (path_idx + 1 >= lat_N) begin
                            exercise_step <= exercise_step - 1'b1;
                            state <= ST_BACK_START;
                        end else begin
                            path_idx <= path_idx + 1'b1;
                            step_idx <= '0;
                            s_curr <= lat_S0;
                            sobol_accepted <= 1'b0;
                            state <= ST_DECIDE_STEP;
                        end
                    end else begin
                        util_mul_a <= s_target;
                        util_mul_b <= inv_K_reg;
                        util_mul_vin <= 1'b1;
                        sub_phase <= 4'd2;
                    end
                end else if (sub_phase == 2 && util_mul_vout) begin
                    s_norm_reg <= util_mul_result;
                    x_basis_reg <= util_mul_result - ONE_Q;
                    util_mul_a <= util_mul_result - ONE_Q;
                    util_mul_b <= util_mul_result - ONE_Q;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd3;
                end else if (sub_phase == 3 && util_mul_vout) begin
                    x2_reg <= util_mul_result;
                    util_mul_a <= beta_reg[1];
                    util_mul_b <= x_basis_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd4;
                end else if (sub_phase == 4 && util_mul_vout) begin
                    beta1x_reg <= util_mul_result;
                    util_mul_a <= beta_reg[2];
                    util_mul_b <= x2_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd5;
                end else if (sub_phase == 5 && util_mul_vout) begin
                    beta2x2_reg <= util_mul_result;
                    cont_est_reg <= beta_reg[0] + beta1x_reg + util_mul_result;
                    chosen_reg <= (immediate_reg >= (beta_reg[0] + beta1x_reg + util_mul_result))
                        ? immediate_reg : cont_reg;
                    cashflow_we <= 1'b1;
                    cashflow_waddr <= path_idx[PATH_AW-1:0];
                    cashflow_wdata <= (immediate_reg >= (beta_reg[0] + beta1x_reg + util_mul_result))
                        ? immediate_reg : cont_reg;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][LSM] path=%0d step=%0d key=immediate value=0x%08h signed=%0d", path_idx, exercise_step, immediate_reg, $signed(immediate_reg));
                    $display("[NUM][LSM] path=%0d step=%0d key=cont_est value=0x%08h signed=%0d", path_idx, exercise_step, beta_reg[0] + beta1x_reg + util_mul_result, $signed(beta_reg[0] + beta1x_reg + util_mul_result));
                    $display("[NUM][LSM] path=%0d step=%0d key=chosen value=0x%08h signed=%0d", path_idx, exercise_step,
                             (immediate_reg >= (beta_reg[0] + beta1x_reg + util_mul_result)) ? immediate_reg : cont_reg,
                             $signed((immediate_reg >= (beta_reg[0] + beta1x_reg + util_mul_result)) ? immediate_reg : cont_reg));
`endif
                    sub_phase <= '0;
                    if (path_idx + 1 >= lat_N) begin
                        exercise_step <= exercise_step - 1'b1;
                        state <= ST_BACK_START;
                    end else begin
                        path_idx <= path_idx + 1'b1;
                        step_idx <= '0;
                        s_curr <= lat_S0;
                        sobol_accepted <= 1'b0;
                        state <= ST_DECIDE_STEP;
                    end
                end
            end

            ST_FINAL_ACC: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (sub_phase == 0) begin
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1 && util_mul_rout) begin
                    util_mul_a <= lat_option_type ? disc_reg : disc_m_reg;
                    util_mul_b <= cashflow_read;
                    util_mul_vin <= 1'b1;
                    sub_phase <= 4'd2;
                end else if (sub_phase == 2 && util_mul_vout) begin
                    sum_pv <= sum_pv + extended(util_mul_result);
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][PV] path=%0d step=0 key=discounted_pv value=0x%08h signed=%0d",
                             path_idx, util_mul_result, $signed(util_mul_result));
`endif
                    sub_phase <= '0;
                    if (path_idx + 1 >= lat_N) begin
                        state <= ST_FINAL_DIV;
                    end else begin
                        path_idx <= path_idx + 1'b1;
                    end
                end
            end

            ST_FINAL_DIV: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (sub_phase == 0) begin
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][FINAL] key=sum_pv value64=0x%016h signed=%0d", sum_pv, $signed(sum_pv));
`endif
                    final_div_sign <= sum_pv[63];
                    final_dividend_abs <= sum_pv[63] ? -sum_pv : sum_pv;
                    final_div_remainder <= '0;
                    final_div_quotient <= '0;
                    final_div_bit <= 7'd63;
                    sub_phase <= 4'd1;
                end else if (sub_phase == 1) begin
                    final_div_remainder <= final_div_remainder_step;
                    final_div_quotient <= final_div_quotient_step;
                    if (final_div_bit == 7'd0) begin
                        result_price <= final_avg_saturate(final_div_quotient_step, final_div_sign);
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][FINAL] key=avg_quotient value64=0x%016h signed=%0d", final_div_quotient_step, $signed(final_div_quotient_step));
                        $display("[NUM][FINAL] key=avg_den value64=0x%016h signed=%0d", final_div_den, $signed(final_div_den));
                        $display("[NUM][FINAL] key=price value=0x%08h signed=%0d",
                                 final_avg_saturate(final_div_quotient_step, final_div_sign),
                                 $signed(final_avg_saturate(final_div_quotient_step, final_div_sign)));
`endif
                        sub_phase <= '0;
                        state <= ST_DONE;
                    end else begin
                        final_div_bit <= final_div_bit - 1'b1;
                    end
                end
            end

            ST_DONE: begin
                result_valid <= 1'b1;
                if (core_timeout)
                    result_price <= 32'hDEAD0001;
                core_active <= 1'b0;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

    assign result_cycles_lo = cycle_counter[31:0];
    assign result_cycles_hi = cycle_counter[63:32];

endmodule
