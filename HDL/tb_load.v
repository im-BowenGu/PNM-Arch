`timescale 1ns/1ps
`include "pnm_defs.vh"

// =============================================================================
// tb_load — sustained load / stress test of the PNM fabric sketch
//
// Topology (spine + board):
//
//   inject --> ing(L1) --pass--> hfr --pass--> ing(L2) --pass--> pass_sink
//                 |                              |
//                nob                            nob
//                 |                              |
//              board_L1                       board_L2
//
//   board_L* : turn(X=2) -> hfr -> turn(X=5) -> x_sink
//                   |                  |
//                eject(0x25)        eject(0x53)
//                   |                  |
//                node_25             node_53
//
// Load profile:
//   - continuous injection at full rate (valid every cycle when ready)
//   - mixed destinations: L1/0x25, L1/0x53, L2/0x25, L2/0x53, pass-through L3
//   - sink backpressure duty cycles 100% / 50% / 25%
//   - scoreboard checks byte counts + payload checksums
// =============================================================================

module load_sink #(
    // 0 = always ready, 1 = 50% (every other cycle), 2 = 25% (1 of 4)
    parameter integer BP_MODE = 0
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_sop,
    input  wire       in_eop,
    output reg        in_ready,
    output reg [31:0] byte_count,
    output reg [31:0] pkt_count,
    output reg [31:0] checksum,
    output reg [31:0] sop_count,
    output reg [31:0] eop_count
);
    reg [1:0] cyc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_ready   <= 1'b1;
            byte_count <= 32'd0;
            pkt_count  <= 32'd0;
            checksum   <= 32'd0;
            sop_count  <= 32'd0;
            eop_count  <= 32'd0;
            cyc        <= 2'd0;
        end else begin
            cyc <= cyc + 2'd1;
            if (BP_MODE == 0)
                in_ready <= 1'b1;
            else if (BP_MODE == 1)
                in_ready <= cyc[0];           // 50%
            else
                in_ready <= (cyc == 2'd0);    // 25%

            if (in_valid && in_ready) begin
                byte_count <= byte_count + 32'd1;
                checksum   <= checksum + {24'd0, in_data};
                if (in_sop) sop_count <= sop_count + 32'd1;
                if (in_eop) begin
                    eop_count <= eop_count + 32'd1;
                    pkt_count <= pkt_count + 32'd1;
                end
            end
        end
    end
endmodule

module tb_load;
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk; // 100 MHz

    integer errors = 0;

    // ---- inject ----
    reg  [7:0] inj_data;
    reg        inj_valid, inj_sop, inj_eop;
    wire       inj_ready;

    // ---- spine ----
    wire [7:0] i1p_d; wire i1p_v, i1p_s, i1p_e, i1p_r;
    wire [7:0] n1_d;  wire n1_v,  n1_s,  n1_e,  n1_r;
    wire [7:0] h1_d;  wire h1_v,  h1_s,  h1_e,  h1_r;
    wire [7:0] i2p_d; wire i2p_v, i2p_s, i2p_e, i2p_r;
    wire [7:0] n2_d;  wire n2_v,  n2_s,  n2_e,  n2_r;

    z_ingress #(.LOCAL_LAYER(8'h01)) ing1 (
        .clk(clk), .rst_n(rst_n),
        .spin_data(inj_data), .spin_valid(inj_valid), .spin_sop(inj_sop),
        .spin_eop(inj_eop), .spin_ready(inj_ready),
        .spout_data(i1p_d), .spout_valid(i1p_v), .spout_sop(i1p_s),
        .spout_eop(i1p_e), .spout_ready(i1p_r),
        .nob_data(n1_d), .nob_valid(n1_v), .nob_sop(n1_s),
        .nob_eop(n1_e), .nob_ready(n1_r)
    );

    hfr h_spine (
        .clk(clk), .rst_n(rst_n),
        .in_data(i1p_d), .in_valid(i1p_v), .in_sop(i1p_s),
        .in_eop(i1p_e), .in_ready(i1p_r),
        .out_data(h1_d), .out_valid(h1_v), .out_sop(h1_s),
        .out_eop(h1_e), .out_ready(h1_r)
    );

    z_ingress #(.LOCAL_LAYER(8'h02)) ing2 (
        .clk(clk), .rst_n(rst_n),
        .spin_data(h1_d), .spin_valid(h1_v), .spin_sop(h1_s),
        .spin_eop(h1_e), .spin_ready(h1_r),
        .spout_data(i2p_d), .spout_valid(i2p_v), .spout_sop(i2p_s),
        .spout_eop(i2p_e), .spout_ready(i2p_r),
        .nob_data(n2_d), .nob_valid(n2_v), .nob_sop(n2_s),
        .nob_eop(n2_e), .nob_ready(n2_r)
    );

    // ---- board fabric for layer 1 (from n1_*) ----
    wire [7:0] l1t2x_d; wire l1t2x_v, l1t2x_s, l1t2x_e, l1t2x_r;
    wire [7:0] l1t2y_d; wire l1t2y_v, l1t2y_s, l1t2y_e, l1t2y_r;
    wire [7:0] l1hb_d;  wire l1hb_v,  l1hb_s,  l1hb_e,  l1hb_r;
    wire [7:0] l1t5x_d; wire l1t5x_v, l1t5x_s, l1t5x_e, l1t5x_r;
    wire [7:0] l1t5y_d; wire l1t5y_v, l1t5y_s, l1t5y_e, l1t5y_r;
    wire [7:0] l1ej2_d; wire l1ej2_v, l1ej2_s, l1ej2_e, l1ej2_r;
    wire [7:0] l1ej5_d; wire l1ej5_v, l1ej5_s, l1ej5_e, l1ej5_r;
    wire [7:0] l1n25_d; wire l1n25_v, l1n25_s, l1n25_e, l1n25_r;
    wire [7:0] l1n53_d; wire l1n53_v, l1n53_s, l1n53_e, l1n53_r;

    xy_turn #(.LOCAL_X(4'h2)) l1_turn2 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(n1_d), .xin_valid(n1_v), .xin_sop(n1_s),
        .xin_eop(n1_e), .xin_ready(n1_r),
        .xout_data(l1t2x_d), .xout_valid(l1t2x_v), .xout_sop(l1t2x_s),
        .xout_eop(l1t2x_e), .xout_ready(l1t2x_r),
        .yout_data(l1t2y_d), .yout_valid(l1t2y_v), .yout_sop(l1t2y_s),
        .yout_eop(l1t2y_e), .yout_ready(l1t2y_r)
    );

    node_eject #(.LOCAL_MODULE(8'h25)) l1_ej25 (
        .clk(clk), .rst_n(rst_n),
        .yin_data(l1t2y_d), .yin_valid(l1t2y_v), .yin_sop(l1t2y_s),
        .yin_eop(l1t2y_e), .yin_ready(l1t2y_r),
        .yout_data(l1ej2_d), .yout_valid(l1ej2_v), .yout_sop(l1ej2_s),
        .yout_eop(l1ej2_e), .yout_ready(1'b1),
        .node_data(l1n25_d), .node_valid(l1n25_v), .node_sop(l1n25_s),
        .node_eop(l1n25_e), .node_ready(l1n25_r)
    );

    hfr l1_hx (
        .clk(clk), .rst_n(rst_n),
        .in_data(l1t2x_d), .in_valid(l1t2x_v), .in_sop(l1t2x_s),
        .in_eop(l1t2x_e), .in_ready(l1t2x_r),
        .out_data(l1hb_d), .out_valid(l1hb_v), .out_sop(l1hb_s),
        .out_eop(l1hb_e), .out_ready(l1hb_r)
    );

    xy_turn #(.LOCAL_X(4'h5)) l1_turn5 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(l1hb_d), .xin_valid(l1hb_v), .xin_sop(l1hb_s),
        .xin_eop(l1hb_e), .xin_ready(l1hb_r),
        .xout_data(l1t5x_d), .xout_valid(l1t5x_v), .xout_sop(l1t5x_s),
        .xout_eop(l1t5x_e), .xout_ready(l1t5x_r),
        .yout_data(l1t5y_d), .yout_valid(l1t5y_v), .yout_sop(l1t5y_s),
        .yout_eop(l1t5y_e), .yout_ready(l1t5y_r)
    );

    node_eject #(.LOCAL_MODULE(8'h53)) l1_ej53 (
        .clk(clk), .rst_n(rst_n),
        .yin_data(l1t5y_d), .yin_valid(l1t5y_v), .yin_sop(l1t5y_s),
        .yin_eop(l1t5y_e), .yin_ready(l1t5y_r),
        .yout_data(l1ej5_d), .yout_valid(l1ej5_v), .yout_sop(l1ej5_s),
        .yout_eop(l1ej5_e), .yout_ready(1'b1),
        .node_data(l1n53_d), .node_valid(l1n53_v), .node_sop(l1n53_s),
        .node_eop(l1n53_e), .node_ready(l1n53_r)
    );

    // ---- board fabric for layer 2 (from n2_*) ----
    wire [7:0] l2t2x_d; wire l2t2x_v, l2t2x_s, l2t2x_e, l2t2x_r;
    wire [7:0] l2t2y_d; wire l2t2y_v, l2t2y_s, l2t2y_e, l2t2y_r;
    wire [7:0] l2hb_d;  wire l2hb_v,  l2hb_s,  l2hb_e,  l2hb_r;
    wire [7:0] l2t5x_d; wire l2t5x_v, l2t5x_s, l2t5x_e, l2t5x_r;
    wire [7:0] l2t5y_d; wire l2t5y_v, l2t5y_s, l2t5y_e, l2t5y_r;
    wire [7:0] l2n25_d; wire l2n25_v, l2n25_s, l2n25_e, l2n25_r;
    wire [7:0] l2n53_d; wire l2n53_v, l2n53_s, l2n53_e, l2n53_r;

    xy_turn #(.LOCAL_X(4'h2)) l2_turn2 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(n2_d), .xin_valid(n2_v), .xin_sop(n2_s),
        .xin_eop(n2_e), .xin_ready(n2_r),
        .xout_data(l2t2x_d), .xout_valid(l2t2x_v), .xout_sop(l2t2x_s),
        .xout_eop(l2t2x_e), .xout_ready(l2t2x_r),
        .yout_data(l2t2y_d), .yout_valid(l2t2y_v), .yout_sop(l2t2y_s),
        .yout_eop(l2t2y_e), .yout_ready(l2t2y_r)
    );

    wire [7:0] l2ej2_d; wire l2ej2_v, l2ej2_s, l2ej2_e;
    node_eject #(.LOCAL_MODULE(8'h25)) l2_ej25 (
        .clk(clk), .rst_n(rst_n),
        .yin_data(l2t2y_d), .yin_valid(l2t2y_v), .yin_sop(l2t2y_s),
        .yin_eop(l2t2y_e), .yin_ready(l2t2y_r),
        .yout_data(l2ej2_d), .yout_valid(l2ej2_v), .yout_sop(l2ej2_s),
        .yout_eop(l2ej2_e), .yout_ready(1'b1),
        .node_data(l2n25_d), .node_valid(l2n25_v), .node_sop(l2n25_s),
        .node_eop(l2n25_e), .node_ready(l2n25_r)
    );

    hfr l2_hx (
        .clk(clk), .rst_n(rst_n),
        .in_data(l2t2x_d), .in_valid(l2t2x_v), .in_sop(l2t2x_s),
        .in_eop(l2t2x_e), .in_ready(l2t2x_r),
        .out_data(l2hb_d), .out_valid(l2hb_v), .out_sop(l2hb_s),
        .out_eop(l2hb_e), .out_ready(l2hb_r)
    );

    xy_turn #(.LOCAL_X(4'h5)) l2_turn5 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(l2hb_d), .xin_valid(l2hb_v), .xin_sop(l2hb_s),
        .xin_eop(l2hb_e), .xin_ready(l2hb_r),
        .xout_data(l2t5x_d), .xout_valid(l2t5x_v), .xout_sop(l2t5x_s),
        .xout_eop(l2t5x_e), .xout_ready(l2t5x_r),
        .yout_data(l2t5y_d), .yout_valid(l2t5y_v), .yout_sop(l2t5y_s),
        .yout_eop(l2t5y_e), .yout_ready(l2t5y_r)
    );

    wire [7:0] l2ej5_d; wire l2ej5_v, l2ej5_s, l2ej5_e;
    node_eject #(.LOCAL_MODULE(8'h53)) l2_ej53 (
        .clk(clk), .rst_n(rst_n),
        .yin_data(l2t5y_d), .yin_valid(l2t5y_v), .yin_sop(l2t5y_s),
        .yin_eop(l2t5y_e), .yin_ready(l2t5y_r),
        .yout_data(l2ej5_d), .yout_valid(l2ej5_v), .yout_sop(l2ej5_s),
        .yout_eop(l2ej5_e), .yout_ready(1'b1),
        .node_data(l2n53_d), .node_valid(l2n53_v), .node_sop(l2n53_s),
        .node_eop(l2n53_e), .node_ready(l2n53_r)
    );

    // ---- sinks with varied backpressure (0=100%, 1=50%, 2=25%) ----
    wire [31:0] s_pass_b, s_pass_p, s_pass_c, s_pass_s, s_pass_e;
    wire [31:0] s_l1_25_b, s_l1_25_p, s_l1_25_c, s_l1_25_s, s_l1_25_e;
    wire [31:0] s_l1_53_b, s_l1_53_p, s_l1_53_c, s_l1_53_s, s_l1_53_e;
    wire [31:0] s_l2_25_b, s_l2_25_p, s_l2_25_c, s_l2_25_s, s_l2_25_e;
    wire [31:0] s_l2_53_b, s_l2_53_p, s_l2_53_c, s_l2_53_s, s_l2_53_e;
    wire [31:0] s_l1x_b, s_l1x_p, s_l1x_c, s_l1x_s, s_l1x_e;
    wire [31:0] s_l2x_b, s_l2x_p, s_l2x_c, s_l2x_s, s_l2x_e;

    // Elastic HFRs in front of backpressured node sinks (depth-1 skid)
    wire [7:0] l1n25b_d; wire l1n25b_v, l1n25b_s, l1n25b_e, l1n25b_r;
    wire [7:0] l1n53b_d; wire l1n53b_v, l1n53b_s, l1n53b_e, l1n53b_r;
    wire [7:0] l2n53b_d; wire l2n53b_v, l2n53b_s, l2n53b_e, l2n53b_r;

    hfr h_l1_25 (
        .clk(clk), .rst_n(rst_n),
        .in_data(l1n25_d), .in_valid(l1n25_v), .in_sop(l1n25_s),
        .in_eop(l1n25_e), .in_ready(l1n25_r),
        .out_data(l1n25b_d), .out_valid(l1n25b_v), .out_sop(l1n25b_s),
        .out_eop(l1n25b_e), .out_ready(l1n25b_r)
    );
    hfr h_l1_53 (
        .clk(clk), .rst_n(rst_n),
        .in_data(l1n53_d), .in_valid(l1n53_v), .in_sop(l1n53_s),
        .in_eop(l1n53_e), .in_ready(l1n53_r),
        .out_data(l1n53b_d), .out_valid(l1n53b_v), .out_sop(l1n53b_s),
        .out_eop(l1n53b_e), .out_ready(l1n53b_r)
    );
    hfr h_l2_53 (
        .clk(clk), .rst_n(rst_n),
        .in_data(l2n53_d), .in_valid(l2n53_v), .in_sop(l2n53_s),
        .in_eop(l2n53_e), .in_ready(l2n53_r),
        .out_data(l2n53b_d), .out_valid(l2n53b_v), .out_sop(l2n53b_s),
        .out_eop(l2n53b_e), .out_ready(l2n53b_r)
    );

    load_sink #(.BP_MODE(0)) sk_pass (
        .clk(clk), .rst_n(rst_n),
        .in_data(i2p_d), .in_valid(i2p_v), .in_sop(i2p_s), .in_eop(i2p_e),
        .in_ready(i2p_r),
        .byte_count(s_pass_b), .pkt_count(s_pass_p), .checksum(s_pass_c),
        .sop_count(s_pass_s), .eop_count(s_pass_e)
    );
    load_sink #(.BP_MODE(1)) sk_l1_25 ( // 50% ready
        .clk(clk), .rst_n(rst_n),
        .in_data(l1n25b_d), .in_valid(l1n25b_v), .in_sop(l1n25b_s), .in_eop(l1n25b_e),
        .in_ready(l1n25b_r),
        .byte_count(s_l1_25_b), .pkt_count(s_l1_25_p), .checksum(s_l1_25_c),
        .sop_count(s_l1_25_s), .eop_count(s_l1_25_e)
    );
    load_sink #(.BP_MODE(2)) sk_l1_53 ( // 25% ready
        .clk(clk), .rst_n(rst_n),
        .in_data(l1n53b_d), .in_valid(l1n53b_v), .in_sop(l1n53b_s), .in_eop(l1n53b_e),
        .in_ready(l1n53b_r),
        .byte_count(s_l1_53_b), .pkt_count(s_l1_53_p), .checksum(s_l1_53_c),
        .sop_count(s_l1_53_s), .eop_count(s_l1_53_e)
    );
    load_sink #(.BP_MODE(0)) sk_l2_25 (
        .clk(clk), .rst_n(rst_n),
        .in_data(l2n25_d), .in_valid(l2n25_v), .in_sop(l2n25_s), .in_eop(l2n25_e),
        .in_ready(l2n25_r),
        .byte_count(s_l2_25_b), .pkt_count(s_l2_25_p), .checksum(s_l2_25_c),
        .sop_count(s_l2_25_s), .eop_count(s_l2_25_e)
    );
    load_sink #(.BP_MODE(1)) sk_l2_53 (
        .clk(clk), .rst_n(rst_n),
        .in_data(l2n53b_d), .in_valid(l2n53b_v), .in_sop(l2n53b_s), .in_eop(l2n53b_e),
        .in_ready(l2n53b_r),
        .byte_count(s_l2_53_b), .pkt_count(s_l2_53_p), .checksum(s_l2_53_c),
        .sop_count(s_l2_53_s), .eop_count(s_l2_53_e)
    );
    load_sink #(.BP_MODE(0)) sk_l1x (
        .clk(clk), .rst_n(rst_n),
        .in_data(l1t5x_d), .in_valid(l1t5x_v), .in_sop(l1t5x_s), .in_eop(l1t5x_e),
        .in_ready(l1t5x_r),
        .byte_count(s_l1x_b), .pkt_count(s_l1x_p), .checksum(s_l1x_c),
        .sop_count(s_l1x_s), .eop_count(s_l1x_e)
    );
    load_sink #(.BP_MODE(0)) sk_l2x (
        .clk(clk), .rst_n(rst_n),
        .in_data(l2t5x_d), .in_valid(l2t5x_v), .in_sop(l2t5x_s), .in_eop(l2t5x_e),
        .in_ready(l2t5x_r),
        .byte_count(s_l2x_b), .pkt_count(s_l2x_p), .checksum(s_l2x_c),
        .sop_count(s_l2x_s), .eop_count(s_l2x_e)
    );

    // ---- inject stats ----
    integer inj_pkts, inj_bytes, inj_cycles, stall_cycles;
    reg     injecting;

    // Destination round-robin: 5 classes
    // 0: L1 / 0x25
    // 1: L1 / 0x53
    // 2: L2 / 0x25
    // 3: L2 / 0x53
    // 4: L3 / pass
    integer dest_idx;
    integer pay_len; // payload length in bytes (1..16)
    integer i;
    reg [7:0] layer_b, mod_b, ctrl_b, pay_b;
    reg [15:0] len_b;
    reg [31:0] exp_l1_25, exp_l1_53, exp_l2_25, exp_l2_53, exp_pass;
    reg [31:0] exp_ck_l1_25, exp_ck_l1_53, exp_ck_l2_25, exp_ck_l2_53, exp_ck_pass;
    // node stream = CTRL + LEN_LO + LEN_HI + payload + CRC_LO + CRC_HI  (no MODULE)
    // pass stream  = LAYER + MODULE + CTRL + LEN + payload + CRC          (full)
    // node bytes per pkt = 3 + pay_len + 2 = pay_len + 5
    // pass bytes per pkt = 5 + pay_len + 2 = pay_len + 7

    task inject_byte;
        input [7:0] d;
        input       sop;
        input       eop;
        begin
            // Drive on negedge; complete handshake on posedge (no double-fire).
            @(negedge clk);
            inj_data  = d;
            inj_sop   = sop;
            inj_eop   = eop;
            inj_valid = 1'b1;
            begin : wait_hs
                forever begin
                    @(posedge clk);
                    inj_cycles = inj_cycles + 1;
                    if (inj_ready) begin
                        // transfer accepted this edge
                        inj_bytes = inj_bytes + 1;
                        disable wait_hs;
                    end else
                        stall_cycles = stall_cycles + 1;
                end
            end
            @(negedge clk);
            inj_valid = 1'b0;
            inj_sop   = 1'b0;
            inj_eop   = 1'b0;
        end
    endtask

    task inject_pkt;
        input [7:0] layer;
        input [7:0] mod_id;
        input [7:0] ctrl;
        input integer plen; // 1..16
        input [7:0] seed;  // payload base
        integer k;
        reg [7:0] pb;
        reg [31:0] node_ck_add;
        reg [31:0] pass_ck_add;
        begin
            node_ck_add = 32'd0;
            pass_ck_add = 32'd0;

            // LAYER (pass path only)
            inject_byte(layer, 1'b1, 1'b0);
            pass_ck_add = pass_ck_add + {24'd0, layer};

            // MODULE (stripped before node; counted on pass only)
            inject_byte(mod_id, 1'b0, 1'b0);
            pass_ck_add = pass_ck_add + {24'd0, mod_id};

            // CTRL
            inject_byte(ctrl, 1'b0, 1'b0);
            pass_ck_add = pass_ck_add + {24'd0, ctrl};
            node_ck_add = node_ck_add + {24'd0, ctrl};

            // LEN
            inject_byte(plen[7:0], 1'b0, 1'b0);
            inject_byte(8'h00, 1'b0, 1'b0);
            pass_ck_add = pass_ck_add + {24'd0, plen[7:0]} + 32'd0;
            node_ck_add = node_ck_add + {24'd0, plen[7:0]} + 32'd0;

            for (k = 0; k < plen; k = k + 1) begin
                pb = seed + k[7:0];
                inject_byte(pb, 1'b0, 1'b0);
                pass_ck_add = pass_ck_add + {24'd0, pb};
                node_ck_add = node_ck_add + {24'd0, pb};
            end

            // CRC (fixed dummy)
            inject_byte(8'hA5, 1'b0, 1'b0);
            inject_byte(8'h5A, 1'b0, 1'b1);
            pass_ck_add = pass_ck_add + 32'h00A5 + 32'h005A;
            node_ck_add = node_ck_add + 32'h00A5 + 32'h005A;

            inj_pkts = inj_pkts + 1;

            if (layer == 8'h01 && mod_id == 8'h25) begin
                exp_l1_25    = exp_l1_25 + 1;
                exp_ck_l1_25 = exp_ck_l1_25 + node_ck_add;
            end else if (layer == 8'h01 && mod_id == 8'h53) begin
                exp_l1_53    = exp_l1_53 + 1;
                exp_ck_l1_53 = exp_ck_l1_53 + node_ck_add;
            end else if (layer == 8'h02 && mod_id == 8'h25) begin
                exp_l2_25    = exp_l2_25 + 1;
                exp_ck_l2_25 = exp_ck_l2_25 + node_ck_add;
            end else if (layer == 8'h02 && mod_id == 8'h53) begin
                exp_l2_53    = exp_l2_53 + 1;
                exp_ck_l2_53 = exp_ck_l2_53 + node_ck_add;
            end else if (layer == 8'h03) begin
                exp_pass     = exp_pass + 1;
                exp_ck_pass  = exp_ck_pass + pass_ck_add;
            end
        end
    endtask

    task check_eq;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got %0d expected %0d", name, got, exp);
                errors = errors + 1;
            end else
                $display("PASS: %0s = %0d", name, got);
        end
    endtask

    // =========================================================================
    initial begin
        inj_data = 0; inj_valid = 0; inj_sop = 0; inj_eop = 0;
        inj_pkts = 0; inj_bytes = 0; inj_cycles = 0; stall_cycles = 0;
        dest_idx = 0;
        exp_l1_25 = 0; exp_l1_53 = 0; exp_l2_25 = 0; exp_l2_53 = 0; exp_pass = 0;
        exp_ck_l1_25 = 0; exp_ck_l1_53 = 0; exp_ck_l2_25 = 0;
        exp_ck_l2_53 = 0; exp_ck_pass = 0;
        injecting = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        $display("=== LOAD TEST: 500 packets, mixed dest, backpressure ===");
        injecting = 1;

        for (i = 0; i < 500; i = i + 1) begin
            dest_idx = i % 5;
            pay_len  = 1 + (i % 16); // 1..16
            ctrl_b   = 8'h40 | (i[3:0]); // vary ctrl low nibble
            case (dest_idx)
                0: begin layer_b = 8'h01; mod_b = 8'h25; end
                1: begin layer_b = 8'h01; mod_b = 8'h53; end
                2: begin layer_b = 8'h02; mod_b = 8'h25; end
                3: begin layer_b = 8'h02; mod_b = 8'h53; end
                default: begin layer_b = 8'h03; mod_b = 8'h77; end
            endcase
            inject_pkt(layer_b, mod_b, ctrl_b, pay_len, i[7:0]);
        end

        injecting = 0;
        // drain under backpressure (25% sinks need headroom)
        repeat (20000) @(negedge clk);

        $display("");
        $display("--- Injection ---");
        $display("packets injected : %0d", inj_pkts);
        $display("bytes injected   : %0d", inj_bytes);
        $display("inject cycles    : %0d", inj_cycles);
        $display("stall cycles     : %0d", stall_cycles);
        if (inj_cycles > 0)
            $display("offer duty       : %0d%%", (100 * (inj_cycles - stall_cycles)) / inj_cycles);

        $display("");
        $display("--- Packet delivery ---");
        check_eq("L1 node 0x25 pkts", s_l1_25_p, exp_l1_25);
        check_eq("L1 node 0x53 pkts", s_l1_53_p, exp_l1_53);
        check_eq("L2 node 0x25 pkts", s_l2_25_p, exp_l2_25);
        check_eq("L2 node 0x53 pkts", s_l2_53_p, exp_l2_53);
        check_eq("spine pass pkts  ", s_pass_p,  exp_pass);

        $display("");
        $display("--- SOP/EOP integrity ---");
        check_eq("L1/25 sop==eop", s_l1_25_s, s_l1_25_e);
        check_eq("L1/53 sop==eop", s_l1_53_s, s_l1_53_e);
        check_eq("L2/25 sop==eop", s_l2_25_s, s_l2_25_e);
        check_eq("L2/53 sop==eop", s_l2_53_s, s_l2_53_e);
        check_eq("pass  sop==eop", s_pass_s,  s_pass_e);
        check_eq("L1/25 sop==pkt", s_l1_25_s, s_l1_25_p);
        check_eq("pass  sop==pkt", s_pass_s,  s_pass_p);

        $display("");
        $display("--- Checksums ---");
        check_eq("L1/25 checksum", s_l1_25_c, exp_ck_l1_25);
        check_eq("L1/53 checksum", s_l1_53_c, exp_ck_l1_53);
        check_eq("L2/25 checksum", s_l2_25_c, exp_ck_l2_25);
        check_eq("L2/53 checksum", s_l2_53_c, exp_ck_l2_53);
        check_eq("pass  checksum", s_pass_c,  exp_ck_pass);

        $display("");
        $display("--- Misroute guards (X-lane residual must be 0) ---");
        check_eq("L1 X residual pkts", s_l1x_p, 0);
        check_eq("L2 X residual pkts", s_l2x_p, 0);

        $display("");
        $display("--- Throughput snapshot ---");
        $display("L1/25 bytes=%0d pkts=%0d (50%% ready sink)", s_l1_25_b, s_l1_25_p);
        $display("L1/53 bytes=%0d pkts=%0d (25%% ready sink)", s_l1_53_b, s_l1_53_p);
        $display("L2/25 bytes=%0d pkts=%0d (100%% ready)",     s_l2_25_b, s_l2_25_p);
        $display("L2/53 bytes=%0d pkts=%0d (50%% ready)",      s_l2_53_b, s_l2_53_p);
        $display("pass  bytes=%0d pkts=%0d (100%% ready)",     s_pass_b,  s_pass_p);

        if (errors == 0)
            $display("\n*** LOAD TEST PASSED (%0d packets) ***", inj_pkts);
        else
            $display("\n*** LOAD TEST FAILED: %0d error(s) ***", errors);

        $finish;
    end

    initial begin
        #50_000_000; // 50 ms sim time watchdog
        $display("TIMEOUT under load");
        $finish;
    end

endmodule
