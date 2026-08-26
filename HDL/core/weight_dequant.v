`timescale 1ns/1ps

// =============================================================================
// weight_dequant — Weight-Only Quantization Dequantizer (INT4/INT8 → BF16)
//
// Converts quantized weights to BF16 for the BF16 MAC array.
// Supports INT4 (packed nibbles) and INT8 (full byte) modes.
//
// BF16 output format: sign(1) | exponent(8) | mantissa(7)
// Conversion: bf16_out = bf16(int_weight)
//
// Pipeline latency: 1 cycle
//
// Use case: W4A16 and W8A16 inference — weights stored as INT4/INT8 in LPDDR6,
// dequantized at the node MAC boundary before BF16 multiply-accumulate.
// =============================================================================

module weight_dequant (
    input  wire        clk,
    input  wire        rst_n,

    // Configuration
    input  wire        mode,        // 0 = INT4 (packed nibbles), 1 = INT8

    // Weight input (INT4 packed or INT8)
    input  wire [7:0]  weight_in,   // INT4: {hi[3:0], lo[3:0]}; INT8: full byte
    input  wire        nibble_sel,  // for INT4: 0=low nibble, 1=high nibble
    input  wire        valid_in,

    // BF16 output
    output reg  [15:0] bf16_out,
    output reg         valid_out
);

    // =========================================================================
    // INT4/INT8 extraction
    // =========================================================================
    wire signed [7:0] weight_raw = mode ?
        weight_in :  // INT8: full byte
        (nibble_sel ? {{4{weight_in[7]}}, weight_in[7:4]} :
                      {{4{weight_in[3]}}, weight_in[3:0]});  // INT4: sign-extended

    // =========================================================================
    // Combinational: Extract sign and absolute value
    // =========================================================================
    wire weight_sign = weight_raw[7];
    wire [7:0] weight_abs = weight_raw[7] ? -weight_raw : weight_raw;

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
    // Pipeline Stage 1: Register BF16 result
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bf16_out  <= 16'h0;
            valid_out <= 1'b0;
        end else begin
            if (weight_abs == 0) begin
                bf16_out <= {weight_sign, 8'd0, 7'd0};  // zero
            end else begin
                bf16_out <= {weight_sign, bf16_exp, norm_mantissa[6:0]};
            end
            valid_out <= valid_in;
        end
    end

endmodule
