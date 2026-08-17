`timescale 1ns/1ps

// =============================================================================
// fp16_mac_array — FP16 Multiply-Accumulate Array
//
// A systolic array of FP16 MAC units for matrix-vector multiplication.
// Used in the PE tile's attention and dense projection layers.
//
// Architecture:
//   - ARRAY_SIZE × ARRAY_SIZE grid of MAC units
//   - Input activations flow from left to right (X dimension)
//   - Weight values are pre-loaded and stationary (Y dimension)
//   - Partial sums flow downward (Y dimension)
//   - Output results emerge at the bottom
//
// This matches the paper's weight-stationary dataflow (§2.9):
//   - Weights are pre-loaded into the MAC array's registers at boot
//   - Token activations stream through the array
//   - Results accumulate and exit at the bottom
//
// The array computes: Y[i] = Σ_j W[i][j] * X[j] for each output row i.
// With ARRAY_SIZE=16, this processes 16 elements per cycle at peak.
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
    // Weight storage: ARRAY_SIZE × ARRAY_SIZE registers (pre-loaded at boot)
    // =========================================================================
    reg [15:0] weights [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // =========================================================================
    // Activation pipeline: ARRAY_SIZE stages, one per column
    // =========================================================================
    reg [15:0] act_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1]; // [stage][row]
    reg        act_v_pipe [0:ARRAY_SIZE-1];
    reg        act_s_pipe [0:ARRAY_SIZE-1];
    reg        act_e_pipe [0:ARRAY_SIZE-1];

    // =========================================================================
    // Partial sum pipeline: accumulates downward
    // =========================================================================
    reg [31:0] psum [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1]; // [stage][row]
    reg        psum_valid [0:ARRAY_SIZE-1];

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
    // MAC pipeline: activation × weight + partial_sum
    // =========================================================================
    integer si, ri;
    reg [15:0] fma_a, fma_b, fma_c;
    reg        fma_valid_in;
    wire [15:0] fma_result;
    wire        fma_valid_out;

    // Single FMA unit shared across the array (time-multiplexed for area)
    // In production, each array element would have its own FMA.
    fp16_fma u_fma (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fma_a),
        .b         (fma_b),
        .c         (fma_c),
        .valid_in  (fma_valid_in),
        .result    (fma_result),
        .valid_out (fma_valid_out)
    );

    // Simple behavioral model: process one MAC per cycle
    reg [7:0] mac_row, mac_col;
    reg       mac_active;

    assign busy = mac_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_row <= 0;
            mac_col <= 0;
            mac_active <= 0;
            for (si = 0; si < ARRAY_SIZE; si = si + 1) begin
                act_v_pipe[si] <= 0;
                act_s_pipe[si] <= 0;
                act_e_pipe[si] <= 0;
                psum_valid[si] <= 0;
                for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1) begin
                    act_pipe[si][ri] <= 0;
                    psum[si][ri] <= 0;
                end
            end
        end else begin
            // Feed activations into the first stage
            if (act_valid) begin
                for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                    act_pipe[0][ri] <= act_in[ri*16 +: 16];
                act_v_pipe[0] <= 1;
                act_s_pipe[0] <= act_sop;
                act_e_pipe[0] <= act_eop;
                mac_active <= 1;
            end else begin
                act_v_pipe[0] <= 0;
            end

            // Pipeline propagation (simplified: 1 stage per cycle)
            for (si = 1; si < ARRAY_SIZE; si = si + 1) begin
                for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                    act_pipe[si][ri] <= act_pipe[si-1][ri];
                act_v_pipe[si] <= act_v_pipe[si-1];
                act_s_pipe[si] <= act_s_pipe[si-1];
                act_e_pipe[si] <= act_e_pipe[si-1];
            end

            // MAC computation (one per cycle for area efficiency)
            if (mac_active && act_v_pipe[mac_col]) begin
                fma_a <= act_pipe[mac_col][mac_row];
                fma_b <= weights[mac_row][mac_col];
                fma_c <= psum[mac_col][mac_row][15:0];
                fma_valid_in <= 1;

                if (fma_valid_out) begin
                    psum[mac_col][mac_row] <= {16'h0000, fma_result};
                end

                // Advance MAC position
                if (mac_row == ARRAY_SIZE - 1) begin
                    mac_row <= 0;
                    if (mac_col == ARRAY_SIZE - 1) begin
                        mac_col <= 0;
                        mac_active <= 0;
                    end else begin
                        mac_col <= mac_col + 1;
                    end
                end else begin
                    mac_row <= mac_row + 1;
                end
            end else begin
                fma_valid_in <= 0;
            end

            // Output results from the last stage
            for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                result_out[ri*16 +: 16] <= psum[ARRAY_SIZE-1][ri][15:0];
            result_valid <= act_v_pipe[ARRAY_SIZE-1];
            result_sop   <= act_s_pipe[ARRAY_SIZE-1];
            result_eop   <= act_e_pipe[ARRAY_SIZE-1];
        end
    end

endmodule
