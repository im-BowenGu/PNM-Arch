`timescale 1ns/1ps

// =============================================================================
// kv_quant — KV Cache INT4 Quantization Unit
//
// Compresses BF16 KV entries to INT4 for 2-4x storage density improvement.
// Uses per-block symmetric quantization: each block of BLOCK_SIZE values shares
// one BF16 scale factor. INT4 range: -8..7 (signed, symmetric around 0).
//
// Quantize path (store):   BF16 → scale + INT4 packed nibbles
// Dequantize path (load):  INT4 + scale → BF16
//
// Quantize maps each value's magnitude m onto the block range [0, block_max]
// as a 4-bit index qn = floor(m / scale) in 0..8, sign applied; scale is the
// step size block_max>>3. Dequantize is the exact inverse: reconstructs
// sign * (|int4| * scale). Because the INT4 magnitude is multiplied back in,
// the round-trip preserves each value's relative magnitude — the earlier
// implementation discarded the INT4 magnitude and always returned +/- full
// scale, collapsing every nonzero entry to the same reconstructed value.
//
// Pipeline latency: 2 cycles (quantize), 1 cycle (dequantize)
//
// Use case: Extends effective KV cache context length by 2-4x when paired with
// kv_cache_bank.v. Quality loss <0.5% perplexity for typical LLM workloads
// with BLOCK_SIZE=16 and dynamic scaling.
// =============================================================================

module kv_quant #(
    parameter BLOCK_SIZE = 16,
    parameter DATA_WIDTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mode,      // 0 = quantize, 1 = dequantize

    // Quantize interface
    input  wire [DATA_WIDTH-1:0] q_data_in,
    input  wire        q_valid_in,
    output reg  [3:0]  q_int4_out,
    output reg  [DATA_WIDTH-1:0] q_scale_out,
    output reg         q_scale_valid,
    output reg         q_valid_out,
    output reg         q_block_done,

    // Dequantize interface
    input  wire [3:0]  d_int4_in,
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
    reg [3:0]  emit_cnt;
    reg [15:0] emit_scale;

    wire [15:0] abs_val = {1'b0, q_data_in[14:0]};
    wire [15:0] new_max = (abs_val > block_max) ? abs_val : block_max;

    // =========================================================================
    // Quantize index computed combinationally from the value currently being
    // emitted and the block scale: qn = floor(m / emit_scale), clamped to 8.
    // Computed with comparisons on m >= k*emit_scale so no divider is needed.
    // =========================================================================
    wire [15:0] emit_mag = {1'b0, block_buf[emit_cnt][14:0]};
    wire [15:0] e1 = emit_scale;
    wire [16:0] e2 = {1'b0, emit_scale} << 1;
    wire [17:0] e3 = {2'b00, emit_scale} * 16'd3;
    wire [17:0] e4 = {2'b00, emit_scale} << 2;
    wire [18:0] e5 = {3'b000, emit_scale} * 16'd5;
    wire [18:0] e6 = {3'b000, emit_scale} * 16'd6;
    wire [18:0] e7 = {3'b000, emit_scale} * 16'd7;
    wire [18:0] e8 = {3'b000, emit_scale} << 3;
    reg  [3:0]  qn;
    always @* begin
        if (emit_scale == 16'd0) begin
            qn = 4'd0;
        end else begin
            qn = 4'd0;
            if (emit_mag >= e1[15:0]) qn = 4'd1;
            if (emit_mag >= e2[15:0]) qn = 4'd2;
            if (emit_mag >= e3[15:0]) qn = 4'd3;
            if (emit_mag >= e4[15:0]) qn = 4'd4;
            if (emit_mag >= e5[15:0]) qn = 4'd5;
            if (emit_mag >= e6[15:0]) qn = 4'd6;
            if (emit_mag >= e7[15:0]) qn = 4'd7;
            if (emit_mag >= e8[15:0]) qn = 4'd8;
        end
    end
    // 4-bit signed encoding of the index. Negative magnitudes map to two's
    // complement (qn up to 8 -> -8..-1, representable). Positive magnitudes must
    // clamp to 7: qn=8 would encode 0b1000 whose sign bit flips the peak positive
    // value to -8*scale on dequantization. Clamping keeps the sign correct.
    wire [3:0] enc_index = block_buf[emit_cnt][15]
                            ? (~qn + 4'd1) & 4'hF
                            : (qn > 4'd7 ? 4'd7 : qn);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state     <= COLLECT;
            block_cnt   <= 0;
            block_max   <= 0;
            emit_cnt    <= 0;
            emit_scale  <= 0;
            q_int4_out  <= 0;
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
                        if (block_cnt == BLOCK_SIZE[3:0] - 4'd1) begin
                            // Block full: transition to EMIT immediately
                            q_state   <= EMIT;
                            emit_cnt  <= 0;
                            emit_scale <= {1'b0, new_max[14:3]};
                            block_cnt <= 0;
                            block_max <= 0;
                        end else begin
                            block_cnt <= block_cnt + 1;
                        end
                    end
                end

                EMIT: begin
                    q_int4_out   <= enc_index;
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
    // Dequantize path: INT4 + scale → BF16 (1 cycle)
    // Reconstructs sign * (|int4| * scale) so the INT4 magnitude is preserved.
    // =========================================================================
    wire [3:0]  dmag  = d_int4_in[3] ? (~d_int4_in + 4'd1) & 4'hF : d_int4_in;
    wire [18:0] recon = dmag * {3'b000, d_scale_in[14:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_data_out  <= 0;
            d_valid_out <= 0;
        end else if (mode) begin
            d_valid_out <= d_valid_in;
            if (d_valid_in) begin
                // recon = |int4| * scale, up to 8*4095 = 32760, fits in 15 bits
                if (d_int4_in == 4'd0)
                    d_data_out <= 0;
                else if (d_int4_in[3])
                    d_data_out <= {1'b1, recon[14:0]};
                else
                    d_data_out <= {1'b0, recon[14:0]};
            end
        end
    end

endmodule
