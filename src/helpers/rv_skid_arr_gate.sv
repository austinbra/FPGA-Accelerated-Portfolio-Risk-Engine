timeunit 1ns; timeprecision 1ps;
module rv_skid_arr_gate #(parameter int N=1, DW=32) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              s_valid,
  output logic              s_ready,
  input  logic signed [DW-1:0] s_data [0:N-1],
  input  logic              gate_accept,
  output logic              m_valid,
  input  logic              m_ready,
  output logic signed [DW-1:0] m_data [0:N-1]
);
  // Declare before use
  logic                     buf_valid;
  logic signed [DW-1:0]     buf_data [0:N-1];

  // Ready
  logic base_ready;
  assign base_ready = (!buf_valid) || m_ready;
  assign s_ready    = gate_accept && base_ready;

  // Valid (buffer wins; pass-through gated by accept)
  assign m_valid = buf_valid ? 1'b1 : (s_valid && gate_accept);

  // Data mux
  genvar gi;
  generate
    for (gi = 0; gi < N; ++gi) begin : GEN_OUT
      assign m_data[gi] = buf_valid ? buf_data[gi] : s_data[gi];
    end
  endgenerate

  // Capture on pass-through stall
  logic capture_to_buf;
  assign capture_to_buf = (!buf_valid) && s_valid && s_ready && !m_ready;

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_valid <= 1'b0;
      for (k = 0; k < N; ++k) buf_data[k] <= '0;
    end else begin
      if (m_ready && buf_valid) begin
        buf_valid <= 1'b0;
      end else if (capture_to_buf) begin
        for (k = 0; k < N; ++k) buf_data[k] <= s_data[k];
        buf_valid <= 1'b1;
      end
    end
  end
endmodule