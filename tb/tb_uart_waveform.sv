`timescale 1ns/1ps

// Small waveform-oriented lab for the byte and word UART receive path. This
// intentionally excludes the pricing core so transport experiments run fast.
module tb_uart_waveform;
    localparam int CLK_FREQ_HZ = 95_238_095;
    localparam int BAUD_RATE = 115_200;
    localparam realtime CLK_HALF_PERIOD_NS = 5.250;
    localparam realtime UART_BIT_PERIOD_NS = 1_000_000_000.0 / BAUD_RATE;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic serial_rx = 1'b1;
    logic word_valid;
    logic [31:0] word_data;

    logic [1:0] phase = 2'd0;
    logic [5:0] received_byte_count = 6'd0;
    logic [3:0] received_word_count = 4'd0;
    logic [31:0] last_received_word = 32'd0;

    // Promote useful internals into the testbench scope so GTKWave and simple
    // VCD parsers do not depend on simulator-specific hierarchy formatting.
    wire [2:0] rx_state = dut.uart_rx_inst.state;
    wire [7:0] rx_byte = dut.uart_rx_inst.rx_data;
    wire rx_byte_valid = dut.uart_rx_inst.rx_valid;

    logic [31:0] request [0:7];

    uart_rx32 #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(serial_rx),
        .valid_out(word_valid),
        .data_out(word_data)
    );

    always #(CLK_HALF_PERIOD_NS) clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            received_byte_count <= 6'd0;
            received_word_count <= 4'd0;
            last_received_word <= 32'd0;
        end else begin
            if (rx_byte_valid)
                received_byte_count <= received_byte_count + 1'b1;
            if (word_valid) begin
                if (word_data !== request[received_word_count])
                    $fatal(1, "word %0d mismatch: expected %08x, got %08x",
                           received_word_count, request[received_word_count],
                           word_data);
                last_received_word <= word_data;
                received_word_count <= received_word_count + 1'b1;
            end
        end
    end

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            serial_rx = 1'b1;
            repeat (8) @(posedge clk);
            rst_n = 1'b1;
            repeat (8) @(posedge clk);
        end
    endtask

    task automatic send_byte(input logic [7:0] value, input logic bad_stop);
        integer bit_index;
        begin
            serial_rx = 1'b0;
            #(UART_BIT_PERIOD_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                serial_rx = value[bit_index];
                #(UART_BIT_PERIOD_NS);
            end
            serial_rx = bad_stop ? 1'b0 : 1'b1;
            #(UART_BIT_PERIOD_NS);
            serial_rx = 1'b1;
        end
    endtask

    task automatic send_word(input logic [31:0] value);
        begin
            send_byte(value[7:0], 1'b0);
            send_byte(value[15:8], 1'b0);
            send_byte(value[23:16], 1'b0);
            send_byte(value[31:24], 1'b0);
        end
    endtask

    task automatic check_packet(input string label);
        begin
            wait (received_word_count == 8);
            repeat (8) @(posedge clk);
            if (received_byte_count !== 32)
                $fatal(1, "%s byte count mismatch: got %0d", label,
                       received_byte_count);
            $display("PASS: %s produced eight UART words", label);
        end
    endtask

    initial begin
        request[0] = 32'd1024;
        request[1] = 32'd4;
        request[2] = 32'h0064_0000;
        request[3] = 32'h0064_0000;
        request[4] = 32'h0000_0CCD;
        request[5] = 32'h0000_3333;
        request[6] = 32'h0001_0000;
        request[7] = 32'd1;

        $dumpfile("uart_rx_lab.vcd");
        $dumpvars(0, phase);
        $dumpvars(0, serial_rx);
        $dumpvars(0, rx_state);
        $dumpvars(0, rx_byte);
        $dumpvars(0, rx_byte_valid);
        $dumpvars(0, word_data);
        $dumpvars(0, word_valid);
        $dumpvars(0, received_byte_count);
        $dumpvars(0, received_word_count);
        $dumpvars(0, last_received_word);

        // Phase 1: the ideal, completely back-to-back 32-byte request. This
        // passes in simulation and demonstrates why simulation alone did not
        // expose the physical-board failure.
        apply_reset();
        phase = 2'd1;
        for (int word_index = 0; word_index < 8; word_index = word_index + 1)
            send_word(request[word_index]);
        check_packet("continuous request");

        // Phase 2: one deliberately invalid stop bit. The corrected receiver
        // must not emit rx_byte_valid for this frame.
        apply_reset();
        phase = 2'd2;
        send_byte(8'hA5, 1'b1);
        repeat (1000) @(posedge clk);
        if (received_byte_count !== 0)
            $fatal(1, "bad-stop byte was accepted");
        $display("PASS: invalid stop bit was rejected");

        // Phase 3: the physical-host strategy: four contiguous bytes per word
        // and a 2 ms idle-high guard between words.
        apply_reset();
        phase = 2'd3;
        for (int word_index = 0; word_index < 8; word_index = word_index + 1) begin
            send_word(request[word_index]);
            #2_000_000;
        end
        check_packet("guarded-word request");

        #100_000;
        $display("UART waveform lab complete");
        $finish;
    end
endmodule
