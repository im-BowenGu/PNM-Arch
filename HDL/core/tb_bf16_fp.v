`timescale 1ns/1ps

// =============================================================================
// tb_bf16_fp — self-checking testbench for HDL/core/bf16_fp.vh.
//
// Reads bf16_ops.hex / bf16_a.hex / bf16_b.hex (one word per line, produced by
// bf16_fp_ref.py) and prints one "R <i> <hex>" line per vector.  The Python
// driver compares the output against its exact-rational golden file.
// =============================================================================

module tb_bf16_fp;

`include "bf16_fp.vh"

    localparam MAXV = 16384;

    reg [7:0]  ops [0:MAXV-1];
    reg [15:0] amem [0:MAXV-1];
    reg [15:0] bmem [0:MAXV-1];

    integer i;
    reg [15:0] a, b, res;

    initial begin
        $readmemh("bf16_ops.hex", ops);
        $readmemh("bf16_a.hex", amem);
        $readmemh("bf16_b.hex", bmem);
        for (i = 0; i < MAXV; i = i + 1) begin
            if (ops[i] == 8'hF) begin
                $finish;
            end
            a = amem[i];
            b = bmem[i];
            case (ops[i])
                8'd0: res = bf16_mul(a, b);
                8'd1: res = bf16_add(a, b);
                8'd2: res = bf16_sub(a, b);
                8'd3: res = bf16_div(a, b);
                8'd4: res = bf16_exp(a);
                8'd5: res = bf16_rsqrt(a);
                8'd6: res = bf16_tanh(a);
                default: res = 16'h0000;
            endcase
            $display("R %0d %04x", i, res);
        end
        $finish;
    end

endmodule
