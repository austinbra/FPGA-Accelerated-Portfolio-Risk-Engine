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
    parameter int NUM_LANES              = 1
)(
    input  logic clk_100,
    input  logic rst_btn_n,
    input  logic uart_rxd,
    output logic uart_txd
);
    localparam int W  = fpga_cfg_pkg::FP_WIDTH;
    localparam int QF = fpga_cfg_pkg::FP_QFRAC;
    localparam signed [W-1:0] ONE_Q = 32'sd1 <<< QF;

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

`ifdef TOP_NUM_DEBUG
    function automatic string num_pass_name(input state_t st);
        case (st)
            ST_DECIDE_STEP, ST_DECIDE_FEED, ST_FINAL_DIV: num_pass_name = "decide";
            default: num_pass_name = "train";
        endcase
    endfunction

    logic [15:0] dbg_lsm_path;
    logic [15:0] dbg_pv_path;
    logic signed [W-1:0] lsm_debug_immediate;
    logic signed [W-1:0] lsm_debug_cont_est;
`endif

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
    logic signed [W-1:0] lane_s_curr [0:NUM_LANES-1];

    // Per-lane path state (exercise-date and terminal stock prices)
    localparam int LANE_IDX_W = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 1;
    logic signed [W-1:0] lane_s_exercise [0:NUM_LANES-1];
    logic signed [W-1:0] lane_s_terminal [0:NUM_LANES-1];
    logic [LANE_IDX_W-1:0] lane_feed_idx;

    // Feed muxes: serialize per-lane results for accumulator / LSM
    logic signed [W-1:0] feed_s_exercise;
    logic signed [W-1:0] feed_s_terminal;
    assign feed_s_exercise = lane_s_exercise[lane_feed_idx];
    assign feed_s_terminal = lane_s_terminal[lane_feed_idx];

    // Accumulation for decision pass average
    logic signed [63:0]  sum_pv;

    // Beta from regression
    logic signed [W-1:0] beta_reg [0:2];

    // Cycle counter
    logic [63:0] cycle_counter;
    logic        core_active;

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
    // Pipeline: sobol -> inverseCDF -> GBM  (NUM_LANES replicated copies)
    // =========================================================================
    // FSM-facing scalars (aliased to lane 0)
    logic                    sobol_vin, sobol_rout;
    logic [W-1:0]            sobol_idx;
    logic [$clog2(MAX_STEPS)-1:0] sobol_dim;
    logic                    gbm_vout;
    logic                    inv_vout;

    // Per-lane pipeline interface arrays
    logic                    lane_sobol_vin  [0:NUM_LANES-1];
    logic                    lane_sobol_rout [0:NUM_LANES-1];
    logic [W-1:0]            lane_sobol_idx  [0:NUM_LANES-1];
    logic [$clog2(MAX_STEPS)-1:0] lane_sobol_dim [0:NUM_LANES-1];
    logic                    lane_gbm_vout   [0:NUM_LANES-1];
    logic signed [W-1:0]    lane_gbm_s_next [0:NUM_LANES-1];
    logic                    lane_inv_vout   [0:NUM_LANES-1];

    // All lanes must agree before a broadcast sobol fire.
    always_comb begin
        sobol_rout = 1'b1;
        for (int ii = 0; ii < NUM_LANES; ii++)
            sobol_rout &= lane_sobol_rout[ii];
    end
    // Plan D5: identical per-lane latency -> lane0 valid implies all lanes' S_next are aligned.
    assign gbm_vout = lane_gbm_vout[0];
    assign inv_vout = lane_inv_vout[0];

    // Broadcast FSM sobol request to all lanes (lane ln uses path path_idx + ln).
    generate
    for (genvar ln = 0; ln < NUM_LANES; ln++) begin : gen_sobol_drive
        assign lane_sobol_vin[ln]  = sobol_vin;
        assign lane_sobol_idx[ln]  = {16'd0, path_idx} + W'(ln) + W'(1);
        assign lane_sobol_dim[ln] = sobol_dim;
    end
    endgenerate

    // Replicated pipeline instances
    generate
    for (genvar ln = 0; ln < NUM_LANES; ln++) begin : gen_lane
        logic sobol_vout_i;
        logic [W-1:0] sobol_out_i;
        logic [W-1:0] sobol_direction_i [0:MAX_STEPS*W-1];
        logic [15:0] sobol_q16_hi_i;
        logic signed [W-1:0] sobol_q16_i;
        logic inv_rout_i;
        logic signed [W-1:0] inv_z_i;
        logic gbm_rout_i;

        sobol #(.M(MAX_STEPS)) u_sobol (
            .clk       (clk_100),
            .rst_n     (rst_btn_n),
            .valid_in  (lane_sobol_vin[ln]),
            .ready_out (lane_sobol_rout[ln]),
            .valid_out (sobol_vout_i),
            .ready_in  (inv_rout_i),
            .idx_in    (lane_sobol_idx[ln]),
            .dim_in    (lane_sobol_dim[ln]),
            .sobol_out (sobol_out_i),
            .direction (sobol_direction_i)
        );

        assign sobol_q16_hi_i = sobol_out_i[31:16];
        assign sobol_q16_i = $signed({16'd0, (sobol_q16_hi_i == 16'd0) ? 16'd1 : sobol_q16_hi_i});

        inverseCDF u_inv (
            .clk       (clk_100),
            .rst_n     (rst_btn_n),
            .valid_in  (sobol_vout_i),
            .ready_out (inv_rout_i),
            .u_in      (sobol_q16_i),
            .valid_out (lane_inv_vout[ln]),
            .ready_in  (gbm_rout_i),
            .z_out     (inv_z_i)
        );

        GBM u_gbm (
            .clk         (clk_100),
            .rst_n       (rst_btn_n),
            .valid_in    (lane_inv_vout[ln]),
            .ready_out   (gbm_rout_i),
            .valid_out   (lane_gbm_vout[ln]),
            .ready_in    (1'b1),
            .z           (inv_z_i),
            .S           (lane_s_curr[ln]),
            .drift_const (drift_const_reg),
            .vol_sqrt_dt (vol_sqrt_dt_reg),
            .S_next      (lane_gbm_s_next[ln])
        );

`ifdef TOP_NUM_DEBUG
        logic [15:0] dbg_path_q;
        logic [7:0]  dbg_step_q;

        always_ff @(posedge clk_100 or negedge rst_btn_n) begin
            if (!rst_btn_n) begin
                dbg_path_q <= '0;
                dbg_step_q <= '0;
            end else begin
                if (lane_sobol_vin[ln] && lane_sobol_rout[ln]) begin
                    dbg_path_q <= path_idx + 16'(ln);
                    dbg_step_q <= step_idx + 8'd1;
                end
                if (sobol_vout_i) begin
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=%0d key=sobol_raw value=0x%08h signed=%0d",
                             num_pass_name(state), dbg_path_q, dbg_step_q, ln,
                             sobol_out_i, $signed(sobol_out_i));
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=%0d key=u_q16 value=0x%08h signed=%0d",
                             num_pass_name(state), dbg_path_q, dbg_step_q, ln,
                             sobol_q16_i, $signed(sobol_q16_i));
                end
                if (lane_inv_vout[ln]) begin
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=%0d key=z value=0x%08h signed=%0d",
                             num_pass_name(state), dbg_path_q, dbg_step_q, ln,
                             inv_z_i, $signed(inv_z_i));
                end
                if (u_gbm.exp_vin) begin
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=%0d key=exp_arg value=0x%08h signed=%0d",
                             num_pass_name(state), dbg_path_q, dbg_step_q, ln,
                             u_gbm.exp_arg, $signed(u_gbm.exp_arg));
                end
                if (u_gbm.exp_vout) begin
                    $display("[NUM][PATH] pass=%s path=%0d step=%0d lane=%0d key=exp value=0x%08h signed=%0d",
                             num_pass_name(state), dbg_path_q, dbg_step_q, ln,
                             u_gbm.exp_result, $signed(u_gbm.exp_result));
                end
            end
        end
`endif

    end
    endgenerate

    // =========================================================================
    // Accumulator (training pass)
    // =========================================================================
    logic                    acc_vin, acc_vout, acc_rout, acc_rin;
    logic signed [W-1:0]    acc_x, acc_y;
    logic signed [W-1:0]    acc_beta [0:2];

    accumulator #(.N_SAMPLES(10000)) u_accum (
        .clk           (clk_100),
        .rst_n         (rst_btn_n),
        .valid_in      (acc_vin),
        .ready_out     (acc_rout),
        .valid_out     (acc_vout),
        .ready_in      (acc_rin),
        .x_in          (acc_x),
        .y_in          (acc_y),
        .n_samples_cfg (lat_N[$clog2(10001)-1:0]),
        .beta          (acc_beta)
    );
    assign acc_rin = 1'b1;

    // =========================================================================
    // LSM Decision (decision pass)
    // =========================================================================
    logic                    lsm_vin, lsm_vout, lsm_rout, lsm_rin;
    logic signed [W-1:0]    lsm_pv;

    lsm_decision u_lsm (
        .clk         (clk_100),
        .rst_n       (rst_btn_n),
        .valid_in    (lsm_vin),
        .valid_out   (lsm_vout),
        .ready_in    (lsm_rin),
        .ready_out   (lsm_rout),
        .S_t         (feed_s_exercise),
        .s_norm      (s_norm_reg),
        .beta        (beta_reg),
        .strike      (lat_K),
        .cont_value  (acc_y),
        .option_type (lat_option_type),
        .PV          (lsm_pv)
`ifdef TOP_NUM_DEBUG
        ,
        .debug_immediate(lsm_debug_immediate),
        .debug_cont_est (lsm_debug_cont_est)
`endif
    );
    assign lsm_rin = 1'b1;

    // =========================================================================
    // Payoff computation (combinational): CALL max(S-K,0), PUT max(K-S,0)
    // =========================================================================
    logic signed [W-1:0] terminal_payoff;
    assign terminal_payoff = lat_option_type
        ? ((lat_K > feed_s_terminal) ? (lat_K - feed_s_terminal) : '0)   // PUT
        : ((feed_s_terminal > lat_K) ? (feed_s_terminal - lat_K) : '0);  // CALL

    // =========================================================================
    // Main FSM
    // =========================================================================
    // Sub-phase counter (reused by any state that needs multi-cycle sequencing)
    logic [2:0] sub_phase;
    logic [7:0] disc_pow_cnt;

    // Track whether sobol request was accepted (to avoid double-fire)
    logic sobol_accepted;
    // Drain counter: ignore GBM echo pulses for a few cycles after each collect
    logic [2:0] drain_cnt;

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
            batch_ready     <= 1'b1;
            path_idx        <= '0;
            step_idx        <= '0;
            lane_feed_idx   <= '0;
            for (int ln = 0; ln < NUM_LANES; ln++) begin
                lane_s_curr[ln]     <= '0;
                lane_s_exercise[ln] <= '0;
                lane_s_terminal[ln] <= '0;
            end
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
            drain_cnt       <= '0;
            sobol_vin       <= 1'b0;
            sobol_idx       <= '0;
            sobol_dim       <= '0;
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
            for (int i = 0; i < 3; i++) beta_reg[i] <= '0;
            lat_S0 <= '0; lat_K <= '0; lat_r <= '0;
            lat_sigma <= '0; lat_T <= '0;
            lat_N <= '0; lat_M <= '0;
            lat_option_type <= 1'b0;
`ifdef TOP_NUM_DEBUG
            dbg_lsm_path <= '0;
            dbg_pv_path  <= '0;
`endif
        end else begin
            // Default: clear one-cycle pulses
            result_valid   <= 1'b0;
            sobol_vin      <= 1'b0;
            if (drain_cnt > 0) drain_cnt <= drain_cnt - 1;
            acc_vin        <= 1'b0;
            lsm_vin        <= 1'b0;
            util_mul_vin   <= 1'b0;
            util_div_vin   <= 1'b0;
            util_exp_vin   <= 1'b0;
            util_sqrt_vin  <= 1'b0;

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
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=dt value=0x%08h signed=%0d",
                             util_div_result, $signed(util_div_result));
`endif
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
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=drift_const value=0x%08h signed=%0d",
                             util_mul_result, $signed(util_mul_result));
`endif
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
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=vol_sqrt_dt value=0x%08h signed=%0d",
                             util_mul_result, $signed(util_mul_result));
`endif
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
                    util_div_num <= ONE_Q;
                    util_div_den <= util_exp_result;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd3;
                end
                else if (sub_phase == 3 && util_div_vout) begin
                    disc_reg       <= util_div_result;
                    disc_total_reg <= util_div_result;
                    disc_pow_cnt   <= 8'd1;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=disc value=0x%08h signed=%0d",
                             util_div_result, $signed(util_div_result));
`endif
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
                    util_div_num <= ONE_Q;
                    util_div_den <= lat_K;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_div_vout) begin
                    inv_K_reg <= util_div_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][INIT] key=inv_K value=0x%08h signed=%0d",
                             util_div_result, $signed(util_div_result));
`endif
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
`ifdef TOP_NUM_DEBUG
                    if (disc_pow_cnt + 1 >= lat_M - 1) begin
                        $display("[NUM][INIT] key=disc_total value=0x%08h signed=%0d",
                                 util_mul_result, $signed(util_mul_result));
                    end
`endif
                    sub_phase       <= '0;
                    if (disc_pow_cnt + 1 >= lat_M - 1) begin
                        // disc_total = disc^(M-1) complete
                        path_idx       <= '0;
                        step_idx       <= '0;
                        lane_feed_idx  <= '0;
                        for (int ln = 0; ln < NUM_LANES; ln++)
                            lane_s_curr[ln] <= lat_S0;
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
                end else if (!sobol_accepted && sobol_rout && !gbm_vout && drain_cnt == 0) begin
                    // Phase A: fire sobol for this step (path start or first step)
                    sobol_idx      <= {16'd0, path_idx};
                    sobol_dim      <= step_idx[$clog2(MAX_STEPS)-1:0];
                    sobol_vin      <= 1'b1;
                    sobol_accepted <= 1'b1;
                end else if (sobol_accepted && gbm_vout && drain_cnt == 0) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][PATH] pass=train path=%0d step=%0d lane=%0d key=s_next value=0x%08h signed=%0d",
                                 path_idx + 16'(ln), step_idx + 8'd1, ln,
                                 lane_gbm_s_next[ln], $signed(lane_gbm_s_next[ln]));
`endif
                        if (step_idx == lat_M - 2)
                            lane_s_exercise[ln] <= lane_gbm_s_next[ln];
                        lane_s_curr[ln] <= lane_gbm_s_next[ln];
                    end
                    step_idx       <= step_idx + 1'b1;
                    drain_cnt      <= 3'd5;

                    if (step_idx == lat_M - 1) begin
                        for (int ln = 0; ln < NUM_LANES; ln++)
                            lane_s_terminal[ln] <= lane_gbm_s_next[ln];
                        sub_phase       <= '0;
                        lane_feed_idx   <= '0;
                        sobol_accepted  <= 1'b0;
                        state           <= ST_TRAIN_FEED;
                    end else if (sobol_rout) begin
                        sobol_idx      <= {16'd0, path_idx};
                        sobol_dim      <= step_idx[$clog2(MAX_STEPS)-1:0] + 1'b1;
                        sobol_vin      <= 1'b1;
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
                // sub 1: store cont_value, fire feed_s_exercise * inv_K
                else if (sub_phase == 1 && util_mul_vout) begin
                    acc_y        <= util_mul_result;
                    util_mul_a   <= feed_s_exercise;
                    util_mul_b   <= inv_K_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                // sub 2: store s_norm, feed accumulator
                else if (sub_phase == 2 && util_mul_vout) begin
                    acc_x  <= util_mul_result;   // normalized S/K
                    if (acc_rout) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=s_exercise value=0x%08h signed=%0d",
                                 path_idx + lane_feed_idx, lat_M - 1, feed_s_exercise, $signed(feed_s_exercise));
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=s_terminal value=0x%08h signed=%0d",
                                 path_idx + lane_feed_idx, lat_M, feed_s_terminal, $signed(feed_s_terminal));
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=terminal_payoff value=0x%08h signed=%0d",
                                 path_idx + lane_feed_idx, lat_M, terminal_payoff, $signed(terminal_payoff));
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=cont_y value=0x%08h signed=%0d",
                                 path_idx + lane_feed_idx, lat_M - 1, acc_y, $signed(acc_y));
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=s_norm value=0x%08h signed=%0d",
                                 path_idx + lane_feed_idx, lat_M - 1, util_mul_result, $signed(util_mul_result));
`endif
                        acc_vin   <= 1'b1;
                        sub_phase <= '0;
                        // Use (NUM_LANES-1) without LANE_IDX_W' cast: LANE_IDX_W'(NUM_LANES-1)
                        // can misparsed/truncate (e.g. 1-bit cast of NUM_LANES before -1) and skip lanes.
                        if (lane_feed_idx != (NUM_LANES - 1)) begin
                            lane_feed_idx <= lane_feed_idx + 1'b1;
                        end else begin
                            lane_feed_idx <= '0;
                            path_idx      <= path_idx + 16'(NUM_LANES);
                            if (path_idx + NUM_LANES >= lat_N) begin
                                state <= ST_WAIT_BETA;
                            end else begin
                                step_idx <= '0;
                                for (int ln = 0; ln < NUM_LANES; ln++)
                                    lane_s_curr[ln] <= lat_S0;
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
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][BETA] key=beta0 value=0x%08h signed=%0d", acc_beta[0], $signed(acc_beta[0]));
                    $display("[NUM][BETA] key=beta1 value=0x%08h signed=%0d", acc_beta[1], $signed(acc_beta[1]));
                    $display("[NUM][BETA] key=beta2 value=0x%08h signed=%0d", acc_beta[2], $signed(acc_beta[2]));
`endif
                    path_idx       <= '0;
                    step_idx       <= '0;
                    lane_feed_idx  <= '0;
                    for (int ln = 0; ln < NUM_LANES; ln++)
                        lane_s_curr[ln] <= lat_S0;
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
                end else if (!sobol_accepted && sobol_rout && !gbm_vout && drain_cnt == 0) begin
                    sobol_idx      <= {16'd0, path_idx};
                    sobol_dim      <= step_idx[$clog2(MAX_STEPS)-1:0];
                    sobol_vin      <= 1'b1;
                    sobol_accepted <= 1'b1;
                end else if (sobol_accepted && gbm_vout && drain_cnt == 0) begin
                    for (int ln = 0; ln < NUM_LANES; ln++) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][PATH] pass=decide path=%0d step=%0d lane=%0d key=s_next value=0x%08h signed=%0d",
                                 path_idx + 16'(ln), step_idx + 8'd1, ln,
                                 lane_gbm_s_next[ln], $signed(lane_gbm_s_next[ln]));
`endif
                        if (step_idx == lat_M - 2)
                            lane_s_exercise[ln] <= lane_gbm_s_next[ln];
                        lane_s_curr[ln] <= lane_gbm_s_next[ln];
                    end
                    step_idx       <= step_idx + 1'b1;
                    drain_cnt      <= 3'd5;

                    if (step_idx == lat_M - 1) begin
                        for (int ln = 0; ln < NUM_LANES; ln++)
                            lane_s_terminal[ln] <= lane_gbm_s_next[ln];
                        sub_phase       <= '0;
                        lane_feed_idx   <= '0;
                        sobol_accepted  <= 1'b0;
                        state           <= ST_DECIDE_FEED;
                    end else if (sobol_rout) begin
                        sobol_idx      <= {16'd0, path_idx};
                        sobol_dim      <= step_idx[$clog2(MAX_STEPS)-1:0] + 1'b1;
                        sobol_vin      <= 1'b1;
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
                // sub 1: store cont_value, fire feed_s_exercise * inv_K
                else if (sub_phase == 1 && util_mul_vout) begin
                    acc_y        <= util_mul_result;
                    util_mul_a   <= feed_s_exercise;
                    util_mul_b   <= inv_K_reg;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd2;
                end
                // sub 2: store s_norm, drive lsm_decision
                else if (sub_phase == 2 && util_mul_vout) begin
                    s_norm_reg <= util_mul_result;
                    if (lsm_rout) begin
`ifdef TOP_NUM_DEBUG
                        dbg_lsm_path <= path_idx + lane_feed_idx;
`endif
                        lsm_vin  <= 1'b1;
                        sub_phase <= 3'd3;
                    end
                end
                // sub 3: wait for lsm_decision output
                else if (sub_phase == 3 && lsm_vout) begin
`ifdef TOP_NUM_DEBUG
                    dbg_pv_path <= dbg_lsm_path;
                    $display("[NUM][LSM] path=%0d step=%0d key=immediate value=0x%08h signed=%0d",
                             dbg_lsm_path, lat_M - 1, lsm_debug_immediate, $signed(lsm_debug_immediate));
                    $display("[NUM][LSM] path=%0d step=%0d key=cont_est value=0x%08h signed=%0d",
                             dbg_lsm_path, lat_M - 1, lsm_debug_cont_est, $signed(lsm_debug_cont_est));
                    $display("[NUM][LSM] path=%0d step=%0d key=chosen value=0x%08h signed=%0d",
                             dbg_lsm_path, lat_M - 1, lsm_pv, $signed(lsm_pv));
`endif
                    util_mul_a   <= disc_total_reg;
                    util_mul_b   <= lsm_pv;
                    util_mul_vin <= 1'b1;
                    sub_phase     <= 3'd4;
                end
                // sub 4: accumulate discounted PV
                else if (sub_phase == 4 && util_mul_vout) begin
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][PV] path=%0d step=%0d key=discounted_pv value=0x%08h signed=%0d",
                             dbg_pv_path, lat_M - 1, util_mul_result, $signed(util_mul_result));
`endif
                    sum_pv    <= sum_pv + {{(64-W){util_mul_result[W-1]}}, util_mul_result};
                    sub_phase <= '0;
                    if (lane_feed_idx != (NUM_LANES - 1)) begin
                        lane_feed_idx <= lane_feed_idx + 1'b1;
                    end else begin
                        lane_feed_idx <= '0;
                        path_idx      <= path_idx + 16'(NUM_LANES);
                        if (path_idx + NUM_LANES >= lat_N) begin
                            state <= ST_FINAL_DIV;
                        end else begin
                            step_idx <= '0;
                            for (int ln = 0; ln < NUM_LANES; ln++)
                                lane_s_curr[ln] <= lat_S0;
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
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][FINAL] key=sum_pv value64=0x%016h signed=%0d",
                             sum_pv, $signed(sum_pv));
`endif
                    util_div_num <= sum_pv[W-1:0];
                    util_div_den <= $signed({16'd0, lat_N}) <<< QF;
                    util_div_vin <= 1'b1;
                    sub_phase     <= 3'd1;
                end
                else if (sub_phase == 1 && util_div_vout) begin
                    result_price <= util_div_result;
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][FINAL] key=price value=0x%08h signed=%0d",
                             util_div_result, $signed(util_div_result));
`endif
                    sub_phase     <= '0;
                    state        <= ST_DONE;
                end
            end

            // =================================================================
            // DONE: emit result
            // =================================================================
            ST_DONE: begin
                result_valid <= 1'b1;
                if (core_timeout)
                    result_price <= 32'hDEAD0001;
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

`ifdef TOP_FSM_DEBUG
    state_t prev_state;
    always_ff @(posedge clk_100) begin
        prev_state <= state;
        if (state != prev_state)
            $display("[FSM] t=%0t %0d->%0d sub=%0d path=%0d step=%0d",
                     $time, prev_state, state, sub_phase, path_idx, step_idx);
        if (core_active && cycle_counter[16:0] == '0) begin
            $display("[TOP] t=%0t state=%0d sub=%0d path=%0d step=%0d cyc=%0d inv_v=%b gbm_v=%b",
                     $time, state, sub_phase, path_idx, step_idx, cycle_counter,
                     inv_vout, gbm_vout);
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
