`timescale 1ns/1ps

// =============================================================================
// tb_bf16_mac_array_real — runs a REAL checkpoint tensor through the RTL
// BF16 systolic MAC array.
//
// Reads two hex files produced by real_matvec_poc.py:
//   real_weights.hex  N*N words, row-major W[row][col] (already transposed so
//                     that column c of the result is (M*X)[c] for the real
//                     matrix M)
//   real_act.hex      N words, the activation vector X (a real embedding)
//
// Prints N lines "REAL <col> <bf16-hex>" for the checker to compare against
// an exact BF16-FMA reference.
// =============================================================================
module tb_bf16_mac_array_real;

    localparam N = 16;

    reg clk = 0;
    reg rst_n = 0;

    reg  [N*16-1:0]     act_in;
    reg                 act_valid, act_sop, act_eop;
    reg  [15:0]         weight_in;
    reg                 weight_load;
    reg  [7:0]          weight_row, weight_col;
    wire [N*16-1:0]     result_out;
    wire                result_valid, result_sop, result_eop, busy;

    always #5 clk = ~clk;

    bf16_mac_array #(.ARRAY_SIZE(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .act_in(act_in), .act_valid(act_valid), .act_sop(act_sop), .act_eop(act_eop),
        .weight_in(weight_in), .weight_load(weight_load),
        .weight_row(weight_row), .weight_col(weight_col),
        .result_out(result_out), .result_valid(result_valid),
        .result_sop(result_sop), .result_eop(result_eop), .busy(busy)
    );

    reg [15:0] wmem [0:N*N-1];
    reg [15:0] xmem [0:N-1];

    integer r, c;
    initial begin
        $readmemh("real_weights.hex", wmem);
        $readmemh("real_act.hex", xmem);

        act_in = 0; act_valid = 0; act_sop = 0; act_eop = 0;
        weight_in = 0; weight_load = 0; weight_row = 0; weight_col = 0;

        #25; rst_n = 1; #10;

        // Load the full N x N weight tile (one word per cycle).
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                @(posedge clk);
                weight_in  = wmem[r*N + c];
                weight_row = r[7:0];
                weight_col = c[7:0];
                weight_load = 1;
            end
        end
        @(posedge clk); #1; weight_load = 0;

        // Feed the real activation vector (word r in lane r).
        act_in = 0;
        for (r = 0; r < N; r = r + 1)
            act_in[r*16 +: 16] = xmem[r];
        act_valid = 1; act_sop = 1; act_eop = 1;
        @(posedge clk); #1;
        act_valid = 0; act_sop = 0; act_eop = 0;

        // Drain: row stagger + N columns of PIPE_DEPTH + output capture.
        repeat (N*N*4 + 200) @(posedge clk); #1;

        for (c = 0; c < N; c = c + 1)
            $display("REAL %0d %04x", c, result_out[c*16 +: 16]);

        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish(1); end

endmodule
