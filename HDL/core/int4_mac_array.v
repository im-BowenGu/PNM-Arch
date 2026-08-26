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
//   - Input activations flow left-to-right with 1-cycle skew per column
//   - Weight values are pre-loaded and stationary (weight-stationary dataflow)
//   - Partial sums flow downward, accumulating across rows
//   - Output results emerge at the bottom after ARRAY_SIZE * PIPE_DEPTH cycles
//
// This matches the paper's INT4 quantized inference path:
//   - Weights stored as INT4 in LPDDR6, dequantized to INT8 at the MAC boundary
//   - Activations quantized dynamically via dyn_act_quant.v
//   - 4x packing: 2 INT4 activations per BF16-equivalent byte
// =============================================================================

module int4_mac_array #(
    parameter ARRAY_SIZE = 16,
    parameter PIPE_DEPTH = 2            // int8_mac pipeline stages
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Activation input (INT8, flows left to right) ----------------------
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
    // Pipeline registers (activation skew + partial sum flow)
    // Indexed by [row][col][stage]
    // =========================================================================
    reg [7:0]  act_sr   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        act_v_sr [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg [31:0] psum_sr  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    // =========================================================================
    // PE grid wires
    // =========================================================================
    wire [31:0] mac_result  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_row
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_col
                // Activation input: from left neighbor's last pipeline stage or external input
                wire [7:0] act_from_left;
                if (col == 0) begin : first_col
                    assign act_from_left = act_in[row*8 +: 8];
                end else begin : other_col
                    assign act_from_left = act_sr[row][col-1][PIPE_DEPTH-1];
                end

                // Partial sum input: from top neighbor or zero
                wire [31:0] psum_from_top;
                if (row == 0) begin : top_row
                    assign psum_from_top = 32'd0;
                end else begin : inner_row
                    assign psum_from_top = psum_sr[row-1][col][PIPE_DEPTH-1];
                end

                int8_mac u_mac (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         (act_from_left),
                    .b         (weights[row[3:0]][col[3:0]]),
                    .c         (psum_from_top),
                    .valid_in  (act_valid),
                    .result    (mac_result[row][col]),
                    .valid_out ()
                );
            end
        end
    endgenerate

    // =========================================================================
    // Pipeline registers
    // =========================================================================
    integer i, j, s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1)
                for (j = 0; j < ARRAY_SIZE; j = j + 1)
                    for (s = 0; s < PIPE_DEPTH; s = s + 1) begin
                        act_sr[i][j][s]    <= 8'd0;
                        act_v_sr[i][j][s]  <= 1'b0;
                        psum_sr[i][j][s]   <= 32'd0;
                        psum_v_sr[i][j][s] <= 1'b0;
                    end
        end else begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1)
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    // Stage 0: capture from left neighbor or input
                    if (j == 0) begin
                        act_sr[i][0][0]   <= act_in[i*8 +: 8];
                        act_v_sr[i][0][0] <= act_valid;
                        psum_sr[i][0][0]  <= 32'd0;
                        psum_v_sr[i][0][0]<= act_valid;
                    end else begin
                        act_sr[i][j][0]   <= act_sr[i][j-1][PIPE_DEPTH-1];
                        act_v_sr[i][j][0] <= act_v_sr[i][j-1][PIPE_DEPTH-1];
                        psum_sr[i][j][0]  <= mac_result[i][j];
                        psum_v_sr[i][j][0]<= act_valid;
                    end

                    // Stages 1..PIPE_DEPTH-1: simple shift
                    for (s = 1; s < PIPE_DEPTH; s = s + 1) begin
                        act_sr[i][j][s]    <= act_sr[i][j][s-1];
                        act_v_sr[i][j][s]  <= act_v_sr[i][j][s-1];
                        psum_sr[i][j][s]   <= psum_sr[i][j][s-1];
                        psum_v_sr[i][j][s] <= psum_v_sr[i][j][s-1];
                    end
                end
        end
    end

    // =========================================================================
    // Output: collect results from bottom row (last pipeline stage)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_out   <= {(ARRAY_SIZE*32){1'b0}};
            result_valid <= 1'b0;
            result_sop   <= 1'b0;
            result_eop   <= 1'b0;
        end else begin
            result_valid <= act_v_sr[ARRAY_SIZE-1][ARRAY_SIZE-1][PIPE_DEPTH-1];
            result_sop   <= act_sop;
            result_eop   <= act_eop;
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                result_out[i*32 +: 32] <= psum_sr[ARRAY_SIZE-1][i][PIPE_DEPTH-1];
            end
        end
    end

    assign busy = act_valid;

endmodule
