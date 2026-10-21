`timescale 1ns/1ps

// =============================================================================
// quant_mac_array — parameterized quantized systolic MAC array.
//
// One weight-stationary systolic array shell for the four quantized compute
// units; the CU parameter selects the PE datapath:
//
//   CU = 4  (CU_INT8_MAC)  INT8 MAC      -- int4_mac_array.v
//   CU = 6  (CU_FP4_MAC)   FP4 (E2M1)    -- fp4_mac_array.v
//   CU = 7  (CU_MXFP4)     FP4 + a shared per-row block scale
//                                       -- mxfp4_mac_array.v
//   CU = 11 (CU_TERNARY)   ternary select-add (BitNet b1.58)
//                                       -- ternary_acc_array.v
//
// The four were previously four copies of this shell, differing only in the
// PE they instantiated and (for MXFP4) the per-row scale.  The float family
// was already folded the same way (fp_mac_array.v with bf16_mac_array.v and
// fp16_mac_array.v as wrappers), and the scalar family is folded into
// arith_unit.v -- so this brings the quantized family in line with the
// pattern the rest of the library already follows.
//
// Each PE is an arith_unit with the corresponding CU, which is the same
// datapath the standalone int8_mac / fp4_mac / ternary_acc modules wrap, so
// the numerics are unchanged.
//
// Architecture (unchanged from the four originals):
//   - ARRAY_SIZE × ARRAY_SIZE grid of Processing Elements (PEs)
//   - Input activations broadcast to each row (one 8-bit value per row)
//   - Weight values are pre-loaded and stationary (weight-stationary dataflow)
//   - Partial sums flow downward, accumulating across rows
//   - Output results emerge at the bottom after the pipeline drains
//
// Vertical accumulation is time-staggered.  Each MAC computes
//   result = a*b + c   where c is the accumulated partial sum from the rows
//   above (0 for row 0).  Row r+1 only fires once the partial sum produced by
//   row r has settled into its output pipeline stage.  The activation for
//   each row is latched into a stable register on the feed cycle so it
//   remains valid for however long that row waits for its upstream partial
//   sum.
// =============================================================================

module quant_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2,           // PE pipeline stages
    parameter CU = 4                    // 4 = INT8, 6 = FP4, 7 = MXFP4, 11 = ternary
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

    // -- Block scale input (MXFP4's shared per-row exponent) --------------
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

    // Per-row block scale (MXFP4): clamped to [0..15] so it doubles as the
    // weight shift.  Unused by the other CUs.
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
    // Partial-sum pipeline registers indexed by [row][col][stage].
    // psum_sr[row][col][PIPE_DEPTH-1] holds the accumulated dot-product
    // through rows 0..row and feeds the row-below MAC's c input.
    // =========================================================================
    reg [31:0] psum_sr  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];

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
    wire [63:0] mac_result64  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

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

                // The PE is an arith_unit with the selected CU: the same
                // datapath the standalone int8_mac / fp4_mac / ternary_acc
                // modules wrap, so the numerics are unchanged.
                arith_unit #(.CU(CU)) u_mac (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         ({56'h0, act_hold[row]}),
                    .b         ({56'h0, weights[row][col]}),
                    .c         ({32'h0, psum_from_top}),
                    .op        (3'd0),
                    .pack_select(1'b0),
                    .b_pack_select(1'b0),
                    .wshift    ((CU == 7) ? scale[row] : 4'd0),
                    .valid_in  (fire),
                    .result    (mac_result64[row][col]),
                    .valid_out (mac_valid_out[row][col]),
                    .busy      ()
                );
                assign mac_result[row][col] = mac_result64[row][col][31:0];
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
