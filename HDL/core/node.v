`timescale 1ns/1ps

// =============================================================================
// node — the compute NODE of the node network (the paper's MAC ASIC paired
// with each memory module). Runs one MoE expert pass on a selectable numeric
// ASIC chosen by CU_TYPE, so a single node file can host any of the
// HDL/core compute units:
//
//   CU_TYPE  engine       WIDTH  datapath / activation
//   -------  -----------  -----  ---------------------------------------------
//     0      bf16_fma      16    gate/up -> gelu_tanh(gate)*up -> down
//     1      fp16_fma      16    gate -> down   (identity activation)
//     2      fp32_fma      32    gate -> down
//     3      fp64_fma      64    gate -> down
//     4      int8_mac       8    gate -> down   (INT32 accumulate)
//     5      int4_mac       8    gate -> down   (packed nibbles, low selected)
//     6      fp4_mac        8    gate -> down   (E2M1, low nibble)
//     7      fp4_mac        8    gate -> down   (E2M1 + MXFP4_SHIFT block scale)
//     8      ternary_acc    8    gate -> down   (BitNet b1.58 {-1,0,+1}, INT32)
//
// CU_TYPE 0 is the validated BF16 MoE-expert specialization (bit-exact vs the
// fused-FMA oracle used by the router). Every format shares the same control
// FSM and one accumulate engine interface (`c = a*b + c`); the generate block
// selects the embedded MAC ASIC. The node network / fabric side is the
// flit/repeater/doorbell stack in HDL/.
//
// Weight layout mirrors the fused checkpoint expert tensors:
//   wu [0:2*EFF*N-1]  rows 0..EFF-1    = gate_proj  (gate_up_proj[e][0:EFF])
//                     rows EFF..2EFF-1 = up_proj    (BF16 only)
//   wd [0:N*EFF-1]    row r = down_proj[e][r]
// WIDTH is the external element width and should match CU_TYPE
// (16 for 0/1, 32 for 2, 64 for 3, 8 for 4..7).
// Throughput: (GU_ROWS*N + N*EFF) MAC per expert.
// =============================================================================

module node #(
    parameter N           = 16,     // hidden width
    parameter EFF         = 8,      // expert MoE intermediate width
    parameter integer CU_TYPE = 0,  // numeric ASIC selector (see table above)
    parameter WIDTH       = 16,     // external element width (must match CU_TYPE)
    parameter integer MEM_CHAN = 1, // hidden ingest channels (N must be a multiple)
    parameter GELU_A      = 16'h3F4C,  // bf16(sqrt(2/pi))
    parameter GELU_B      = 16'h3D37,  // bf16(0.044715)
    parameter [3:0] MXFP4_SHIFT = 4'd0 // MXFP4 block-scale left shift on weights
)(
    input wire         clk,
    input wire         rst_n,

    // -- Control -----------------------------------------------------------
    input  wire        start,            // begin expert pass
    output reg         done,             // expert pass complete

    // -- Hidden state read port (MEM_CHAN-wide, from the node's multi-channel
    //    memory: one valid beat delivers MEM_CHAN words) ---------------------
    input  wire        hidden_valid,                 // beat carries MEM_CHAN words
    input  wire [MEM_CHAN*WIDTH-1:0] hidden_data,    // expert input elements

    // -- Weight SRAM write ports (loaded during boot) ----------------------
    input  wire        weight_load,
    input  wire        weight_sel,       // 0: wu (gate/up), 1: wd (down)
    input  wire [15:0] weight_addr,      // linear index into the region
    input  wire [WIDTH-1:0] weight_data, // weight element

    // -- Result peek window (host reads expert output) ---------------------
    input  wire [7:0]  out_addr,         // output index
    output wire [WIDTH-1:0] out_val,     // out[out_addr]

    // -- Debug peek windows (validation only) ------------------------------
    input  wire [7:0]  dbg_addr,
    output wire [WIDTH-1:0] gate_val,
    output wire [WIDTH-1:0] up_val,
    output wire [WIDTH-1:0] act_val
);

    `include "bf16_fp.vh"

    localparam IS_BF16  = (CU_TYPE == 0);
    // gate/up rows computed: BF16 swiglu needs both; every other format only
    // consumes the gate projection (activation is the identity).
    localparam integer GU_ROWS = IS_BF16 ? (2*EFF) : EFF;

    // =========================================================================
    // Weight SRAMs: gate+up fused (2*EFF rows x N) and down (N rows x EFF).
    // Stored zero-extended in 64-bit lanes; the engine slices the low WIDTH.
    // =========================================================================
    reg [63:0] wu [0:2*EFF*N-1];
    reg [63:0] wd [0:N*EFF-1];

    // =========================================================================
    // Latch storage
    // =========================================================================
    reg [63:0] hidden_latch [0:N-1];   // expert input x2
    reg [63:0] gate     [0:EFF-1];     // gate projection per intermediate unit
    reg [63:0] up       [0:EFF-1];     // up projection (BF16 only)
    reg [63:0] act      [0:EFF-1];     // activation
    reg [63:0] out      [0:N-1];       // expert output = WD x act

    // The output-window guard must be width-safe: N can be 256 or more, so a
    // truncated N[7:0] comparison would read 0 and blank the whole window.
    localparam [31:0] N_OUT = N;
    assign out_val  = (out_addr < N_OUT) ? out[out_addr][WIDTH-1:0] : {WIDTH{1'b0}};
    assign gate_val = (dbg_addr < EFF)    ? gate[dbg_addr][WIDTH-1:0] : {WIDTH{1'b0}};
    assign up_val   = (dbg_addr < EFF)    ? up[dbg_addr][WIDTH-1:0]   : {WIDTH{1'b0}};
    assign act_val  = (dbg_addr < EFF)    ? act[dbg_addr][WIDTH-1:0]  : {WIDTH{1'b0}};

    // =========================================================================
    // Selectable arithmetic engine: result = a*b + c (one accumulate step)
    // =========================================================================
    reg  [63:0] eng_a, eng_b, eng_c;
    reg         eng_vld_in;
    wire [63:0] eng_result;
    wire        eng_valid;

    // CU_TYPE -> arith_unit CU.  The node's numeric codes match the unit's for
    // 0..6, MXFP4 is arith CU 7 (fp4 + block-scale wshift), and the BitNet
    // ternary select-add accumulator is arith CU 11 (node CU_TYPE 8).
    localparam ENGINE_CU = (CU_TYPE <= 6) ? CU_TYPE :
                           (CU_TYPE == 7) ? 7 :
                           (CU_TYPE == 8) ? 11 : 0;
    localparam [3:0] ENGINE_WSHIFT = (CU_TYPE == 7) ? MXFP4_SHIFT : 4'd0;

    // One shared engine: the whole FMA/ALU/MAC/select-add family lives in
    // arith_unit, selected by CU_TYPE, instead of a per-CU mux here.  The
    // accumulate contract (a,b,c -> result, valid) is identical for every unit,
    // so the node FSM is unit-agnostic.
    arith_unit #(.CU(ENGINE_CU)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .a(eng_a), .b(eng_b), .c(eng_c),
        .valid_in(eng_vld_in), .op(3'd0),
        .pack_select(1'b0), .b_pack_select(1'b0), .wshift(ENGINE_WSHIFT),
        .result(eng_result), .valid_out(eng_valid), .busy());

    // =========================================================================
    // FSM
    // =========================================================================
    localparam X_IDLE      = 5'd0;
    localparam X_LOAD      = 5'd1;   // capture N hidden words
    localparam X_ROWSTART  = 5'd2;   // reset accumulation for a gate/up row
    localparam X_GU        = 5'd3;   // issue one gate/up MAC
    localparam X_GUACC     = 5'd4;   // wait fused-MAC result
    localparam X_ACT       = 5'd5;   // activation
    localparam X_DWSTART   = 5'd6;   // reset accumulation for a down row
    localparam X_DW        = 5'd7;   // issue one down MAC
    localparam X_DWACC     = 5'd8;   // wait fused-MAC result
    localparam X_DONE      = 5'd9;

    reg [4:0]   x_state;
    reg [11:0]  row_ptr;             // current output row being computed
    reg [11:0]  col_ptr;             // MAC column inside the row
    reg [11:0]  in_ptr;              // hidden ingest pointer (N up to 4096)
    reg [63:0]  acc;                 // running accumulator
    wire        hidden_wr;

    integer i;
    integer c;

    // =========================================================================
    // Weight load
    // =========================================================================
    always @(posedge clk) begin
        if (weight_load) begin
            if (weight_sel)
                wd[weight_addr] <= weight_data;
            else
                wu[weight_addr] <= weight_data;
        end
    end

    // =========================================================================
    // Hidden capture (streamed after start)
    // =========================================================================
    assign hidden_wr = (x_state == X_LOAD) && hidden_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) hidden_latch[i] <= 64'h0;
        end else if (hidden_wr) begin
            for (c = 0; c < MEM_CHAN; c = c + 1)
                hidden_latch[in_ptr + c] <= hidden_data[c*WIDTH +: WIDTH];
        end
    end

    // =========================================================================
    // Main FSM: rows of fused MAC (same accumulate engine as the router)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_state   <= X_IDLE;
            row_ptr   <= 0;
            col_ptr   <= 0;
            in_ptr    <= 0;
            acc       <= 64'h0;
            eng_a     <= 64'h0;
            eng_b     <= 64'h0;
            eng_c     <= 64'h0;
            eng_vld_in<= 1'b0;
            done      <= 1'b0;
            for (i = 0; i < N; i = i + 1) out[i] <= 64'h0;
            for (i = 0; i < EFF; i = i + 1) begin
                gate[i] <= 64'h0;
                up[i]   <= 64'h0;
                act[i]  <= 64'h0;
            end
        end else begin
            done      <= 1'b0;
            eng_vld_in<= 1'b0;

            case (x_state)
                X_IDLE: begin
                    if (start) begin
                        in_ptr   <= 0;
                        row_ptr  <= 0;
                        col_ptr  <= 0;
                        x_state  <= X_LOAD;
                    end
                end

                X_LOAD: begin
                    if (hidden_valid) begin
                        if (in_ptr + MEM_CHAN >= N) begin
                            in_ptr  <= 0;
                            row_ptr <= 0;
                            col_ptr <= 0;
                            x_state <= X_ROWSTART;
                        end else begin
                            in_ptr <= in_ptr + MEM_CHAN;
                        end
                    end
                end

                X_ROWSTART: begin
                    acc     <= 64'h0;
                    col_ptr <= 0;
                    x_state <= X_GU;
                end

                X_GU: begin
                    eng_a      <= hidden_latch[col_ptr];
                    eng_b      <= wu[row_ptr * N + col_ptr];
                    eng_c      <= acc;
                    eng_vld_in <= 1'b1;
                    x_state    <= X_GUACC;
                end

                X_GUACC: begin
                    if (eng_valid) begin
                        acc <= eng_result;
                        if (col_ptr == N - 1) begin
                            if (row_ptr < EFF)
                                gate[row_ptr] <= eng_result;
                            else
                                up[row_ptr - EFF] <= eng_result;
                            if (row_ptr == GU_ROWS - 1) begin
                                row_ptr <= 0;
                                col_ptr <= 0;
                                x_state <= X_ACT;
                            end else begin
                                row_ptr <= row_ptr + 1;
                                x_state <= X_ROWSTART;
                            end
                        end else begin
                            col_ptr <= col_ptr + 1;
                            x_state <= X_GU;
                        end
                    end
                end

                X_ACT: begin
                    if (IS_BF16)
                        for (i = 0; i < EFF; i = i + 1)
                            act[i] = bf16_mul(bf16_gelu(gate[i], GELU_A, GELU_B), up[i]);
                    else
                        for (i = 0; i < EFF; i = i + 1)
                            act[i] = gate[i];
                    row_ptr <= 0;
                    col_ptr <= 0;
                    x_state <= X_DWSTART;
                end

                X_DWSTART: begin
                    acc     <= 64'h0;
                    col_ptr <= 0;
                    x_state <= X_DW;
                end

                X_DW: begin
                    eng_a      <= act[col_ptr];
                    eng_b      <= wd[row_ptr * EFF + col_ptr];
                    eng_c      <= acc;
                    eng_vld_in <= 1'b1;
                    x_state    <= X_DWACC;
                end

                X_DWACC: begin
                    if (eng_valid) begin
                        acc <= eng_result;
                        if (col_ptr == EFF - 1) begin
                            out[row_ptr] <= eng_result;
                            if (row_ptr == N - 1) begin
                                x_state <= X_DONE;
                            end else begin
                                row_ptr <= row_ptr + 1;
                                x_state <= X_DWSTART;
                            end
                        end else begin
                            col_ptr <= col_ptr + 1;
                            x_state <= X_DW;
                        end
                    end
                end

                X_DONE: begin
                    done    <= 1'b1;
                    x_state <= X_IDLE;
                end

                default: x_state <= X_IDLE;
            endcase
        end
    end

endmodule
