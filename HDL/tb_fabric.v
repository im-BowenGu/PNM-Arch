`timescale 1ns/1ps
`include "pnm_defs.vh"

// =============================================================================
// tb_fabric — self-checking test of xyz_repeater, hfr, xy_turn, node_eject
// =============================================================================

module byte_sink #(
    parameter TOGGLE = 0
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_sop,
    input  wire       in_eop,
    output reg        in_ready,
    output reg [15:0] count,
    output reg [7:0]  first,
    output reg [7:0]  second
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_ready <= 1'b1;
            count    <= 16'd0;
            first    <= 8'hxx;
            second   <= 8'hxx;
        end else begin
            if (TOGGLE)
                in_ready <= ~in_ready;
            if (in_valid && in_ready) begin
                if (count == 16'd0) first  <= in_data;
                if (count == 16'd1) second <= in_data;
                count <= count + 16'd1;
            end
        end
    end
endmodule

module tb_fabric;
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk; // 100 MHz

    integer errors = 0;

    // =========================================================================
    // SPINE: driver -> ing(L1) -> hfr -> ing(L2) -> pass_sink
    //                         \-> nob1_sink     \-> nob2_sink
    // =========================================================================
    reg  [7:0] s_data;
    reg        s_valid, s_sop, s_eop;
    wire       s_ready;

    wire [7:0] i1p_data; wire i1p_valid, i1p_sop, i1p_eop, i1p_ready;
    wire [7:0] n1_data;  wire n1_valid,  n1_sop,  n1_eop,  n1_ready;
    wire [7:0] h1_data;  wire h1_valid,  h1_sop,  h1_eop,  h1_ready;
    wire [7:0] i2p_data; wire i2p_valid, i2p_sop, i2p_eop, i2p_ready;
    wire [7:0] n2_data;  wire n2_valid,  n2_sop,  n2_eop,  n2_ready;

    wire [15:0] n1_count, n2_count, pass_count;
    wire [7:0]  n1_first, n2_first, pass_first;
    wire [7:0]  n1_second, n2_second, pass_second;

    xyz_repeater #(.LOCAL_LAYER(8'h01)) rpt1 (
        .clk(clk), .rst_n(rst_n),
        .spin_data(s_data), .spin_valid(s_valid), .spin_sop(s_sop),
        .spin_eop(s_eop), .spin_ready(s_ready),
        .spout_data(i1p_data), .spout_valid(i1p_valid), .spout_sop(i1p_sop),
        .spout_eop(i1p_eop), .spout_ready(i1p_ready),
        .nob_data(n1_data), .nob_valid(n1_valid), .nob_sop(n1_sop),
        .nob_eop(n1_eop), .nob_ready(n1_ready)
    );

    hfr h1 (
        .clk(clk), .rst_n(rst_n),
        .in_data(i1p_data), .in_valid(i1p_valid), .in_sop(i1p_sop),
        .in_eop(i1p_eop), .in_ready(i1p_ready),
        .out_data(h1_data), .out_valid(h1_valid), .out_sop(h1_sop),
        .out_eop(h1_eop), .out_ready(h1_ready)
    );

    xyz_repeater #(.LOCAL_LAYER(8'h02)) rpt2 (
        .clk(clk), .rst_n(rst_n),
        .spin_data(h1_data), .spin_valid(h1_valid), .spin_sop(h1_sop),
        .spin_eop(h1_eop), .spin_ready(h1_ready),
        .spout_data(i2p_data), .spout_valid(i2p_valid), .spout_sop(i2p_sop),
        .spout_eop(i2p_eop), .spout_ready(i2p_ready),
        .nob_data(n2_data), .nob_valid(n2_valid), .nob_sop(n2_sop),
        .nob_eop(n2_eop), .nob_ready(n2_ready)
    );

    byte_sink #(.TOGGLE(0)) snk_n1 (
        .clk(clk), .rst_n(rst_n),
        .in_data(n1_data), .in_valid(n1_valid), .in_sop(n1_sop),
        .in_eop(n1_eop), .in_ready(n1_ready),
        .count(n1_count), .first(n1_first), .second(n1_second)
    );
    byte_sink #(.TOGGLE(0)) snk_n2 (
        .clk(clk), .rst_n(rst_n),
        .in_data(n2_data), .in_valid(n2_valid), .in_sop(n2_sop),
        .in_eop(n2_eop), .in_ready(n2_ready),
        .count(n2_count), .first(n2_first), .second(n2_second)
    );
    byte_sink #(.TOGGLE(0)) snk_pass (
        .clk(clk), .rst_n(rst_n),
        .in_data(i2p_data), .in_valid(i2p_valid), .in_sop(i2p_sop),
        .in_eop(i2p_eop), .in_ready(i2p_ready),
        .count(pass_count), .first(pass_first), .second(pass_second)
    );

    // =========================================================================
    // BOARD: driver_b -> turn(X=2) -> hfr -> turn(X=5) -> x_sink
    //                    \-> eject(0x25) -> node_sink
    //                                      \-> y5_sink (toggle ready)
    // =========================================================================
    reg  [7:0] b_data;
    reg        b_valid, b_sop, b_eop;
    wire       b_ready;

    wire [7:0] t2x_data; wire t2x_valid, t2x_sop, t2x_eop, t2x_ready;
    wire [7:0] t2y_data; wire t2y_valid, t2y_sop, t2y_eop, t2y_ready;
    wire [7:0] hb_data;  wire hb_valid,  hb_sop,  hb_eop,  hb_ready;
    wire [7:0] t5x_data; wire t5x_valid, t5x_sop, t5x_eop, t5x_ready;
    wire [7:0] t5y_data; wire t5y_valid, t5y_sop, t5y_eop, t5y_ready;
    wire [7:0] ej_y_data; wire ej_y_valid, ej_y_sop, ej_y_eop, ej_y_ready;
    wire [7:0] nd_data;   wire nd_valid,   nd_sop,   nd_eop,   nd_ready;

    wire [15:0] node_count, y5_count, x_count;
    wire [7:0]  node_first, y5_first, x_first;
    wire [7:0]  node_second, y5_second, x_second;

    xy_turn #(.LOCAL_X(4'h2)) turn2 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(b_data), .xin_valid(b_valid), .xin_sop(b_sop),
        .xin_eop(b_eop), .xin_ready(b_ready),
        .xout_data(t2x_data), .xout_valid(t2x_valid), .xout_sop(t2x_sop),
        .xout_eop(t2x_eop), .xout_ready(t2x_ready),
        .yout_data(t2y_data), .yout_valid(t2y_valid), .yout_sop(t2y_sop),
        .yout_eop(t2y_eop), .yout_ready(t2y_ready)
    );

    node_eject #(.LOCAL_MODULE(8'h25)) eject25 (
        .clk(clk), .rst_n(rst_n),
        .yin_data(t2y_data), .yin_valid(t2y_valid), .yin_sop(t2y_sop),
        .yin_eop(t2y_eop), .yin_ready(t2y_ready),
        .yout_data(ej_y_data), .yout_valid(ej_y_valid), .yout_sop(ej_y_sop),
        .yout_eop(ej_y_eop), .yout_ready(ej_y_ready),
        .node_data(nd_data), .node_valid(nd_valid), .node_sop(nd_sop),
        .node_eop(nd_eop), .node_ready(nd_ready)
    );

    // unused Y-pass after eject: drain
    assign ej_y_ready = 1'b1;

    hfr hb (
        .clk(clk), .rst_n(rst_n),
        .in_data(t2x_data), .in_valid(t2x_valid), .in_sop(t2x_sop),
        .in_eop(t2x_eop), .in_ready(t2x_ready),
        .out_data(hb_data), .out_valid(hb_valid), .out_sop(hb_sop),
        .out_eop(hb_eop), .out_ready(hb_ready)
    );

    xy_turn #(.LOCAL_X(4'h5)) turn5 (
        .clk(clk), .rst_n(rst_n),
        .xin_data(hb_data), .xin_valid(hb_valid), .xin_sop(hb_sop),
        .xin_eop(hb_eop), .xin_ready(hb_ready),
        .xout_data(t5x_data), .xout_valid(t5x_valid), .xout_sop(t5x_sop),
        .xout_eop(t5x_eop), .xout_ready(t5x_ready),
        .yout_data(t5y_data), .yout_valid(t5y_valid), .yout_sop(t5y_sop),
        .yout_eop(t5y_eop), .yout_ready(t5y_ready)
    );

    byte_sink #(.TOGGLE(0)) snk_node (
        .clk(clk), .rst_n(rst_n),
        .in_data(nd_data), .in_valid(nd_valid), .in_sop(nd_sop),
        .in_eop(nd_eop), .in_ready(nd_ready),
        .count(node_count), .first(node_first), .second(node_second)
    );
    byte_sink #(.TOGGLE(1)) snk_y5 (
        .clk(clk), .rst_n(rst_n),
        .in_data(t5y_data), .in_valid(t5y_valid), .in_sop(t5y_sop),
        .in_eop(t5y_eop), .in_ready(t5y_ready),
        .count(y5_count), .first(y5_first), .second(y5_second)
    );
    byte_sink #(.TOGGLE(0)) snk_x (
        .clk(clk), .rst_n(rst_n),
        .in_data(t5x_data), .in_valid(t5x_valid), .in_sop(t5x_sop),
        .in_eop(t5x_eop), .in_ready(t5x_ready),
        .count(x_count), .first(x_first), .second(x_second)
    );

    // =========================================================================
    // Drivers
    // =========================================================================
    task send_s;
        input [7:0] d;
        input       sop;
        input       eop;
        begin
            @(negedge clk);
            s_data  = d;
            s_sop   = sop;
            s_eop   = eop;
            s_valid = 1'b1;
            begin : wait_s
                forever begin
                    @(negedge clk);
                    if (s_ready) disable wait_s;
                end
            end
            s_valid = 1'b0;
            s_sop   = 1'b0;
            s_eop   = 1'b0;
        end
    endtask

    task send_b;
        input [7:0] d;
        input       sop;
        input       eop;
        begin
            @(negedge clk);
            b_data  = d;
            b_sop   = sop;
            b_eop   = eop;
            b_valid = 1'b1;
            begin : wait_b
                forever begin
                    @(negedge clk);
                    if (b_ready) disable wait_b;
                end
            end
            b_valid = 1'b0;
            b_sop   = 1'b0;
            b_eop   = 1'b0;
        end
    endtask

    // Full spine packet: LAYER, MODULE, CTRL, LEN_LO, LEN_HI, payload..., CRC_LO, CRC_HI
    task send_spine_pkt;
        input [7:0] layer;
        input [7:0] mod_id;
        input [7:0] ctrl;
        input [7:0] pay0;
        input [7:0] pay1;
        begin
            send_s(layer,  1'b1, 1'b0);
            send_s(mod_id, 1'b0, 1'b0);
            send_s(ctrl,   1'b0, 1'b0);
            send_s(8'h02,  1'b0, 1'b0); // LEN_LO = 2
            send_s(8'h00,  1'b0, 1'b0); // LEN_HI
            send_s(pay0,   1'b0, 1'b0);
            send_s(pay1,   1'b0, 1'b0);
            send_s(8'h0D,  1'b0, 1'b0); // CRC_LO
            send_s(8'h0C,  1'b0, 1'b1); // CRC_HI + EOP
        end
    endtask

    // Board packet (post-ingress): MODULE is head
    task send_board_pkt;
        input [7:0] mod_id;
        input [7:0] ctrl;
        input [7:0] pay0;
        begin
            send_b(mod_id, 1'b1, 1'b0);
            send_b(ctrl,   1'b0, 1'b0);
            send_b(8'h01,  1'b0, 1'b0); // LEN_LO = 1
            send_b(8'h00,  1'b0, 1'b0); // LEN_HI
            send_b(pay0,   1'b0, 1'b0);
            send_b(8'h0D,  1'b0, 1'b0);
            send_b(8'h0C,  1'b0, 1'b1);
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
            end else begin
                $display("PASS: %0s = %0d", name, got);
            end
        end
    endtask

    task check_hex;
        input [255:0] name;
        input [7:0]   got;
        input [7:0]   exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s = 0x%02h", name, got);
            end
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        s_data  = 8'h00; s_valid = 1'b0; s_sop = 1'b0; s_eop = 1'b0;
        b_data  = 8'h00; b_valid = 1'b0; b_sop = 1'b0; b_eop = 1'b0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("=== SPINE TEST ===");
        // Packet A: layer=2 -> nob2 (stripped: 8 bytes, first=MODULE 0x35)
        send_spine_pkt(8'h02, 8'h35, 8'h40, 8'hAA, 8'hBB);
        // Packet B: layer=3 -> pass (full 9 bytes, first=LAYER 0x03)
        send_spine_pkt(8'h03, 8'h77, 8'h40, 8'hCC, 8'hDD);

        // drain
        repeat (20) @(negedge clk);

        check_eq("spine n1_count", n1_count, 0);
        check_eq("spine n2_count", n2_count, 8);
        check_eq("spine pass_count", pass_count, 9);
        check_hex("spine n2_first (MODULE)", n2_first, 8'h35);
        check_hex("spine n2_second (CTRL)", n2_second, 8'h40);
        check_hex("spine pass_first (LAYER)", pass_first, 8'h03);

        $display("=== BOARD TEST ===");
        // Packet C: module 0x25 (X=2,Y=5) -> turn2 -> eject25 -> node
        // (7 bytes, first=MODULE forwarded as DEST, Paper §2.10)
        send_board_pkt(8'h25, 8'h80, 8'h5A);
        // Packet D: module 0x53 (X=5,Y=3) -> pass turn2 -> turn5 -> y5 (7 bytes, first=MODULE)
        send_board_pkt(8'h53, 8'h80, 8'h6B);

        // drain (toggle-ready sink needs extra cycles)
        repeat (60) @(negedge clk);

        check_eq("board node_count", node_count, 7);
        check_eq("board y5_count", y5_count, 7);
        check_eq("board x_count", x_count, 0);
        check_hex("board node_first (MODULE)", node_first, 8'h25);
        check_hex("board node_second (CTRL)", node_second, 8'h80);
        check_hex("board y5_first (MODULE)", y5_first, 8'h53);

        if (errors == 0)
            $display("\n*** ALL TESTS PASSED ***");
        else
            $display("\n*** %0d TEST(S) FAILED ***", errors);

        $finish;
    end

    // watchdog
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
