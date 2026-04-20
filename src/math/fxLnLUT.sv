timeunit 1ns; timeprecision 1ps;
module fxlnLUT #(
    parameter int WIDTH     = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT      = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC     = fpga_cfg_pkg::FP_QFRAC,
    parameter int LUT_BITS  = 12,
    parameter string LUT_FILE = mem_paths_pkg::LN_LUT
)(
    input logic clk,
    input logic rst_n,

    input  logic valid_in,
    output logic ready_out,
    output logic valid_out,
    input  logic ready_in,

    input logic [WIDTH-1:0] a,
    output logic [WIDTH-1:0] result
);
    localparam int LUT_SIZE = 1 << LUT_BITS;
    localparam int SHIFT    = QFRAC - LUT_BITS;

    localparam signed [WIDTH-1:0] LN_CLAMP = -32'sd1310720;  // -20.0 in Q16.16

    initial begin
        if (SHIFT < 0)
            $fatal(1, "fxlnLUT: invalid SHIFT; QFRAC=%0d LUT_BITS=%0d", QFRAC, LUT_BITS);
        assert (LN_CLAMP == $signed(32'hFFEC0000))
            else $error("fxlnLUT: LN_CLAMP mismatch");
    end

    (* rom_style = "block" *)
    logic [WIDTH-1:0] lut [0:LUT_SIZE-1];
    initial $readmemh(LUT_FILE, lut);

    logic                            s1_valid;
    logic                            s1_clamped;
    logic [LUT_BITS-1:0]             s1_addr;

    logic                  v_reg;
    logic signed [WIDTH-1:0] result_reg;

    wire s2_can_drain = ready_in || !v_reg;
    wire s1_can_drain = !s1_valid || s2_can_drain;

    assign ready_out = s1_can_drain;

    logic [LUT_BITS-1:0] addr_c;
    logic                clamp_c;

    always_comb begin
        addr_c  = ($unsigned(a) >> SHIFT) & {LUT_BITS{1'b1}};
        clamp_c = (a == '0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            s1_clamped <= 1'b0;
            s1_addr    <= '0;
        end else begin
            if (s1_valid && s2_can_drain)
                s1_valid <= 1'b0;

            if (valid_in && ready_out) begin
                s1_valid   <= 1'b1;
                s1_clamped <= clamp_c;
                s1_addr    <= addr_c;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_reg      <= 1'b0;
            result_reg <= '0;
        end else begin
            if (v_reg && ready_in)
                v_reg <= 1'b0;

            if (s1_valid && s2_can_drain) begin
                v_reg      <= 1'b1;
                result_reg <= s1_clamped ? LN_CLAMP : $signed(lut[s1_addr]);
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
        else $error("fxlnLUT: Result changed while backpressured.");

    property p_input_not_overwritten;
        @(posedge clk) disable iff (!rst_n)
            (valid_in && !ready_out) |-> $stable(a);
    endproperty
    assert property (p_input_not_overwritten)
        else $error("fxlnLUT: Input overwritten while !ready_out.");
`endif

endmodule
