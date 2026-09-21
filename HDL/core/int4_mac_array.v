`timescale 1ns/1ps

// =============================================================================
// int4_mac_array — INT4 Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of INT8 MAC units operating on INT4
// packed activations, providing 4x packing density vs BF16 (paper §2.9).
//
// Architecture:
//   - ARRAY_SIZE × ARRAY_SIZE grid of Processing Elements (PEs)
//   - Each PE instantiates one int8_mac unit with local weight register
//   - Input activations broadcast to each row (one INT8 value per row)
//   - Weight values are pre-loaded and stationary (weight-stationary dataflow)
//   - Partial sums flow downward, accumulating across rows
//   - Output results emerge at the bottom after the pipeline drains
//
// This matches the paper's INT4 quantized inference path:
//   - Weights stored as INT4 in LPDDR6, dequantized to INT8 at the MAC boundary
//   - Activations quantized dynamically via dyn_act_quant.v
//   - 4x packing: 2 INT4 activations per BF16-equivalent byte
//
// Vertical accumulation is time-staggered. Each MAC computes
//   result = a*b + c   where c is the accumulated partial sum from the rows
//   above (0 for row 0). Row r+1 is only allowed to fire (valid_in asserts)
//   once the partial sum produced by row r has settled into its output
//   pipeline stage (psum_v_sr[r][col][PIPE_DEPTH-1]). Row 0 fires from the
//   external act_valid. This gating is essential: capturing mac_result
//   unconditionally on every cycle (the earlier bug) let stale results and
//   mis-timed accumulates produce all-zero outputs. The activation for each
//   row is latched into a stable register on the feed cycle so it remains
//   valid for however long that row waits for its upstream partial sum.
// =============================================================================

module int4_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // int8_mac pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (INT8, one value per row) ------------------------
    input  wire [ARRAY_SIZE*8-1:0] act_in,     // activation vector (8b each)
    input  wire                    act_valid,
    input  wire                    act_sop,
    input  wire                    act_eop,

    // -- Weight input (pre-loaded, stationary) -----------------------------
    input  wire [7:0]              weight_in,  // INT8 weight value
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
    // Per-row activation hold: latched once on the feed cycle, kept stable so
    // a row's MAC can sample its own activation whenever its upstream partial
    // sum has settled (rows fire at progressively later times). The row-0 fire
    // is delayed one cycle (act_valid_q) so act_hold has settled before row 0's
    // MAC samples its `a` operand.
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
    // Partial-sum pipeline registers indexed by [row][col][stage].
    // psum_sr[row][col][PIPE_DEPTH-1] holds the accumulated dot-product
    // through rows 0..row and feeds the row-below MAC's c input.
    // =========================================================================
    reg [31:0] psum_sr  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    // =========================================================================
    // PE grid
    // =========================================================================
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_row
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_col
                // Partial sum from above: zero for row 0, else row above's
                // settled accumulator output.
                wire [31:0] psum_from_top;
                if (row == 0) begin : top_row
                    assign psum_from_top = 32'd0;
                end else begin : inner_row
                    assign psum_from_top = psum_sr[row-1][col][PIPE_DEPTH-1];
                end

                // Row 0 fires from the external feed; rows below fire when
                // their upstream accumulated partial sum has settled.
                wire fire;
                if (row == 0) begin : fire_row0
                    assign fire = act_valid_q;
                end else begin : fire_other
                    assign fire = psum_v_sr[row-1][col][PIPE_DEPTH-1];
                end

                int8_mac u_mac (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         (act_hold[row]),
                    .b         (weights[row][col]),
                    .c         (psum_from_top),
                    .valid_in  (fire),
                    .result    (mac_result[row][col]),
                    .valid_out (mac_valid_out[row][col])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Partial-sum pipeline: capture each row's MAC result only when that MAC
    // signals a valid output; otherwise hold the previous accumulation.
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
                    // Stage 0: capture this row's MAC output only when valid.
                    // The valid is a one-shot pulse, not a sticky level: it
                    // must clear the cycle the MAC is idle, or it latches high
                    // forever, keeping result_valid asserted and re-firing the
                    // lower rows on stale partial sums for subsequent vectors.
                    if (mac_valid_out[i][j]) begin
                        psum_sr[i][j][0]   <= mac_result[i][j];
                        psum_v_sr[i][j][0] <= 1'b1;
                    end else begin
                        psum_v_sr[i][j][0] <= 1'b0;
                    end

                    // Stages 1..PIPE_DEPTH-1: simple shift
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
    // sop/eop must be queued at feed time and presented with the result, not
    // sampled from the live act_sop/act_eop on the (much later) result cycle.
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
            // The bottom-right psum valid pulse marks the result cycle. Present
            // the queued sop/eop alongside result_valid.
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
