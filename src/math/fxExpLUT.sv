timeunit 1ns; timeprecision 1ps;
module fxExpLUT #(
    parameter int WIDTH       = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT        = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC       = fpga_cfg_pkg::FP_QFRAC,
    parameter int LUT_BITS    = 12,
    parameter string LUT_FILE = "src/gen/exp_lut_4096.mem",
    parameter bit SIGNED_RANGE = 0   // 1: 8192 LUT, handles signed a (exp(a) for a in [-1,1])
)(
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      valid_in,
    output logic                      ready_out,

    output logic                      valid_out,
    input  logic                      ready_in,

    input  logic signed [WIDTH-1:0]   a,
    output logic signed [WIDTH-1:0]   result
);
    localparam int HALF_LUT = (1 << LUT_BITS);
    localparam int LUT_SIZE = SIGNED_RANGE ? (2 << LUT_BITS) : (1 << LUT_BITS);
    // Domain: [0,1) for unsigned; [-1,1] for signed (low half exp(x), high half exp(-x))
    localparam signed [WIDTH-1:0] A_MIN = SIGNED_RANGE ? -(1 <<< QFRAC) : '0;
    localparam signed [WIDTH-1:0] A_MAX = (1 <<< QFRAC) - 1;

    localparam int SHIFT = QFRAC - LUT_BITS;

    initial begin
        if (SHIFT < 0)
            $fatal(1, "fxExpLUT: invalid SHIFT; QFRAC=%0d LUT_BITS=%0d", QFRAC, LUT_BITS);
    end

    (* rom_style = "block" *)
    logic [WIDTH-1:0] lut [0:LUT_SIZE-1];
    initial $readmemh(LUT_FILE, lut);

    // Stage 1: clamp + register address
    logic                            s1_valid;
    logic [$clog2(LUT_SIZE)-1:0]     s1_addr;

    // Stage 2: LUT read + output
    logic                  v_reg;
    logic signed [WIDTH-1:0] result_reg;

    wire s2_can_drain = ready_in || !v_reg;
    wire s1_can_drain = !s1_valid || s2_can_drain;

    assign ready_out = s1_can_drain;

    // Combinational clamp + address for signed or unsigned
    logic signed [WIDTH-1:0]       a_clamped_c;
    logic [$clog2(LUT_SIZE)-1:0]  addr_c;
    always_comb begin
        a_clamped_c = a;
        addr_c = '0;
        if (SIGNED_RANGE) begin
            if (a >= A_MAX)       a_clamped_c = A_MAX;
            else if (a <= A_MIN)  a_clamped_c = A_MIN;
            if (a < 0) begin
                addr_c = HALF_LUT + ($unsigned(-a_clamped_c) >> SHIFT);
                if (addr_c >= LUT_SIZE) addr_c = LUT_SIZE - 1;
            end else begin
                addr_c = $unsigned(a_clamped_c) >> SHIFT;
                if (addr_c >= HALF_LUT) addr_c = HALF_LUT - 1;
            end
        end else begin
            if (a <= A_MIN)      a_clamped_c = A_MIN;
            else if (a >= A_MAX) a_clamped_c = A_MAX;
            addr_c = ($unsigned(a_clamped_c) >> SHIFT);
        end
    end

    // Stage 1: register address
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_addr  <= '0;
        end else begin
            if (s1_valid && s2_can_drain)
                s1_valid <= 1'b0;

            if (valid_in && ready_out) begin
                s1_valid <= 1'b1;
                s1_addr  <= addr_c;
            end
        end
    end

    // Stage 2: LUT read from registered address
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_reg      <= 1'b0;
            result_reg <= '0;
        end else begin
            if (v_reg && ready_in)
                v_reg <= 1'b0;

            if (s1_valid && s2_can_drain) begin
                v_reg      <= 1'b1;
                result_reg <= lut[s1_addr];
            end
        end
    end

    assign valid_out = v_reg;
    assign result    = result_reg;

`ifdef ASSERT_STRICT
    property p_stall_stable;
        @(posedge clk) disable iff (!rst_n)
            valid_out && !ready_in |=> $stable(result);
    endproperty
    assert property (p_stall_stable)
        else $error("fxExpLUT: Result changed while backpressured.");

    property p_input_not_overwritten;
        @(posedge clk) disable iff (!rst_n)
            (valid_in && !ready_out) |-> $stable(a);
    endproperty
    assert property (p_input_not_overwritten)
        else $error("fxExpLUT: Input overwritten while !ready_out.");
`endif

endmodule
