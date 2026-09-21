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
// Quantize maps each value's magnitude m onto the block's maximum magnitude
// as an 8-bit index qn = floor(m / scale) in 0..128, sign applied. scale is
// the step size block_max>>7. Dequantize is the exact inverse: reconstructs
// sign * (|int8| * scale). Because the INT8 magnitude is multiplied back in,
// the round-trip preserves each value's relative magnitude — the earlier
// implementation discarded the INT8 magnitude and always returned +/- full
// scale, collapsing every nonzero activation to the same reconstructed value.
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
    reg [4:0]  block_cnt;
    reg [15:0] block_max;
    reg [4:0]  emit_cnt;
    reg [15:0] emit_scale;

    wire [15:0] abs_val = {1'b0, q_data_in[14:0]};
    wire [15:0] new_max = (abs_val > block_max) ? abs_val : block_max;

    // =========================================================================
    // Quantize index: qn = floor(m / scale), computed per emitted value with a
    // small combinational restoring divider. qn ranges 0..128 (value 128
    // appears as -128 in two's complement); 0 when the scale is zero.
    // =========================================================================
    function automatic [15:0] div_floor;
        input [15:0] nu;
        input [15:0] de;
        reg [16:0] rem;
        integer dk;
        begin
            div_floor = 16'd0;
            if (de == 16'd0) div_floor = 8'd0;
            else begin
                rem = 17'd0;
                for (dk = 15; dk >= 0; dk = dk - 1) begin
                    rem = {rem[15:0], nu[dk]};
                    if ({1'b0, de} <= rem) begin
                        rem = rem - {1'b0, de};
                        div_floor[dk] = 1'b1;
                    end
                end
            end
        end
    endfunction
    wire [15:0] emit_mag = {1'b0, block_buf[emit_cnt][14:0]};
    wire [7:0]  qn = div_floor(emit_mag, emit_scale);
    // 8-bit signed encoding of the index. Negative magnitudes map to two's
    // complement (qn up to 128 -> -128..-1, representable). Positive magnitudes
    // must clamp to 127: qn=128 would encode 0x80 whose sign bit flips the peak
    // positive activation to -128*scale on dequantization. Clamping keeps the
    // sign correct (the symmetric INT8 range is -128..127).
    wire [7:0] enc_index = block_buf[emit_cnt][15]
                            ? (~qn + 8'd1) & 8'hFF
                            : (qn > 8'd127 ? 8'd127 : qn);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state     <= COLLECT;
            block_cnt   <= 0;
            block_max   <= 0;
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
                        if (block_cnt == BLOCK_SIZE[4:0] - 5'd1) begin
                            q_state   <= EMIT;
                            emit_cnt  <= 0;
                            emit_scale <= {1'b0, new_max[14:7]};
                            block_cnt <= 0;
                            block_max <= 0;
                        end else begin
                            block_cnt <= block_cnt + 1;
                        end
                    end
                end

                EMIT: begin
                    q_int8_out   <= enc_index;
                    q_scale_out  <= emit_scale;
                    q_scale_valid <= (emit_cnt == 0);
                    q_valid_out  <= 1;

                    if (emit_cnt == BLOCK_SIZE[4:0] - 5'd1) begin
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
    // Reconstructs sign * (|int8| * scale) so the INT8 magnitude is preserved.
    // =========================================================================
    wire [7:0]  dmag  = d_int8_in[7] ? (~d_int8_in + 8'd1) & 8'hFF : d_int8_in;
    wire [22:0] recon = dmag * {8'b0, d_scale_in[14:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_data_out  <= 0;
            d_valid_out <= 0;
        end else if (mode) begin
            d_valid_out <= d_valid_in;
            if (d_valid_in) begin
                // recon = |int8| * scale; truncate to 15-bit magnitude
                if (d_int8_in == 8'd0)
                    d_data_out <= 0;
                else if (d_int8_in[7])
                    d_data_out <= {1'b1, recon[14:0]};
                else
                    d_data_out <= {1'b0, recon[14:0]};
            end
        end
    end

endmodule
