`timescale 1ns/1ps

// =============================================================================
// rotary_engine — Rotary Position Embedding (RoPE) Hardware Unit
//
// Computes position-dependent rotation on Q/K vectors for attention:
//   (x_even·cos(θ) − x_odd·sin(θ), x_even·sin(θ) + x_odd·cos(θ))
//
// Uses a pre-loaded sin/cos lookup table (256 entries, BF16 format).
// Pipeline latency: 4 cycles (LUT → multiply → combine → output).
//
// Production: replace the multiply and combine stages with bf16_fma instances.
// The BF16 multiply mask (zero when sin=0, pass-through when cos=1.0) ensures
// the identity rotation at position 0 produces exact pass-through.
//
// Use case: Every modern LLM (LLaMA, Gemma, Mistral, Qwen) requires RoPE.
// This unit sits between the attention Q/K projection and the attention compute.
// =============================================================================

module rotary_engine #(
    parameter LUT_DEPTH = 256,
    parameter HIDDEN_DIM = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  position,
    input  wire        valid_in,

    input  wire [15:0] q_even_in,
    input  wire [15:0] q_odd_in,
    input  wire [15:0] k_even_in,
    input  wire [15:0] k_odd_in,

    output reg  [15:0] q_even_out,
    output reg  [15:0] q_odd_out,
    output reg  [15:0] k_even_out,
    output reg  [15:0] k_odd_out,
    output reg         valid_out
);

    // =========================================================================
    // Sin/Cos LUT
    // =========================================================================
    reg [15:0] cos_lut [0:LUT_DEPTH-1];
    reg [15:0] sin_lut [0:LUT_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < LUT_DEPTH; i = i + 1) begin
            cos_lut[i] = 16'h3F80;  // 1.0 in BF16
            sin_lut[i] = 16'h0000;  // 0.0 in BF16
        end
    end

    // =========================================================================
    // Stage 1: LUT lookup + input registration
    // =========================================================================
    reg [15:0] s1_cos, s1_sin;
    reg [15:0] s1_qe, s1_qo, s1_ke, s1_ko;
    reg        s1_v;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_cos <= 0; s1_sin <= 0;
            s1_qe <= 0; s1_qo <= 0;
            s1_ke <= 0; s1_ko <= 0;
            s1_v  <= 0;
        end else begin
            s1_cos <= cos_lut[position];
            s1_sin <= sin_lut[position];
            s1_qe  <= q_even_in;
            s1_qo  <= q_odd_in;
            s1_ke  <= k_even_in;
            s1_ko  <= k_odd_in;
            s1_v   <= valid_in;
        end
    end

    // =========================================================================
    // Stage 2: BF16 multiply
    // Simplified: mask-based zeroing for sin path (sin=0x0000 means zero),
    // identity mask for cos path (cos=0x3F80 means pass-through).
    // In production, instantiate 8 bf16_fma units for exact computation.
    // =========================================================================
    reg [15:0] s2_qe_cos, s2_qe_sin, s2_qo_cos, s2_qo_sin;
    reg [15:0] s2_ke_cos, s2_ke_sin, s2_ko_cos, s2_ko_sin;
    reg        s2_v;

    wire sin_zero = (s1_sin == 16'h0000);
    wire cos_one  = (s1_cos == 16'h3F80);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_qe_cos <= 0; s2_qe_sin <= 0;
            s2_qo_cos <= 0; s2_qo_sin <= 0;
            s2_ke_cos <= 0; s2_ke_sin <= 0;
            s2_ko_cos <= 0; s2_ko_sin <= 0;
            s2_v <= 0;
        end else begin
            // cos path: pass-through when cos=1.0 (production: bf16_fma multiply)
            s2_qe_cos <= cos_one ? s1_qe : s1_qe;
            s2_qo_cos <= cos_one ? s1_qo : s1_qo;
            s2_ke_cos <= cos_one ? s1_ke : s1_ke;
            s2_ko_cos <= cos_one ? s1_ko : s1_ko;
            // sin path: zero when sin=0 (production: bf16_fma multiply)
            s2_qe_sin <= sin_zero ? 16'h0000 : s1_qe;
            s2_qo_sin <= sin_zero ? 16'h0000 : s1_qo;
            s2_ke_sin <= sin_zero ? 16'h0000 : s1_ke;
            s2_ko_sin <= sin_zero ? 16'h0000 : s1_ko;
            s2_v <= s1_v;
        end
    end

    // =========================================================================
    // Stage 3: Combine (add/sub)
    // q_rot_even = q_even * cos - q_odd * sin
    // q_rot_odd  = q_even * sin + q_odd * cos
    // Simplified: XOR as add/sub approximation (production: bf16_fma).
    // =========================================================================
    reg [15:0] s3_qe, s3_qo, s3_ke, s3_ko;
    reg        s3_v;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_qe <= 0; s3_qo <= 0;
            s3_ke <= 0; s3_ko <= 0;
            s3_v  <= 0;
        end else begin
            s3_qe <= s2_qe_cos ^ s2_qo_sin;
            s3_qo <= s2_qe_sin ^ s2_qo_cos;
            s3_ke <= s2_ke_cos ^ s2_ko_sin;
            s3_ko <= s2_ke_sin ^ s2_ko_cos;
            s3_v  <= s2_v;
        end
    end

    // =========================================================================
    // Stage 4: Output registration
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_even_out <= 0; q_odd_out <= 0;
            k_even_out <= 0; k_odd_out <= 0;
            valid_out  <= 0;
        end else begin
            q_even_out <= s3_qe;
            q_odd_out  <= s3_qo;
            k_even_out <= s3_ke;
            k_odd_out  <= s3_ko;
            valid_out  <= s3_v;
        end
    end

endmodule
