timeunit 1ns;
timeprecision 1ps;

// One-entry fall-through ready/valid buffer for an array payload.
// gate_accept controls admission of new items but never blocks a buffered item.
module rv_skid_arr_gate #(
    parameter int N  = 1,
    parameter int DW = 32
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         s_valid,
    output logic                         s_ready,
    input  logic signed [DW-1:0]         s_data [0:N-1],
    input  logic                         gate_accept,

    output logic                         m_valid,
    input  logic                         m_ready,
    output logic signed [DW-1:0]         m_data [0:N-1]
);

    logic                         buf_valid;
    logic signed [DW-1:0]         buf_data [0:N-1];
    logic                         s_fire;
    logic                         m_fire;

    // A new item can enter when admission is enabled and the buffer is empty,
    // or when the current buffered item will leave on this cycle.
    assign s_ready = gate_accept && (!buf_valid || m_ready);

    // Buffered data takes priority; otherwise the input falls through.
    assign m_valid = buf_valid || (s_valid && gate_accept);

    for (genvar i = 0; i < N; i++) begin : gen_output_mux
        assign m_data[i] = buf_valid ? buf_data[i] : s_data[i];
    end

    assign s_fire = s_valid && s_ready;
    assign m_fire = m_valid && m_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
            for (int i = 0; i < N; i++) begin
                buf_data[i] <= '0;
            end
        end else begin
            unique case ({m_fire, s_fire})
                2'b00: begin
                    // No transfer: retain the current state.
                end

                2'b01: begin
                    // Input accepted while the downstream is stalled.
                    buf_valid <= 1'b1;
                    for (int i = 0; i < N; i++) begin
                        buf_data[i] <= s_data[i];
                    end
                end

                2'b10: begin
                    // Buffered item consumed without a replacement.
                    buf_valid <= 1'b0;
                end

                2'b11: begin
                    if (buf_valid) begin
                        // Consume the buffered item and store its replacement.
                        buf_valid <= 1'b1;
                        for (int i = 0; i < N; i++) begin
                            buf_data[i] <= s_data[i];
                        end
                    end else begin
                        // Direct pass-through consumed; storage remains empty.
                        buf_valid <= 1'b0;
                    end
                end
            endcase
        end
    end

endmodule
