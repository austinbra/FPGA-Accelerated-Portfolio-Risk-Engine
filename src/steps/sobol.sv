timeunit 1ns; timeprecision 1ps;
module sobol #(
    parameter int WIDTH     = fpga_cfg_pkg::FP_WIDTH,   // 16, 32, 64...
    parameter int M         = 50,                       // total time-steps "dimensions"
    parameter int LANE_ID   = 0,
    parameter string DIRECTION_MEM_FILE = mem_paths_pkg::DIRECTION_MEM
)(
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         valid_in,
    output logic                         ready_out,
    output logic                         valid_out, //to downstream
    input  logic                         ready_in, //from downstream

    input  logic [WIDTH-1:0]             idx_in,       // current path index (row)
    input  logic [$clog2(M)-1:0]         dim_in,       // current time-step (col)
    output logic [WIDTH-1:0]             sobol_out,

    // expose the entire LUT for TB / debugging
    output logic [WIDTH-1:0]        direction [0:M*WIDTH-1]
);

    // Direction-number memory :  M * WIDTH words
    (* ram_style = "block" *)
    initial $readmemh(DIRECTION_MEM_FILE, direction);
    

    wire [WIDTH-1:0] gray;
    assign gray = idx_in ^ (idx_in >> 1); 
    //one on/off shifts the new dot into the biggest available gap.
    //Because the reciprical is deterministic, the generator never stores the earlier points.
    //You just feed in the row index i and the formula dictates the new coordinate


    wire [WIDTH-1:0] leaf [0:WIDTH-1];
    
    generate
        for (genvar k = 0; k < WIDTH; k = k + 1) begin
            assign leaf[k] = gray[k] ? direction[dim_in*WIDTH + k] : '0; //for each bit position check if high then save x and y value, else 0
        end
    endgenerate// Procedural block for debugging    

    // depth = ceil(log2(WIDTH))
    localparam int LEVELS = $clog2(WIDTH);

    // Stages; example: stage[l][i] holds XOR result at level l, element i
    wire [WIDTH-1:0] stage [0:LEVELS][0:WIDTH-1];
    generate
        for (genvar k = 0; k < WIDTH; k++)begin
            assign stage[0][k] = leaf[k];
        end
        
        //xor everything together
        for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : GEN_LEVEL
            for (genvar j = 0; j < (WIDTH >> (lvl+1)); j++) begin : GEN_PAIR
                assign stage[lvl+1][j] = stage[lvl][2*j] ^ stage[lvl][2*j+1];
            end
        end
    endgenerate
    
    wire [WIDTH-1:0] sobol_raw;
    assign sobol_raw = stage[LEVELS][0];


    // Fixed Buffer logic
    logic buffer_valid;
    logic [WIDTH-1:0] buffer_data;

    assign ready_out = !buffer_valid || ready_in;
    assign valid_out = buffer_valid;
    assign sobol_out = buffer_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_valid <= 1'b0;
            buffer_data <= '0;
        end else begin
            // Use case statement to handle all combinations explicitly
            unique case ({valid_in && ready_out, buffer_valid && ready_in})
                2'b00: begin
                    // No input, no output - no change
                end
                2'b01: begin
                    // No input, output consumed
                    buffer_valid <= 1'b0;
                end
                2'b10: begin
                    // Input accepted, no output
                    buffer_data <= sobol_raw;
                    buffer_valid <= 1'b1;
                end
                2'b11: begin
                    // Both input accepted and output consumed simultaneously
                    buffer_data <= sobol_raw;
                    // buffer_valid stays 1'b1
                end
            endcase
        end
    end

    // Assertions for verification
    `ifndef SYNTHESIS
    // WIDTH must be power of two
    initial begin
        assert (WIDTH > 0 && (1 << $clog2(WIDTH)) == WIDTH)
            else $error("Sobol: WIDTH must be a power of 2");
    end

    // Hold-checks only on sustained backpressure
    logic out_bp, out_bp_prev, in_bp, in_bp_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {out_bp_prev, out_bp} <= '0;
            {in_bp_prev,  in_bp } <= '0;
        end else begin
            // output side
            out_bp_prev <= out_bp;
            out_bp      <= (valid_out && !ready_in);
            if (out_bp_prev && out_bp)
                assert ($stable(sobol_out))
                    else $error("Sobol: Stall overwrite - data loss");

            // input side
            in_bp_prev  <= in_bp;
            in_bp       <= (valid_in && !ready_out);
            if (in_bp_prev && in_bp) begin
                assert ($stable(idx_in)) else $error("Sobol: idx_in changed under backpressure");
                assert ($stable(dim_in)) else $error("Sobol: dim_in changed under backpressure");
            end
        end
    end
    `endif

endmodule
