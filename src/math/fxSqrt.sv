timeunit 1ns; timeprecision 1ps;
module fxSqrt #(
    parameter int WIDTH = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC = fpga_cfg_pkg::FP_QFRAC,
    parameter int LUT_BITS = 8,
    parameter int LATENCY = fpga_cfg_pkg::FP_SQRT_LATENCY,
    parameter string LUT_FILE = "src/gen/sqrt_lut_256.mem"
)(
    input  logic            clk,
    input  logic            rst_n,
    input  logic            valid_in,
    output logic            ready_out,
    output logic            valid_out,
    input  logic            ready_in,
    input  logic [WIDTH-1:0] a,
    output logic [WIDTH-1:0] result
);
    logic                out_valid;
    logic [WIDTH-1:0]    out_data;

    assign ready_out = !out_valid || ready_in;
    assign valid_out = out_valid;
    assign result    = out_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= '0;
        end else begin
            if (valid_in && ready_out) begin
                real a_real, s_real;
                a_real = $itor($signed(a)) / $itor(1 << QFRAC);
                if (a_real <= 0.0)
                    s_real = 0.0;
                else
                    s_real = $sqrt(a_real);
                out_data  <= $rtoi(s_real * $itor(1 << QFRAC));
                out_valid <= 1'b1;
            end else if (out_valid && ready_in) begin
                out_valid <= 1'b0;
            end
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n) valid_out && !ready_in |=> $stable(result))
        else $error("fxSqrt stall overwrite");
endmodule
