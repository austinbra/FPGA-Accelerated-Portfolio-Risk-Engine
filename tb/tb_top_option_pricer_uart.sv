`timescale 1ns/1ps

module tb_top_option_pricer_uart_core #(
    parameter bit EXPECT_TIMEOUT = 1'b1,
    parameter int NUM_BATCHES = 1,
    parameter int NUM_LANES = 1,
    parameter bit MULTI_EXERCISE = 1'b0,
    parameter int TB_GLOBAL_MAX_CYCLES = 12_000_000,
    parameter int unsigned DEFAULT_PATHS = 64,
    parameter int unsigned DEFAULT_STEPS = 12,
    parameter logic [31:0] DEFAULT_S0 = 32'h0064_0000,
    parameter logic [31:0] DEFAULT_K = 32'h0064_0000,
    parameter logic [31:0] DEFAULT_R = 32'h0000_0CCD,
    parameter logic [31:0] DEFAULT_SIGMA = 32'h0000_3333,
    parameter logic [31:0] DEFAULT_T = 32'h0001_0000,
    parameter bit DEFAULT_IS_PUT = 1'b1,
    parameter bit HAS_DEFAULT_EXPECTED_PRICE = 1'b0,
    parameter logic [31:0] DEFAULT_EXPECTED_PRICE = '0
);
    parameter int CLK_FREQ_HZ = 100_000_000;
    parameter int BAUD_RATE   = 115200;
    localparam int NUM_PARAMS = 8;
    localparam int NUM_RESULT = 4;
    localparam int MAX_WAIT_CYCLES = (TB_GLOBAL_MAX_CYCLES > 8_000_000) ? TB_GLOBAL_MAX_CYCLES : 8_000_000;
    localparam int unsigned DUT_CORE_MAX_CYCLES = EXPECT_TIMEOUT ? 32'd32 : 32'd50_000_000;
    localparam int unsigned DUT_MULTI_CORE_MAX_CYCLES = EXPECT_TIMEOUT ? 32'd32 : 32'd1_000_000_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic tx_valid_in;
    logic [31:0] tx_data_in;
    logic tx_ready_out;
    logic uart_to_dut;
    logic tx_busy;

    logic [7:0] rx_byte;
    logic rx_byte_valid;
    logic dut_uart_txd;

    logic [31:0] params [0:NUM_PARAMS-1];
    logic [31:0] echoes [0:NUM_PARAMS-1];
    logic [31:0] result_words [0:NUM_RESULT-1];

    int i;
    int b;
    int wait_cycles;
    int errors;
    int dut_tx_toggle_count;
    int dut_tx_toggle_printed;
    int rx_byte_valid_count;
    int rx_byte_valid_printed;
    int sobol_valid_count;
    int inv_valid_count;
    int gbm_valid_count;
    int lsm_valid_count;
    int core_start_count;
    int core_done_count;
    int core_timeout_count;
    int inv_fold_v_count;
    int inv_lnlut_v_count;
    int inv_mul_v_count;
    int inv_sqrt_v_count;
    int inv_rational_v_count;

    always #5 clk = ~clk;

    uart_tx32 #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_host_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .valid_in (tx_valid_in),
        .data_in  (tx_data_in),
        .ready_out(tx_ready_out),
        .tx       (uart_to_dut),
        .tx_busy  (tx_busy)
    );

    uart_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_host_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (dut_uart_txd),
        .rx_data  (rx_byte),
        .rx_valid (rx_byte_valid)
    );

    top_mc_option_pricer #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE),
        .CORE_MAX_CYCLES(DUT_CORE_MAX_CYCLES),
        .MULTI_CORE_MAX_CYCLES(DUT_MULTI_CORE_MAX_CYCLES),
        .NUM_LANES  (NUM_LANES),
        .MULTI_EXERCISE(MULTI_EXERCISE)
    ) dut (
        .clk_100  (clk),
        .rst_btn_n(rst_n),
        .uart_rxd (uart_to_dut),
        .uart_txd (dut_uart_txd)
    );

    task automatic wait_for_tx_ready;
        begin
            wait_cycles = 0;
            while (!tx_ready_out && wait_cycles < MAX_WAIT_CYCLES) begin
                @(posedge clk);
                wait_cycles++;
            end
            if (!tx_ready_out)
                $fatal(1, "Timeout waiting for tx_ready_out");
        end
    endtask

    task automatic send_word(input logic [31:0] word);
        begin
            wait_for_tx_ready();
            @(posedge clk);
            tx_data_in  <= word;
            tx_valid_in <= 1'b1;
            @(posedge clk);
            tx_valid_in <= 1'b0;
            tx_data_in  <= '0;
        end
    endtask

    task automatic wait_for_rx_byte_valid;
        begin
            wait_cycles = 0;
            while (!rx_byte_valid && wait_cycles < MAX_WAIT_CYCLES) begin
                @(negedge clk);
                wait_cycles++;
            end
            if (!rx_byte_valid)
                $fatal(1, "Timeout waiting for rx_byte_valid (dut_tx_toggle_count=%0d dut_uart_txd=%0b)", dut_tx_toggle_count, dut_uart_txd);
        end
    endtask

    task automatic recv_byte(output logic [7:0] b);
        begin
            // Ensure we wait for a fresh rx_valid pulse, not a stale high.
            wait_cycles = 0;
            while (rx_byte_valid && wait_cycles < MAX_WAIT_CYCLES) begin
                @(negedge clk);
                wait_cycles++;
            end
            if (rx_byte_valid)
                $fatal(1, "Timeout waiting for rx_byte_valid deassert");

            wait_for_rx_byte_valid();
            b = rx_byte;
        end
    endtask

    task automatic wait_for_tx_busy(input logic exp_busy, input string what);
        begin
            wait_cycles = 0;
            while ((tx_busy !== exp_busy) && wait_cycles < MAX_WAIT_CYCLES) begin
                @(posedge clk);
                wait_cycles++;
            end
            if (tx_busy !== exp_busy)
                $fatal(1, "Timeout waiting for %s", what);
        end
    endtask

    task automatic recv_word(output logic [31:0] word);
        logic [7:0] b0, b1, b2, b3;
        begin
            recv_byte(b0);
            recv_byte(b1);
            recv_byte(b2);
            recv_byte(b3);
            word = {b3, b2, b1, b0};
        end
    endtask

    task automatic run_one_batch(input int batch_idx);
        int unsigned v_paths;
        int unsigned v_steps;
        logic [31:0] v_s0, v_k, v_r, v_sig, v_t;
        int unsigned v_opt;
        int unsigned v_expected_price;
        int has_expected_price;
        logic signed [31:0] v_intrinsic;
        logic [63:0] cyc64;
        int _pu;
        begin
            // Q16.16 payload per batch (defaults match legacy smoke / validation):
            // paths, steps, S0, K, r, sigma, T, option_type (0=CALL, 1=PUT)
            // Override from xsim: -testplusarg paths=64 -testplusarg steps=12 ...
            // (decimal Q16.16 words for S0,K,r,sigma,T — same encoding as UART host)
            v_paths = DEFAULT_PATHS;
            v_steps = DEFAULT_STEPS;
            v_s0    = DEFAULT_S0;
            v_k     = DEFAULT_K;
            v_r     = DEFAULT_R;
            v_sig   = DEFAULT_SIGMA;
            v_t     = DEFAULT_T;
            v_opt   = DEFAULT_IS_PUT ? 32'd1 : 32'd0;
            v_expected_price = DEFAULT_EXPECTED_PRICE;
            has_expected_price = HAS_DEFAULT_EXPECTED_PRICE;

            // xsim warns if $value$plusargs is used as a task; assign to an int sink.
            _pu = $value$plusargs("paths=%d", v_paths);
            _pu = $value$plusargs("steps=%d", v_steps);
            _pu = $value$plusargs("S0=%d", v_s0);
            _pu = $value$plusargs("K=%d", v_k);
            _pu = $value$plusargs("r=%d", v_r);
            _pu = $value$plusargs("sigma=%d", v_sig);
            _pu = $value$plusargs("T=%d", v_t);
            _pu = $value$plusargs("opt=%d", v_opt);
            _pu = $value$plusargs("expected_price=%d", v_expected_price);
            if (_pu) has_expected_price = 1;

            params[0] = v_paths;
            params[1] = v_steps;
            params[2] = v_s0;
            params[3] = v_k;
            params[4] = v_r;
            params[5] = v_sig;
            params[6] = v_t;
            params[7] = v_opt[0] ? 32'd1 : 32'd0;

            for (i = 0; i < NUM_PARAMS; i++) begin
                send_word(params[i]);
                wait_for_tx_busy(1'b1, "tx_busy assert");
                wait_for_tx_busy(1'b0, "tx_busy deassert");
            end

            // Expect echoed params
            for (i = 0; i < NUM_PARAMS; i++) begin
                recv_word(echoes[i]);
                if (echoes[i] !== params[i]) begin
                    $display("Batch %0d echo mismatch[%0d]: exp=0x%08h got=0x%08h", batch_idx, i, params[i], echoes[i]);
                    errors++;
                end
            end

            // Expect result packet: marker, price, cycles_lo, cycles_hi
            for (i = 0; i < NUM_RESULT; i++) begin
                recv_word(result_words[i]);
            end

            if (result_words[0] !== 32'hABCD0001) begin
                $display("Batch %0d result marker mismatch: got=0x%08h", batch_idx, result_words[0]);
                errors++;
            end

            if (EXPECT_TIMEOUT) begin
                if (result_words[1] !== 32'hDEAD0001) begin
                    $display("Batch %0d expected timeout marker, got price=0x%08h", batch_idx, result_words[1]);
                    errors++;
                end
            end else begin
                if (result_words[1] === 32'hDEAD0001) begin
                    $display("Batch %0d unexpected timeout marker in compute-complete mode.", batch_idx);
                    errors++;
                end
            end

            if (^result_words[1] === 1'bx) begin
                $display("Batch %0d result price contains X/Z: 0x%08h", batch_idx, result_words[1]);
                errors++;
            end

            if (!EXPECT_TIMEOUT && has_expected_price &&
                result_words[1] !== v_expected_price[31:0]) begin
                $display("Batch %0d exact price mismatch: expected=0x%08h got=0x%08h",
                         batch_idx, v_expected_price[31:0], result_words[1]);
                errors++;
            end

            v_intrinsic = v_opt[0]
                ? (($signed(v_k) > $signed(v_s0)) ? $signed(v_k) - $signed(v_s0) : 32'sd0)
                : (($signed(v_s0) > $signed(v_k)) ? $signed(v_s0) - $signed(v_k) : 32'sd0);
            if (!EXPECT_TIMEOUT && MULTI_EXERCISE &&
                $signed(result_words[1]) < v_intrinsic) begin
                $display("Batch %0d valuation-time floor violated: intrinsic=0x%08h got=0x%08h",
                         batch_idx, v_intrinsic, result_words[1]);
                errors++;
            end

            if (!EXPECT_TIMEOUT && result_words[1] != 32'hDEAD0001) begin
                // Q16.16 sanity: an ATM vanilla option with S0=K=100 should price in [0.1, 50.0]
                // i.e. raw value in [0x0000_1999, 0x0032_0000]
                if ($signed(result_words[1]) <= 0 || $signed(result_words[1]) > 32'sh0032_0000) begin
                    $display("Batch %0d price out of plausible range: 0x%08h (Q16.16 = %0d.%0d)",
                             batch_idx, result_words[1],
                             result_words[1][31:16], result_words[1][15:0]);
                    errors++;
                end else begin
                    $display("Batch %0d price = 0x%08h (Q16.16 ~ %0d)", batch_idx, result_words[1],
                             result_words[1] >>> 16);
                end
            end

            if (!EXPECT_TIMEOUT) begin
                cyc64 = {result_words[3], result_words[2]};
                $display("[VIRTUAL_A7] paths=%0d steps=%0d core_cycles=%0d price_raw=0x%08h marker=0x%08h",
                         v_paths, v_steps, cyc64, result_words[1], result_words[0]);
            end

            if (EXPECT_TIMEOUT && result_words[2] === 32'd0 && result_words[3] === 32'd0) begin
                $display("Batch %0d cycle count unexpectedly zero in timeout mode", batch_idx);
                errors++;
            end
        end
    endtask

    initial begin
        tx_valid_in = 1'b0;
        tx_data_in  = '0;
        errors = 0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        for (b = 0; b < NUM_BATCHES; b++) begin
            run_one_batch(b);
        end

        if (errors == 0) begin
            $display("PASS: top UART echo/result packet check (%0d batch(es))", NUM_BATCHES);
        end else begin
            $display("FAIL: %0d error(s) detected", errors);
            $fatal(1, "UART testbench assertions failed");
        end

`ifdef TB_UART_DEBUG
        $display("dut_uart_txd toggle count = %0d", dut_tx_toggle_count);
        $display("stage valids: sobol=%0d inv=%0d gbm=%0d lsm=%0d", sobol_valid_count, inv_valid_count, gbm_valid_count, lsm_valid_count);
        $display("core events: start=%0d done=%0d timeout=%0d", core_start_count, core_done_count, core_timeout_count);
        $display("inverse internals: fold=%0d ln=%0d mul=%0d sqrt=%0d rat=%0d", inv_fold_v_count, inv_lnlut_v_count, inv_mul_v_count, inv_sqrt_v_count, inv_rational_v_count);
`endif

        #100 $finish;
    end

    initial begin
        repeat (TB_GLOBAL_MAX_CYCLES * NUM_BATCHES) @(posedge clk);
        $fatal(1, "Global TB timeout");
    end

    always @(dut_uart_txd) begin
`ifdef TB_UART_DEBUG
        dut_tx_toggle_count++;
        if (dut_tx_toggle_printed < 20) begin
            $display("%0t DUT_TX_TOGGLE -> %0b", $time, dut_uart_txd);
            dut_tx_toggle_printed++;
        end
`endif
    end

    always @(posedge clk) begin
        if (rx_byte_valid) begin
`ifdef TB_UART_DEBUG
            rx_byte_valid_count++;
            if (rx_byte_valid_printed < 20) begin
                $display("%0t HOST_RX_BYTE=0x%02x", $time, rx_byte);
                rx_byte_valid_printed++;
            end
`endif
        end
    end

`ifdef TB_UART_DEBUG
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.sobol_vout)        sobol_valid_count++;
            if (dut.inv_vout)          inv_valid_count++;
            if (dut.gbm_vout)          gbm_valid_count++;
            if (dut.lsm_vout)          lsm_valid_count++;
            if (dut.core_active)       core_start_count++;
            if (dut.result_valid)      core_done_count++;
            if (dut.core_timeout)      core_timeout_count++;
            if (dut.u_inv.v1)          inv_fold_v_count++;
            if (dut.u_inv.v2a)         inv_lnlut_v_count++;
            if (dut.u_inv.v2b)         inv_mul_v_count++;
            if (dut.u_inv.v3)          inv_sqrt_v_count++;
            if (dut.u_inv.valid_out)   inv_rational_v_count++;
        end
    end
`endif
endmodule

// Compatibility wrapper: default mode expects timeout marker.
module tb_top_option_pricer_uart;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b1)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Explicit mode: real compute-complete path should not timeout.
module tb_top_option_pricer_uart_compute;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Same as compute mode but NUM_LANES=2 (xelab -generic_top splits on '=' on some hosts).
module tb_top_option_pricer_uart_compute_lanes2;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_LANES  (2),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Same as compute mode but NUM_LANES=3 (wrapper avoids generic override parsing issues).
module tb_top_option_pricer_uart_compute_lanes3;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_LANES  (3),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Same as compute mode but NUM_LANES=4 (wrapper avoids generic override parsing issues).
module tb_top_option_pricer_uart_compute_lanes4;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_LANES  (4),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Same as compute mode but NUM_LANES=8 (wrapper avoids generic override parsing issues).
module tb_top_option_pricer_uart_compute_lanes8;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_LANES  (8),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Multi-exercise-date RTL v1: single lane, cashflow RAM, deterministic path regeneration.
module tb_top_option_pricer_uart_compute_multi;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_LANES(1),
        .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

module tb_top_option_pricer_uart_compute_multi_lanes2;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0), .NUM_LANES(2), .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

module tb_top_option_pricer_uart_compute_multi_lanes4;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0), .NUM_LANES(4), .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

module tb_top_option_pricer_uart_compute_multi_lanes8;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0), .NUM_LANES(8), .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Focused valuation-time boundary cases. With four paths the raw estimator is
// below intrinsic, so the expected result proves that the t=0 floor is active.
module tb_top_option_pricer_uart_intrinsic_put_lanes4;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0), .NUM_LANES(4), .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000),
        .DEFAULT_PATHS(4), .DEFAULT_STEPS(4),
        .DEFAULT_S0(32'h0032_0000), .DEFAULT_K(32'h0064_0000),
        .DEFAULT_IS_PUT(1'b1),
        .HAS_DEFAULT_EXPECTED_PRICE(1'b1),
        .DEFAULT_EXPECTED_PRICE(32'h0032_0000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

module tb_top_option_pricer_uart_intrinsic_call_lanes4;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0), .NUM_LANES(4), .MULTI_EXERCISE(1'b1),
        .TB_GLOBAL_MAX_CYCLES(1_500_000_000),
        .DEFAULT_PATHS(4), .DEFAULT_STEPS(1),
        .DEFAULT_S0(32'h0096_0000), .DEFAULT_K(32'h0064_0000),
        .DEFAULT_R(32'h0000_0000), .DEFAULT_IS_PUT(1'b0),
        .HAS_DEFAULT_EXPECTED_PRICE(1'b1),
        .DEFAULT_EXPECTED_PRICE(32'h0032_0000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule

// Back-to-back compute-mode requests (multi-batch regression).
module tb_top_option_pricer_uart_multibatch;
    tb_top_option_pricer_uart_core #(
        .EXPECT_TIMEOUT(1'b0),
        .NUM_BATCHES(2),
        .TB_GLOBAL_MAX_CYCLES(1_000_000_000)
    ) i_tb_top_option_pricer_uart_core ();
endmodule
