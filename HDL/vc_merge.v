`include "pnm_defs.vh"

// =============================================================================
// vc_merge — 2-in/1-out arbitrated merge for the reverse (egress) paths
// Paper §2.9 (result egress) / §4.3 (classes 0 and 1)
//
// The forward fabric is a demux tree (flit_gate); the reverse path is a pure
// merge tree — node TX -> Y-up -> X-up -> xyz_repeater -> up-spine — with no
// routing decisions anywhere.  Each merge is this module: it grants one of
// its two upstream ports for a whole packet (decision held until eop, so
// packets are never torn), round-robin between the ports, and forwards that
// port's data and VC sideband downstream.  Backpressure is standard: the
// granted port's ready tracks the downstream handshake, the other port stalls
// in place.
//
// The dependency graph of these merges is a DAG (board egress -> spine
// ascent), so the arbitration cannot deadlock (paper §4.3 liveness argument).
// =============================================================================
module vc_merge (
    input  wire       clk,
    input  wire       rst_n,

    // upstream port A (priority is round-robin, not fixed)
    input  wire [7:0] a_data,
    input  wire       a_valid,
    input  wire       a_sop,
    input  wire       a_eop,
    output wire       a_ready,
    input  wire [1:0] a_vc,

    // upstream port B
    input  wire [7:0] b_data,
    input  wire       b_valid,
    input  wire       b_sop,
    input  wire       b_eop,
    output wire       b_ready,
    input  wire [1:0] b_vc,

    // downstream master
    output wire [7:0] out_data,
    output wire       out_valid,
    output wire       out_sop,
    output wire       out_eop,
    input  wire       out_ready,
    output wire [1:0] out_vc
);

    localparam S_IDLE = 2'd0, S_A = 2'd1, S_B = 2'd2;

    reg [1:0] state_q;
    reg       pri_q;        // 0: A goes first when both wait, 1: B

    wire out_advance = out_ready || !out_valid;

    reg [1:0] state_nxt;
    always @(*) begin
        case (state_q)
            S_IDLE: state_nxt = pri_q
                    ? (b_valid ? S_B : (a_valid ? S_A : S_IDLE))
                    : (a_valid ? S_A : (b_valid ? S_B : S_IDLE));
            S_A:    state_nxt = (a_valid && a_eop) ? (b_valid ? S_B : S_IDLE) : S_A;
            default:state_nxt = (b_valid && b_eop) ? (a_valid ? S_A : S_IDLE) : S_B;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            pri_q   <= 1'b0;
        end else if (out_advance) begin
            state_q <= state_nxt;
            if (state_q == S_A && a_valid && a_eop) pri_q <= 1'b1;
            if (state_q == S_B && b_valid && b_eop) pri_q <= 1'b0;
        end
    end

    // the granted port: the one we are in, or the one we are about to enter
    // while idle (so a waiting packet advances without a bubble)
    wire g_a = (state_q == S_A) || (state_q == S_IDLE && state_nxt == S_A);
    wire g_b = (state_q == S_B) || (state_q == S_IDLE && state_nxt == S_B);

    assign out_data  = g_a ? a_data : b_data;
    assign out_vc    = g_a ? a_vc   : b_vc;
    assign out_valid = g_a ? a_valid : b_valid;
    assign out_sop   = g_a ? a_sop   : b_sop;
    assign out_eop   = g_a ? a_eop   : b_eop;

    assign a_ready = out_advance && g_a;
    assign b_ready = out_advance && g_b;

endmodule
