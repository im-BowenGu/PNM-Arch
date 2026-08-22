`timescale 1ns/1ps

module fp32_mac_array #(
    parameter ARRAY_SIZE = 8,
    parameter PIPE_DEPTH = 4
)(
    input  wire clk,
    input  wire rst_n,

    input  wire [ARRAY_SIZE*32-1:0] act_in,
    input  wire act_valid,
    input  wire act_sop,
    input  wire act_eop,

    input  wire weight_load,
    input  wire [7:0] weight_row,
    input  wire [7:0] weight_col,
    input  wire [31:0] weight_data,

    output reg  [ARRAY_SIZE*32-1:0] result_out,
    output reg  result_valid,
    output reg  result_sop,
    output reg  result_eop,
    output wire busy
);

    reg [31:0] weights [0:ARRAY_SIZE*ARRAY_SIZE-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin : winit
            integer wi;
            for (wi = 0; wi < ARRAY_SIZE*ARRAY_SIZE; wi = wi + 1)
                weights[wi] <= 32'h00000000;
        end else if (weight_load) begin
            weights[weight_row * ARRAY_SIZE + weight_col] <= weight_data;
        end
    end

    wire [31:0] fma_result  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire        fma_valid_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    reg [31:0] act_sr  [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        act_v_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg [31:0] psum_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];
    reg        psum_v_sr [0:ARRAY_SIZE*ARRAY_SIZE-1][0:PIPE_DEPTH-1];

    reg [7:0] row_delay_cnt [0:ARRAY_SIZE-1];
    reg       row_armed [0:ARRAY_SIZE-1];

    integer r, c, s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < ARRAY_SIZE*ARRAY_SIZE; r = r + 1) begin
                for (s = 0; s < PIPE_DEPTH; s = s + 1) begin
                    act_sr[r][s]   <= 32'h00000000;
                    act_v_sr[r][s] <= 1'b0;
                    psum_sr[r][s]  <= 32'h00000000;
                    psum_v_sr[r][s] <= 1'b0;
                end
            end
            for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                row_delay_cnt[r] <= 0;
                row_armed[r] <= 0;
            end
        end else begin
            if (act_valid) begin
                for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                    row_delay_cnt[r] <= 0;
                    row_armed[r] <= (r == 0) ? 1'b1 : 1'b0;
                end
            end else begin
                for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                    if (!row_armed[r] && row_delay_cnt[r] < r * PIPE_DEPTH) begin
                        row_delay_cnt[r] <= row_delay_cnt[r] + 1;
                        if (row_delay_cnt[r] + 1 == r * PIPE_DEPTH)
                            row_armed[r] <= 1'b1;
                    end
                end
            end

            for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                for (c = 0; c < ARRAY_SIZE; c = c + 1) begin
                    if (c == 0) begin
                        act_sr[r*ARRAY_SIZE][0]   <= act_in[r*32 +: 32];
                        act_v_sr[r*ARRAY_SIZE][0] <= row_armed[r];
                        if (r == 0) begin
                            psum_sr[0][0]   <= 32'h00000000;
                            psum_v_sr[0][0] <= row_armed[0];
                        end else begin
                            psum_sr[r*ARRAY_SIZE][0]   <= fma_result[r-1][0];
                            psum_v_sr[r*ARRAY_SIZE][0] <= fma_valid_out[r-1][0];
                        end
                    end else begin
                        act_sr[r*ARRAY_SIZE+c][0]   <= act_sr[r*ARRAY_SIZE+c-1][PIPE_DEPTH-1];
                        act_v_sr[r*ARRAY_SIZE+c][0] <= act_v_sr[r*ARRAY_SIZE+c-1][PIPE_DEPTH-1];
                        if (r == 0) begin
                            psum_sr[c][0]   <= 32'h00000000;
                            psum_v_sr[c][0] <= act_v_sr[r*ARRAY_SIZE+c][0];
                        end else begin
                            psum_sr[r*ARRAY_SIZE+c][0]   <= fma_result[r-1][c];
                            psum_v_sr[r*ARRAY_SIZE+c][0] <= fma_valid_out[r-1][c];
                        end
                    end

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

    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : mac_rows
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : mac_cols

                wire fma_valid_in;
                if (row == 0)
                    assign fma_valid_in = act_v_sr[col][PIPE_DEPTH-1];
                else
                    assign fma_valid_in = psum_v_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1];

                fp32_fma u_fma (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .a         (act_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1]),
                    .b         (weights[row * ARRAY_SIZE + col]),
                    .c         (psum_sr[row * ARRAY_SIZE + col][PIPE_DEPTH-1]),
                    .valid_in  (fma_valid_in),
                    .result    (fma_result[row][col]),
                    .valid_out (fma_valid_out[row][col])
                );
            end
        end
    endgenerate

    reg [7:0] out_pipe_cnt;
    reg       out_active;
    reg       out_sop_q, out_eop_q;
    reg       out_valid_reg;
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
            out_valid_reg <= 0;
            result_out <= 0;
        end else begin
            if (act_valid) begin
                out_active <= 1;
                out_pipe_cnt <= 0;
                out_sop_q <= act_sop;
                out_eop_q <= act_eop;
                out_valid_reg <= 0;
            end

            if (out_active) begin
                out_pipe_cnt <= out_pipe_cnt + 1;

                if (fma_valid_out[ARRAY_SIZE-1][ARRAY_SIZE-1]) begin
                    for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                        result_out[ri*32 +: 32] <= fma_result[ARRAY_SIZE-1][ri];
                    result_valid <= 1;
                    result_sop <= out_sop_q;
                    result_eop <= out_eop_q;
                    out_active <= 0;
                end
            end else begin
                result_valid <= 0;
            end
        end
    end

endmodule
