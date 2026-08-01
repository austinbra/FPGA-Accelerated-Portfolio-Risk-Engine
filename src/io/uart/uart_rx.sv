`timescale 1ns/1ps
module uart_rx #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter BAUD_RATE    = 115200
)(
    input  logic clk,
    input  logic rst_n,
    input  logic rx,
    output logic [7:0] rx_data,
    output logic       rx_valid
);

    localparam int CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam int MID_SAMPLE   = CLKS_PER_BIT / 2;

    typedef enum logic [2:0] {
        IDLE, START, DATA, STOP, READY
    } state_t;

    state_t state;
    logic [15:0] clk_count;
    logic [2:0] bit_index;
    logic [7:0] rx_shift;
    logic       rx_valid_r;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync_ff;

    assign rx_valid = rx_valid_r;

    // The FTDI RX line is asynchronous to the generated core clock. Two
    // colocated stages prevent a metastable first sample from reaching the
    // UART state machine.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_sync_ff <= 2'b11;
        else
            rx_sync_ff <= {rx_sync_ff[0], rx};
    end

    wire rx_sync = rx_sync_ff[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            clk_count   <= 0;
            bit_index   <= 0;
            rx_shift    <= 0;
            rx_data     <= 0;
            rx_valid_r  <= 0;
        end else begin
            rx_valid_r <= 0;  // default: deassert valid unless set later

            case (state)
                IDLE: begin
                    clk_count <= 0;
                    bit_index <= 0;
                    if (rx_sync == 0)
                        state <= START;
                end

                START: begin
                    if (clk_count == MID_SAMPLE) begin
                        if (rx_sync == 0) begin
                            clk_count <= 0;
                            state     <= DATA;
                        end else begin
                            state <= IDLE;  // false start bit
                        end
                    end else
                        clk_count <= clk_count + 1;
                end

                DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 0;
                        rx_shift[bit_index] <= rx_sync;
                        if (bit_index == 7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 1;
                    end else
                        clk_count <= clk_count + 1;
                end

                STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 0;
                        // Reject framing errors instead of accepting a byte
                        // and treating a later data bit as the next start.
                        if (rx_sync)
                            state <= READY;
                        else
                            state <= IDLE;
                    end else
                        clk_count <= clk_count + 1;
                end

                READY: begin
                    rx_data    <= rx_shift;
                    rx_valid_r <= 1;  // one-cycle pulse
                    state      <= IDLE;
                end
            endcase
        end
    end
endmodule
