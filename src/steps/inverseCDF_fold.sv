timeunit 1ns; timeprecision 1ps;
// Fold U(0,1) into x ∈ (0,0.5] and emit a negate flag for symmetry.
module inverseCDF_fold #(
    parameter int WIDTH     = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT      = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC     = fpga_cfg_pkg::FP_QFRAC
)(
    input logic clk,
    input logic rst_n,

    input logic valid_in,
    input  logic ready_in,
    output logic valid_out,
    output logic ready_out,

    input logic signed [WIDTH-1:0] u,

    output logic [WIDTH-1:0] x,         // (0, 0.5]
    output logic negate                 // If 1, final z-score should be negated
);

    localparam signed [WIDTH-1:0] HALF = 32'sd1 << (QFRAC-1); // 0.5

    logic [WIDTH-1:0] x_reg;
    logic negate_reg, valid_reg;
    logic shift_en;
    assign shift_en = ready_in && valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_reg <= '0;
            negate_reg <= '0;
            valid_reg <= '0;
        end else begin
            if (valid_in && ready_out) begin
            if (u < HALF) begin
                x_reg <= u;
                negate_reg <= 1'b1;
            end else begin
                x_reg <= (1 << QFRAC) - u;
                negate_reg <= 1'b0;
            end
                valid_reg <= 1'b1;
            end else if (shift_en) begin
                valid_reg <= '0;
            end
        end
    end

    assign x            = x_reg;
    assign negate       = negate_reg;
    assign valid_out    = valid_reg;
    assign ready_out    = !valid_reg || ready_in;

    assert property (@(posedge clk) disable iff (!rst_n) valid_in && !ready_out |=> $stable(u)) 
        else $error("inverseCDF_fold: Input overwrite");

endmodule
