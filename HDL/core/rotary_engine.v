`timescale 1ns/1ps

// =============================================================================
// rotary_engine — Rotary Position Embedding (RoPE) Hardware Unit
//
// Computes position-dependent rotation on Q/K vectors for attention:
//   (x_even*cos(theta) - x_odd*sin(theta), x_even*sin(theta) + x_odd*cos(theta))
//
// Uses a pre-loaded sin/cos lookup table (256 entries, BF16 format).
// Pipeline latency: 4 cycles (LUT -> multiply -> combine -> output).
//
// Stage 2 optimizations:
//   - cos=1.0 (0x3F80): identity multiply, pass through unchanged
//   - sin=0.0 (0x0000): zero multiply, output zero
//   - other: full BF16 multiply via the bf16_mul function
// Stage 3 uses BF16 add/subtract via the bf16_addsub function.
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
    // Combinational BF16 multiplier.
    //
    // BF16 format: [15] sign, [14:7] exponent (bias 127), [6:0] mantissa
    // with implicit leading 1.
    //
    // For the identity/zero fast paths, the caller bypasses this function
    // entirely (see stage 2 below).
    // =========================================================================
    function [15:0] bf16_mul(input [15:0] x, input [15:0] y);
        reg        xs, ys, rs;
        reg [7:0]  xe, ye;
        reg [8:0]  esum;
        reg [6:0]  xm, ym;
        reg [13:0] m_x, m_y;
        reg [27:0] prod;
        reg        prod_ge2;
        reg [7:0]  re;
        reg [6:0]  rm;
        reg [15:0] result;
        begin
            xs = x[15];
            ys = y[15];
            rs = xs ^ ys;
            xe = x[14:7];
            ye = y[14:7];
            xm = x[6:0];
            ym = y[6:0];

            if ((xe == 0 && xm == 0) || (ye == 0 && ym == 0)) begin
                result = 16'h0000;
            end
            else if (xe == 8'hFF || ye == 8'hFF) begin
                result = {rs, 8'hFF, 7'h00};
            end
            else begin
                // Multiply mantissas with implicit leading 1s.
                // (1.xx * 1.yy) is in [1.0, 4.0). Use 14-bit fixed-point
                // (bit 13 = integer, bits [12:0] = fraction) for each operand,
                // giving a 28-bit product.
                m_x = {1'b1, xm, 6'd0};  // 1.xx in 14-bit fixed-point
                m_y = {1'b1, ym, 6'd0};
                prod = m_x * m_y;

                // prod[27] = 1 if value >= 2.0 (leading integer bit sits at
                // bit 26 for 1.xx in [1.0, 2.0), bit 27 for [2.0, 4.0)).
                prod_ge2 = prod[27];

                // Result exponent = xe + ye - 127 + prod_ge2.
                // Sum xe+ye can exceed 255 (two 8-bit exponents), so accumulate
                // in the 9-bit esum *before* subtracting the bias. Overflow to
                // Inf when esum >= 382, underflow to zero when esum <= 127.
                esum = {1'b0, xe} + {1'b0, ye} + {8'd0, prod_ge2};
                if (esum > 9'd381) begin
                    result = {rs, 8'hFF, 7'h00};
                end else if (esum < 9'd128) begin
                    result = 16'h0000;
                end else begin
                    re = esum[7:0] - 8'd127;

                    // Extract 7-bit mantissa.
                    if (prod_ge2)
                        rm = prod[26:20];
                    else
                        rm = prod[25:19];

                    result = {rs, re, rm};
                end
            end
            bf16_mul = result;
        end
    endfunction

    // =========================================================================
    // Combinational BF16 add/subtract.
    //
    // Computes a + b (sub=0) or a - b (sub=1).
    // =========================================================================
    function [15:0] bf16_addsub(input [15:0] a, input [15:0] b, input sub);
        reg        a_sign, b_sign, r_sign;
        reg [7:0]  a_exp, b_exp, r_exp;
        reg [15:0] a_LM, b_LM;
        reg [16:0] mag;
        reg [6:0]  man;
        reg [15:0] sh_mag;
        integer    shift, hi, K, sh;
        reg [15:0] result;
        begin
            a_sign = a[15];
            b_sign = b[15] ^ sub;
            a_exp  = a[14:7];
            b_exp  = b[14:7];

            // Handle zero: zero has exp=0 and raw mantissa=0
            if ((a_exp == 0 && a[6:0] == 0) || (b_exp == 0 && b[6:0] == 0)) begin
                if (a_exp == 0 && a[6:0] == 0) begin
                    // a is zero: 0 + b = b, 0 - b = -b, 0 - 0 = +0
                    if (b_exp == 0 && b[6:0] == 0)
                        result = 16'h0000;
                    else if (sub)
                        result = {1'b1, b[14:0]};
                    else
                        result = b;
                end else begin
                    result = a; // b is zero: a +/- 0 = a
                end
            end
            else if (a_exp == 8'hFF || b_exp == 8'hFF) begin
                result = (a_exp == 8'hFF) ? a : b;
            end
            else begin
                // Long mantissas: implicit + 7 mantissa bits + 8 fraction guard
                // bits (16-bit, in [2^15, 2^16)), so alignment right-shifts
                // preserve fraction bits during cancellation.
                a_LM = {1'b1, a[6:0], 8'b0};
                b_LM = {1'b1, b[6:0], 8'b0};
                if (a_exp >= b_exp) begin
                    r_sign = a_sign; r_exp = a_exp;
                    shift = a_exp - b_exp;
                    if (shift >= 16) b_LM = 0;
                    else b_LM = b_LM >> shift;
                end else begin
                    r_sign = b_sign; r_exp = b_exp;
                    shift = b_exp - a_exp;
                    if (shift >= 16) a_LM = 0;
                    else a_LM = a_LM >> shift;
                end

                if (a_sign == b_sign) begin
                    // Same sign: add magnitudes; carry past bit 15 bumps exponent
                    r_sign = a_sign;
                    mag = a_LM + b_LM;
                    if (mag[16]) begin
                        r_exp = r_exp + 8'd1;
                        if (r_exp > 8'd254) begin
                            result = {r_sign, 8'hFF, 7'h00};
                        end else begin
                            man = mag[15:9];
                            result = {r_sign, r_exp, man};
                        end
                    end else begin
                        man = mag[14:8];
                        result = {r_sign, r_exp, man};
                    end
                end else begin
                    // Opposite signs: subtract magnitudes, then normalize
                    if (a_LM >= b_LM) begin
                        mag = a_LM - b_LM;
                        r_sign = a_sign;
                    end else begin
                        mag = b_LM - a_LM;
                        r_sign = b_sign;
                    end
                    if (mag == 0) begin
                        result = 16'h0000;
                    end else begin
                        // Find highest set bit hi in [0..15], shift it to bit 15
                        hi = -1;
                        for (sh = 15; sh >= 0; sh = sh - 1)
                            if (mag[sh] && hi < 0) hi = sh;
                        K = 15 - hi;
                        // Detect underflow *before* subtracting: r_exp is a
                        // plain 8-bit reg, and r_exp - K would wrap for K > r_exp.
                        if (K >= r_exp) begin
                            result = 16'h0000;
                        end else begin
                            r_exp = r_exp - K;
                            sh_mag = mag << K;
                            man = sh_mag[14:8];
                            result = {r_sign, r_exp, man};
                        end
                    end
                end
            end
            bf16_addsub = result;
        end
    endfunction

    // =========================================================================
    // Sin/Cos LUT (initialized to identity: cos=1.0, sin=0.0 at all positions).
    // In production, initialize with actual sin/cos values for each position.
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
    //   Fast paths: cos=1.0 -> pass through, sin=0.0 -> zero
    //   Full path: bf16_mul function for other values
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
            // cos path: identity when cos=1.0, full multiply otherwise
            s2_qe_cos <= cos_one ? s1_qe : bf16_mul(s1_qe, s1_cos);
            s2_qo_cos <= cos_one ? s1_qo : bf16_mul(s1_qo, s1_cos);
            s2_ke_cos <= cos_one ? s1_ke : bf16_mul(s1_ke, s1_cos);
            s2_ko_cos <= cos_one ? s1_ko : bf16_mul(s1_ko, s1_cos);
            // sin path: zero when sin=0.0, full multiply otherwise
            s2_qe_sin <= sin_zero ? 16'h0000 : bf16_mul(s1_qe, s1_sin);
            s2_qo_sin <= sin_zero ? 16'h0000 : bf16_mul(s1_qo, s1_sin);
            s2_ke_sin <= sin_zero ? 16'h0000 : bf16_mul(s1_ke, s1_sin);
            s2_ko_sin <= sin_zero ? 16'h0000 : bf16_mul(s1_ko, s1_sin);
            s2_v <= s1_v;
        end
    end

    // =========================================================================
    // Stage 3: Combine (add/sub)
    //   q_rot_even = q_even * cos - q_odd * sin
    //   q_rot_odd  = q_even * sin + q_odd * cos
    // =========================================================================
    reg [15:0] s3_qe, s3_qo, s3_ke, s3_ko;
    reg        s3_v;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_qe <= 0; s3_qo <= 0;
            s3_ke <= 0; s3_ko <= 0;
            s3_v  <= 0;
        end else begin
            s3_qe <= bf16_addsub(s2_qe_cos, s2_qo_sin, 1'b1);
            s3_qo <= bf16_addsub(s2_qe_sin, s2_qo_cos, 1'b0);
            s3_ke <= bf16_addsub(s2_ke_cos, s2_ko_sin, 1'b1);
            s3_ko <= bf16_addsub(s2_ke_sin, s2_ko_cos, 1'b0);
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
