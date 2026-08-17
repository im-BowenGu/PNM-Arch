`timescale 1ns/1ps

// =============================================================================
// moe_gating — MoE Gating Network (Paper §2.8)
//
// Computes: logits = hidden_state × router_weights  (matrix-vector multiply)
// Then selects the top-K experts via a running-selection buffer.
//
// Architecture:
//   A single BF16 FMA unit processes one (expert, hidden_dim) MAC per cycle.
//   For each expert e:
//     acc = 0
//     for h = 0..HIDDEN_DIM-1:
//       acc += hidden[h] * weights[e][h]    (via bf16_fma, 3-cycle latency)
//     logit[e] = acc
//   Then: top-K selector finds the K largest logits.
//   Finally: coordinate lookup maps expert index → (layer, module_id).
//
// Throughput: HIDDEN_DIM cycles per expert, NUM_EXPERTS × HIDDEN_DIM total.
// For Gemma-4 (2816 hidden, 128 experts): ~360K cycles = ~360 us at 1 GHz.
//
// Weight loading:
//   weights[e][h] are loaded via the weight_load interface during boot.
//   Each weight is a BF16 (16-bit) value stored in on-chip SRAM.
// =============================================================================

module moe_gating #(
    parameter NUM_EXPERTS = 16,          // total experts per layer
    parameter HIDDEN_DIM  = 64,          // hidden dimension of gating projection
    parameter TOP_K       = 4,           // experts selected per token
    parameter ADDR_BITS   = 10           // log2(HIDDEN_DIM) max
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- Control -----------------------------------------------------------
    input  wire        start,            // begin gating computation
    output reg         done,             // top-K selection complete
    input  wire [7:0]  current_layer,    // model layer index (for coord lookup)

    // -- Hidden state read port (from token payload) ----------------------
    output reg  [ADDR_BITS-1:0] hidden_addr,
    input  wire [15:0] hidden_data,      // BF16 hidden[h]

    // -- Weight SRAM write port (loaded during boot) ----------------------
    input  wire        weight_load,
    input  wire [ADDR_BITS-1:0] weight_addr,  // linear index into weights[]
    input  wire [15:0] weight_data,      // BF16 weight value

    // -- MoE expert map (from router chip SRAM) ---------------------------
    input  wire [7:0]  moe_layer_in,     // physical layer for expert
    input  wire [7:0]  moe_module_in,    // module_id for expert

    // -- Top-K results (packed arrays for Verilog-2005) -------------------
    output reg  [TOP_K*8-1:0]   expert_idx_packed,   // {idx[K-1], ..., idx[0]}
    output reg  [TOP_K*16-1:0]  expert_logit_packed,  // {logit[K-1], ..., logit[0]}

    // -- FMA status -------------------------------------------------------
    output wire        fma_busy          // FMA unit is computing
);

    // =========================================================================
    // Weight SRAM: NUM_EXPERTS × HIDDEN_DIM entries, 16 bits each
    // =========================================================================
    reg [15:0] weights [0:NUM_EXPERTS*HIDDEN_DIM-1];

    // =========================================================================
    // Hidden state latch: captured at start
    // =========================================================================
    reg [15:0] hidden_latch [0:HIDDEN_DIM-1];

    // =========================================================================
    // Logit output buffer
    // =========================================================================
    reg [15:0] logits [0:NUM_EXPERTS-1];

    // =========================================================================
    // Top-K unpacked outputs (for internal use)
    // =========================================================================
    reg [7:0]  topk_idx  [0:TOP_K-1];
    reg [15:0] topk_logit [0:TOP_K-1];

    // Pack into output ports
    integer pi;
    always @(*) begin
        for (pi = 0; pi < TOP_K; pi = pi + 1) begin
            expert_idx_packed[pi*8 +: 8]   = topk_idx[pi];
            expert_logit_packed[pi*16 +: 16] = topk_logit[pi];
        end
    end

    // =========================================================================
    // Gating FSM
    // =========================================================================
    localparam G_IDLE       = 3'd0;
    localparam G_LOAD_HIDDEN= 3'd1;
    localparam G_COMPUTE    = 3'd2;
    localparam G_ACCUM      = 3'd3;
    localparam G_NEXT_EXPERT= 3'd4;
    localparam G_TOPK       = 3'd5;
    localparam G_DONE       = 3'd6;

    reg [2:0]  g_state;
    reg [7:0]  expert_ptr;
    reg [ADDR_BITS-1:0] dim_ptr;
    reg [15:0] acc;

    // =========================================================================
    // BF16 FMA: result = (a * b) + c
    // =========================================================================
    reg [15:0] fma_a, fma_b, fma_c;
    reg        fma_valid_in;
    wire [15:0] fma_result;
    wire        fma_valid_out;

    bf16_fma u_fma (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fma_a),
        .b         (fma_b),
        .c         (fma_c),
        .valid_in  (fma_valid_in),
        .result    (fma_result),
        .valid_out (fma_valid_out)
    );

    assign fma_busy = (g_state != G_IDLE);

    // =========================================================================
    // Weight load
    // =========================================================================
    always @(posedge clk) begin
        if (weight_load)
            weights[weight_addr] <= weight_data;
    end

    // =========================================================================
    // Hidden state capture
    // =========================================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < HIDDEN_DIM; i = i + 1)
                hidden_latch[i] <= 16'h0000;
        end else if (g_state == G_LOAD_HIDDEN) begin
            hidden_latch[dim_ptr] <= hidden_data;
        end
    end

    // =========================================================================
    // Main gating FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_state    <= G_IDLE;
            expert_ptr <= 0;
            dim_ptr    <= 0;
            acc        <= 16'h0000;
            fma_a      <= 16'h0000;
            fma_b      <= 16'h0000;
            fma_c      <= 16'h0000;
            fma_valid_in <= 1'b0;
            done       <= 1'b0;
            hidden_addr <= 0;
            for (i = 0; i < NUM_EXPERTS; i = i + 1)
                logits[i] <= 16'h0000;
            for (i = 0; i < TOP_K; i = i + 1) begin
                topk_idx[i]  <= 8'hFF;
                topk_logit[i] <= 16'h0000;
            end
        end else begin
            done <= 1'b0;
            fma_valid_in <= 1'b0;

            case (g_state)
                G_IDLE: begin
                    if (start) begin
                        expert_ptr <= 0;
                        g_state    <= G_LOAD_HIDDEN;
                        dim_ptr    <= 0;
    
                    end
                end

                G_LOAD_HIDDEN: begin
                    hidden_addr <= dim_ptr;
                    if (dim_ptr == HIDDEN_DIM - 1) begin
                        dim_ptr <= 0;
                        acc     <= 16'h0000;
                        g_state <= G_COMPUTE;

                    end else begin
                        dim_ptr <= dim_ptr + 1;
                    end
                end

                G_COMPUTE: begin
                    fma_a         <= hidden_latch[dim_ptr];
                    fma_b         <= weights[expert_ptr * HIDDEN_DIM + dim_ptr];
                    fma_c         <= acc;
                    fma_valid_in  <= 1'b1;
                    g_state       <= G_ACCUM;

                end

                G_ACCUM: begin
                    fma_valid_in <= 1'b0;
                    if (fma_valid_out) begin
                        acc <= fma_result;

                        if (dim_ptr == HIDDEN_DIM - 1) begin
                            logits[expert_ptr] <= fma_result;
                            g_state <= G_NEXT_EXPERT;
                        end else begin
                            dim_ptr <= dim_ptr + 1;
                            g_state <= G_COMPUTE;
                        end
                    end
                end

                G_NEXT_EXPERT: begin
                    if (expert_ptr == NUM_EXPERTS - 1) begin
                        g_state <= G_TOPK;
                        expert_ptr <= 0;
                        dim_ptr    <= 0;

                    end else begin
                        expert_ptr <= expert_ptr + 1;
                        dim_ptr    <= 0;
                        acc        <= 16'h0000;
                        g_state    <= G_COMPUTE;

                    end
                end

                G_TOPK: begin
                    if (topk_state == TOPK_DONE) begin
                        g_state <= G_DONE;
                        done    <= 1'b1;
                    end
                end

                G_DONE: begin
                    g_state <= G_IDLE;
                end

                default: g_state <= G_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Top-K selector: multi-cycle insertion scan
    //
    // The sorted buffer topk_logit[0..TOP_K-1] is descending (index 0 = max).
    // INIT cycle: populate with first TOP_K experts from logits[].
    // SCAN cycles: one expert per clock.  If the new logit beats the current
    //   minimum (topk_logit[TOP_K-1]), find the insertion index, shift the
    //   tail down, and insert.  NBAs are safe here because each shift reads
    //   from a strictly lower index than it writes, and all NBA reads capture
    //   the pre-update values.
    // =========================================================================
    localparam TOPK_IDLE = 2'd0;
    localparam TOPK_INIT = 2'd1;
    localparam TOPK_SCAN = 2'd2;
    localparam TOPK_DONE = 2'd3;

    reg [1:0]  topk_state;
    reg [7:0]  topk_scan_ptr;
    reg [2:0]  topk_ins_pos;
    integer ti;

    // Combinational: find insertion position for logits[topk_scan_ptr]
    // Scans from index 0 (largest) toward TOP_K-1 (smallest).
    // Returns the first index where the new logit is strictly larger.
    // If no such index, returns TOP_K (meaning "not inserted").
    always @(*) begin
        topk_ins_pos = TOP_K[2:0];
        for (ti = 0; ti < TOP_K; ti = ti + 1) begin
            if (topk_ins_pos == TOP_K[2:0] && logits[topk_scan_ptr] > topk_logit[ti])
                topk_ins_pos = ti[2:0];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            topk_state   <= TOPK_IDLE;
            topk_scan_ptr <= 0;
            for (ti = 0; ti < TOP_K; ti = ti + 1) begin
                topk_idx[ti]   <= 8'hFF;
                topk_logit[ti] <= 16'h0000;
            end
        end else begin
            case (topk_state)
                TOPK_IDLE: begin
                    if (g_state == G_NEXT_EXPERT && expert_ptr == NUM_EXPERTS - 1) begin
                        // Populate sorted buffer with first TOP_K experts
                        for (ti = 0; ti < TOP_K; ti = ti + 1) begin
                            topk_idx[ti]   <= ti[7:0];
                            topk_logit[ti] <= logits[ti];
                        end
                        topk_scan_ptr <= TOP_K[7:0];
                        topk_state    <= TOPK_SCAN;
                    end
                end

                TOPK_SCAN: begin
                    if (topk_ins_pos < TOP_K[2:0]) begin
                        // Shift entries [topk_ins_pos .. TOP_K-2] down by one
                        for (ti = TOP_K - 1; ti > 0; ti = ti - 1) begin
                            if (ti[2:0] > topk_ins_pos) begin
                                topk_idx[ti]   <= topk_idx[ti - 1];
                                topk_logit[ti] <= topk_logit[ti - 1];
                            end
                        end
                        // Insert at the found position
                        topk_idx[topk_ins_pos]   <= topk_scan_ptr;
                        topk_logit[topk_ins_pos] <= logits[topk_scan_ptr];
                    end
                    // Advance or finish
                    if (topk_scan_ptr == NUM_EXPERTS[7:0] - 1)
                        topk_state <= TOPK_DONE;
                    else
                        topk_scan_ptr <= topk_scan_ptr + 1;
                end

                TOPK_DONE: begin
                    if (g_state == G_IDLE)
                        topk_state <= TOPK_IDLE;
                end

                default: topk_state <= TOPK_IDLE;
            endcase
        end
    end

endmodule
