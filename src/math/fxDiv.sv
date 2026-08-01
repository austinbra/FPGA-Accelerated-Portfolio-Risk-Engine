// ============================================================================
//  fxDiv.sv - generic Qm.n fixed-point divider wrapper for Xilinx div_gen v5.1
//             * 32-cycle generated core   * ready/valid blocking flow
//             * Dividend is NUM  << QFRAC (kept WIDTH+QFRAC bits)
//             * Safe divide-by-zero bypass (returns numerator)
//             * Parameters identical to fxMul for drop-in symmetry
// ============================================================================

timeunit 1ns; timeprecision 1ps;
module fxDiv #(
    parameter int WIDTH    = fpga_cfg_pkg::FP_WIDTH ,
    parameter int QINT     = fpga_cfg_pkg::FP_QINT  ,   // not used internally
    parameter int QFRAC    = fpga_cfg_pkg::FP_QFRAC ,
    parameter int LATENCY  = fpga_cfg_pkg::FP_DIV_LATENCY
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // upstream handshake
    input  logic                       valid_in,
    output logic                       ready_out,
    input  logic signed [WIDTH-1:0]    numerator,
    input  logic signed [WIDTH-1:0]    denominator,

    // downstream handshake
    output logic                       valid_out,
    input  logic                       ready_in,
    output logic signed [WIDTH-1:0]    result
);

    //-------------------------------------------------------------------------
    // 1.  Compile-time sanity checks
    //-------------------------------------------------------------------------
    initial begin
        assert (LATENCY > 0)
          else $error("fxDiv: LATENCY must be > 0");
        assert (QFRAC > 0)
          else $error("fxDiv: QFRAC must be > 0");

        // The IP used here is still built for 48/32/16.  Warn early if the
        // generics do not match what the core was generated for.
        if (WIDTH   != 32)  $warning("fxDiv: WIDTH != 32 - 'fxDiv_core' IP must be regenerated.");
        if (QFRAC   != 16)  $warning("fxDiv: QFRAC != 16 - 'fxDiv_core' IP must be regenerated.");
        if (LATENCY != 32)  $warning("fxDiv: LATENCY != 32 - 'fxDiv_core' IP was built for 32 cycles.");
    end


    //-------------------------------------------------------------------------
    // 2.  Prepare operands
    //-------------------------------------------------------------------------
    localparam int DIVIDEND_W = WIDTH + QFRAC;   // 32 + 16  →  48
    localparam signed [WIDTH-1:0] ONE_Q = (1 <<< QFRAC);

    logic signed [DIVIDEND_W-1:0] dividend;
    assign dividend = $signed(numerator) <<< QFRAC;


    logic signed [WIDTH-1:0] safe_den;
    assign safe_den = (denominator == 0) ? ONE_Q : denominator;

    // The divisor and dividend are separate AXI-Stream channels. Their
    // TREADY signals are allowed to differ, so capture each upstream request
    // once and keep an independent TVALID asserted until that channel accepts
    // its operand.
    logic signed [WIDTH-1:0]       divisor_reg;
    logic signed [DIVIDEND_W-1:0] dividend_reg;
    logic                          divisor_pending;
    logic                          dividend_pending;
    logic                          transaction_active;
    logic                          core_div_rdy;
    logic                          core_dvd_rdy;
    logic                          core_tvalid;
    logic [79:0]                   core_dout;

    assign ready_out = rst_n && !transaction_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divisor_reg        <= '0;
            dividend_reg       <= '0;
            divisor_pending    <= 1'b0;
            dividend_pending   <= 1'b0;
            transaction_active <= 1'b0;
        end else begin
            if (!transaction_active) begin
                if (valid_in) begin
                    divisor_reg        <= safe_den;
                    dividend_reg       <= dividend;
                    divisor_pending    <= 1'b1;
                    dividend_pending   <= 1'b1;
                    transaction_active <= 1'b1;
                end
            end else begin
                if (divisor_pending && core_div_rdy)
                    divisor_pending <= 1'b0;
                if (dividend_pending && core_dvd_rdy)
                    dividend_pending <= 1'b0;

                if (core_tvalid && ready_in) begin
                    divisor_pending    <= 1'b0;
                    dividend_pending   <= 1'b0;
                    transaction_active <= 1'b0;
                end
            end
        end
    end


    //-------------------------------------------------------------------------
    // 3.  div_gen instance (fixed topology - see note above)
    //-------------------------------------------------------------------------
    // div_gen v5.1 (48/32 signed, remainder) packs its 80-bit output as
    // {quotient[47:0], remainder[31:0]}. Keep this aligned with the generated
    // IP example testbench and src/sim/fxDiv_core_stub.sv.

    fxDiv_core div_u (
        .aclk                   (clk),
        .aresetn                (rst_n),

        .s_axis_divisor_tvalid  (divisor_pending),
        .s_axis_divisor_tready  (core_div_rdy),
        .s_axis_divisor_tdata   (divisor_reg),

        .s_axis_dividend_tvalid (dividend_pending),
        .s_axis_dividend_tready (core_dvd_rdy),
        .s_axis_dividend_tdata  (dividend_reg),

        .m_axis_dout_tvalid     (core_tvalid),
        .m_axis_dout_tready     (ready_in),
        .m_axis_dout_tdata      (core_dout)
    );


    //-------------------------------------------------------------------------
    // 4.  Handshake glue + output selection
    //-------------------------------------------------------------------------
    assign valid_out = core_tvalid;
    // The Q16.16 scaling is already present in dividend = numerator << QFRAC,
    // so return the low WIDTH bits of the integer quotient.
    assign result    = core_dout[WIDTH +: WIDTH];   // 63:32 for the 48/32 core


`ifdef FXDIV_DEBUG
    logic signed [WIDTH-1:0] debug_expected_result;
    logic signed [WIDTH-1:0] debug_numerator;
    logic signed [WIDTH-1:0] debug_denominator;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_expected_result <= '0;
            debug_numerator       <= '0;
            debug_denominator     <= '0;
        end else begin
            if (valid_in && ready_out) begin
                debug_expected_result <= (denominator == 0)
                    ? numerator
                    : $signed(dividend) / $signed(safe_den);
                debug_numerator   <= numerator;
                debug_denominator <= denominator;
`ifdef FXDIV_TRACE
                $display(
                    "[DIV][REQ] time=%0t instance=%m numerator=0x%08h denominator=0x%08h",
                    $time,
                    numerator,
                    denominator
                );
`endif
            end

`ifdef FXDIV_TRACE
            if (core_tvalid && ready_in) begin
                $display(
                    "[DIV][RSP] time=%0t instance=%m numerator=0x%08h denominator=0x%08h result=0x%08h",
                    $time,
                    debug_numerator,
                    debug_denominator,
                    result
                );
            end
`endif

            if (core_tvalid && ready_in && result !== debug_expected_result) begin
                $fatal(
                    1,
                    "FXDIV_MISMATCH instance=%m numerator=0x%08h denominator=0x%08h got=0x%08h expected=0x%08h core=0x%020h",
                    debug_numerator,
                    debug_denominator,
                    result,
                    debug_expected_result,
                    core_dout
                );
            end
        end
    end
`endif

    //-------------------------------------------------------------------------
    // 5.  Assertion - back-pressure
    //-------------------------------------------------------------------------
    // A result must belong to an accepted request, and the wrapper cannot
    // advertise another request while the current transaction is active.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (core_tvalid)
                assert (transaction_active)
                    else $error("fxDiv: divider produced an untracked result");
            if (transaction_active)
                assert (!ready_out)
                    else $error("fxDiv: accepted overlapping transactions");
        end
    end

endmodule
