timeunit 1ns;
timeprecision 1ps;

// Simulation-only behavioral stand-in for Xilinx div_gen wrapper used by fxDiv.
// This module is intentionally simple and should not be used for synthesis.
module fxDiv_core (
    input  logic        aclk,
    input  logic        aresetn,
    input  logic        s_axis_divisor_tvalid,
    output logic        s_axis_divisor_tready,
    input  logic [31:0] s_axis_divisor_tdata,
    input  logic        s_axis_dividend_tvalid,
    output logic        s_axis_dividend_tready,
    input  logic [47:0] s_axis_dividend_tdata,
    output logic        m_axis_dout_tvalid,
    input  logic        m_axis_dout_tready,
    output logic [79:0] m_axis_dout_tdata
);
    logic        out_valid;
    logic [79:0] out_data;

    logic signed [31:0] divisor_s;
    logic signed [47:0] dividend_s;
    logic signed [47:0] quotient_s;
    logic signed [15:0] remainder_s;

    assign divisor_s  = $signed(s_axis_divisor_tdata);
    assign dividend_s = $signed(s_axis_dividend_tdata);

    assign s_axis_divisor_tready  = !out_valid;
    assign s_axis_dividend_tready = !out_valid;
    assign m_axis_dout_tvalid     = out_valid;
    assign m_axis_dout_tdata      = out_data;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            out_valid <= 1'b0;
            out_data  <= '0;
        end else begin
            if (!out_valid && s_axis_divisor_tvalid && s_axis_dividend_tvalid) begin
                if (divisor_s == 0) begin
                    quotient_s  = '0;
                    remainder_s = '0;
                end else begin
                    quotient_s  = dividend_s / divisor_s;
                    remainder_s = dividend_s % divisor_s;
                end
                // Pad to 80 bits like Xilinx div_gen v5.1 dout width for fxDiv.sv slice alignment.
                out_data  <= {16'd0, quotient_s, remainder_s};
                out_valid <= 1'b1;
            end else if (out_valid && m_axis_dout_tready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule
