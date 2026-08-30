`timescale 1ns/1ps

// =============================================================================
// fp4_mac_array — FP4 (E2M1) Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of FP4 (E2M1) MAC units, providing 4x
// packing density vs BF16, the same as INT4 (paper §2.9).  Two FP4 values pack
// per byte on both the activation and weight lanes; each PE dequantizes its
// nibble to fixed point and accumulates to INT32 (see fp4_mac.v).
//
// Architecture is identical to int4_mac_array.v: ARRAY_SIZE × ARRAY_SIZE
// grid, weight-stationary, vertical time-staggered accumulation with the
// row-below firing only on a settled partial sum (the fix that makes the
// earlier unconditional-capture accumulation bug impossible).
//
// Dot-product scale convention: each fp4_mac emits sum(d8a * d8b) over its
// column; the physical dot product is result_out / 64.
// =============================================================================

module fp4_mac_array #(
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
    // Per-row activation hold: latched once on the feed cycle, kept stable.
    // Row 0 fires one cycle after the feed (act_valid_q) so its activation hold
    // has settled before sampling.
    // =========================================================================
    reg [7:0] act_hold [0:ARRAY_SIZE-1];
    reg       act_valid_q;
    integer ha;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_valid_q <= 1'b0;
            for (ha = 0; ha < ARRAY_SIZE; ha = ha + 1)
                act_hold[ha] <= 8'd0;
        end else begin
            act_valid_q <= act_valid;
            if (act_valid) begin
                for (ha = 0; ha < ARRAY_SIZE; ha = ha + 1)
                    act_hold[ha] <= act_in[ha*8 +: 8];
            end
        end
    end

    // =========================================================================
    // MAC results and validity from each PE
    // =========================================================================
    wire [31:0] mac_result    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire        mac_valid_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // =========================================================================
    // Partial-sum pipeline registers indexed by [row][col][stage].
    // =========================================================================
    reg [31:0] psum_sr  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    // =========================================================================
    // PE grid — each PE consumes the low nibble of its activation and weight
    // (a single FP4 column plane).  Byte pairs are the array's addressable
    // granularity; nibble selection is a transport-time concern (see the
    // pe_tile_stub / host driver packing), so here one column plane is
    // computed per pass.
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
                    .wshift    (4'd0),         // plain FP4: no block scale
                    .valid_in  (fire),
                    .result    (mac_result[row][col]),
                    .valid_out (mac_valid_out[row][col])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Partial-sum pipeline: capture each row's MAC result only when valid.
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
            if (act_valid) begin
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

    assign busy = act_valid;

endmodule
