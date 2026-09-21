`timescale 1ns/1ps

// =============================================================================
// mxfp4_mac_array — MXFP4 (OCP Microscaling E2M1) Systolic MAC Array
//
// Same weight-stationary systolic structure as fp4_mac_array.v, but each row
// of weights carries an 8-bit shared block scale (OCP Microscaling): all
// weights in a 32-element block are dequantized by the same 2^scale factor
// before the multiply-accumulate.  This recovers dynamic range that 4-bit
// FP4 alone cannot represent, at the cost of one shared exponent per block.
//
// Per-row scale: scale[row] is loaded from scale_in/scale_load using
// weight_row as the row index.  Each fp4_mac in that row receives
// wshift = scale[row], which lifts its weight dequant by 2^scale before the
// multiply, so a single accumulator value = sum(d8a * (d8b << scale))/64.
//
// Dot-product scale convention: physical result = result_out / 64.
// =============================================================================

module mxfp4_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // fp4_mac pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (packed FP4, two per byte per row) ---------------
    input  wire [ARRAY_SIZE*8-1:0] act_in,     // activation vector (2xFP4 each)
    input  wire                    act_valid,
    input  wire                    act_sop,
    input  wire                    act_eop,

    // -- Weight input (pre-loaded, stationary, packed FP4) -----------------
    input  wire [7:0]              weight_in,  // packed FP4 weight byte
    input  wire                    weight_load,
    input  wire [7:0]              weight_row,
    input  wire [7:0]              weight_col,

    // -- Block scale input (MXFP4 shared per-row exponent) -----------------
    input  wire [7:0]              scale_in,   // raw 8-bit scale
    input  wire                    scale_load, // load scale[row] from scale_in

    // -- Result output (emerges at bottom) ---------------------------------
    output reg  [ARRAY_SIZE*32-1:0] result_out, // result vector (32b each)
    output reg                      result_valid,
    output reg                      result_sop,
    output reg                      result_eop,

    // -- Status ------------------------------------------------------------
    output wire                     busy
);

    // =========================================================================
    // Weight storage
    // =========================================================================
    reg [7:0] weights [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    integer wr, wc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wr = 0; wr < ARRAY_SIZE; wr = wr + 1)
                for (wc = 0; wc < ARRAY_SIZE; wc = wc + 1)
                    weights[wr][wc] <= 8'd0;
        end else if (weight_load) begin
            weights[weight_row[3:0]][weight_col[3:0]] <= weight_in;
        end
    end

    // =========================================================================
    // Per-row block scale (MXFP4): clamped to [0..15] so it doubles as the
    // fp4_mac wshift width; the low nibble of the loaded byte is the shift.
    // =========================================================================
    reg [3:0] scale [0:ARRAY_SIZE-1];
    integer sr_;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (sr_ = 0; sr_ < ARRAY_SIZE; sr_ = sr_ + 1)
                scale[sr_] <= 4'd0;
        end else if (scale_load) begin
            scale[weight_row[3:0]] <= scale_in[3:0];
        end
    end

    // =========================================================================
    // Per-row activation hold: latched once on the feed cycle, kept stable.
    // =========================================================================
    reg [7:0] act_hold [0:ARRAY_SIZE-1];
    reg       act_valid_q;
    reg       fed;
    integer ha;
    // Arming: one feed in flight at a time; a refeed while the previous vector
    // is still propagating is ignored (host must wait for busy), matching the
    // fp16/bf16/fp32 arrays' !out_active accept gating.
    wire accept = act_valid && !fed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_valid_q <= 1'b0;
            fed <= 1'b0;
            for (ha = 0; ha < ARRAY_SIZE; ha = ha + 1)
                act_hold[ha] <= 8'd0;
        end else begin
            act_valid_q <= accept;
            if (accept) begin
                fed <= 1'b1;
                for (ha = 0; ha < ARRAY_SIZE; ha = ha + 1)
                    act_hold[ha] <= act_in[ha*8 +: 8];
            end
            if (psum_v_sr[ARRAY_SIZE-1][ARRAY_SIZE-1][PIPE_DEPTH-1])
                fed <= 1'b0;
        end
    end

    // =========================================================================
    // MAC results and validity from each PE
    // =========================================================================
    wire [31:0] mac_result    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire        mac_valid_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // =========================================================================
    // Partial-sum pipeline registers
    // =========================================================================
    reg [31:0] psum_sr  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    // =========================================================================
    // PE grid — each PE consumes the low nibble plane of its activation and
    // weight, and the block scale of its row.
    // =========================================================================
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_row
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_col
                wire [31:0] psum_from_top;
                if (row == 0) begin : top_row
                    assign psum_from_top = 32'd0;
                end else begin : inner_row
                    assign psum_from_top = psum_sr[row-1][col][PIPE_DEPTH-1];
                end

                wire fire;
                if (row == 0) begin : fire_row0
                    assign fire = act_valid_q;
                end else begin : fire_other
                    assign fire = psum_v_sr[row-1][col][PIPE_DEPTH-1];
                end

                fp4_mac u_mac (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         (act_hold[row]),
                    .pack_select(1'b0),        // low nibble plane
                    .b         (weights[row][col]),
                    .b_pack_select(1'b0),
                    .c         (psum_from_top),
                    .wshift    (scale[row]),
                    .valid_in  (fire),
                    .result    (mac_result[row][col]),
                    .valid_out (mac_valid_out[row][col])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Partial-sum pipeline
    // =========================================================================
    integer i, j, s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1)
                for (j = 0; j < ARRAY_SIZE; j = j + 1)
                    for (s = 0; s < PIPE_DEPTH; s = s + 1) begin
                        psum_sr[i][j][s]   <= 32'd0;
                        psum_v_sr[i][j][s] <= 1'b0;
                    end
        end else begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1)
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    if (mac_valid_out[i][j]) begin
                        psum_sr[i][j][0]   <= mac_result[i][j];
                        psum_v_sr[i][j][0] <= 1'b1;
                    end else begin
                        psum_v_sr[i][j][0] <= 1'b0;
                    end
                    for (s = 1; s < PIPE_DEPTH; s = s + 1) begin
                        psum_sr[i][j][s]   <= psum_sr[i][j][s-1];
                        psum_v_sr[i][j][s] <= psum_v_sr[i][j][s-1];
                    end
                end
        end
    end

    // =========================================================================
    // Output: collect results from bottom row (last pipeline stage)
    // =========================================================================
    reg out_sop_q, out_eop_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_out   <= {(ARRAY_SIZE*32){1'b0}};
            result_valid <= 1'b0;
            result_sop   <= 1'b0;
            result_eop   <= 1'b0;
            out_sop_q    <= 1'b0;
            out_eop_q    <= 1'b0;
        end else begin
            if (accept) begin
                out_sop_q <= act_sop;
                out_eop_q <= act_eop;
            end
            if (psum_v_sr[ARRAY_SIZE-1][ARRAY_SIZE-1][PIPE_DEPTH-1]) begin
                result_valid <= 1'b1;
                result_sop   <= out_sop_q;
                result_eop   <= out_eop_q;
            end else begin
                result_valid <= 1'b0;
                result_sop   <= 1'b0;
                result_eop   <= 1'b0;
            end
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                result_out[i*32 +: 32] <= psum_sr[ARRAY_SIZE-1][i][PIPE_DEPTH-1];
            end
        end
    end

    assign busy = fed;

endmodule
