module uart_input_handler #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input logic clk,
    input logic rst_n,
    
    input logic rx,         // serial rx line
    output logic tx,         // serial tx line
    
    output logic batch_valid,
    input logic batch_ready,
    
    output logic [31:0] paths,
    output logic [31:0] steps,
    output logic [31:0] S0,
    output logic [31:0] K,
    output logic [31:0] r,
    output logic [31:0] sigma,
    output logic [31:0] T,
    output logic        option_type,  // 0=CALL (max(S-K,0)), 1=PUT (max(K-S,0))

    // Optional benchmark/result packet from compute core
    input  logic        result_valid,
    input  logic [31:0] result_price,
    input  logic [31:0] result_cycles_lo,
    input  logic [31:0] result_cycles_hi
);

    // FSM states
    typedef enum logic [1:0] {
        S_RECEIVE,
        S_WAIT_READY
    } state_t;
    
    state_t state, next_state;
    
    logic [2:0] word_cnt;
    
    // UART rx signals
    logic [31:0] rx_data;
    logic rx_valid;
    
    // UART tx signals
    logic tx_ready;
    logic tx_valid;
    logic [31:0] tx_data;
    
    // Register storage (8 words: paths, steps, S0, K, r, sigma, T, option_type)
    logic [31:0] reg_array [0:7];
    
    logic rx_valid_d;
logic rx_valid_rising;
logic batch_complete_pulse;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rx_valid_d <= 1'b0;
    else
        rx_valid_d <= rx_valid;
end

assign rx_valid_rising = rx_valid && !rx_valid_d;
assign batch_complete_pulse = (state == S_RECEIVE) && rx_valid_rising && (word_cnt == 7);
    
    // FSM sequential logic and storage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RECEIVE;
            word_cnt <= 0;
        end else begin
            state <= next_state;
            if (state == S_RECEIVE && rx_valid_rising) begin
            reg_array[word_cnt] <= rx_data;
            $display("Stored word %0d = 0x%08x", word_cnt, rx_data);
            word_cnt <= word_cnt + 1;
        end

        if (state == S_WAIT_READY && batch_ready)
            word_cnt <= 0;
        end
    end
    
    // FSM next state logic
    always_comb begin
    next_state = state;
    batch_valid = 0;

    case (state)
        S_RECEIVE: begin
            if (rx_valid_rising && word_cnt == 7)
                next_state = S_WAIT_READY;
        end

        S_WAIT_READY: begin
            batch_valid = 1;
            if (batch_ready)
                next_state = S_RECEIVE;
        end
    endcase
end
    
    // Assign outputs
    assign paths = reg_array[0];
    assign steps = reg_array[1];
    assign S0 = reg_array[2];
    assign K = reg_array[3];
    assign r = reg_array[4];
    assign sigma = reg_array[5];
    assign T = reg_array[6];
    assign option_type = reg_array[7][0];
    
    // UART rx module
    uart_rx32 #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) uart_rx_inst (
        .clk(clk),
        .rst_n (rst_n),
        .rx(rx),
        .valid_out(rx_valid),
        .data_out (rx_data)
    );
    
// ==============================
    // Optional UART TX (Echo-back after full batch)
    // ==============================
    uart_tx32 #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) uart_tx_inst (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (tx_valid),
        .data_in   (tx_data),
        .ready_out (tx_ready),
        .tx        (tx),
        .tx_busy   ()
    );

    // OPTIONAL: Simple echo of each word during WAIT_READY
    logic [2:0] echo_cnt;
    logic       echoing;
    logic       sending_result;
    logic [1:0] result_idx;
    logic [31:0] result_buf [0:3];
    logic       result_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            echo_cnt <= 0;
            echoing <= 0;
            sending_result <= 0;
            result_idx <= 0;
            result_pending <= 0;
            result_buf[0] <= 32'hABCD0001; // marker/version for host decode
            result_buf[1] <= '0;
            result_buf[2] <= '0;
            result_buf[3] <= '0;
        end else begin
            if (batch_complete_pulse) begin
                echo_cnt <= 3'd0;
                echoing <= 1'b1;
`ifdef UART_DEBUG
                $display("%0t UART_HANDLER: batch complete, starting echo", $time);
`endif
            end

            if (result_valid) begin
                result_buf[0] <= 32'hABCD0001;
                result_buf[1] <= result_price;
                result_buf[2] <= result_cycles_lo;
                result_buf[3] <= result_cycles_hi;
                result_pending <= 1'b1;
            end

            if (echoing && tx_ready) begin
`ifdef UART_DEBUG
                $display("%0t UART_HANDLER: echo word idx=%0d data=0x%08x", $time, echo_cnt, reg_array[echo_cnt]);
`endif
                echo_cnt <= echo_cnt + 1;
                if (echo_cnt == 7)
                    echoing <= 0;
            end

            if (!echoing && result_pending && !sending_result && tx_ready) begin
                sending_result <= 1'b1;
                result_idx <= '0;
`ifdef UART_DEBUG
                $display("%0t UART_HANDLER: starting result packet", $time);
`endif
            end

            if (sending_result && tx_ready) begin
`ifdef UART_DEBUG
                $display("%0t UART_HANDLER: result word idx=%0d data=0x%08x", $time, result_idx, result_buf[result_idx]);
`endif
                if (result_idx == 2'd3) begin
                    sending_result <= 1'b0;
                    result_pending <= 1'b0;
                end else begin
                    result_idx <= result_idx + 1'b1;
                end
            end
        end
    end

    assign tx_valid = echoing || sending_result;
    assign tx_data  = sending_result ? result_buf[result_idx] : reg_array[echo_cnt];
endmodule
