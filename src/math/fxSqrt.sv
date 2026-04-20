timeunit 1ns; timeprecision 1ps;
// Restoring digit-by-digit sqrt: radicand = {unsigned(a), QFRAC{1'b0}}, ITERATIONS = QINT/2 + QFRAC.
module fxSqrt #(
    parameter int WIDTH = fpga_cfg_pkg::FP_WIDTH,
    parameter int QINT = fpga_cfg_pkg::FP_QINT,
    parameter int QFRAC = fpga_cfg_pkg::FP_QFRAC,
    parameter int LUT_BITS = 8,
    parameter int LATENCY = fpga_cfg_pkg::FP_SQRT_LATENCY,
    parameter string LUT_FILE = mem_paths_pkg::SQRT_LUT
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
    localparam int ITERATIONS = (QINT / 2) + QFRAC;
    localparam int unsigned ITER_M1 = ITERATIONS - 1;

    initial begin
        assert (ITERATIONS > 0)
            else $error("fxSqrt: ITERATIONS must be > 0");
    end
    // LATENCY, LUT_BITS, LUT_FILE kept for call-site compatibility (sqrt is non-LUT).

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_COMP,
        ST_DONE
    } st_t;

    st_t st;

    logic [63:0] rem;
    logic [31:0] root_acc;
    logic [47:0] rad_acc;
    logic [$clog2(ITERATIONS)-1:0] iter;

    logic [WIDTH-1:0] result_r;

    wire [1:0] pr;
    wire [63:0] rem_wide;
    wire [63:0] trial;
    wire [63:0] rem_next;
    wire        rem_ge;
    wire [31:0] root_next;

    assign pr       = rad_acc[47:46];
    assign rem_wide = (rem << 2) | {62'd0, pr};
    assign trial    = {38'd0, root_acc[23:0], 2'b01};
    assign rem_ge   = (rem_wide >= trial);
    assign rem_next = rem_ge ? (rem_wide - trial) : rem_wide;
    assign root_next = rem_ge ? ((root_acc << 1) | 1'b1) : (root_acc << 1);

    assign ready_out = (st == ST_IDLE) && (!valid_out || ready_in);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            valid_out <= 1'b0;
            result_r  <= '0;
            rem       <= '0;
            root_acc  <= '0;
            rad_acc   <= '0;
            iter      <= '0;
        end else begin
            unique case (st)
                ST_IDLE: begin
                    if (valid_in && ready_out) begin
                        if ($signed(a) <= 0) begin
                            result_r  <= '0;
                            valid_out <= 1'b1;
                            st        <= ST_DONE;
                        end else begin
                            rem      <= '0;
                            root_acc <= '0;
                            rad_acc  <= {a[WIDTH-1:0], {QFRAC{1'b0}}};
                            iter     <= '0;
                            st       <= ST_COMP;
                        end
                    end
                end

                ST_COMP: begin
                    rem      <= rem_next;
                    root_acc <= root_next;
                    rad_acc  <= rad_acc << 2;

                    if (iter == ITER_M1[$clog2(ITERATIONS)-1:0]) begin
                        result_r  <= {8'd0, root_next[23:0]};
                        valid_out <= 1'b1;
                        st        <= ST_DONE;
                    end else begin
                        iter <= iter + 1'b1;
                    end
                end

                ST_DONE: begin
                    if (ready_in) begin
                        valid_out <= 1'b0;
                        st        <= ST_IDLE;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

    assign result = result_r;

`ifdef ASSERT_STRICT
    property p_stall_stable;
        @(posedge clk) disable iff (!rst_n)
            valid_out && !ready_in |=> $stable(result);
    endproperty
    assert property (p_stall_stable)
        else $error("fxSqrt: Result changed while backpressured.");
`endif

endmodule
