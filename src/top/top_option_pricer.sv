timeunit 1ns;
timeprecision 1ps;

// =============================================================================
// top_mc_option_pricer
//
// Two-pass QMC-LSMC American option pricer.
//
// Pass 1 (Training): Generate N paths of M steps via sobol -> inverseCDF -> GBM.
//   After each path, feed (S_exercise, disc * terminal_payoff) into the accumulator.
//   After N paths, regression produces beta[0:2].
//
// Pass 2 (Decision): Regenerate the same N paths (Sobol is deterministic).
//   For each path, lsm_decision compares immediate exercise payoff against the
//   regression-estimated continuation, then chooses the actual cashflow.
//   PV is discounted to t=0 and accumulated into a running sum.
//
// Result: price = sum_pv / N, output via UART.
//
// Exercise date: step M-1 (one step before maturity).  Maturity at step M.
// =============================================================================

module top_mc_option_pricer #(
    parameter int CLK_FREQ_HZ            = 100_000_000,
    parameter int BAUD_RATE              = 115200,
    parameter int unsigned CORE_MAX_CYCLES = 32'd50_000_000,
    parameter int MAX_STEPS              = 50,
    parameter bit ANTITHETIC_EN          = 1'b1,
    parameter int NUM_LANES              = 1
)(
    input  logic clk_100,
    input  logic rst_btn_n,
    input  logic uart_rxd,
    output logic uart_txd
);
    localparam int W  = fpga_cfg_pkg::FP_WIDTH;
    localparam int QF = fpga_cfg_pkg::FP_QFRAC;
    localparam int LANE_W = (NUM_LANES <= 1) ? 1 : $clog2(NUM_LANES);

    // =========================================================================
    // UART I/O
    // =========================================================================
    logic        batch_valid, batch_ready;
    logic [31:0] param_paths, param_steps, param_S0, param_K;
    logic [31:0] param_r, param_sigma, param_T;
    logic        param_option_type;
    logic        result_valid;
    logic [31:0] result_price, result_cycles_lo, result_cycles_hi;
    logic [31:0] result_status;

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
        .result_cycles_hi(result_cycles_hi),
        .result_status   (result_status)
    );

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_INIT_DT,
        ST_INIT_GBM_CONST,
        ST_INIT_DISC,
        ST_INIT_INV_K,
        ST_INIT_DISC_TOTAL,
        ST_TRAIN_STEP,
        ST_TRAIN_FEED,
        ST_WAIT_BETA,
        ST_DECIDE_STEP,
        ST_DECIDE_FEED,
        ST_FINAL_DIV,
        ST_DONE
    } state_t;
    state_t state;

    // Latched parameters (stable through entire computation)
    logic signed [W-1:0] lat_S0, lat_K, lat_r, lat_sigma, lat_T;
    logic [15:0]         lat_N;
    logic [7:0]          lat_M;
    logic                lat_option_type;  // 0=CALL, 1=PUT

    // Computed during INIT
    logic signed [W-1:0] dt_reg;
    logic signed [W-1:0] drift_const_reg;
    logic signed [W-1:0] vol_sqrt_dt_reg;
    logic signed [W-1:0] disc_reg;
    logic signed [W-1:0] disc_total_reg;
    logic signed [W-1:0] inv_K_reg;      // 1/K for moneyness normalization
    logic signed [W-1:0] s_norm_reg;     // s_exercise / K

    // Path/step counters
    logic [15:0]         path_idx;
    logic [7:0]          step_idx;
    logic [LANE_W-1:0]   feed_lane_idx;
    logic [NUM_LANES-1:0] lane_active_mask;
    logic [LANE_W:0]      lane_active_count;
    logic signed [W-1:0] s_curr_lane [0:NUM_LANES-1];
    logic signed [W-1:0] s_exercise_lane [0:NUM_LANES-1];
    logic signed [W-1:0] s_terminal_lane [0:NUM_LANES-1];

    // Antithetic variates: even path_idx = normal, odd = negated z.
    // Path-index mapping is centralized so D5 lane scheduling can reuse it.
    function automatic [15:0] map_path_to_sobol(input [15:0] pidx);
        map_path_to_sobol = ANTITHETIC_EN ? pidx[15:1] : pidx;
    endfunction
    function automatic logic is_antithetic_path(input [15:0] pidx);
        is_antithetic_path = ANTITHETIC_EN & pidx[0];
    endfunction
    function automatic [15:0] lane_path_idx(
        input [15:0] base_path,
        input int unsigned lane_idx
    );
        lane_path_idx = base_path + lane_idx[15:0];
    endfunction
    function automatic [NUM_LANES-1:0] lane_mask_from_count(input [LANE_W:0] cnt);
        lane_mask_from_count = '0;
        for (int i = 0; i < NUM_LANES; i++) begin
            if (i < cnt)
                lane_mask_from_count[i] = 1'b1;
        end
    endfunction
    function automatic [LANE_W:0] active_lane_count_from_base(
        input [15:0] base_path,
        input [15:0] total
    );
        logic [15:0] remaining;
        remaining = total - base_path;
        if (remaining >= NUM_LANES[15:0])
            active_lane_count_from_base = NUM_LANES[LANE_W:0];
        else
            active_lane_count_from_base = remaining[LANE_W:0];
    endfunction
    wire [15:0]          total_paths = ANTITHETIC_EN ? {lat_N[14:0], 1'b0} : lat_N;

    // Accumulation for decision pass average
    logic signed [63:0]  sum_pv;

    // Beta from regression
    logic signed [W-1:0] beta_reg [0:2];

    // Cycle counter
    logic [63:0] cycle_counter;
    logic        core_active;

    // Status flags (sticky, collected during computation)
    // bit 0: timeout occurred
    // bit 1: regression singular (fallback to mean payoff)
    logic [31:0] status_flags;

    // =========================================================================
    // Utility multiplier (time-shared across INIT and per-path computations)
    // =========================================================================
    logic                    util_mul_vin, util_mul_vout, util_mul_rin, util_mul_rout;
    logic signed [W-1:0]    util_mul_a, util_mul_b, util_mul_result;

    fxMul #() u_util_mul (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in (util_mul_vin),
        .ready_out(util_mul_rout),
        .valid_out(util_mul_vout),
        .ready_in (util_mul_rin),
        .a        (util_mul_a),
        .b        (util_mul_b),
        .result   (util_mul_result)
    );
    assign util_mul_rin = 1'b1;

    // =========================================================================
    // Utility divider (dt computation + final average)
    // =========================================================================
    logic                    util_div_vin, util_div_vout, util_div_rin, util_div_rout;
    logic signed [W-1:0]    util_div_num, util_div_den, util_div_result;

    fxDiv #() u_util_div (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in  (util_div_vin),
        .ready_out (util_div_rout),
        .valid_out (util_div_vout),
        .ready_in  (util_div_rin),
        .numerator (util_div_num),
        .denominator(util_div_den),
        .result    (util_div_result)
    );
    assign util_div_rin = 1'b1;

    // =========================================================================
    // Utility ExpLUT (disc computation)
    // =========================================================================
    logic                    util_exp_vin, util_exp_vout, util_exp_rin, util_exp_rout;
    logic signed [W-1:0]    util_exp_a, util_exp_result;

    fxExpLUT #() u_util_exp (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in (util_exp_vin),
        .ready_out(util_exp_rout),
        .valid_out(util_exp_vout),
        .ready_in (util_exp_rin),
        .a        (util_exp_a),
        .result   (util_exp_result)
    );
    assign util_exp_rin = 1'b1;

    // =========================================================================
    // Utility Sqrt (INIT only: sqrt(dt) for vol_sqrt_dt)
    // =========================================================================
    logic                    util_sqrt_vin, util_sqrt_vout, util_sqrt_rin, util_sqrt_rout;
    logic [W-1:0]            util_sqrt_a, util_sqrt_result;

    fxSqrt #() u_util_sqrt (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in (util_sqrt_vin),
        .ready_out(util_sqrt_rout),
        .valid_out(util_sqrt_vout),
        .ready_in (util_sqrt_rin),
        .a        (util_sqrt_a),
        .result   (util_sqrt_result)
    );
    assign util_sqrt_rin = 1'b1;

    // =========================================================================
    // Pipeline lanes: sobol -> inverseCDF -> GBM
    // Current scheduler policy: one active lane at a time, round-robin by path.
    // This keeps behavior stable while preparing full multi-lane scheduling.
    // =========================================================================
    logic [NUM_LANES-1:0]    sobol_vin_lane, sobol_rout_lane, sobol_vout_lane;
    logic [W-1:0]            sobol_idx_lane [0:NUM_LANES-1];
    logic [$clog2(MAX_STEPS)-1:0] sobol_dim_lane [0:NUM_LANES-1];
    logic [W-1:0]            sobol_out_lane [0:NUM_LANES-1];
    logic [W-1:0]            sobol_direction_lane [0:NUM_LANES-1][0:MAX_STEPS*W-1];

    logic [NUM_LANES-1:0]    inv_vout_lane, inv_rout_lane;
    logic signed [W-1:0]     inv_z_lane [0:NUM_LANES-1];

    logic [NUM_LANES-1:0]    gbm_vout_lane, gbm_rout_lane;
    logic signed [W-1:0]     gbm_s_next_lane [0:NUM_LANES-1];

    logic                    sobol_all_rout;
    logic                    gbm_all_vout;
    logic                    pipe_ready_in;

    always_comb begin
        sobol_all_rout = 1'b1;
        gbm_all_vout   = 1'b1;
        for (int ln = 0; ln < NUM_LANES; ln++) begin
            if (lane_active_mask[ln]) begin
                sobol_all_rout &= sobol_rout_lane[ln];
                gbm_all_vout   &= gbm_vout_lane[ln];
            end
        end
    end

    genvar lane;
    generate
        for (lane = 0; lane < NUM_LANES; lane++) begin : GEN_PIPE_LANE
            logic signed [W-1:0] sobol_q16_lane;
            logic signed [W-1:0] inv_z_eff_lane;
            logic signed [W-1:0] gbm_z_lane;
            assign sobol_q16_lane = $signed({{QF{1'b0}}, sobol_out_lane[lane][W-1:QF]});  // Q0.32 → Q16.16
            assign inv_z_eff_lane = is_antithetic_path(lane_path_idx(path_idx, lane)) ? -inv_z_lane[lane] : inv_z_lane[lane];
            assign gbm_z_lane     = inv_z_eff_lane;

            sobol #(
                .M      (MAX_STEPS),
                .LANE_ID(lane)
            ) u_sobol (
                .clk       (clk_100),
                .rst_n     (rst_btn_n),
                .valid_in  (sobol_vin_lane[lane]),
                .ready_out (sobol_rout_lane[lane]),
                .valid_out (sobol_vout_lane[lane]),
                .ready_in  (inv_rout_lane[lane]),
                .idx_in    (sobol_idx_lane[lane]),
                .dim_in    (sobol_dim_lane[lane]),
                .sobol_out (sobol_out_lane[lane]),
                .direction (sobol_direction_lane[lane])
            );

            inverseCDF u_inv (
                .clk       (clk_100),
                .rst_n     (rst_btn_n),
                .valid_in  (sobol_vout_lane[lane]),
                .ready_out (inv_rout_lane[lane]),
                .u_in      (sobol_q16_lane),
                .valid_out (inv_vout_lane[lane]),
                .ready_in  (gbm_rout_lane[lane]),
                .z_out     (inv_z_lane[lane])
            );

            GBM u_gbm (
                .clk         (clk_100),
                .rst_n       (rst_btn_n),
                .valid_in    (inv_vout_lane[lane]),
                .ready_out   (gbm_rout_lane[lane]),
                .valid_out   (gbm_vout_lane[lane]),
                .ready_in    (pipe_ready_in),
                .z           (gbm_z_lane),
                .S           (s_curr_lane[lane]),
                .drift_const (drift_const_reg),
                .vol_sqrt_dt (vol_sqrt_dt_reg),
                .S_next      (gbm_s_next_lane[lane])
            );
        end
    endgenerate

    // FSM always accepts GBM output when it arrives
    assign pipe_ready_in = 1'b1;

    // =========================================================================
    // Accumulator (training pass)
    // =========================================================================
    logic                    acc_vin, acc_vout, acc_rout, acc_rin;
    logic signed [W-1:0]    acc_x, acc_y;
    logic signed [W-1:0]    acc_beta [0:2];
    logic                    acc_singular;

    accumulator #(.N_SAMPLES(10000)) u_accum (
        .clk                (clk_100),
        .rst_n              (rst_btn_n),
        .valid_in           (acc_vin),
        .ready_out          (acc_rout),
        .valid_out          (acc_vout),
        .ready_in           (acc_rin),
        .x_in               (acc_x),
        .y_in               (acc_y),
        .n_samples_cfg      (total_paths[$clog2(10001)-1:0]),
        .beta               (acc_beta),
        .regression_singular(acc_singular)
    );
    assign acc_rin = 1'b1;

    // =========================================================================
    // LSM Decision (decision pass)
    // =========================================================================
    logic                    lsm_vin, lsm_vout, lsm_rout, lsm_rin;
    logic signed [W-1:0]    lsm_pv;
    logic signed [W-1:0]    s_exercise_sel, s_terminal_sel;
    logic signed [W-1:0]    terminal_payoff;

    lsm_decision u_lsm (
        .clk         (clk_100),
        .rst_n       (rst_btn_n),
        .valid_in    (lsm_vin),
        .valid_out   (lsm_vout),
        .ready_in    (lsm_rin),
        .ready_out   (lsm_rout),
        .S_t         (s_exercise_sel),
        .s_norm      (s_norm_reg),
        .beta        (beta_reg),
        .strike      (lat_K),
        .cont_value  (acc_y),
        .option_type (lat_option_type),
        .PV          (lsm_pv)
    );
    assign lsm_rin = 1'b1;

    // =========================================================================
    // Payoff computation (combinational): CALL max(S-K,0), PUT max(K-S,0)
    // =========================================================================
    assign s_exercise_sel = s_exercise_lane[feed_lane_idx];
    assign s_terminal_sel = s_terminal_lane[feed_lane_idx];
    assign terminal_payoff = lat_option_type
        ? ((lat_K > s_terminal_sel) ? (lat_K - s_terminal_sel) : '0)   // PUT
        : ((s_terminal_sel > lat_K) ? (s_terminal_sel - lat_K) : '0);  // CALL

    // =========================================================================
    // Main FSM
    // =========================================================================
    // Sub-phase counter (reused by any state that needs multi-cycle sequencing)
    logic [2:0] sub_phase;
    logic [7:0] disc_pow_cnt;

    // Track whether sobol request was accepted (to avoid double-fire)
    logic sobol_accepted;

    // Timeout
    logic core_timeout;
    assign core_timeout = core_active && (cycle_counter >= CORE_MAX_CYCLES);

    always_ff @(posedge clk_100 or negedge rst_btn_n) begin
        if (!rst_btn_n) begin
            state           <= ST_IDLE;
            core_active     <= 1'b0;
            cycle_counter   <= '0;
            result_valid    <= 1'b0;
            result_price    <= '0;
            status_flags    <= '0;
            batch_ready     <= 1'b1;
            path_idx        <= '0;
            step_idx        <= '0;
            feed_lane_idx   <= '0;
            lane_active_mask <= '0;
            lane_active_count <= '0;
            sum_pv          <= '0;
            dt_reg          <= '0;
            drift_const_reg <= '0;
            vol_sqrt_dt_reg <= '0;
            disc_reg        <= '0;
            disc_total_reg  <= '0;
            inv_K_reg       <= '0;
            s_norm_reg      <= '0;
            sub_phase        <= '0;
            disc_pow_cnt    <= '0;
            sobol_accepted  <= 1'b0;
            acc_vin         <= 1'b0;
            acc_x           <= '0;
            acc_y           <= '0;
            lsm_vin         <= 1'b0;
            util_mul_vin    <= 1'b0;
            util_mul_a      <= '0;
            util_mul_b      <= '0;
            util_div_vin    <= 1'b0;
            util_div_num    <= '0;
            util_div_den    <= '0;
            util_exp_vin    <= 1'b0;
            util_exp_a      <= '0;
            util_sqrt_vin   <= 1'b0;
            util_sqrt_a     <= '0;
            for (int ln = 0; ln < NUM_LANES; ln++) begin
                s_curr_lane[ln]     <= '0;
                s_exercise_lane[ln] <= '0;
                s_terminal_lane[ln] <= '0;
                sobol_vin_lane[ln]  <= 1'b0;
                sobol_idx_lane[ln]  <= '0;
                sobol_dim_lane[ln]  <= '0;
            end
            for (int i = 0; i < 3; i++) beta_reg[i] <= '0;
            lat_S0 <= '0; lat_K <= '0; lat_r <= '0;
            lat_sigma <= '0; lat_T <= '0;
            lat_N <= '0; lat_M <= '0;
            lat_option_type <= 1'b0;
        end else begin
            // Default: clear one-cycle pulses
            result_valid   <= 1'b0;
            acc_vin        <= 1'b0;
            lsm_vin        <= 1'b0;
            util_mul_vin   <= 1'b0;
            util_div_vin   <= 1'b0;
            util_exp_vin   <= 1'b0;
            util_sqrt_vin  <= 1'b0;
            for (int ln = 0; ln < NUM_LANES; ln++)
                sobol_vin_lane[ln] <= 1'b0;

            // Cycle counter
            if (core_active)
                cycle_counter <= cycle_counter + 1'b1;

            case (state)

            // =================================================================
            // IDLE: wait for UART batch
            // =================================================================
            ST_IDLE: begin
                batch_ready <= 1'b1;
                if (batch_valid && batch_ready) begin
                    lat_S0    <= $signed(param_S0);
                    lat_K     <= $signed(param_K);
                    lat_r     <= $signed(param_r);
                    lat_sigma <= $signed(param_sigma);
                    lat_T     <= $signed(param_T);
                    lat_N     <= param_paths[15:0];
                    lat_M     <= param_steps[7:0];
                    lat_option_type <= param_option_type;
                    batch_ready   <= 1'b0;
                    core_active   <= 1'b1;
                    cycle_counter <= '0;
                    status_flags  <= '0;
                    sub_phase      <= '0;
                    state         <= ST_INIT_DT;
                end
            end

            // =================================================================
            // INIT_DT: compute dt = T / M
            // =================================================================
            ST_INIT_DT: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= lat_T;
                    util_div_den <= $signed({24'd0, lat_M}) <<< QF;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_div_vout) begin
                    dt_reg   <= util_div_result;
                    sub_phase <= '0;
                    state    <= ST_INIT_GBM_CONST;
                end
            end

            // =================================================================
            // INIT_GBM_CONST: pre-compute drift_const and vol_sqrt_dt for GBM
            //   sigma2 = sigma*sigma; drift_const = (r - sigma2/2)*dt;
            //   sqrt_dt = sqrt(dt); vol_sqrt_dt = sigma*sqrt_dt
            // =================================================================
            ST_INIT_GBM_CONST: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a   <= lat_sigma;
                    util_mul_b   <= lat_sigma;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_mul_vout) begin
                    util_mul_a   <= lat_r - (util_mul_result >>> 1);
                    util_mul_b   <= dt_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                else if (sub_phase == 2 && util_mul_vout) begin
                    drift_const_reg <= util_mul_result;
                    util_sqrt_a     <= dt_reg;
                    util_sqrt_vin   <= 1'b1;
                    sub_phase       <= 3'd3;
                end
                else if (sub_phase == 3 && util_sqrt_vout) begin
                    util_mul_a   <= lat_sigma;
                    util_mul_b   <= $signed(util_sqrt_result);
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd4;
                end
                else if (sub_phase == 4 && util_mul_vout) begin
                    vol_sqrt_dt_reg <= util_mul_result;
                    sub_phase       <= '0;
                    state          <= ST_INIT_DISC;
                end
            end

            // =================================================================
            // INIT_DISC: compute disc = exp(-r * dt)
            //   sub 0: mul(-r, dt)  -> neg_r_dt
            //   sub 1: exp(neg_r_dt) -> disc  (ExpLUT expects >= 0; handle sign)
            // =================================================================
            ST_INIT_DISC: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a   <= -lat_r;
                    util_mul_b   <= dt_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_mul_vout) begin
                    // neg_r_dt = -r * dt. For r > 0, neg_r_dt < 0.
                    // disc = exp(neg_r_dt). ExpLUT expects |x|; for neg arg,
                    // exp(-|x|) = 1/exp(|x|). But we approximate: disc ~ 1 - r*dt
                    // for small r*dt, or pass |neg_r_dt| and invert later.
                    // For simplicity, use the abs + reciprocal method:
                    // exp(-a) = 1/exp(a) for a>0.
                    util_exp_a   <= (util_mul_result[W-1]) ?
                                    -util_mul_result : util_mul_result;
                    util_exp_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                else if (sub_phase == 2 && util_exp_vout) begin
                    // If neg_r_dt was negative (typical: r>0, dt>0), disc = 1/exp(|neg_r_dt|)
                    // For now, store exp_result and handle reciprocal if needed.
                    // Since disc = exp(-r*dt) < 1 for r>0, and ExpLUT gives exp(|r*dt|) > 1,
                    // we need the reciprocal.
                    // We'll do a quick div: disc = ONE / exp_result
                    util_div_num <= fpga_cfg_pkg::FP_ONE;
                    util_div_den <= util_exp_result;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd3;
                end
                else if (sub_phase == 3 && util_div_vout) begin
                    disc_reg       <= util_div_result;
                    disc_total_reg <= util_div_result;
                    disc_pow_cnt   <= 8'd1;
                    sub_phase       <= '0;
                    state          <= ST_INIT_INV_K;
                end
            end

            // =================================================================
            // INIT_INV_K: compute inv_K = 1/K for moneyness normalization
            // =================================================================
            ST_INIT_INV_K: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= fpga_cfg_pkg::FP_ONE;
                    util_div_den <= lat_K;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_div_vout) begin
                    inv_K_reg <= util_div_result;
                    sub_phase  <= '0;
                    state     <= (lat_M <= 2) ? ST_TRAIN_STEP : ST_INIT_DISC_TOTAL;
                end
            end

            // =================================================================
            // INIT_DISC_TOTAL: compute disc_total = disc^(M-1) iteratively
            // =================================================================
            ST_INIT_DISC_TOTAL: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a   <= disc_total_reg;
                    util_mul_b   <= disc_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_mul_vout) begin
                    disc_total_reg <= util_mul_result;
                    disc_pow_cnt   <= disc_pow_cnt + 1'b1;
                    sub_phase       <= '0;
                    if (disc_pow_cnt + 1 >= lat_M - 1) begin
                        // disc_total = disc^(M-1) complete
                        path_idx       <= '0;
                        step_idx       <= '0;
                        feed_lane_idx  <= '0;
                        lane_active_count <= active_lane_count_from_base('0, total_paths);
                        lane_active_mask  <= lane_mask_from_count(active_lane_count_from_base('0, total_paths));
                        for (int ln = 0; ln < NUM_LANES; ln++)
                            s_curr_lane[ln] <= lat_S0;
                        sobol_accepted <= 1'b0;
                        state          <= ST_TRAIN_STEP;
                    end
                end
            end

            // =================================================================
            // TRAIN_STEP: streaming pipeline — fire Sobol as soon as pipeline accepts
            // Phase 4: fire step k+1 in SAME cycle as GBM outputs step k (no idle cycle)
            // =================================================================
            ST_TRAIN_STEP: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (!sobol_accepted && sobol_all_rout) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
                        if (lane_active_mask[ln]) begin
                            sobol_idx_lane[ln] <= {16'd0, map_path_to_sobol(lane_path_idx(path_idx, ln))};
                            sobol_dim_lane[ln] <= step_idx[$clog2(MAX_STEPS)-1:0];
                            sobol_vin_lane[ln] <= 1'b1;
                        end
                    end
                    sobol_accepted <= 1'b1;
                end else if (sobol_accepted && gbm_all_vout) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
                        if (lane_active_mask[ln]) begin
                            if (step_idx == lat_M - 2)
                                s_exercise_lane[ln] <= gbm_s_next_lane[ln];
                            s_curr_lane[ln] <= gbm_s_next_lane[ln];
                        end
                    end
                    step_idx <= step_idx + 1'b1;

                    if (step_idx == lat_M - 1) begin
                        for (int ln = 0; ln < NUM_LANES; ln++) begin
                            if (lane_active_mask[ln])
                                s_terminal_lane[ln] <= gbm_s_next_lane[ln];
                        end
                        feed_lane_idx  <= '0;
                        sub_phase      <= '0;
                        sobol_accepted <= 1'b0;
                        state          <= ST_TRAIN_FEED;
                    end else if (sobol_all_rout) begin
                        for (int ln = 0; ln < NUM_LANES; ln++) begin
                            if (lane_active_mask[ln]) begin
                                sobol_idx_lane[ln] <= {16'd0, map_path_to_sobol(lane_path_idx(path_idx, ln))};
                                sobol_dim_lane[ln] <= step_idx[$clog2(MAX_STEPS)-1:0] + 1'b1;
                                sobol_vin_lane[ln] <= 1'b1;
                            end
                        end
                        sobol_accepted <= 1'b1;
                    end else begin
                        sobol_accepted <= 1'b0;
                    end
                end
            end

            // =================================================================
            // TRAIN_FEED: cont_value = disc * terminal_payoff,
            //             s_norm = s_exercise * inv_K, feed accumulator
            // =================================================================
            ST_TRAIN_FEED: begin
                if (core_timeout)
                    state <= ST_DONE;
                // sub 0: fire disc * terminal_payoff
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a   <= disc_reg;
                    util_mul_b   <= terminal_payoff;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                // sub 1: store cont_value, fire s_exercise * inv_K
                else if (sub_phase == 1 && util_mul_vout) begin
                    acc_y        <= util_mul_result;
                    util_mul_a   <= s_exercise_sel;
                    util_mul_b   <= inv_K_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                // sub 2: store s_norm, feed accumulator
                else if (sub_phase == 2 && util_mul_vout) begin
                    acc_x  <= util_mul_result;   // normalized S/K
                    if (acc_rout) begin
                        acc_vin  <= 1'b1;
                        sub_phase <= '0;
                        if ({1'b0, feed_lane_idx} + 1'b1 < lane_active_count) begin
                            feed_lane_idx <= feed_lane_idx + 1'b1;
                        end else begin
                            path_idx      <= path_idx + lane_active_count;
                            feed_lane_idx <= '0;
                            if (path_idx + lane_active_count >= total_paths) begin
                                state <= ST_WAIT_BETA;
                            end else begin
                                step_idx <= '0;
                                lane_active_count <= active_lane_count_from_base(path_idx + lane_active_count, total_paths);
                                lane_active_mask  <= lane_mask_from_count(active_lane_count_from_base(path_idx + lane_active_count, total_paths));
                                for (int ln = 0; ln < NUM_LANES; ln++)
                                    s_curr_lane[ln] <= lat_S0;
                                sobol_accepted <= 1'b0;
                                state          <= ST_TRAIN_STEP;
                            end
                        end
                    end
                end
            end

            // =================================================================
            // WAIT_BETA: accumulator runs regression, outputs beta
            // =================================================================
            ST_WAIT_BETA: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (acc_vout) begin
                    for (int i = 0; i < 3; i++)
                        beta_reg[i] <= acc_beta[i];
                    if (acc_singular)
                        status_flags[1] <= 1'b1;
                    path_idx       <= '0;
                    step_idx       <= '0;
                    feed_lane_idx  <= '0;
                    lane_active_count <= active_lane_count_from_base('0, total_paths);
                    lane_active_mask  <= lane_mask_from_count(active_lane_count_from_base('0, total_paths));
                    for (int ln = 0; ln < NUM_LANES; ln++)
                        s_curr_lane[ln] <= lat_S0;
                    sobol_accepted <= 1'b0;
                    sum_pv         <= '0;
                    state          <= ST_DECIDE_STEP;
                end
            end

            // =================================================================
            // DECIDE_STEP: streaming pipeline, same as TRAIN_STEP
            // =================================================================
            ST_DECIDE_STEP: begin
                if (core_timeout) begin
                    state <= ST_DONE;
                end else if (!sobol_accepted && sobol_all_rout) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
                        if (lane_active_mask[ln]) begin
                            sobol_idx_lane[ln] <= {16'd0, map_path_to_sobol(lane_path_idx(path_idx, ln))};
                            sobol_dim_lane[ln] <= step_idx[$clog2(MAX_STEPS)-1:0];
                            sobol_vin_lane[ln] <= 1'b1;
                        end
                    end
                    sobol_accepted <= 1'b1;
                end else if (sobol_accepted && gbm_all_vout) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
                        if (lane_active_mask[ln]) begin
                            if (step_idx == lat_M - 2)
                                s_exercise_lane[ln] <= gbm_s_next_lane[ln];
                            s_curr_lane[ln] <= gbm_s_next_lane[ln];
                        end
                    end
                    step_idx <= step_idx + 1'b1;

                    if (step_idx == lat_M - 1) begin
                        for (int ln = 0; ln < NUM_LANES; ln++) begin
                            if (lane_active_mask[ln])
                                s_terminal_lane[ln] <= gbm_s_next_lane[ln];
                        end
                        feed_lane_idx  <= '0;
                        sub_phase      <= '0;
                        sobol_accepted <= 1'b0;
                        state          <= ST_DECIDE_FEED;
                    end else if (sobol_all_rout) begin
                        for (int ln = 0; ln < NUM_LANES; ln++) begin
                            if (lane_active_mask[ln]) begin
                                sobol_idx_lane[ln] <= {16'd0, map_path_to_sobol(lane_path_idx(path_idx, ln))};
                                sobol_dim_lane[ln] <= step_idx[$clog2(MAX_STEPS)-1:0] + 1'b1;
                                sobol_vin_lane[ln] <= 1'b1;
                            end
                        end
                        sobol_accepted <= 1'b1;
                    end else begin
                        sobol_accepted <= 1'b0;
                    end
                end
            end

            // =================================================================
            // DECIDE_FEED: cont_value, s_norm, drive lsm_decision, accumulate PV
            // =================================================================
            ST_DECIDE_FEED: begin
                if (core_timeout)
                    state <= ST_DONE;
                // sub 0: fire disc * terminal_payoff
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a   <= disc_reg;
                    util_mul_b   <= terminal_payoff;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                // sub 1: store cont_value, fire s_exercise * inv_K
                else if (sub_phase == 1 && util_mul_vout) begin
                    acc_y        <= util_mul_result;
                    util_mul_a   <= s_exercise_sel;
                    util_mul_b   <= inv_K_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                // sub 2: store s_norm, drive lsm_decision
                else if (sub_phase == 2 && util_mul_vout) begin
                    s_norm_reg <= util_mul_result;
                    if (lsm_rout) begin
                        lsm_vin  <= 1'b1;
                        sub_phase <= 3'd3;
                    end
                end
                // sub 3: wait for lsm_decision output
                else if (sub_phase == 3 && lsm_vout) begin
                    util_mul_a   <= disc_total_reg;
                    util_mul_b   <= lsm_pv;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd4;
                end
                // sub 4: accumulate discounted PV
                else if (sub_phase == 4 && util_mul_vout) begin
                    sum_pv   <= sum_pv + {{(64-W){util_mul_result[W-1]}}, util_mul_result};
                    sub_phase <= '0;
                    if ({1'b0, feed_lane_idx} + 1'b1 < lane_active_count) begin
                        feed_lane_idx <= feed_lane_idx + 1'b1;
                    end else begin
                        path_idx      <= path_idx + lane_active_count;
                        feed_lane_idx <= '0;
                        if (path_idx + lane_active_count >= total_paths) begin
                            state <= ST_FINAL_DIV;
                        end else begin
                            step_idx <= '0;
                            lane_active_count <= active_lane_count_from_base(path_idx + lane_active_count, total_paths);
                            lane_active_mask  <= lane_mask_from_count(active_lane_count_from_base(path_idx + lane_active_count, total_paths));
                            for (int ln = 0; ln < NUM_LANES; ln++)
                                s_curr_lane[ln] <= lat_S0;
                            sobol_accepted <= 1'b0;
                            state          <= ST_DECIDE_STEP;
                        end
                    end
                end
            end

            // =================================================================
            // FINAL_DIV: price = sum_pv / N
            // =================================================================
            ST_FINAL_DIV: begin
                if (core_timeout)
                    state <= ST_DONE;
                else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= sum_pv[W-1:0];
                    util_div_den <= $signed({16'd0, total_paths}) <<< QF;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_div_vout) begin
                    result_price <= util_div_result;
                    sub_phase     <= '0;
                    state        <= ST_DONE;
                end
            end

            // =================================================================
            // DONE: emit result
            // =================================================================
            ST_DONE: begin
                result_valid <= 1'b1;
                if (core_timeout) begin
                    result_price     <= 32'hDEAD0001;
                    status_flags[0]  <= 1'b1;
                end
                core_active <= 1'b0;
                state       <= ST_IDLE;
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

    // =========================================================================
    // Result cycle counters
    // =========================================================================
    assign result_cycles_lo = cycle_counter[31:0];
    assign result_cycles_hi = cycle_counter[63:32];
    assign result_status    = status_flags;

    // synthesis translate_off
    initial begin
        if (NUM_LANES < 1)
            $fatal(1, "NUM_LANES must be >= 1");
        if (NUM_LANES != 1)
            $display("[D5] NUM_LANES=%0d enabled: Sobol/InvCDF/GBM are replicated and path scheduling round-robins lanes. Full concurrent multi-lane feeding/merge is next.", NUM_LANES);
    end
    // synthesis translate_on

`ifdef TOP_FSM_DEBUG
    state_t prev_state;
    always_ff @(posedge clk_100) begin
        prev_state <= state;
        if (state != prev_state)
            $display("[FSM] t=%0t %0d->%0d sub=%0d path=%0d step=%0d",
                     $time, prev_state, state, sub_phase, path_idx, step_idx);
        if (core_active && cycle_counter[16:0] == '0) begin
            $display("[TOP] t=%0t state=%0d sub=%0d path=%0d step=%0d cyc=%0d lanes=%b gbm_all=%b",
                     $time, state, sub_phase, path_idx, step_idx, cycle_counter,
                     lane_active_mask, gbm_all_vout);
        end
        if (core_active && cycle_counter == 64'd200)
            $display("[TOP-INIT] dt=%h disc=%h disc_total=%h inv_K=%h lat_M=%0d lat_N=%0d",
                     dt_reg, disc_reg, disc_total_reg, inv_K_reg, lat_M, lat_N);
        if (acc_vin)
            $display("[ACC-IN] t=%0t x=%h y=%h path=%0d", $time, acc_x, acc_y, path_idx);
        if (acc_vout)
            $display("[ACC-OUT] t=%0t beta0=%h beta1=%h beta2=%h",
                     $time, acc_beta[0], acc_beta[1], acc_beta[2]);
        if (lsm_vin)
            $display("[LSM-IN] t=%0t", $time);
        if (lsm_vout)
            $display("[LSM-OUT] t=%0t pv=%h", $time, lsm_pv);
    end
`endif

endmodule
