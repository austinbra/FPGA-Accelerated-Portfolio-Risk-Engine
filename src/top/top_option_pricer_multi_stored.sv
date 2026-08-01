timeunit 1ns;
timeprecision 1ps;

// Stored-path, banked, multi-lane Longstaff-Schwartz engine.
//
// Differences from top_mc_option_pricer_multi v1:
//   * every simulated spot is generated once and retained in banked BRAM;
//   * NUM_LANES independent Sobol/inverse-CDF/GBM pipes generate path bundles;
//   * paths are scheduled step-major so independent samples overlap in flight;
//   * each lane owns one path/cashflow bank, avoiding multi-port contention;
//   * regression features are evaluated concurrently by lane-local workers;
//   * lane-local 64-bit sufficient statistics are reduced exactly before solve.
//
// The arithmetic contract remains the same as the C++ RTL mirror:
//   PUT: exercise at dates 1..M-1 using [1, x, x^2], x=S/K-1.
//   CALL: no pathwise early exercise for q=0; discount terminal payoff by disc^M.
//   Both: compare the discounted estimate with intrinsic value at valuation time.
module top_mc_option_pricer_multi_stored #(
    parameter int CLK_FREQ_HZ              = 100_000_000,
    parameter int BAUD_RATE                = 115200,
    parameter int unsigned CORE_MAX_CYCLES = 32'd1_000_000_000,
    parameter int MAX_STEPS                = 50,
    parameter int MAX_PATHS                = 1024,
    parameter int NUM_LANES                = 1
)(
    input  logic clk_100,
    input  logic rst_btn_n,
    input  logic uart_rxd,
    output logic uart_txd
);
    localparam int W          = fpga_cfg_pkg::FP_WIDTH;
    localparam int QF         = fpga_cfg_pkg::FP_QFRAC;
    localparam int ROWS_MAX   = (MAX_PATHS + NUM_LANES - 1) / NUM_LANES;
    localparam int ROW_AW      = (ROWS_MAX <= 2) ? 1 : $clog2(ROWS_MAX);
    localparam int ROW_COUNT_W = (ROWS_MAX <= 1) ? 1 : $clog2(ROWS_MAX + 1);
    localparam int PATH_COUNT_W = (MAX_PATHS <= 1) ? 1 : $clog2(MAX_PATHS + 1);
    localparam int SPOT_DEPTH = ROWS_MAX * MAX_STEPS;
    localparam int SPOT_AW    = (SPOT_DEPTH <= 2) ? 1 : $clog2(SPOT_DEPTH);
    localparam signed [W-1:0] ONE_Q = 32'sd1 <<< QF;
    localparam signed [W-1:0] BETA_ABS_CAP_Q = 32'sd4096 <<< QF;

    initial begin
        assert (NUM_LANES >= 1) else $fatal(1, "NUM_LANES must be >= 1");
        assert ((MAX_PATHS % NUM_LANES) == 0)
            else $fatal(1, "MAX_PATHS must divide evenly across NUM_LANES");
    end

    // ---------------------------------------------------------------------
    // UART job/result interface
    // ---------------------------------------------------------------------
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
        .clk(clk_100), .rst_n(rst_btn_n), .rx(uart_rxd), .tx(uart_txd),
        .batch_valid(batch_valid), .batch_ready(batch_ready),
        .paths(param_paths), .steps(param_steps), .S0(param_S0), .K(param_K),
        .r(param_r), .sigma(param_sigma), .T(param_T),
        .option_type(param_option_type),
        .result_valid(result_valid), .result_price(result_price),
        .result_cycles_lo(result_cycles_lo), .result_cycles_hi(result_cycles_hi)
    );

    typedef logic signed [63:0] acc_t;

    function automatic acc_t extended(input logic signed [W-1:0] v);
        return {{(64-W){v[W-1]}}, v};
    endfunction

    function automatic logic signed [W-1:0] saturate64(input acc_t val);
        logic signed [W-1:0] max_pos;
        logic signed [W-1:0] min_neg;
        begin
            max_pos = {1'b0, {W-1{1'b1}}};
            min_neg = {1'b1, {W-1{1'b0}}};
            if (val > extended(max_pos))       saturate64 = max_pos;
            else if (val < extended(min_neg)) saturate64 = min_neg;
            else                              saturate64 = val[W-1:0];
        end
    endfunction

    function automatic logic signed [W-1:0] abs32(input logic signed [W-1:0] v);
        return v[W-1] ? -v : v;
    endfunction

    function automatic logic beta_over_cap(
        input logic signed [W-1:0] b0,
        input logic signed [W-1:0] b1,
        input logic signed [W-1:0] b2
    );
        return (abs32(b0) > BETA_ABS_CAP_Q) ||
               (abs32(b1) > BETA_ABS_CAP_Q) ||
               (abs32(b2) > BETA_ABS_CAP_Q);
    endfunction

    function automatic logic signed [W-1:0] payoff_value(
        input logic signed [W-1:0] spot,
        input logic signed [W-1:0] strike,
        input logic is_put
    );
        if (is_put)
            payoff_value = (strike > spot) ? (strike - spot) : '0;
        else
            payoff_value = (spot > strike) ? (spot - strike) : '0;
    endfunction

    function automatic logic signed [W-1:0] final_avg_saturate(
        input logic [63:0] quotient,
        input logic sign
    );
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
                if (quotient >= max_neg_mag) final_avg_saturate = min_neg;
                else final_avg_saturate = -$signed(quotient[W-1:0]);
            end else begin
                if (quotient > max_pos_mag) final_avg_saturate = max_pos;
                else final_avg_saturate = quotient[W-1:0];
            end
        end
    endfunction

    // ---------------------------------------------------------------------
    // Latched parameters and constants
    // ---------------------------------------------------------------------
    logic signed [W-1:0] lat_S0, lat_K, lat_r, lat_sigma, lat_T;
    logic [15:0] lat_N;
    logic [7:0]  lat_M;
    logic        lat_option_type;
    logic signed [W-1:0] dt_reg, drift_const_reg, vol_sqrt_dt_reg;
    logic signed [W-1:0] disc_reg, disc_m_reg, inv_K_reg;

    // ---------------------------------------------------------------------
    // Banked path and cashflow storage
    // ---------------------------------------------------------------------
    logic [SPOT_AW-1:0] spot_raddr [0:NUM_LANES-1];
    logic [SPOT_AW-1:0] spot_waddr [0:NUM_LANES-1];
    logic signed [W-1:0] spot_rdata [0:NUM_LANES-1];
    logic signed [W-1:0] spot_wdata [0:NUM_LANES-1];
    logic spot_we [0:NUM_LANES-1];

    logic [ROW_AW-1:0] cash_raddr [0:NUM_LANES-1];
    logic [ROW_AW-1:0] cash_waddr [0:NUM_LANES-1];
    logic signed [W-1:0] cash_rdata [0:NUM_LANES-1];
    logic signed [W-1:0] cash_wdata [0:NUM_LANES-1];
    logic cash_we [0:NUM_LANES-1];
    logic signed [W-1:0] terminal_payoff_reg [0:NUM_LANES-1];

    for (genvar bank = 0; bank < NUM_LANES; bank++) begin : gen_banked_mem
        // Declare each bank as a separate inferred variable. Besides expressing
        // the physical banking directly, this stays below Vivado's per-variable
        // elaboration limit when NUM_LANES is large.
        (* ram_style = "block" *) logic signed [W-1:0]
            spot_bank [0:SPOT_DEPTH-1];
        // Keep cashflows banked by lane as well. A synchronous block-RAM bank
        // removes the high-fanout distributed-RAM address network and spends
        // only a small fraction of the BRAM left after spot storage.
        (* ram_style = "block" *) logic signed [W-1:0]
            cash_bank [0:ROWS_MAX-1];

        always_ff @(posedge clk_100) begin
            spot_rdata[bank] <= spot_bank[spot_raddr[bank]];
            cash_rdata[bank] <= cash_bank[cash_raddr[bank]];
            if (spot_we[bank])
                spot_bank[spot_waddr[bank]] <= spot_wdata[bank];
            if (cash_we[bank])
                cash_bank[cash_waddr[bank]] <= cash_wdata[bank];
        end
    end

    // ---------------------------------------------------------------------
    // Shared initialization math
    // ---------------------------------------------------------------------
    logic util_mul_vin, util_mul_vout, util_mul_rin, util_mul_rout;
    logic signed [W-1:0] util_mul_a, util_mul_b, util_mul_result;
    fxMul u_util_mul (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_mul_vin), .ready_out(util_mul_rout),
        .valid_out(util_mul_vout), .ready_in(util_mul_rin),
        .a(util_mul_a), .b(util_mul_b), .result(util_mul_result)
    );
    assign util_mul_rin = 1'b1;

    logic util_div_vin, util_div_vout, util_div_rin, util_div_rout;
    logic signed [W-1:0] util_div_num, util_div_den_q, util_div_result;
    fxDiv u_util_div (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_div_vin), .ready_out(util_div_rout),
        .valid_out(util_div_vout), .ready_in(util_div_rin),
        .numerator(util_div_num), .denominator(util_div_den_q),
        .result(util_div_result)
    );
    assign util_div_rin = 1'b1;

    logic util_exp_vin, util_exp_vout, util_exp_rin, util_exp_rout;
    logic signed [W-1:0] util_exp_a, util_exp_result;
    fxExpLUT u_util_exp (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_exp_vin), .ready_out(util_exp_rout),
        .valid_out(util_exp_vout), .ready_in(util_exp_rin),
        .a(util_exp_a), .result(util_exp_result)
    );
    assign util_exp_rin = 1'b1;

    logic util_sqrt_vin, util_sqrt_vout, util_sqrt_rin, util_sqrt_rout;
    logic [W-1:0] util_sqrt_a, util_sqrt_result;
    fxSqrt u_util_sqrt (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(util_sqrt_vin), .ready_out(util_sqrt_rout),
        .valid_out(util_sqrt_vout), .ready_in(util_sqrt_rin),
        .a(util_sqrt_a), .result(util_sqrt_result)
    );
    assign util_sqrt_rin = 1'b1;

    // ---------------------------------------------------------------------
    // Replicated path-generation lanes
    // ---------------------------------------------------------------------
    logic lane_sobol_vin [0:NUM_LANES-1];
    logic lane_sobol_rout[0:NUM_LANES-1];
    logic lane_sobol_vout[0:NUM_LANES-1];
    logic [W-1:0] lane_sobol_out[0:NUM_LANES-1];
    logic [15:0] lane_u_hi[0:NUM_LANES-1];
    logic signed [W-1:0] lane_u_q16[0:NUM_LANES-1];
    logic lane_inv_rout[0:NUM_LANES-1];
    logic lane_inv_vout[0:NUM_LANES-1];
    logic signed [W-1:0] lane_z[0:NUM_LANES-1];
    logic lane_gbm_rout[0:NUM_LANES-1];
    logic lane_gbm_vout[0:NUM_LANES-1];
    logic signed [W-1:0] lane_s_next[0:NUM_LANES-1];
    logic [PATH_COUNT_W-1:0] gen_path_base;
    logic [ROW_COUNT_W-1:0] gen_issue_row;
    logic [ROW_COUNT_W-1:0] gen_output_row;
    logic [7:0] gen_step;
    logic [SPOT_AW-1:0] gen_issue_spot_addr;
    logic [SPOT_AW-1:0] gen_output_spot_addr;
    logic [SPOT_AW-1:0] scan_spot_addr;
    logic gen_data_valid;
    logic gbm_level_seen;
    logic gen_issue_valid;
    logic gen_issue_fire;
    logic gen_output_fire;
    logic lane_s_fifo_full[0:NUM_LANES-1];

    logic all_sobol_ready;
    logic all_gbm_valid;
    logic all_s_fifo_space;
    always_comb begin
        all_sobol_ready = 1'b1;
        all_gbm_valid = 1'b1;
        all_s_fifo_space = 1'b1;
        for (int ar = 0; ar < NUM_LANES; ar++) begin
            all_sobol_ready &= lane_sobol_rout[ar];
            all_gbm_valid &= lane_gbm_vout[ar];
            all_s_fifo_space &= !lane_s_fifo_full[ar];
        end
    end

    for (genvar lane = 0; lane < NUM_LANES; lane++) begin : gen_path_lanes
        logic [W-1:0] s_align_push[0:0];
        logic [W-1:0] s_align_pop[0:0];
        logic s_fifo_empty;

        sobol #(.M(MAX_STEPS), .LANE_ID(lane)) u_sobol (
            .clk(clk_100), .rst_n(rst_btn_n),
            .valid_in(lane_sobol_vin[lane]), .ready_out(lane_sobol_rout[lane]),
            .valid_out(lane_sobol_vout[lane]), .ready_in(lane_inv_rout[lane]),
            .idx_in({16'd0, gen_path_base} + W'(lane + 1)),
            .dim_in(gen_step[$clog2(MAX_STEPS)-1:0]),
            .sobol_out(lane_sobol_out[lane]), .direction()
        );

        // The inverse-CDF has variable backpressure, so align the independent
        // path's current spot with its Z sample before the GBM stage.
        assign s_align_push[0] = (gen_step == 0) ? lat_S0 : spot_rdata[lane];
        event_align_fifo_arr #(.N(1), .DW(W), .DEPTH(16)) u_s_align (
            .clk(clk_100), .rst_n(rst_btn_n),
            .push_en(lane_sobol_vin[lane] && lane_sobol_rout[lane]),
            .pop_en(lane_inv_vout[lane] && lane_gbm_rout[lane]),
            .push_data(s_align_push), .pop_data(s_align_pop),
            .full(lane_s_fifo_full[lane]), .empty(s_fifo_empty)
        );

        assign lane_u_hi[lane] = lane_sobol_out[lane][31:16];
        assign lane_u_q16[lane] = $signed({16'd0,
            (lane_u_hi[lane] == 16'd0) ? 16'd1 : lane_u_hi[lane]});

        inverseCDF #(.LANE_ID(lane)) u_inv (
            .clk(clk_100), .rst_n(rst_btn_n),
            .valid_in(lane_sobol_vout[lane]), .ready_out(lane_inv_rout[lane]),
            .u_in(lane_u_q16[lane]),
            .valid_out(lane_inv_vout[lane]), .ready_in(lane_gbm_rout[lane]),
            .z_out(lane_z[lane])
        );

        GBM #(.LANE_ID(lane)) u_gbm (
            .clk(clk_100), .rst_n(rst_btn_n),
            .valid_in(lane_inv_vout[lane]), .ready_out(lane_gbm_rout[lane]),
            .valid_out(lane_gbm_vout[lane]), .ready_in(1'b1),
            .z(lane_z[lane]), .S($signed(s_align_pop[0])),
            .drift_const(drift_const_reg), .vol_sqrt_dt(vol_sqrt_dt_reg),
            .S_next(lane_s_next[lane])
        );

        assign lane_sobol_vin[lane] = gen_issue_valid;
`ifdef TOP_NUM_DEBUG
        always_ff @(posedge clk_100)
            if (lane_inv_vout[lane] && lane_gbm_rout[lane])
                $display("[NUM][INV-OUT] lane=%0d z=0x%08h S=0x%08h", lane,
                         lane_z[lane], s_align_pop[0]);
`endif
    end

    // ---------------------------------------------------------------------
    // Lane-local stored-path feature workers
    // ---------------------------------------------------------------------
    localparam logic [1:0] FEATURE_TRAIN  = 2'd0;
    localparam logic [1:0] FEATURE_DECIDE = 2'd1;
    localparam logic [1:0] FEATURE_FINAL  = 2'd2;

    logic feature_start[0:NUM_LANES-1];
    logic feature_ready[0:NUM_LANES-1];
    logic feature_done [0:NUM_LANES-1];
    logic [1:0] feature_mode;
    logic signed [W-1:0] feature_factor;
    logic feature_itm[0:NUM_LANES-1];
    logic signed [W-1:0] feature_cont[0:NUM_LANES-1];
    logic signed [W-1:0] feature_x[0:NUM_LANES-1];
    logic signed [W-1:0] feature_x2[0:NUM_LANES-1];
    logic signed [W-1:0] feature_x3[0:NUM_LANES-1];
    logic signed [W-1:0] feature_x4[0:NUM_LANES-1];
    logic signed [W-1:0] feature_xy[0:NUM_LANES-1];
    logic signed [W-1:0] feature_x2y[0:NUM_LANES-1];
    logic signed [W-1:0] feature_chosen[0:NUM_LANES-1];
    logic signed [W-1:0] beta_reg[0:2];

    for (genvar fl = 0; fl < NUM_LANES; fl++) begin : gen_feature_lanes
        multi_lsm_feature_lane u_feature (
            .clk(clk_100), .rst_n(rst_btn_n),
            .start(feature_start[fl]), .ready(feature_ready[fl]),
            .mode(feature_mode), .spot(spot_rdata[fl]),
            .cashflow(cash_rdata[fl]), .factor(feature_factor),
            .strike(lat_K), .inv_K(inv_K_reg), .is_put(lat_option_type),
            .beta0(beta_reg[0]), .beta1(beta_reg[1]), .beta2(beta_reg[2]),
            .done(feature_done[fl]), .itm(feature_itm[fl]),
            .cont(feature_cont[fl]), .x(feature_x[fl]), .x2(feature_x2[fl]),
            .x3(feature_x3[fl]), .x4(feature_x4[fl]),
            .xy(feature_xy[fl]), .x2y(feature_x2y[fl]),
            .chosen(feature_chosen[fl])
        );
    end

    // Lane-local exact integer sums.
    acc_t lane_sum1[0:NUM_LANES-1], lane_sumx[0:NUM_LANES-1];
    acc_t lane_sumx2[0:NUM_LANES-1], lane_sumx3[0:NUM_LANES-1];
    acc_t lane_sumx4[0:NUM_LANES-1], lane_sumy[0:NUM_LANES-1];
    acc_t lane_sumxy[0:NUM_LANES-1], lane_sumx2y[0:NUM_LANES-1];
    acc_t lane_pv[0:NUM_LANES-1];
    logic [15:0] lane_itm_count[0:NUM_LANES-1];

    acc_t sum1, sumx, sumx2, sumx3, sumx4, sumy, sumxy, sumx2y, sum_pv;
    logic [15:0] itm_count;
    always_comb begin
        sum1='0; sumx='0; sumx2='0; sumx3='0; sumx4='0;
        sumy='0; sumxy='0; sumx2y='0; sum_pv='0; itm_count='0;
        for (int sr = 0; sr < NUM_LANES; sr++) begin
            sum1 += lane_sum1[sr]; sumx += lane_sumx[sr];
            sumx2 += lane_sumx2[sr]; sumx3 += lane_sumx3[sr];
            sumx4 += lane_sumx4[sr]; sumy += lane_sumy[sr];
            sumxy += lane_sumxy[sr]; sumx2y += lane_sumx2y[sr];
            sum_pv += lane_pv[sr]; itm_count += lane_itm_count[sr];
        end
    end

    // ---------------------------------------------------------------------
    // Regression solver
    // ---------------------------------------------------------------------
    logic reg_vin, reg_vout, reg_rout, reg_singular;
    logic signed [W-1:0] reg_mat[0:11];
    logic signed [W-1:0] reg_beta[0:2];
    regression u_regression (
        .clk(clk_100), .rst_n(rst_btn_n),
        .valid_in(reg_vin), .ready_out(reg_rout), .ready_in(1'b1),
        .mat_flat(reg_mat), .valid_out(reg_vout),
        .singular_err(reg_singular), .beta(reg_beta)
    );

    // ---------------------------------------------------------------------
    // Controller
    // ---------------------------------------------------------------------
    typedef enum logic [4:0] {
        ST_IDLE, ST_INIT_DT, ST_INIT_GBM_CONST, ST_INIT_DISC,
        ST_INIT_INV_K, ST_INIT_DISC_M,
        ST_GEN_PATHS, ST_TERM_READ, ST_TERM_CAPTURE, ST_TERM_WRITE,
        ST_BACK_START, ST_TRAIN_READ, ST_TRAIN_START, ST_TRAIN_WAIT,
        ST_MEAN_DIV, ST_REG_START, ST_REG_WAIT,
        ST_DECIDE_READ, ST_DECIDE_START, ST_DECIDE_WAIT,
        ST_FINAL_READ, ST_FINAL_START, ST_FINAL_WAIT,
        ST_FINAL_DIV, ST_DONE
    } state_t;
    state_t state;

    logic [ROW_COUNT_W-1:0] rows_active;
    logic [ROW_COUNT_W-1:0] scan_row;
    logic [7:0] exercise_step;
    logic [NUM_LANES-1:0] feature_pending;
    logic [3:0] sub_phase;
    logic [7:0] disc_pow_cnt;
    logic signed [W-1:0] mean_y_reg;

    // Generate paths step-major. Independent path bundles may be in flight
    // together; input spots are FIFO-aligned through inverse-CDF and results
    // retire in-order into their lane-local BRAM banks.
    always_comb begin
        gen_issue_valid = (state == ST_GEN_PATHS) &&
                          (gen_issue_row < rows_active) &&
                          ((gen_step == 0) || gen_data_valid) &&
                          all_s_fifo_space;
        gen_issue_fire = gen_issue_valid && all_sobol_ready;
        gen_output_fire = (state == ST_GEN_PATHS) && all_gbm_valid &&
                          !gbm_level_seen;
    end

    logic [63:0] cycle_counter;
    logic core_active;
    wire core_timeout = core_active && (cycle_counter >= CORE_MAX_CYCLES);

    logic [63:0] final_dividend_abs, final_div_remainder, final_div_quotient;
    logic [6:0] final_div_bit;
    logic final_div_sign;
    logic [64:0] final_div_trial_reg;
    logic final_div_ge;
    wire [63:0] final_div_den = (lat_N == 0) ? 64'd1 : {48'd0, lat_N};
    logic signed [W-1:0] final_average;
    logic signed [W-1:0] valuation_intrinsic_reg;

    assign final_average = final_avg_saturate(final_div_quotient, final_div_sign);

    wire [NUM_LANES-1:0] feature_done_vec;
    for (genvar fd = 0; fd < NUM_LANES; fd++)
        assign feature_done_vec[fd] = feature_done[fd];

    // Memory ports are a pure function of the active phase.
    always_comb begin
        for (int mp = 0; mp < NUM_LANES; mp++) begin
            spot_raddr[mp] = '0; spot_waddr[mp] = '0;
            spot_wdata[mp] = '0; spot_we[mp] = 1'b0;
            cash_raddr[mp] = scan_row[ROW_AW-1:0];
            cash_waddr[mp] = scan_row[ROW_AW-1:0];
            cash_wdata[mp] = '0; cash_we[mp] = 1'b0;

            if (state == ST_GEN_PATHS && gen_output_fire) begin
                spot_we[mp] = 1'b1;
                spot_waddr[mp] = gen_output_spot_addr;
                spot_wdata[mp] = lane_s_next[mp];
            end

            if (state == ST_GEN_PATHS && gen_step != 0) begin
                spot_raddr[mp] = gen_issue_spot_addr;
            end else if (state == ST_TERM_READ || state == ST_TERM_WRITE) begin
                spot_raddr[mp] = scan_spot_addr;
            end else if (state == ST_TRAIN_READ || state == ST_TRAIN_START ||
                         state == ST_TRAIN_WAIT || state == ST_DECIDE_READ ||
                         state == ST_DECIDE_START || state == ST_DECIDE_WAIT) begin
                spot_raddr[mp] = scan_spot_addr;
            end

            if (state == ST_TERM_WRITE) begin
                cash_we[mp] = 1'b1;
                cash_wdata[mp] = terminal_payoff_reg[mp];
            end else if (state == ST_DECIDE_WAIT && feature_done[mp]) begin
                cash_we[mp] = 1'b1;
                cash_wdata[mp] = feature_chosen[mp];
            end
        end
    end

    always_ff @(posedge clk_100 or negedge rst_btn_n) begin
        if (!rst_btn_n) begin
            state <= ST_IDLE;
            batch_ready <= 1'b1; result_valid <= 1'b0; result_price <= '0;
            core_active <= 1'b0; cycle_counter <= '0;
            lat_S0<='0; lat_K<='0; lat_r<='0; lat_sigma<='0; lat_T<='0;
            lat_N<='0; lat_M<='0; lat_option_type<=1'b1;
            dt_reg<='0; drift_const_reg<='0; vol_sqrt_dt_reg<='0;
            disc_reg<='0; disc_m_reg<='0; inv_K_reg<='0;
            util_mul_vin<=1'b0; util_mul_a<='0; util_mul_b<='0;
            util_div_vin<=1'b0; util_div_num<='0; util_div_den_q<='0;
            util_exp_vin<=1'b0; util_exp_a<='0;
            util_sqrt_vin<=1'b0; util_sqrt_a<='0;
            reg_vin<=1'b0;
            gen_path_base<='0; gen_issue_row<='0; gen_output_row<='0;
            gen_step<='0; gen_data_valid<=1'b0; gbm_level_seen<=1'b0;
            gen_issue_spot_addr<='0; gen_output_spot_addr<='0; scan_spot_addr<='0;
            rows_active<='0; scan_row<='0; exercise_step<='0;
            feature_pending<='0; feature_mode<=FEATURE_TRAIN; feature_factor<='0;
            sub_phase<='0; disc_pow_cnt<='0; mean_y_reg<='0;
            final_dividend_abs<='0; final_div_remainder<='0;
            final_div_quotient<='0; final_div_bit<='0; final_div_sign<=1'b0;
            final_div_trial_reg<='0; final_div_ge<=1'b0;
            valuation_intrinsic_reg<='0;
            for (int rr=0; rr<12; rr++) reg_mat[rr] <= '0;
            for (int bb=0; bb<3; bb++) beta_reg[bb] <= '0;
            for (int ln=0; ln<NUM_LANES; ln++) begin
                feature_start[ln] <= 1'b0;
                terminal_payoff_reg[ln] <= '0;
                lane_sum1[ln]<='0; lane_sumx[ln]<='0; lane_sumx2[ln]<='0;
                lane_sumx3[ln]<='0; lane_sumx4[ln]<='0; lane_sumy[ln]<='0;
                lane_sumxy[ln]<='0; lane_sumx2y[ln]<='0;
                lane_itm_count[ln]<='0; lane_pv[ln]<='0;
            end
        end else begin
            result_valid <= 1'b0; util_mul_vin <= 1'b0; util_div_vin <= 1'b0;
            util_exp_vin <= 1'b0; util_sqrt_vin <= 1'b0; reg_vin <= 1'b0;
            for (int ln=0; ln<NUM_LANES; ln++) begin
                feature_start[ln] <= 1'b0;
            end
            if (core_active) cycle_counter <= cycle_counter + 1'b1;
            if (!all_gbm_valid) gbm_level_seen <= 1'b0;

            unique case (state)
            ST_IDLE: begin
                batch_ready <= 1'b1;
                if (batch_valid && batch_ready) begin
                    lat_S0 <= $signed(param_S0); lat_K <= $signed(param_K);
                    lat_r <= $signed(param_r); lat_sigma <= $signed(param_sigma);
                    lat_T <= $signed(param_T); lat_N <= param_paths[15:0];
                    lat_M <= param_steps[7:0]; lat_option_type <= param_option_type;
                    rows_active <= param_paths[15:0] / NUM_LANES;
                    batch_ready <= 1'b0; core_active <= 1'b1;
                    cycle_counter <= '0; result_price <= '0; sub_phase <= '0;
                    state <= ST_INIT_DT;
                end
            end

            ST_INIT_DT: begin
                valuation_intrinsic_reg <= payoff_value(lat_S0, lat_K, lat_option_type);
                if (core_timeout) state <= ST_DONE;
                else if (param_paths > MAX_PATHS || param_steps > MAX_STEPS ||
                         param_paths == 0 || param_steps < 1 ||
                         ((param_paths % NUM_LANES) != 0)) begin
                    result_price <= 32'hDEAD0002; state <= ST_DONE;
                end else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= lat_T;
                    util_div_den_q <= $signed({24'd0, lat_M}) <<< QF;
                    util_div_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    dt_reg <= util_div_result; sub_phase <= 0;
                    state <= ST_INIT_GBM_CONST;
                end
            end

            ST_INIT_GBM_CONST: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= lat_sigma; util_mul_b <= lat_sigma;
                    util_mul_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    util_mul_a <= lat_r - (util_mul_result >>> 1);
                    util_mul_b <= dt_reg; util_mul_vin <= 1'b1; sub_phase <= 2;
                end else if (sub_phase == 2 && util_mul_vout) begin
                    drift_const_reg <= util_mul_result;
                    util_sqrt_a <= dt_reg; util_sqrt_vin <= 1'b1; sub_phase <= 3;
                end else if (sub_phase == 3 && util_sqrt_vout) begin
                    util_mul_a <= lat_sigma; util_mul_b <= $signed(util_sqrt_result);
                    util_mul_vin <= 1'b1; sub_phase <= 4;
                end else if (sub_phase == 4 && util_mul_vout) begin
                    vol_sqrt_dt_reg <= util_mul_result; sub_phase <= 0;
                    state <= ST_INIT_DISC;
                end
            end

            ST_INIT_DISC: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= -lat_r; util_mul_b <= dt_reg;
                    util_mul_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    util_exp_a <= util_mul_result[W-1] ? -util_mul_result : util_mul_result;
                    util_exp_vin <= 1'b1; sub_phase <= 2;
                end else if (sub_phase == 2 && util_exp_vout) begin
                    util_div_num <= ONE_Q; util_div_den_q <= util_exp_result;
                    util_div_vin <= 1'b1; sub_phase <= 3;
                end else if (sub_phase == 3 && util_div_vout) begin
                    disc_reg <= util_div_result; sub_phase <= 0;
                    state <= ST_INIT_INV_K;
                end
            end

            ST_INIT_INV_K: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= ONE_Q; util_div_den_q <= lat_K;
                    util_div_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    inv_K_reg <= util_div_result; disc_m_reg <= disc_reg;
                    disc_pow_cnt <= 1; sub_phase <= 0;
                    if (lat_M <= 1) begin
                        gen_path_base <= 0; gen_issue_row <= 0; gen_output_row <= 0;
                        gen_step <= 0; gen_data_valid <= 1'b0; gbm_level_seen <= 1'b0;
                        gen_issue_spot_addr <= 0; gen_output_spot_addr <= 0;
                        state <= ST_GEN_PATHS;
                    end else state <= ST_INIT_DISC_M;
                end
            end

            ST_INIT_DISC_M: begin
                if (core_timeout) state <= ST_DONE;
                else if (sub_phase == 0 && util_mul_rout) begin
                    util_mul_a <= disc_m_reg; util_mul_b <= disc_reg;
                    util_mul_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_mul_vout) begin
                    disc_m_reg <= util_mul_result; disc_pow_cnt <= disc_pow_cnt + 1'b1;
                    sub_phase <= 0;
                    if (disc_pow_cnt + 1 >= lat_M) begin
                        gen_path_base <= 0; gen_issue_row <= 0; gen_output_row <= 0;
                        gen_step <= 0; gen_data_valid <= 1'b0; gbm_level_seen <= 1'b0;
                        gen_issue_spot_addr <= 0; gen_output_spot_addr <= 0;
                        state <= ST_GEN_PATHS;
                    end
                end
            end

            ST_GEN_PATHS: begin
                if (core_timeout) state <= ST_DONE;
                else begin
                    // A synchronous BRAM read primes the previous step's spot
                    // before the next independent path bundle is issued.
                    if (gen_step != 0 && !gen_data_valid &&
                        gen_issue_row < rows_active)
                        gen_data_valid <= 1'b1;

                    if (gen_issue_fire) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][GEN-ISSUE] base=%0d step=%0d", gen_path_base, gen_step + 1);
`endif
                        gen_issue_row <= gen_issue_row + 1'b1;
                        gen_path_base <= gen_path_base + NUM_LANES;
                        if (gen_step != 0) begin
                            gen_data_valid <= 1'b0;
                            gen_issue_spot_addr <= gen_issue_spot_addr + MAX_STEPS;
                        end
                    end

                    if (gen_output_fire) begin
                        gbm_level_seen <= 1'b1;
                    for (int ln=0; ln<NUM_LANES; ln++) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][PATH] pass=terminal path=%0d step=%0d lane=%0d key=s_next value=0x%08h signed=%0d",
                                 gen_output_row*NUM_LANES + ln, gen_step + 1, ln,
                                 lane_s_next[ln], $signed(lane_s_next[ln]));
`endif
                    end

                        if (gen_output_row + 1 >= rows_active) begin
                            if (gen_step + 1 >= lat_M) begin
                                scan_row <= 0;
                                scan_spot_addr <= lat_M - 1'b1;
                                state <= ST_TERM_READ;
                            end else begin
                                gen_step <= gen_step + 1'b1;
                                gen_path_base <= 0;
                                gen_issue_row <= 0;
                                gen_output_row <= 0;
                                gen_data_valid <= 1'b0;
                                gen_issue_spot_addr <= gen_step;
                                gen_output_spot_addr <= gen_step + 1'b1;
                            end
                        end else begin
                            gen_output_row <= gen_output_row + 1'b1;
                            gen_output_spot_addr <= gen_output_spot_addr + MAX_STEPS;
                        end
                    end
                end
            end

            ST_TERM_READ: state <= ST_TERM_CAPTURE;
            ST_TERM_CAPTURE: begin
                for (int ln=0; ln<NUM_LANES; ln++)
                    terminal_payoff_reg[ln] <=
                        payoff_value(spot_rdata[ln], lat_K, lat_option_type);
                state <= ST_TERM_WRITE;
            end
            ST_TERM_WRITE: begin
`ifdef TOP_NUM_DEBUG
                for (int ln=0; ln<NUM_LANES; ln++)
                    $display("[NUM][ACC-IN] path=%0d step=%0d key=terminal_payoff value=0x%08h signed=%0d",
                             scan_row*NUM_LANES+ln, lat_M,
                             terminal_payoff_reg[ln],
                             $signed(terminal_payoff_reg[ln]));
`endif
                if (scan_row + 1 >= rows_active) begin
                    if (!lat_option_type || lat_M <= 1) begin
                        scan_row <= 0; state <= ST_FINAL_READ;
                    end else begin
                        exercise_step <= lat_M - 1'b1; state <= ST_BACK_START;
                    end
                end else begin
                    scan_row <= scan_row + 1'b1;
                    scan_spot_addr <= scan_spot_addr + MAX_STEPS;
                    state <= ST_TERM_READ;
                end
            end

            ST_BACK_START: begin
                if (exercise_step == 0) begin
                    scan_row <= 0;
                    for (int ln=0; ln<NUM_LANES; ln++) lane_pv[ln] <= '0;
                    state <= ST_FINAL_READ;
                end else begin
                    scan_row <= 0;
                    for (int ln=0; ln<NUM_LANES; ln++) begin
                        lane_sum1[ln]<='0; lane_sumx[ln]<='0; lane_sumx2[ln]<='0;
                        lane_sumx3[ln]<='0; lane_sumx4[ln]<='0; lane_sumy[ln]<='0;
                        lane_sumxy[ln]<='0; lane_sumx2y[ln]<='0;
                        lane_itm_count[ln]<='0;
                    end
                    scan_spot_addr <= exercise_step - 1'b1;
                    state <= ST_TRAIN_READ;
                end
            end

            ST_TRAIN_READ: state <= ST_TRAIN_START;
            ST_TRAIN_START: begin
                feature_mode <= FEATURE_TRAIN; feature_factor <= disc_reg;
                for (int ln=0; ln<NUM_LANES; ln++) feature_start[ln] <= 1'b1;
                feature_pending <= {NUM_LANES{1'b1}};
                state <= ST_TRAIN_WAIT;
            end
            ST_TRAIN_WAIT: begin
                for (int ln=0; ln<NUM_LANES; ln++) if (feature_done[ln]) begin
                    feature_pending[ln] <= 1'b0;
                    if (feature_itm[ln]) begin
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=x_basis value=0x%08h signed=%0d",
                                 scan_row*NUM_LANES+ln,exercise_step,feature_x[ln],$signed(feature_x[ln]));
                        $display("[NUM][ACC-IN] path=%0d step=%0d key=cont_y value=0x%08h signed=%0d",
                                 scan_row*NUM_LANES+ln,exercise_step,feature_cont[ln],$signed(feature_cont[ln]));
`endif
                        lane_sum1[ln] <= lane_sum1[ln] + (acc_t'(1) <<< QF);
                        lane_sumx[ln] <= lane_sumx[ln] + extended(feature_x[ln]);
                        lane_sumx2[ln] <= lane_sumx2[ln] + extended(feature_x2[ln]);
                        lane_sumx3[ln] <= lane_sumx3[ln] + extended(feature_x3[ln]);
                        lane_sumx4[ln] <= lane_sumx4[ln] + extended(feature_x4[ln]);
                        lane_sumy[ln] <= lane_sumy[ln] + extended(feature_cont[ln]);
                        lane_sumxy[ln] <= lane_sumxy[ln] + extended(feature_xy[ln]);
                        lane_sumx2y[ln] <= lane_sumx2y[ln] + extended(feature_x2y[ln]);
                        lane_itm_count[ln] <= lane_itm_count[ln] + 1'b1;
                    end
                end
                if ((feature_pending & ~feature_done_vec) == '0) begin
                    if (scan_row + 1 >= rows_active) begin
                        sub_phase <= 0; state <= ST_MEAN_DIV;
                    end else begin
                        scan_row <= scan_row + 1'b1;
                        scan_spot_addr <= scan_spot_addr + MAX_STEPS;
                        state <= ST_TRAIN_READ;
                    end
                end
            end

            ST_MEAN_DIV: begin
                if (itm_count == 0) begin
                    beta_reg[0]<='0; beta_reg[1]<='0; beta_reg[2]<='0;
                    scan_row<=0; scan_spot_addr<=exercise_step-1'b1;
                    state<=ST_DECIDE_READ;
                end else if (sub_phase == 0 && util_div_rout) begin
                    util_div_num <= saturate64(sumy); util_div_den_q <= saturate64(sum1);
                    util_div_vin <= 1'b1; sub_phase <= 1;
                end else if (sub_phase == 1 && util_div_vout) begin
                    mean_y_reg <= util_div_result; sub_phase <= 0;
                    if (itm_count < 3) begin
                        beta_reg[0] <= util_div_result; beta_reg[1]<='0; beta_reg[2]<='0;
                        scan_row<=0; scan_spot_addr<=exercise_step-1'b1;
                        state<=ST_DECIDE_READ;
                    end else state <= ST_REG_START;
                end
            end

            ST_REG_START: if (reg_rout) begin
`ifdef TOP_NUM_DEBUG
                $display("[NUM][ACC-SUM] key=sum1 step=%0d value64=0x%016h signed=%0d",exercise_step,sum1,$signed(sum1));
                $display("[NUM][ACC-SUM] key=sumx step=%0d value64=0x%016h signed=%0d",exercise_step,sumx,$signed(sumx));
                $display("[NUM][ACC-SUM] key=sumx2 step=%0d value64=0x%016h signed=%0d",exercise_step,sumx2,$signed(sumx2));
                $display("[NUM][ACC-SUM] key=sumx3 step=%0d value64=0x%016h signed=%0d",exercise_step,sumx3,$signed(sumx3));
                $display("[NUM][ACC-SUM] key=sumx4 step=%0d value64=0x%016h signed=%0d",exercise_step,sumx4,$signed(sumx4));
                $display("[NUM][ACC-SUM] key=sumy step=%0d value64=0x%016h signed=%0d",exercise_step,sumy,$signed(sumy));
                $display("[NUM][ACC-SUM] key=sumxy step=%0d value64=0x%016h signed=%0d",exercise_step,sumxy,$signed(sumxy));
                $display("[NUM][ACC-SUM] key=sumx2y step=%0d value64=0x%016h signed=%0d",exercise_step,sumx2y,$signed(sumx2y));
`endif
                reg_mat[0]<=saturate64(sum1); reg_mat[1]<=saturate64(sumx);
                reg_mat[2]<=saturate64(sumx2); reg_mat[3]<=saturate64(sumy);
                reg_mat[4]<=saturate64(sumx); reg_mat[5]<=saturate64(sumx2);
                reg_mat[6]<=saturate64(sumx3); reg_mat[7]<=saturate64(sumxy);
                reg_mat[8]<=saturate64(sumx2); reg_mat[9]<=saturate64(sumx3);
                reg_mat[10]<=saturate64(sumx4); reg_mat[11]<=saturate64(sumx2y);
                reg_vin<=1'b1; state<=ST_REG_WAIT;
            end
            ST_REG_WAIT: if (reg_vout) begin
`ifdef TOP_NUM_DEBUG
                $display("[NUM][BETA] key=beta0 step=%0d value=0x%08h signed=%0d",exercise_step,
                         beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?mean_y_reg:reg_beta[0],
                         $signed(beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?mean_y_reg:reg_beta[0]));
                $display("[NUM][BETA] key=beta1 step=%0d value=0x%08h signed=%0d",exercise_step,
                         beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?'0:reg_beta[1],
                         $signed(beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?'0:reg_beta[1]));
                $display("[NUM][BETA] key=beta2 step=%0d value=0x%08h signed=%0d",exercise_step,
                         beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?'0:reg_beta[2],
                         $signed(beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])?'0:reg_beta[2]));
`endif
                if (beta_over_cap(reg_beta[0],reg_beta[1],reg_beta[2])) begin
                    beta_reg[0]<=mean_y_reg; beta_reg[1]<='0; beta_reg[2]<='0;
                end else begin
                    beta_reg[0]<=reg_beta[0]; beta_reg[1]<=reg_beta[1]; beta_reg[2]<=reg_beta[2];
                end
                scan_row<=0; scan_spot_addr<=exercise_step-1'b1;
                state<=ST_DECIDE_READ;
            end

            ST_DECIDE_READ: state <= ST_DECIDE_START;
            ST_DECIDE_START: begin
                feature_mode <= FEATURE_DECIDE; feature_factor <= disc_reg;
                for (int ln=0; ln<NUM_LANES; ln++) feature_start[ln] <= 1'b1;
                feature_pending <= {NUM_LANES{1'b1}};
                state <= ST_DECIDE_WAIT;
            end
            ST_DECIDE_WAIT: begin
                for (int ln=0; ln<NUM_LANES; ln++)
                    if (feature_done[ln]) begin
                        feature_pending[ln] <= 1'b0;
`ifdef TOP_NUM_DEBUG
                        $display("[NUM][LSM] path=%0d step=%0d key=chosen value=0x%08h signed=%0d",
                                 scan_row*NUM_LANES+ln,exercise_step,
                                 feature_chosen[ln],$signed(feature_chosen[ln]));
`endif
                    end
                if ((feature_pending & ~feature_done_vec) == '0) begin
                    if (scan_row + 1 >= rows_active) begin
                        exercise_step <= exercise_step - 1'b1;
                        state <= ST_BACK_START;
                    end else begin
                        scan_row <= scan_row + 1'b1;
                        scan_spot_addr <= scan_spot_addr + MAX_STEPS;
                        state <= ST_DECIDE_READ;
                    end
                end
            end

            ST_FINAL_READ: state <= ST_FINAL_START;
            ST_FINAL_START: begin
                feature_mode <= FEATURE_FINAL;
                feature_factor <= lat_option_type ? disc_reg : disc_m_reg;
                for (int ln=0; ln<NUM_LANES; ln++) feature_start[ln] <= 1'b1;
                feature_pending <= {NUM_LANES{1'b1}};
                state <= ST_FINAL_WAIT;
            end
            ST_FINAL_WAIT: begin
                for (int ln=0; ln<NUM_LANES; ln++) if (feature_done[ln]) begin
                    feature_pending[ln] <= 1'b0;
                    lane_pv[ln] <= lane_pv[ln] + extended(feature_chosen[ln]);
`ifdef TOP_NUM_DEBUG
                    $display("[NUM][PV] path=%0d step=0 key=discounted_pv value=0x%08h signed=%0d",
                             scan_row*NUM_LANES+ln,feature_chosen[ln],$signed(feature_chosen[ln]));
`endif
                end
                if ((feature_pending & ~feature_done_vec) == '0) begin
                    if (scan_row + 1 >= rows_active) begin
                        sub_phase<=0; state<=ST_FINAL_DIV;
                    end else begin
                        scan_row<=scan_row+1'b1; state<=ST_FINAL_READ;
                    end
                end
            end

            ST_FINAL_DIV: begin
                if (sub_phase == 0) begin
                    final_div_sign <= sum_pv[63];
                    final_dividend_abs <= sum_pv[63] ? -sum_pv : sum_pv;
                    final_div_remainder<='0; final_div_quotient<='0;
                    final_div_bit<=63; sub_phase<=1;
                end else if (sub_phase == 1) begin
                    // Register the shift, comparison, and subtraction on
                    // separate cycles. This removes the previous 64-bit
                    // shift/compare/subtract/variable-bit-write critical path.
                    final_div_trial_reg <= {
                        1'b0, final_div_remainder[62:0],
                        final_dividend_abs[final_div_bit]
                    };
                    sub_phase<=2;
                end else if (sub_phase == 2) begin
                    final_div_ge <=
                        final_div_trial_reg >= {1'b0, final_div_den};
                    sub_phase<=3;
                end else if (sub_phase == 3) begin
                    if (final_div_ge)
                        final_div_remainder <=
                            final_div_trial_reg[63:0] - final_div_den;
                    else
                        final_div_remainder <= final_div_trial_reg[63:0];
                    final_div_quotient <= {
                        final_div_quotient[62:0], final_div_ge
                    };
                    if (final_div_bit==0) sub_phase<=4;
                    else begin
                        final_div_bit<=final_div_bit-1'b1;
                        sub_phase<=1;
                    end
                end else begin
                    result_price <= (final_average >= valuation_intrinsic_reg)
                        ? final_average : valuation_intrinsic_reg;
                    sub_phase<=0; state<=ST_DONE;
                end
            end

            ST_DONE: begin
                result_valid<=1'b1;
                if (core_timeout) result_price<=32'hDEAD0001;
                core_active<=1'b0; state<=ST_IDLE;
            end
            default: state<=ST_IDLE;
            endcase
        end
    end

    assign result_cycles_lo = cycle_counter[31:0];
    assign result_cycles_hi = cycle_counter[63:32];
endmodule

// One multiplier per lane, time-shared across exact RTL-style feature math.
// All lanes run independently; ITM and non-ITM paths may finish on different
// cycles, and the top-level tracks completion with a pending bitmask.
module multi_lsm_feature_lane #(
    parameter int W  = fpga_cfg_pkg::FP_WIDTH,
    parameter int QF = fpga_cfg_pkg::FP_QFRAC
)(
    input logic clk, input logic rst_n,
    input logic start, output logic ready,
    input logic [1:0] mode,
    input logic signed [W-1:0] spot, cashflow, factor, strike, inv_K,
    input logic is_put,
    input logic signed [W-1:0] beta0, beta1, beta2,
    output logic done, output logic itm,
    output logic signed [W-1:0] cont, x, x2, x3, x4, xy, x2y, chosen
);
    localparam logic [1:0] MODE_TRAIN=0, MODE_DECIDE=1, MODE_FINAL=2;
    localparam signed [W-1:0] ONE_Q = 32'sd1 <<< QF;
    typedef enum logic [4:0] {
        F_IDLE, F_CONT_L, F_CONT_W, F_NORM_L, F_NORM_W,
        F_X2_L, F_X2_W, F_X3_L, F_X3_W, F_X4_L, F_X4_W,
        F_XY_L, F_XY_W, F_X2Y_L, F_X2Y_W,
        F_B1_L, F_B1_W, F_B2_L, F_B2_W
    } fstate_t;
    fstate_t state;
    logic [1:0] mode_q;
    logic signed [W-1:0] spot_q, cash_q, factor_q, strike_q, invK_q;
    logic signed [W-1:0] b0_q, b1_q, b2_q, immediate_q, b1x_q;
    logic put_q;
    logic mul_vin, mul_vout, mul_rout;
    logic signed [W-1:0] mul_a, mul_b, mul_result;
    fxMul u_mul (
        .clk(clk), .rst_n(rst_n), .valid_in(mul_vin), .ready_out(mul_rout),
        .valid_out(mul_vout), .ready_in(1'b1),
        .a(mul_a), .b(mul_b), .result(mul_result)
    );
    assign ready = (state == F_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=F_IDLE; done<=1'b0; itm<=1'b0; mul_vin<=1'b0;
            mul_a<='0; mul_b<='0; mode_q<='0; spot_q<='0; cash_q<='0;
            factor_q<='0; strike_q<='0; invK_q<='0; b0_q<='0; b1_q<='0;
            b2_q<='0; immediate_q<='0; b1x_q<='0; put_q<=1'b1;
            cont<='0; x<='0; x2<='0; x3<='0; x4<='0; xy<='0; x2y<='0;
            chosen<='0;
        end else begin
            done<=1'b0; mul_vin<=1'b0;
            unique case(state)
            F_IDLE: if(start) begin
                mode_q<=mode; spot_q<=spot; cash_q<=cashflow; factor_q<=factor;
                strike_q<=strike; invK_q<=inv_K; b0_q<=beta0; b1_q<=beta1;
                b2_q<=beta2; put_q<=is_put;
                immediate_q <= is_put ? ((strike>spot)?strike-spot:'0)
                                      : ((spot>strike)?spot-strike:'0);
                itm <= is_put ? (strike>spot) : (spot>strike);
                state<=F_CONT_L;
            end
            F_CONT_L: if(mul_rout) begin
                mul_a<=factor_q; mul_b<=cash_q; mul_vin<=1'b1; state<=F_CONT_W;
            end
            F_CONT_W: if(mul_vout) begin
                cont<=mul_result;
                if(mode_q==MODE_FINAL) begin chosen<=mul_result; done<=1'b1; state<=F_IDLE; end
                else if(immediate_q<=0) begin
                    if(mode_q==MODE_DECIDE) chosen<=mul_result;
                    done<=1'b1; state<=F_IDLE;
                end else state<=F_NORM_L;
            end
            F_NORM_L: if(mul_rout) begin
                mul_a<=spot_q; mul_b<=invK_q; mul_vin<=1'b1; state<=F_NORM_W;
            end
            F_NORM_W: if(mul_vout) begin
                x<=mul_result-ONE_Q; state<=F_X2_L;
            end
            F_X2_L: if(mul_rout) begin
                mul_a<=x; mul_b<=x; mul_vin<=1'b1; state<=F_X2_W;
            end
            F_X2_W: if(mul_vout) begin
                x2<=mul_result;
                if(mode_q==MODE_DECIDE) state<=F_B1_L;
                else state<=F_X3_L;
            end
            F_X3_L: if(mul_rout) begin mul_a<=x2; mul_b<=x; mul_vin<=1'b1; state<=F_X3_W; end
            F_X3_W: if(mul_vout) begin x3<=mul_result; state<=F_X4_L; end
            F_X4_L: if(mul_rout) begin mul_a<=x2; mul_b<=x2; mul_vin<=1'b1; state<=F_X4_W; end
            F_X4_W: if(mul_vout) begin x4<=mul_result; state<=F_XY_L; end
            F_XY_L: if(mul_rout) begin mul_a<=x; mul_b<=cont; mul_vin<=1'b1; state<=F_XY_W; end
            F_XY_W: if(mul_vout) begin xy<=mul_result; state<=F_X2Y_L; end
            F_X2Y_L: if(mul_rout) begin mul_a<=x2; mul_b<=cont; mul_vin<=1'b1; state<=F_X2Y_W; end
            F_X2Y_W: if(mul_vout) begin x2y<=mul_result; done<=1'b1; state<=F_IDLE; end
            F_B1_L: if(mul_rout) begin mul_a<=b1_q; mul_b<=x; mul_vin<=1'b1; state<=F_B1_W; end
            F_B1_W: if(mul_vout) begin b1x_q<=mul_result; state<=F_B2_L; end
            F_B2_L: if(mul_rout) begin mul_a<=b2_q; mul_b<=x2; mul_vin<=1'b1; state<=F_B2_W; end
            F_B2_W: if(mul_vout) begin
                chosen <= (immediate_q >= (b0_q+b1x_q+mul_result)) ? immediate_q : cont;
                done<=1'b1; state<=F_IDLE;
            end
            default: state<=F_IDLE;
            endcase
        end
    end
endmodule
