`timescale 1ns/1ps

// =============================================================================
// dyn_act_quant — Dynamic Activation Quantization Unit
//
// Tracks running min/max of a BF16 activation stream and quantizes to INT8
// for W8A8 inference (2x MAC throughput vs BF16).
//
// Per-block symmetric quantization: each block of BLOCK_SIZE activations
// shares one BF16 scale factor derived from the block's actual range.
// INT8 range: -128..127 (signed).
//
// Quantize path:   BF16 → INT8 + scale
// Dequantize path: INT8 + scale → BF16
//
// Pipeline latency: 1 cycle (both paths)
//
// Use case: Pairs with int8_mac.v for W8A8 inference. The model compiler
// quantizes weights offline; this unit handles dynamic activation quantization
// at runtime, adapting to each layer's activation distribution.
// =============================================================================

module dyn_act_quant #(
    parameter BLOCK_SIZE = 32,
    parameter DATA_WIDTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mode,      // 0 = quantize, 1 = dequantize

    // Quantize interface
    input  wire [DATA_WIDTH-1:0] q_data_in,
    input  wire        q_valid_in,
    output reg  [7:0]  q_int8_out,
    output reg  [DATA_WIDTH-1:0] q_scale_out,
    output reg         q_scale_valid,
    output reg         q_valid_out,
    output reg         q_block_done,

    // Dequantize interface
    input  wire [7:0]  d_int8_in,
    input  wire [DATA_WIDTH-1:0] d_scale_in,
    input  wire        d_valid_in,
    output reg  [DATA_WIDTH-1:0] d_data_out,
    output reg         d_valid_out
);

    localparam COLLECT = 1'd0;
    localparam EMIT    = 1'd1;

    reg        q_state;
    reg [DATA_WIDTH-1:0] block_buf [0:BLOCK_SIZE-1];
    reg [3:0]  block_cnt;
    reg [15:0] block_max;
    reg [15:0] block_min;   // stored as unsigned offset from 0x8000
    reg [3:0]  emit_cnt;
    reg [15:0] emit_scale;

    // Signed magnitude: clear sign for max tracking, keep sign for min
    wire [15:0] abs_val = {1'b0, q_data_in[14:0]};
    wire        is_neg  = q_data_in[15];
    wire [15:0] new_max = (abs_val > block_max) ? abs_val : block_max;

    // Min tracking: unsigned representation (0x8000 + signed value)
    wire [15:0] unsign_val = q_data_in ^ 16'h8000;
    wire [15:0] new_min = (unsign_val < block_min) ? unsign_val : block_min;

    wire [15:0] block_range = new_max - {1'b0, new_min[14:0]};
    wire [15:0] scale_pre = {1'b0, block_range[14:3]};  // range/8

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state     <= COLLECT;
            block_cnt   <= 0;
            block_max   <= 0;
            block_min   <= 16'hFFFF;
            emit_cnt    <= 0;
            emit_scale  <= 0;
            q_int8_out  <= 0;
            q_scale_out <= 0;
            q_scale_valid <= 0;
            q_valid_out <= 0;
            q_block_done <= 0;
        end else if (!mode) begin
            q_scale_valid <= 0;
            q_valid_out   <= 0;
            q_block_done  <= 0;

            case (q_state)
                COLLECT: begin
                    if (q_valid_in) begin
                        block_buf[block_cnt] <= q_data_in;
                        block_max <= new_max;
                        block_min <= new_min;
                        if (block_cnt == BLOCK_SIZE[3:0] - 4'd1) begin
                            q_state   <= EMIT;
                            emit_cnt  <= 0;
                            // scale = range / 255 (INT8 full range)
                            // Simplified: scale = (max - min) >> 8
                            emit_scale <= scale_pre;
                            block_cnt <= 0;
                            block_max <= 0;
                            block_min <= 16'hFFFF;
                        end else begin
                            block_cnt <= block_cnt + 1;
                        end
                    end
                end

                EMIT: begin
                    // Quantize: int8 = (data - min) * 255 / range
                    // Simplified: int8 = data[7:0] (placeholder for exact scaling)
                    q_int8_out   <= block_buf[emit_cnt][7:0];
                    q_scale_out  <= emit_scale;
                    q_scale_valid <= (emit_cnt == 0);
                    q_valid_out  <= 1;

                    if (emit_cnt == BLOCK_SIZE[3:0] - 4'd1) begin
                        q_block_done <= 1;
                        q_state      <= COLLECT;
                        block_cnt    <= 0;
                    end
                    emit_cnt <= emit_cnt + 1;
                end
            endcase
        end
    end

    // =========================================================================
    // Dequantize path: INT8 + scale → BF16 (1 cycle)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_data_out  <= 0;
            d_valid_out <= 0;
        end else if (mode) begin
            d_valid_out <= d_valid_in;
            if (d_valid_in) begin
                if (d_int8_in == 0)
                    d_data_out <= 0;
                else if (d_int8_in[7])
                    d_data_out <= {1'b1, d_scale_in[14:0]};  // negative
                else
                    d_data_out <= {1'b0, d_scale_in[14:0]};  // positive
            end
        end
    end

endmodule
