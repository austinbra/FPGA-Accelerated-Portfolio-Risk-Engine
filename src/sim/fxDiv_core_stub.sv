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
    localparam int unsigned DIV_LATENCY = 32;

    logic        busy;
    logic        out_valid;
    logic [79:0] out_data;
    logic [79:0] pending_data;
    logic [$clog2(DIV_LATENCY)-1:0] cycles_left;

    logic signed [31:0] divisor_s;
    logic signed [47:0] dividend_s;
    logic signed [47:0] quotient_s;
    logic signed [31:0] remainder_s;

    assign divisor_s  = $signed(s_axis_divisor_tdata);
    assign dividend_s = $signed(s_axis_dividend_tdata);

    assign s_axis_divisor_tready  = !busy && !out_valid;
    assign s_axis_dividend_tready = !busy && !out_valid;
    assign m_axis_dout_tvalid     = out_valid;
    assign m_axis_dout_tdata      = out_data;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            busy         <= 1'b0;
            out_valid    <= 1'b0;
            out_data     <= '0;
            pending_data <= '0;
            cycles_left  <= '0;
        end else begin
            if (!busy && !out_valid &&
                s_axis_divisor_tvalid && s_axis_dividend_tvalid) begin
                if (divisor_s == 0) begin
                    quotient_s  = '0;
                    remainder_s = '0;
                end else begin
                    quotient_s  = dividend_s / divisor_s;
                    remainder_s = dividend_s % divisor_s;
                end
                // Match div_gen v5.1 exactly: quotient occupies [79:32] and
                // remainder occupies [31:0].
                pending_data <= {quotient_s, remainder_s};
                cycles_left  <= DIV_LATENCY - 1;
                busy         <= 1'b1;
            end else if (busy) begin
                if (cycles_left == 1) begin
                    out_data    <= pending_data;
                    out_valid   <= 1'b1;
                    cycles_left <= '0;
                    busy        <= 1'b0;
                end else begin
                    cycles_left <= cycles_left - 1'b1;
                end
            end else if (out_valid && m_axis_dout_tready) begin
                // The generated div_gen model does not promise to retain TDATA
                // after TVALID is consumed. Clear it here so downstream logic
                // cannot accidentally rely on a simulation-only held value.
                out_valid <= 1'b0;
                out_data  <= '0;
            end
        end
    end
endmodule
