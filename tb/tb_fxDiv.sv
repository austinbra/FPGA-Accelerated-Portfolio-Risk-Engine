// Self-checking Q16.16 divider contract test.
//
// Compile this test with either src/sim/fxDiv_core_stub.sv or the generated
// Vivado fxDiv_core simulation model. It intentionally relies on ready/valid
// handshakes instead of assuming a fixed divider latency.

`timescale 1ns/1ps

module tb_fxDiv;
    localparam int WIDTH = fpga_cfg_pkg::FP_WIDTH;
    localparam int QFRAC = fpga_cfg_pkg::FP_QFRAC;
    localparam int MAX_WAIT_CYCLES = 256;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic valid_in = 1'b0;
    logic ready_out;
    logic signed [WIDTH-1:0] numerator = '0;
    logic signed [WIDTH-1:0] denominator = '0;
    logic valid_out;
    logic ready_in = 1'b1;
    logic signed [WIDTH-1:0] result;

    int tests = 0;
    int errors = 0;

    fxDiv #(
        .WIDTH(WIDTH),
        .QFRAC(QFRAC)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_out(ready_out),
        .numerator(numerator),
        .denominator(denominator),
        .valid_out(valid_out),
        .ready_in(ready_in),
        .result(result)
    );

    task automatic check_div(
        input logic signed [WIDTH-1:0] numerator_raw,
        input logic signed [WIDTH-1:0] denominator_raw
    );
        logic signed [WIDTH-1:0] expected;
        longint signed scaled_numerator;
        longint signed quotient;
        int waited;
        begin
            if (denominator_raw == 0) begin
                expected = numerator_raw;
            end else begin
                scaled_numerator = longint'($signed(numerator_raw)) <<< QFRAC;
                quotient = scaled_numerator / longint'($signed(denominator_raw));
                expected = quotient[WIDTH-1:0];
            end

            waited = 0;
            while (!ready_out && waited < MAX_WAIT_CYCLES) begin
                @(posedge clk);
                waited++;
            end
            if (!ready_out)
                $fatal(1, "Timeout waiting for divider input readiness");

            @(negedge clk);
            numerator = numerator_raw;
            denominator = denominator_raw;
            valid_in = 1'b1;
            @(negedge clk);
            valid_in = 1'b0;

            waited = 0;
            while (!valid_out && waited < MAX_WAIT_CYCLES) begin
                @(posedge clk);
                waited++;
            end
            if (!valid_out)
                $fatal(1, "Timeout waiting for divider output");

            $display(
                "DIV_RESPONSE index=%0d wait_cycles=%0d numerator=0x%08h denominator=0x%08h",
                tests, waited, numerator_raw, denominator_raw
            );

            if (result !== expected) begin
                $error(
                    "numerator=0x%08h denominator=0x%08h got=0x%08h expected=0x%08h",
                    numerator_raw, denominator_raw, result, expected
                );
                errors++;
            end

            tests++;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        check_div(32'sh0006_0000, 32'sh0002_0000); // 6.0 / 2.0 = 3.0
        check_div(-32'sh0007_8000, 32'sh0002_8000); // -7.5 / 2.5 = -3.0
        check_div(32'sh0001_0000, 32'sh0003_0000); // 1.0 / 3.0
        check_div(32'sh0005_8000, -32'sh0002_0000); // 5.5 / -2.0 = -2.75
        check_div(32'sh007B_0000, 32'sh0000_0000); // divide-by-zero bypass

        if (errors != 0)
            $fatal(1, "FAIL - %0d of %0d divider checks failed", errors, tests);

        $display("PASS - all %0d divider checks matched.", tests);
        $finish;
    end

    initial #50us $fatal(1, "Timeout - divider contract test did not finish");
endmodule
