`timescale 1ns/1ps

// =============================================================================
// weight_dequant — Weight-Only Quantization Dequantizer (INT4/INT8/FP4/MXFP4 → BF16)
//
// Converts quantized weights to BF16 for the BF16 MAC array.
// Supports INT4 (packed nibbles), INT8 (full byte), and FP4 (E2M1, packed
// nibbles) plus MXFP4 (E2M1 with a shared per-block scale).
//
// BF16 output format: sign(1) | exponent(8) | mantissa(7)
// Conversion: bf16_out = bf16(quantized_weight) [x 2^scale for MXFP4]
//
// Pipeline latency: 1 cycle
//
// Use case: W4A16, W8A16, W4F16 and MXFP4 inference — weights stored
// quantized in LPDDR6, dequantized at the node MAC boundary before the
// BF16 multiply-accumulate.
// =============================================================================

module weight_dequant (
    input  wire        clk,
    input  wire        rst_n,

    // Configuration (2-bit): 0 = INT4 nibbles, 1 = INT8, 2 = FP4 (E2M1)
    // nibbles, 3 = MXFP4 (E2M1 nibbles with 2^scale block scale).
    input  wire [1:0]  mode,

    // Weight input
    input  wire [7:0]  weight_in,   // packed or full-byte value
    input  wire        nibble_sel,  // for packed modes: 0=low, 1=high nibble
    input  wire [7:0]  scale_in,    // MXFP4 block scale exponent (mode 3)
    input  wire        valid_in,

    // BF16 output
    output reg  [15:0] bf16_out,
    output reg         valid_out
);

    // =========================================================================
    // Feed extraction: packed nibble (INT4/FP4/MXFP4) or full byte (INT8)
    // =========================================================================
    wire [3:0] packed_nibble = nibble_sel ? weight_in[7:4] : weight_in[3:0];
    wire signed [7:0] weight_raw = (mode == 2'b01) ?
        weight_in :  // INT8: full byte
        {{4{packed_nibble[3]}}, packed_nibble};  // INT4/FP4: sign-extended nibble

    // =========================================================================
    // Combinational: Extract sign and absolute value (9-bit to handle INT8 -128)
    // =========================================================================
    wire weight_sign = weight_raw[7];
    wire signed [8:0] weight_ext = {{1{weight_raw[7]}}, weight_raw};
    wire [8:0] weight_abs_9 = weight_sign ? -weight_ext : {1'b0, weight_raw};
    wire [7:0] weight_abs = weight_abs_9[7:0];

    // =========================================================================
    // Combinational: Find leading one for normalization
    // =========================================================================
    reg [3:0]  lead_pos;
    reg [7:0]  bf16_exp;

    always @(*) begin
        if      (weight_abs[7]) begin lead_pos = 4'd7; end
        else if (weight_abs[6]) begin lead_pos = 4'd6; end
        else if (weight_abs[5]) begin lead_pos = 4'd5; end
        else if (weight_abs[4]) begin lead_pos = 4'd4; end
        else if (weight_abs[3]) begin lead_pos = 4'd3; end
        else if (weight_abs[2]) begin lead_pos = 4'd2; end
        else if (weight_abs[1]) begin lead_pos = 4'd1; end
        else if (weight_abs[0]) begin lead_pos = 4'd0; end
        else                    begin lead_pos = 4'd0; end

        // BF16 exponent = 127 + lead_pos (biased)
        bf16_exp = 8'd127 + {4'd0, lead_pos};
    end

    // Normalize mantissa: shift left so leading 1 is at bit 7
    wire [7:0] norm_mantissa = weight_abs << (4'd7 - lead_pos);

    // =========================================================================
    // FP4 (E2M1) magnitude → BF16 magnitude lookup (exact for all 8 magnitudes,
    // OCP MX table)
    //   code: 0=0, 1=0.5, 2=1.0, 3=1.5, 4=2.0, 5=3.0, 6=4.0, 7=6.0
    // =========================================================================
    reg [15:0] fp4_mag_bf16;
    always @(*) begin
        case (packed_nibble[2:0])
            3'd0:   fp4_mag_bf16 = 16'h0000;   // 0
            3'd1:   fp4_mag_bf16 = 16'h3F00;   // 0.5
            3'd2:   fp4_mag_bf16 = 16'h3F80;   // 1.0
            3'd3:   fp4_mag_bf16 = 16'h3FC0;   // 1.5
            3'd4:   fp4_mag_bf16 = 16'h4000;   // 2.0
            3'd5:   fp4_mag_bf16 = 16'h4040;   // 3.0
            3'd6:   fp4_mag_bf16 = 16'h4080;   // 4.0
            3'd7:   fp4_mag_bf16 = 16'h40C0;   // 6.0
        endcase
    end

    // MXFP4: fold the block scale into the BF16 exponent (2^scale).  A zero
    // weight must stay exact zero (0 x 2^scale = 0), so guard the zero case.
    wire [15:0] fp4_mag_scaled =
        (fp4_mag_bf16 == 16'h0) ? 16'h0 :
        {fp4_mag_bf16[15], fp4_mag_bf16[14:7] + scale_in[3:0], fp4_mag_bf16[6:0]};

    // =========================================================================
    // Pipeline Stage 1: Register BF16 result
    // =========================================================================
    wire [15:0] bf16_mag = (mode[1]) ? fp4_mag_scaled :    // FP4/MXFP4
        (weight_abs == 0) ? {weight_sign, 8'd0, 7'd0} :
                            {weight_sign, bf16_exp, norm_mantissa[6:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bf16_out  <= 16'h0;
            valid_out <= 1'b0;
        end else begin
            if (mode[1]) begin
                // FP4/MXFP4: magnitude from the E2M1 lookup, sign from the nibble
                bf16_out <= bf16_mag | {packed_nibble[3], 15'h0};
            end else begin
                bf16_out <= bf16_mag;
            end
            valid_out <= valid_in;
        end
    end

endmodule
