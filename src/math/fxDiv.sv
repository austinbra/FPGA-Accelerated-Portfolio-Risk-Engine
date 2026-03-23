// ============================================================================
//  fxDiv.sv - generic Qm.n fixed-point divider wrapper for Xilinx div_gen v5.1
//             * 1 clk/quotient   * manual LATENCY cycles   * blocking flow
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
        if (LATENCY != 16)  $warning("fxDiv: LATENCY != 16 - 'fxDiv_core' IP was built for 16 cycles.");
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


    //-------------------------------------------------------------------------
    // 3.  div_gen instance (fixed topology - see note above)
    //-------------------------------------------------------------------------
    logic core_div_rdy, core_dvd_rdy, core_tvalid;
    logic [63:0] core_dout;                     // 48-bit quot  + 16-bit rem

    fxDiv_core div_u (
        .aclk                   (clk),
        .aresetn                (rst_n),

        .s_axis_divisor_tvalid  (valid_in),
        .s_axis_divisor_tready  (core_div_rdy),
        .s_axis_divisor_tdata   (safe_den),

        .s_axis_dividend_tvalid (valid_in),
        .s_axis_dividend_tready (core_dvd_rdy),
        .s_axis_dividend_tdata  (dividend),

        .m_axis_dout_tvalid     (core_tvalid),
        .m_axis_dout_tready     (ready_in),
        .m_axis_dout_tdata      (core_dout)
    );


    //-------------------------------------------------------------------------
    // 4.  Handshake glue + output selection
    //-------------------------------------------------------------------------
    assign ready_out = core_div_rdy && core_dvd_rdy;
    assign valid_out = core_tvalid;
    assign result    = core_dout[DIVIDEND_W-1:QFRAC];   // 47:16 for default build


    //-------------------------------------------------------------------------
    // 5.  Assertion - back-pressure
    //-------------------------------------------------------------------------
    // If the result isn't accepted, ready_out must de-assert within 1 cycle
    // (otherwise we would overwrite the core).
    logic core_bp_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            core_bp_prev <= 1'b0;
        end else begin
            core_bp_prev <= (core_tvalid && !ready_in);
            if (core_bp_prev)
            assert (!ready_out)
                else $error("fxDiv: back-pressure lost - pipeline overwrite");
        end
    end

endmodule
