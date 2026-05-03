timeunit 1ns; timeprecision 1ps;
// Streaming fixed-point multiply with ready/valid flow control.
// LATENCY=1 keeps the legacy single-register behavior for compatibility.
// LATENCY>=2 registers the raw product before Q-format rounding/truncation so
// the DSP multiply path is no longer chained directly into the scaling logic.
module fxMul #(
    parameter int WIDTH    = fpga_cfg_pkg::FP_WIDTH ,
    parameter int QINT     = fpga_cfg_pkg::FP_QINT  ,
    parameter int QFRAC    = fpga_cfg_pkg::FP_QFRAC ,
    parameter int LATENCY  = fpga_cfg_pkg::FP_MUL_LATENCY
)(
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       valid_in,
    output logic                       ready_out,
    input  logic                       ready_in,
    output logic                       valid_out,

    input  logic signed [WIDTH-1:0]    a,
    input  logic signed [WIDTH-1:0]    b,
    output logic signed [WIDTH-1:0]    result
);
    initial begin
        assert (LATENCY >= 1)
            else $error("fxMul: LATENCY must be >= 1");
        assert (QFRAC > 0)
            else $error("fxMul: QFRAC must be > 0");
    end

    function automatic logic signed [WIDTH-1:0] scale_q(
        input logic signed [2*WIDTH-1:0] prod
    );
        logic signed [2*WIDTH-1:0] rounded;
        begin
            // Preserve the legacy Q16.16 behavior: round, arithmetic-shift,
            // then truncate to WIDTH. This intentionally does not saturate.
            rounded = prod + ({{(2*WIDTH-1){1'b0}}, 1'b1} <<< (QFRAC-1));
            scale_q = rounded >>> QFRAC;
        end
    endfunction

    generate
        if (LATENCY == 1) begin : gen_single_cycle
            logic v_reg;
            logic signed [WIDTH-1:0] result_reg;
            logic stall;
            logic accept;
            (* use_dsp = "yes" *) logic signed [2*WIDTH-1:0] raw_prod;

            assign stall = v_reg && !ready_in;
            assign ready_out = !stall;
            assign accept = valid_in && ready_out;
            assign raw_prod = a * b;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v_reg      <= 1'b0;
                    result_reg <= '0;
                end else if (ready_out) begin
                    v_reg <= accept;
                    if (accept)
                        result_reg <= scale_q(raw_prod);
                end
            end

            assign valid_out = v_reg;
            assign result = result_reg;
        end else begin : gen_pipelined
            localparam int PROD_STAGES = LATENCY - 1;

            logic [PROD_STAGES-1:0] prod_valid;
            logic signed [2*WIDTH-1:0] prod_pipe [0:PROD_STAGES-1];
            logic result_valid;
            logic signed [WIDTH-1:0] result_reg;
            logic shift_en;
            logic accept;
            (* use_dsp = "yes" *) logic signed [2*WIDTH-1:0] raw_prod;

            assign shift_en = ready_in || !result_valid;
            assign ready_out = shift_en;
            assign accept = valid_in && ready_out;
            assign raw_prod = a * b;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    prod_valid[0] <= 1'b0;
                    prod_pipe[0] <= '0;
                    result_valid <= 1'b0;
                    result_reg   <= '0;
                end else if (shift_en) begin
                    prod_valid[0] <= accept;
                    if (accept)
                        prod_pipe[0] <= raw_prod;

                    result_valid <= prod_valid[PROD_STAGES-1];
                    if (prod_valid[PROD_STAGES-1])
                        result_reg <= scale_q(prod_pipe[PROD_STAGES-1]);
                end
            end

            for (genvar i = 1; i < PROD_STAGES; i++) begin : gen_prod_pipe
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        prod_pipe[i] <= '0;
                    end else if (shift_en) begin
                        if (prod_valid[i-1])
                            prod_pipe[i] <= prod_pipe[i-1];
                    end
                end
            end

            if (PROD_STAGES > 1) begin : gen_valid_pipe
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (int i = 1; i < PROD_STAGES; i++)
                            prod_valid[i] <= 1'b0;
                    end else if (shift_en) begin
                        for (int i = 1; i < PROD_STAGES; i++)
                            prod_valid[i] <= prod_valid[i-1];
                    end
                end
            end

            assign valid_out = result_valid;
            assign result = result_reg;
        end
    endgenerate

`ifdef ASSERT_STRICT
    logic bp_prev;
    logic signed [WIDTH-1:0] held_result;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bp_prev     <= 1'b0;
            held_result <= '0;
        end else begin
            if (valid_out && !ready_in)
                held_result <= result;

            if (bp_prev)
                assert (valid_out && result == held_result && !ready_out)
                    else $error("fxMul: backpressure overwrite");

            bp_prev <= valid_out && !ready_in;
        end
    end
`endif

endmodule
