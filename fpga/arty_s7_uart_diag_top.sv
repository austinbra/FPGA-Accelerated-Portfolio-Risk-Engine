timeunit 1ns;
timeprecision 1ps;

// Minimal physical diagnostic for separating UART behavior from the pricing
// core. The host receives its eight echoed words followed by:
//   word 0: 0xABCD0001 (emitted by uart_input_handler)
//   word 1: generated-core edges measured during 10 ms of board-clock time
//   word 2: UART CLKS_PER_BIT compiled into this design
//   word 3: 0xD1A60000 for board-clock UART, 0xD1A60001 for core-clock UART
module arty_s7_uart_diag_top #(
    parameter bit USE_CORE_UART_CLOCK = 1'b0,
    parameter real CORE_CLKOUT_DIVIDE_F = 10.500,
    parameter int CORE_CLK_FREQ_HZ = 95_238_095
)(
    input  logic CLK100MHZ,
    input  logic btn0,
    input  logic uart_txd_in,
    output logic uart_rxd_out
);
    localparam int BOARD_CLK_FREQ_HZ = 100_000_000;
    localparam int BAUD_RATE = 115_200;
    localparam int UART_CLK_FREQ_HZ = USE_CORE_UART_CLOCK
        ? CORE_CLK_FREQ_HZ : BOARD_CLK_FREQ_HZ;
    localparam int UART_CLKS_PER_BIT = UART_CLK_FREQ_HZ / BAUD_RATE;
    localparam int MEASURE_WINDOW_CYCLES = 1_000_000;

    wire mmcm_clkfb;
    wire mmcm_clkfb_buf;
    wire core_clk_unbuffered;
    wire core_clk;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(10.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(CORE_CLKOUT_DIVIDE_F),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_core_clock (
        .CLKIN1(CLK100MHZ),
        .CLKFBIN(mmcm_clkfb_buf),
        .RST(btn0),
        .PWRDWN(1'b0),
        .CLKFBOUT(mmcm_clkfb),
        .CLKOUT0(core_clk_unbuffered),
        .LOCKED(mmcm_locked)
    );

    BUFG u_core_clock_feedback_buf (.I(mmcm_clkfb), .O(mmcm_clkfb_buf));
    BUFG u_core_clock_output_buf (.I(core_clk_unbuffered), .O(core_clk));

    logic [1:0] board_reset_sync;
    always_ff @(posedge CLK100MHZ or posedge btn0) begin
        if (btn0)
            board_reset_sync <= 2'b00;
        else
            board_reset_sync <= {board_reset_sync[0], 1'b1};
    end
    wire board_rst_n = board_reset_sync[1];

    wire core_reset_async = btn0 | ~mmcm_locked;
    logic [1:0] core_reset_sync;
    always_ff @(posedge core_clk or posedge core_reset_async) begin
        if (core_reset_async)
            core_reset_sync <= 2'b00;
        else
            core_reset_sync <= {core_reset_sync[0], 1'b1};
    end
    wire core_rst_n = core_reset_sync[1];

    wire uart_clk = USE_CORE_UART_CLOCK ? core_clk : CLK100MHZ;
    wire uart_rst_n = USE_CORE_UART_CLOCK ? core_rst_n : board_rst_n;

    // A Gray counter crosses from the generated core clock to the independent
    // 100 MHz input domain. Its delta over exactly 1,000,000 board cycles is a
    // physical ratio measurement, not a value inferred from XDC constraints.
    logic [31:0] core_count_binary;
    logic [31:0] core_count_gray;
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            core_count_binary <= 32'd0;
            core_count_gray <= 32'd0;
        end else begin
            core_count_binary <= core_count_binary + 1'b1;
            core_count_gray <= (core_count_binary + 1'b1)
                ^ ((core_count_binary + 1'b1) >> 1);
        end
    end

    (* ASYNC_REG = "TRUE" *) logic [31:0] core_gray_sync_ff1;
    (* ASYNC_REG = "TRUE" *) logic [31:0] core_gray_sync_ff2;
    logic [19:0] measure_window_count;
    logic [31:0] previous_core_count;
    logic [31:0] measured_core_edges;

    function automatic logic [31:0] gray_to_binary(input logic [31:0] gray);
        logic [31:0] value;
        begin
            value[31] = gray[31];
            for (int index = 30; index >= 0; index = index - 1)
                value[index] = value[index + 1] ^ gray[index];
            return value;
        end
    endfunction

    always_ff @(posedge CLK100MHZ or negedge board_rst_n) begin
        if (!board_rst_n) begin
            core_gray_sync_ff1 <= 32'd0;
            core_gray_sync_ff2 <= 32'd0;
            measure_window_count <= 20'd0;
            previous_core_count <= 32'd0;
            measured_core_edges <= 32'd0;
        end else begin
            core_gray_sync_ff1 <= core_count_gray;
            core_gray_sync_ff2 <= core_gray_sync_ff1;
            if (measure_window_count == MEASURE_WINDOW_CYCLES - 1) begin
                measure_window_count <= 20'd0;
                measured_core_edges <= gray_to_binary(core_gray_sync_ff2)
                    - previous_core_count;
                previous_core_count <= gray_to_binary(core_gray_sync_ff2);
            end else begin
                measure_window_count <= measure_window_count + 1'b1;
            end
        end
    end

    // The measurement changes only every 10 ms, so two destination-domain
    // samples provide a stable diagnostic value for the response packet.
    logic [31:0] measured_edges_sync_ff1;
    logic [31:0] measured_edges_sync_ff2;
    always_ff @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin
            measured_edges_sync_ff1 <= 32'd0;
            measured_edges_sync_ff2 <= 32'd0;
        end else begin
            measured_edges_sync_ff1 <= measured_core_edges;
            measured_edges_sync_ff2 <= measured_edges_sync_ff1;
        end
    end

    logic batch_valid;
    logic [31:0] unused_paths;
    logic [31:0] unused_steps;
    logic [31:0] unused_s0;
    logic [31:0] unused_k;
    logic [31:0] unused_r;
    logic [31:0] unused_sigma;
    logic [31:0] unused_t;
    logic unused_option_type;

    uart_input_handler #(
        .CLK_FREQ_HZ(UART_CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart (
        .clk(uart_clk),
        .rst_n(uart_rst_n),
        .rx(uart_txd_in),
        .tx(uart_rxd_out),
        .batch_valid(batch_valid),
        .batch_ready(1'b1),
        .paths(unused_paths),
        .steps(unused_steps),
        .S0(unused_s0),
        .K(unused_k),
        .r(unused_r),
        .sigma(unused_sigma),
        .T(unused_t),
        .option_type(unused_option_type),
        .result_valid(batch_valid),
        .result_price(measured_edges_sync_ff2),
        .result_cycles_lo(UART_CLKS_PER_BIT),
        .result_cycles_hi(USE_CORE_UART_CLOCK ? 32'hD1A6_0001
                                               : 32'hD1A6_0000)
    );
endmodule
