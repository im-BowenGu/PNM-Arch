`timescale 1ns/1ps

// =============================================================================
// fp16_mac_array — FP16 Systolic Multiply-Accumulate Array
//
// A weight-stationary systolic array of FP16 MAC units for matrix-vector
// multiplication, matching Google TPU architecture (paper §2.9).
//
// Architecture:
//   - ARRAY_SIZE × ARRAY_SIZE grid of Processing Elements (PEs)
//   - Each PE instantiates one fp16_fma unit with local weight register
//   - Input activations flow left-to-right with 1-cycle skew per column
//   - Weight values are pre-loaded and stationary (weight-stationary dataflow)
//   - Partial sums flow downward, accumulating across rows
//   - Output results emerge at the bottom after ARRAY_SIZE * PIPE_DEPTH cycles
//
// Pipeline timing:
//   - Each PE has PIPE_DEPTH-stage pipelines for activation and partial sum
//   - The FMA inside each PE takes PIPE_DEPTH cycles to produce output
//   - Between PEs, pipeline registers ensure correct timing
//   - Total array latency: ARRAY_SIZE * PIPE_DEPTH cycles
//
// This matches the paper's weight-stationary dataflow (§2.9):
//   - Weights are pre-loaded into the MAC array's registers at boot
//   - Token activations stream through the array
//   - Results accumulate and exit at the bottom
//
// The array computes: Y[i] = Σ_j W[i][j] * X[j] for each output row i.
// =============================================================================

module fp16_mac_array #(
    parameter ARRAY_SIZE = 16,          // MAC units per dimension
    parameter PIPE_DEPTH = 3            // FMA pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (flows left to right) -------------------------
    input  wire [ARRAY_SIZE*16-1:0] act_in,    // activation vector (16b each)
    input  wire                     act_valid,
    input  wire                     act_sop,    // start of output row
    input  wire                     act_eop,    // end of output row

    // -- Weight input (pre-loaded, stationary) --------------------------
    input  wire [15:0]              weight_in,  // weight value to load
    input  wire                     weight_load, // load weight into array
    input  wire [7:0]               weight_row,  // row to load into
    input  wire [7:0]               weight_col,  // column to load into

    // -- Result output (emerges at bottom) ------------------------------
    output reg  [ARRAY_SIZE*16-1:0] result_out, // result vector (16b each)
    output reg                      result_valid,
    output reg                      result_sop,
    output reg                      result_eop,

    // -- Status ---------------------------------------------------------
    output wire                     busy         // array is computing
);

    // =========================================================================
    // Weight storage
    // =========================================================================
    reg [15:0] weights [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // =========================================================================
    // Internal wires: FMA results and valid signals from each PE
    // =========================================================================
    wire [15:0] fma_result  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire        fma_valid_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Activation and partial sum pipeline registers (flattened for Verilog-2005)
    // Indexed as [row * ARRAY_SIZE + col][stage]
    reg [15:0] act_sr  [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        act_v_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg [15:0] psum_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    // =========================================================================
    // Weight loading
    // =========================================================================
    integer wi, wj;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < ARRAY_SIZE; wi = wi + 1)
                for (wj = 0; wj < ARRAY_SIZE; wj = wj + 1)
                    weights[wi][wj] <= 16'h0000;
        end else if (weight_load) begin
            weights[weight_row][weight_col] <= weight_in;
        end
    end

    // =========================================================================
    // Pipeline logic: handle activation routing and partial sum accumulation
    // =========================================================================
    integer r, c, s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < ARRAY_SIZE*ARRAY_SIZE; r = r + 1) begin
                for (s = 0; s < PIPE_DEPTH; s = s + 1) begin
                    act_sr[r][s]   <= 16'h0000;
                    act_v_sr[r][s] <= 1'b0;
                    psum_sr[r][s]  <= 16'h0000;
                    psum_v_sr[r][s] <= 1'b0;
                end
            end
        end else begin
            for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                for (c = 0; c < ARRAY_SIZE; c = c + 1) begin
                    // -- Stage 0: capture input --
                    if (c == 0) begin
                        // Column 0: get activation from external input
                        act_sr[r*ARRAY_SIZE][0]   <= act_in[r*16 +: 16];
                        act_v_sr[r*ARRAY_SIZE][0] <= act_valid;
                        // Partial sum input: zero for row 0, from row above for row > 0
                        if (r == 0) begin
                            psum_sr[0][0]  <= 16'h0000;
                            psum_v_sr[0][0] <= act_valid;
                        end else begin
                            psum_sr[r*ARRAY_SIZE][0]  <= fma_result[r-1][0];
                            psum_v_sr[r*ARRAY_SIZE][0] <= fma_valid_out[r-1][0];
                        end
                    end else begin
                        // Columns 1..ARRAY_SIZE-1: get from left neighbor
                        act_sr[r*ARRAY_SIZE+c][0]   <= act_sr[r*ARRAY_SIZE+c-1][PIPE_DEPTH-1];
                        act_v_sr[r*ARRAY_SIZE+c][0] <= act_v_sr[r*ARRAY_SIZE+c-1][PIPE_DEPTH-1];
                        // Partial sum: from row above (same column)
                        if (r == 0) begin
                            psum_sr[c][0]  <= 16'h0000;
                            psum_v_sr[c][0] <= act_v_sr[r*ARRAY_SIZE+c][0];
                        end else begin
                            psum_sr[r*ARRAY_SIZE+c][0]  <= fma_result[r-1][c];
                            psum_v_sr[r*ARRAY_SIZE+c][0] <= fma_valid_out[r-1][c];
                        end
                    end

                    // -- Stages 1..PIPE_DEPTH-1: shift pipeline --
                    for (s = 1; s < PIPE_DEPTH; s = s + 1) begin
                        act_sr[r*ARRAY_SIZE+c][s]   <= act_sr[r*ARRAY_SIZE+c][s-1];
                        act_v_sr[r*ARRAY_SIZE+c][s]  <= act_v_sr[r*ARRAY_SIZE+c][s-1];
                        psum_sr[r*ARRAY_SIZE+c][s]  <= psum_sr[r*ARRAY_SIZE+c][s-1];
                        psum_v_sr[r*ARRAY_SIZE+c][s] <= psum_v_sr[r*ARRAY_SIZE+c][s-1];
                    end
                end
            end
        end
    end

    // =========================================================================
    // FMA instantiation: ARRAY_SIZE × ARRAY_SIZE units
    // =========================================================================
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : mac_rows
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : mac_cols

                fp16_fma u_fma (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         (act_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1]),
                    .b         (weights[row][col]),
                    .c         (psum_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1]),
                    .valid_in  (act_v_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1]),
                    .result    (fma_result[row][col]),
                    .valid_out (fma_valid_out[row][col])
                );

            end
        end
    endgenerate

    // =========================================================================
    // Output collection: bottom row results after pipeline fill
    // =========================================================================
    reg [7:0] out_pipe_cnt;
    reg       out_active;
    reg       out_sop_q, out_eop_q;
    integer ri;

    assign busy = out_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pipe_cnt <= 0;
            out_active <= 0;
            result_valid <= 0;
            result_sop <= 0;
            result_eop <= 0;
            out_sop_q <= 0;
            out_eop_q <= 0;
            for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                result_out[ri*16 +: 16] <= 16'h0000;
        end else begin
            if (act_valid) begin
                out_active <= 1;
                out_pipe_cnt <= 0;
                out_sop_q <= act_sop;
                out_eop_q <= act_eop;
            end

            if (out_active) begin
                out_pipe_cnt <= out_pipe_cnt + 1;

                // Collect results from bottom row after pipeline fill
                if (out_pipe_cnt >= ARRAY_SIZE * PIPE_DEPTH - 1) begin
                    for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                        result_out[ri*16 +: 16] <= fma_result[ARRAY_SIZE-1][ri];
                    result_valid <= fma_valid_out[ARRAY_SIZE-1][0];
                    result_sop <= out_sop_q;
                    result_eop <= out_eop_q;
                end

                if (out_pipe_cnt == ARRAY_SIZE * PIPE_DEPTH + PIPE_DEPTH)
                    out_active <= 0;
            end else begin
                result_valid <= 0;
            end
        end
    end

endmodule
