`include "pnm_defs.vh"
`timescale 1ns/1ps

// =============================================================================
// tb_expert_loop — end-to-end expert dispatch loop on real RTL
//
// Simulates the full "extract gating, route to expert node, load weights,
// reason, store output, unload, next token" loop at 100 MHz, cycle-exact,
// with NO router chip, NO POST, and NO Go orchestrator:
//
//   1. A ram_phy_stub holds a chunk of host RAM (gating weights, per-expert
//      node weight matrices, per-token hidden states, output store).
//   2. A boot loader streams the 16x64 gating weights out of the RAM stub
//      into moe_gating's weight port (holding the expert->{layer,module}
//      coordinate map stable per 64-word row).
//   3. Per token k: moe_gating bursts hidden words out of the RAM stub
//      (tolerating the stub's read latency) and computes the 16 BF16
//      logits with its internal bf16_fma (3-cycle), then picks top-K.
//   4. The top-1 expert's flit is built with a TB CRC-16/CCITT-FALSE FSM and
//      injected byte-serial into the REAL fabric: lxy_repeater (strips
//      LAYER_ID, VC 2->3) -> xy_turn (matches X nibble) -> node_eject chain
//      (matches full MODULE_ID) -> doorbell (DEST/CRC/framing validation).
//   5. The visited node's controller loads its 256-word BF16 matrix from the
//      RAM stub into a bf16_mac_array, feeds the token's 16-word activation,
//      captures the array result, stores it to the RAM stub output region,
//      then unloads the array via 256 zero-fill weight writes.
//   6. Repeat for the next token; a final $display emits the decoded response.
//
// Synthetic data scheme (BF16-exact; all integers <= 256 are exact):
//   gating_w[e][i] = 1.0 (0x3F80) except gating_w[e][e] = 2.0 (0x4000)
//   hidden_k[i]    = 1.0 (0x3F80) except hidden_k[k] = 3.0 (0x4040)
//   => logit[k] = 63*1 + 2*3 = 69.0 (0x428A); every other expert = 67.0 (0x4286)
//   Expert e node matrix: W_e = (e+1) * I_16   (diagonal scale)
//   node result[j] = (e+1) * hidden_first16[j]
//
// RAM map (single ram_phy_stub, DEPTH=16384):
//   0x0000..0x03FF gating weights   (16 experts x 64)
//   0x0800..0x17FF expert matrices  (3 x 256)  [EXPERT_W_BASE = 2048]
//   0x1800..0x18BF hidden vectors   (3 x 64)   [HIDDEN_BASE  = 6144]
//   0x2000..0x204F output store     (3 x 16)   [OUTPUT_BASE  = 8192]
//
// Compile (from HDL/):
//   iverilog -g2005 -I. -o /tmp/expert_loop.vvp tb_expert_loop.v \
//     core/ram_phy_stub.v core/moe_gating.v core/bf16_mac_array.v \
//     core/bf16_fma.v core/crc16.v core/doorbell.v \
//     flit_gate.v hfr.v xy_turn.v node_eject.v lxy_repeater.v vc_merge.v
//   vvp /tmp/expert_loop.vvp
// =============================================================================

module tb_expert_loop;

    // ---------------------------------------------------------------------
    // Clock / reset / watchdog
    // ---------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;              // 100 MHz

    reg rst_n = 0;
    integer cycle = 0;
    always @(posedge clk) cycle = cycle + 1;

    initial begin
        $dumpfile("/tmp/expert_loop.vcd");
        // Targeted dump: fabric + sequencer + doorbell signals only (the
        // 87K-var full-hierarchy dump includes every RAM word and made the
        // run crawl; these ~40 vars are all the visualizer needs).
        $dumpvars(0,
            tb_expert_loop.clk, tb_expert_loop.rst_n, tb_expert_loop.cycle,
            tb_expert_loop.t_state, tb_expert_loop.ram_phase, tb_expert_loop.tok,
            tb_expert_loop.boot_done, tb_expert_loop.gate_done, tb_expert_loop.gate_start,
            tb_expert_loop.gate_hidden_valid, tb_expert_loop.gate_module_packed,
            tb_expert_loop.gate_idx_packed, tb_expert_loop.gate_logit_packed,
            tb_expert_loop.token_done[0], tb_expert_loop.token_done[1], tb_expert_loop.token_done[2],
            tb_expert_loop.node_done[0], tb_expert_loop.node_done[1], tb_expert_loop.node_done[2],
            tb_expert_loop.spin_data, tb_expert_loop.spin_valid, tb_expert_loop.spin_sop,
            tb_expert_loop.spin_eop, tb_expert_loop.spin_vc, tb_expert_loop.spin_ready,
            tb_expert_loop.nob_data, tb_expert_loop.nob_valid, tb_expert_loop.nob_sop,
            tb_expert_loop.nob_eop, tb_expert_loop.nob_vc,
            tb_expert_loop.y0_data, tb_expert_loop.y0_valid, tb_expert_loop.y0_sop,
            tb_expert_loop.y0_eop, tb_expert_loop.y0_vc,
            tb_expert_loop.n0_data, tb_expert_loop.n0_valid, tb_expert_loop.n0_sop,
            tb_expert_loop.n0_eop, tb_expert_loop.n0_vc,
            tb_expert_loop.db0_fire, tb_expert_loop.db0_ack, tb_expert_loop.db0_activations,
            tb_expert_loop.db0_rejections, tb_expert_loop.db1_fire, tb_expert_loop.db1_activations,
            tb_expert_loop.db1_rejections, tb_expert_loop.db2_fire, tb_expert_loop.db2_activations,
            tb_expert_loop.db2_rejections,
            tb_expert_loop.m0_act_valid, tb_expert_loop.m0_result_valid, tb_expert_loop.m0_busy,
            tb_expert_loop.m1_act_valid, tb_expert_loop.m1_result_valid, tb_expert_loop.m1_busy,
            tb_expert_loop.m2_act_valid, tb_expert_loop.m2_result_valid, tb_expert_loop.m2_busy,
            tb_expert_loop.spout_ready, tb_expert_loop.nob_up_ready, tb_expert_loop.spup_ready,
            tb_expert_loop.xin_ready, tb_expert_loop.xout_ready,
            tb_expert_loop.y0_ready, tb_expert_loop.y1_ready, tb_expert_loop.y2_ready,
            tb_expert_loop.yres_vready, tb_expert_loop.n0_ready, tb_expert_loop.n1_ready,
            tb_expert_loop.n2_ready, tb_expert_loop.db0_ready, tb_expert_loop.db1_ready,
            tb_expert_loop.db2_ready);
        // reset is DEASSERTED by the preload initial block after the RAM
        // preload completes (see below) — do not deassert here.
        // watchdog: 8 ms of simulated time is far beyond the ~200 us budget
        #8_000_000;
        $display("*** WATCHDOG TIMEOUT ***");
        $finish;
    end

    // ---------------------------------------------------------------------
    // RAM stub instance (the single host-RAM chunk)
    // ---------------------------------------------------------------------
    localparam DEPTH     = 16384;
    localparam ADDR_W    = 14;
    localparam RDLAT     = 4;

    reg  [ADDR_W-1:0] ram_rd_addr;
    reg               ram_rd_req;
    wire [15:0]       ram_rd_data;
    wire              ram_rd_valid;
    wire [ADDR_W-1:0] ram_wr_addr;
    wire              ram_wr_en;
    wire [15:0]       ram_wr_data;

    // Write-port mux: the preload initial block owns the write port while
    // the chip is still in reset (rst_n==0); once reset deasserts, the node
    // controllers' output-store writes take over.
    reg               pre_wr_en;
    reg  [ADDR_W-1:0] pre_wr_addr;
    reg  [15:0]       pre_wr_data;
    reg               nc_wr_en;
    reg  [ADDR_W-1:0] nc_wr_addr;
    reg  [15:0]       nc_wr_data;
    assign ram_wr_en   = (rst_n == 1'b0) ? pre_wr_en   : nc_wr_en;
    assign ram_wr_addr = (rst_n == 1'b0) ? pre_wr_addr : nc_wr_addr;
    assign ram_wr_data = (rst_n == 1'b0) ? pre_wr_data : nc_wr_data;

    ram_phy_stub #(
        .DEPTH        (DEPTH),
        .ADDR_W       (ADDR_W),
        .READ_LATENCY (RDLAT)
    ) u_ram (
        .clk      (clk),
        .rst_n    (rst_n),
        .rd_addr  (ram_rd_addr),
        .rd_req   (ram_rd_req),
        .rd_data  (ram_rd_data),
        .rd_valid (ram_rd_valid),
        .wr_addr  (ram_wr_addr),
        .wr_en    (ram_wr_en),
        .wr_data  (ram_wr_data)
    );

    localparam GATING_W_BASE = 0;      // 16 x 64 = 1024 words
    localparam EXPERT_W_BASE = 2048;   // 3 x 256 = 768 words
    localparam HIDDEN_BASE   = 6144;   // 3 x 64  = 192 words
    localparam OUTPUT_BASE   = 8192;   // 3 x 16  = 48 words

    // ---------------------------------------------------------------------
    // RAM read-port arbiter: boot loader / gating hidden feed / node
    // controllers / final readback are strictly sequential, so a phase
    // mux suffices.
    // ---------------------------------------------------------------------
    localparam PH_BOOT      = 3'd0;
    localparam PH_GATE      = 3'd1;
    localparam PH_NODE      = 3'd2;
    localparam PH_READBACK  = 3'd3;
    localparam PH_IDLE      = 3'd4;

    reg [2:0] ram_phase = PH_BOOT;

    // boot-loader read request
    reg               boot_rd_req;
    reg  [ADDR_W-1:0] boot_rd_addr;

    // gating hidden feed read request
    reg               gate_rd_req;
    reg  [ADDR_W-1:0] gate_rd_addr;

    // node controller read request (shared by the three visited nodes)
    reg               node_rd_req;
    reg  [ADDR_W-1:0] node_rd_addr;

    // final readback read request
    reg               readback_rd_req;
    reg  [ADDR_W-1:0] readback_rd_addr;

    always @(*) begin
        case (ram_phase)
            PH_BOOT: begin
                ram_rd_req  = boot_rd_req;
                ram_rd_addr = boot_rd_addr;
            end
            PH_GATE: begin
                ram_rd_req  = gate_rd_req;
                ram_rd_addr = gate_rd_addr;
            end
            PH_NODE: begin
                ram_rd_req  = node_rd_req;
                ram_rd_addr = node_rd_addr;
            end
            PH_READBACK: begin
                ram_rd_req  = readback_rd_req;
                ram_rd_addr = readback_rd_addr;
            end
            default: begin
                ram_rd_req  = 1'b0;
                ram_rd_addr = {ADDR_W{1'b0}};
            end
        endcase
    end

    // =========================================================================
    //  moe_gating
    // =========================================================================
    reg        gate_start;
    wire       gate_done;
    wire [9:0] gate_hidden_addr;
    reg  [15:0] gate_hidden_data;
    reg        gate_hidden_valid;
    reg        gate_weight_load;
    reg  [9:0] gate_weight_addr;
    reg  [15:0] gate_weight_data;
    reg  [7:0] gate_moe_layer_in;
    reg  [7:0] gate_moe_module_in;
    wire [31:0] gate_idx_packed;
    wire [63:0] gate_logit_packed;
    wire [31:0] gate_layer_packed;
    wire [31:0] gate_module_packed;

    moe_gating #(
        .NUM_EXPERTS (16),
        .HIDDEN_DIM  (64),
        .TOP_K       (4),
        .ADDR_BITS   (10)
    ) u_gate (
        .clk                  (clk),
        .rst_n                (rst_n),
        .start                (gate_start),
        .done                 (gate_done),
        .hidden_addr          (gate_hidden_addr),
        .hidden_data          (gate_hidden_data),
        .hidden_valid         (gate_hidden_valid),
        .weight_load          (gate_weight_load),
        .weight_addr          (gate_weight_addr),
        .weight_data          (gate_weight_data),
        .current_layer        (8'd1),
        .moe_layer_in         (gate_moe_layer_in),
        .moe_module_in        (gate_moe_module_in),
        .expert_idx_packed    (gate_idx_packed),
        .expert_logit_packed  (gate_logit_packed),
        .expert_layer_packed  (gate_layer_packed),
        .expert_module_packed (gate_module_packed),
        .fma_busy             ()
    );

    // =========================================================================
    //  Fabric: lxy_repeater -> (spout to sink) + (nob -> board)
    // =========================================================================
    reg  [7:0]  spin_data;
    reg         spin_valid;
    reg         spin_sop;
    reg         spin_eop;
    wire        spin_ready;
    reg  [1:0]  spin_vc;

    wire [7:0]  spout_data;
    wire        spout_valid;
    wire        spout_sop;
    wire        spout_eop;
    wire        spout_ready;
    wire [1:0]  spout_vc;

    wire [7:0]  nob_data;
    wire        nob_valid;
    wire        nob_sop;
    wire        nob_eop;
    wire        nob_ready;
    wire [1:0]  nob_vc;

    wire [7:0]  nob_up_data = 8'h00;
    wire        nob_up_valid = 1'b0;
    wire        nob_up_sop  = 1'b0;
    wire        nob_up_eop  = 1'b0;
    wire        nob_up_ready;
    wire [1:0]  nob_up_vc   = 2'b00;

    wire [7:0]  spup_in_data = 8'h00;
    wire        spup_in_valid = 1'b0;
    wire        spup_in_sop  = 1'b0;
    wire        spup_in_eop  = 1'b0;
    wire        spup_in_ready;
    wire [1:0]  spup_in_vc   = 2'b00;

    wire [7:0]  spup_data;
    wire        spup_valid;
    wire        spup_sop;
    wire        spup_eop;
    wire        spup_ready;
    wire [1:0]  spup_vc;

    lxy_repeater u_lxy (
        .clk          (clk),
        .rst_n        (rst_n),
        .route_bitmap (11'h080),               // layer 1, X axis, +, dist 0
        .spin_data    (spin_data),
        .spin_valid   (spin_valid),
        .spin_sop     (spin_sop),
        .spin_eop     (spin_eop),
        .spin_ready   (spin_ready),
        .spin_vc      (spin_vc),
        .spout_data   (spout_data),
        .spout_valid  (spout_valid),
        .spout_sop    (spout_sop),
        .spout_eop    (spout_eop),
        .spout_ready  (spout_ready),
        .spout_vc     (spout_vc),
        .nob_data     (nob_data),
        .nob_valid    (nob_valid),
        .nob_sop      (nob_sop),
        .nob_eop      (nob_eop),
        .nob_ready    (nob_ready),
        .nob_vc       (nob_vc),
        .nob_up_data  (nob_up_data),
        .nob_up_valid (nob_up_valid),
        .nob_up_sop   (nob_up_sop),
        .nob_up_eop   (nob_up_eop),
        .nob_up_ready (nob_up_ready),
        .nob_up_vc    (nob_up_vc),
        .spup_in_data (spup_in_data),
        .spup_in_valid(spup_in_valid),
        .spup_in_sop  (spup_in_sop),
        .spup_in_eop  (spup_in_eop),
        .spup_in_ready(spup_in_ready),
        .spup_in_vc   (spup_in_vc),
        .spup_data    (spup_data),
        .spup_valid   (spup_valid),
        .spup_sop     (spup_sop),
        .spup_eop     (spup_eop),
        .spup_ready   (spup_ready),
        .spup_vc      (spup_vc)
    );

    assign spout_ready = 1'b1;   // spine tail sink
    assign spup_ready  = 1'b1;   // up-spine sink

    // down-spine tail: same flit also feeds an hfr + sink (per reference
    // chassis the spout path must not stall; the flit is matched at the
    // lxy_repeater so the spout path carries nothing for our packets)
    wire [7:0]  tail_data;
    wire        tail_valid, tail_sop, tail_eop, tail_ready;
    wire [1:0]  tail_vc;
    hfr u_tail_hfr (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_data      (spout_data),
        .in_valid     (spout_valid),
        .in_sop       (spout_sop),
        .in_eop       (spout_eop),
        .in_ready     (spout_ready),
        .in_vc        (spout_vc),
        .out_data     (tail_data),
        .out_valid    (tail_valid),
        .out_sop      (tail_sop),
        .out_eop      (tail_eop),
        .out_ready    (tail_ready),
        .out_vc       (tail_vc),
        .route_bitmap (11'h080),
        .layer_match  ()
    );
    assign tail_ready = 1'b1;

    // ---------------------------------------------------------------------
    // Board: nob -> xy_turn #(LOCAL_X=0) -> Y-lane node_eject chain
    // ---------------------------------------------------------------------
    wire [7:0]  xin_data = nob_data;
    wire        xin_valid = nob_valid;
    wire        xin_sop   = nob_sop;
    wire        xin_eop   = nob_eop;
    wire        xin_ready;
    wire [1:0]  xin_vc    = nob_vc;
    assign nob_ready = xin_ready;   // board's ready looped back to the lxy match port

    wire [7:0]  xout_data;
    wire        xout_valid, xout_sop, xout_eop, xout_ready;
    wire [1:0]  xout_vc;

    wire [7:0]  y0_data;
    wire        y0_valid, y0_sop, y0_eop, y0_ready;
    wire [1:0]  y0_vc;

    xy_turn #(.LOCAL_X(4'h0)) u_xy (
        .clk       (clk),
        .rst_n     (rst_n),
        .xin_data  (xin_data),
        .xin_valid (xin_valid),
        .xin_sop   (xin_sop),
        .xin_eop   (xin_eop),
        .xin_ready (xin_ready),
        .xin_vc    (xin_vc),
        .xout_data (xout_data),
        .xout_valid(xout_valid),
        .xout_sop  (xout_sop),
        .xout_eop  (xout_eop),
        .xout_ready(xout_ready),
        .xout_vc   (xout_vc),
        .yout_data (y0_data),
        .yout_valid(y0_valid),
        .yout_sop  (y0_sop),
        .yout_eop  (y0_eop),
        .yout_ready(y0_ready),
        .yout_vc   (y0_vc)
    );
    assign xout_ready = 1'b1;   // X-lane sink (no board beyond X=0)

    // ---------------------------------------------------------------------
    // Three visited nodes: node_eject 0x00 -> 0x01 -> 0x02 -> yres sink
    // ---------------------------------------------------------------------
    wire [7:0]  y1_data, y2_data, yres_data;
    wire        y1_valid, y2_valid, yres_valid;
    wire        y1_sop,   y2_sop,   yres_sop;
    wire        y1_eop,   y2_eop,   yres_eop;
    wire        y1_ready, y2_ready, yres_vready;
    wire [1:0]  y1_vc, y2_vc, yres_vc;

    // ---- node_eject 0x00 ----
    wire [7:0]  n0_data; wire n0_valid, n0_sop, n0_eop, n0_ready; wire [1:0] n0_vc;
    assign n0_ready = db0_ready;   // doorbell s_ready (always 1) back to ejector
    node_eject #(.LOCAL_MODULE(8'h00)) u_ej0 (
        .clk        (clk), .rst_n (rst_n),
        .yin_data   (y0_data),  .yin_valid (y0_valid),
        .yin_sop    (y0_sop),   .yin_eop   (y0_eop),
        .yin_ready  (y0_ready), .yin_vc    (y0_vc),
        .yout_data  (y1_data),  .yout_valid(y1_valid),
        .yout_sop   (y1_sop),   .yout_eop  (y1_eop),
        .yout_ready (y1_ready), .yout_vc   (y1_vc),
        .node_data  (n0_data),  .node_valid(n0_valid),
        .node_sop   (n0_sop),   .node_eop  (n0_eop),
        .node_ready (n0_ready), .node_vc   (n0_vc)
    );

    // ---- node_eject 0x01 ----
    wire [7:0]  n1_data; wire n1_valid, n1_sop, n1_eop, n1_ready; wire [1:0] n1_vc;
    assign n1_ready = db1_ready;   // doorbell s_ready back to ejector
    node_eject #(.LOCAL_MODULE(8'h01)) u_ej1 (
        .clk        (clk), .rst_n (rst_n),
        .yin_data   (y1_data),  .yin_valid (y1_valid),
        .yin_sop    (y1_sop),   .yin_eop   (y1_eop),
        .yin_ready  (y1_ready), .yin_vc    (y1_vc),
        .yout_data  (y2_data),  .yout_valid(y2_valid),
        .yout_sop   (y2_sop),   .yout_eop  (y2_eop),
        .yout_ready (y2_ready), .yout_vc   (y2_vc),
        .node_data  (n1_data),  .node_valid(n1_valid),
        .node_sop   (n1_sop),   .node_eop  (n1_eop),
        .node_ready (n1_ready), .node_vc   (n1_vc)
    );

    // ---- node_eject 0x02 ----
    wire [7:0]  n2_data; wire n2_valid, n2_sop, n2_eop, n2_ready; wire [1:0] n2_vc;
    assign n2_ready = db2_ready;   // doorbell s_ready back to ejector
    node_eject #(.LOCAL_MODULE(8'h02)) u_ej2 (
        .clk        (clk), .rst_n (rst_n),
        .yin_data   (y2_data),  .yin_valid (y2_valid),
        .yin_sop    (y2_sop),   .yin_eop   (y2_eop),
        .yin_ready  (y2_ready), .yin_vc    (y2_vc),
        .yout_data  (yres_data), .yout_valid(yres_valid),
        .yout_sop   (yres_sop),  .yout_eop  (yres_eop),
        .yout_ready (yres_vready), .yout_vc (yres_vc),
        .node_data  (n2_data),  .node_valid(n2_valid),
        .node_sop   (n2_sop),   .node_eop  (n2_eop),
        .node_ready (n2_ready), .node_vc   (n2_vc)
    );
    assign yres_vready = 1'b1;  // Y-lane sink after the last node

    // ---------------------------------------------------------------------
    // node controllers 0..2: doorbell + bf16_mac_array, with nodes wired
    // to the RAM stub read port via the node_rd_* mux and FSM per node
    // ---------------------------------------------------------------------

    // ---- node 0 (expert 0: W = 1*I) ----
    wire [7:0]  db0_data = n0_data;
    wire        db0_valid = n0_valid;
    wire        db0_eop   = n0_eop;
    wire        db0_sop;
    assign db0_sop = n0_sop;
    wire        db0_ready;
    wire [1:0]  db0_vc;
    assign db0_vc = n0_vc;
    wire        db0_fire;
    wire        db0_ack;
    wire        db0_node_err;
    wire [31:0] db0_activations;
    wire [31:0] db0_rejections;

    doorbell #(.LOCAL_MODULE(8'h00)) u_db0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_data     (db0_data),
        .s_valid    (db0_valid),
        .s_ready    (db0_ready),
        .s_eop      (db0_eop),
        .fire       (db0_fire),
        .ack        (db0_ack),
        .node_err   (db0_node_err),
        .activations(db0_activations),
        .rejections (db0_rejections)
    );

    reg  [255:0] m0_act_in;
    reg          m0_act_valid, m0_act_sop, m0_act_eop;
    reg  [15:0]  m0_weight_in;
    reg          m0_weight_load;
    reg  [7:0]   m0_weight_row, m0_weight_col;
    wire [255:0] m0_result_out;
    wire         m0_result_valid;
    wire         m0_result_sop, m0_result_eop;
    wire         m0_busy;

    bf16_mac_array #(.ARRAY_SIZE(16), .PIPE_DEPTH(3)) u_mac0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .act_in      (m0_act_in),
        .act_valid   (m0_act_valid),
        .act_sop     (m0_act_sop),
        .act_eop     (m0_act_eop),
        .weight_in   (m0_weight_in),
        .weight_load (m0_weight_load),
        .weight_row  (m0_weight_row),
        .weight_col  (m0_weight_col),
        .result_out  (m0_result_out),
        .result_valid(m0_result_valid),
        .result_sop  (m0_result_sop),
        .result_eop  (m0_result_eop),
        .busy        (m0_busy)
    );

    // ---- node 1 (expert 1: W = 2*I) ----
    wire [7:0]  db1_data = n1_data;
    wire        db1_valid = n1_valid;
    wire        db1_eop   = n1_eop;
    wire        db1_sop = n1_sop;
    wire        db1_ready;
    wire [1:0]  db1_vc = n1_vc;
    wire        db1_fire, db1_ack, db1_node_err;
    wire [31:0] db1_activations, db1_rejections;

    doorbell #(.LOCAL_MODULE(8'h01)) u_db1 (
        .clk        (clk), .rst_n (rst_n),
        .s_data     (db1_data), .s_valid (db1_valid),
        .s_ready    (db1_ready), .s_eop   (db1_eop),
        .fire       (db1_fire), .ack (db1_ack),
        .node_err   (db1_node_err),
        .activations(db1_activations),
        .rejections (db1_rejections)
    );

    reg  [255:0] m1_act_in;
    reg          m1_act_valid, m1_act_sop, m1_act_eop;
    reg  [15:0]  m1_weight_in;
    reg          m1_weight_load;
    reg  [7:0]   m1_weight_row, m1_weight_col;
    wire [255:0] m1_result_out;
    wire         m1_result_valid;
    wire         m1_result_sop, m1_result_eop;
    wire         m1_busy;

    bf16_mac_array #(.ARRAY_SIZE(16), .PIPE_DEPTH(3)) u_mac1 (
        .clk         (clk), .rst_n (rst_n),
        .act_in      (m1_act_in), .act_valid (m1_act_valid),
        .act_sop     (m1_act_sop), .act_eop   (m1_act_eop),
        .weight_in   (m1_weight_in), .weight_load (m1_weight_load),
        .weight_row  (m1_weight_row), .weight_col (m1_weight_col),
        .result_out  (m1_result_out), .result_valid (m1_result_valid),
        .result_sop  (m1_result_sop), .result_eop   (m1_result_eop),
        .busy        (m1_busy)
    );

    // ---- node 2 (expert 2: W = 3*I) ----
    wire [7:0]  db2_data = n2_data;
    wire        db2_valid = n2_valid;
    wire        db2_eop   = n2_eop;
    wire        db2_sop = n2_sop;
    wire        db2_ready;
    wire [1:0]  db2_vc = n2_vc;
    wire        db2_fire, db2_ack, db2_node_err;
    wire [31:0] db2_activations, db2_rejections;

    doorbell #(.LOCAL_MODULE(8'h02)) u_db2 (
        .clk        (clk), .rst_n (rst_n),
        .s_data     (db2_data), .s_valid (db2_valid),
        .s_ready    (db2_ready), .s_eop   (db2_eop),
        .fire       (db2_fire), .ack (db2_ack),
        .node_err   (db2_node_err),
        .activations(db2_activations),
        .rejections (db2_rejections)
    );

    reg  [255:0] m2_act_in;
    reg          m2_act_valid, m2_act_sop, m2_act_eop;
    reg  [15:0]  m2_weight_in;
    reg          m2_weight_load;
    reg  [7:0]   m2_weight_row, m2_weight_col;
    wire [255:0] m2_result_out;
    wire         m2_result_valid;
    wire         m2_result_sop, m2_result_eop;
    wire         m2_busy;

    bf16_mac_array #(.ARRAY_SIZE(16), .PIPE_DEPTH(3)) u_mac2 (
        .clk         (clk), .rst_n (rst_n),
        .act_in      (m2_act_in), .act_valid (m2_act_valid),
        .act_sop     (m2_act_sop), .act_eop   (m2_act_eop),
        .weight_in   (m2_weight_in), .weight_load (m2_weight_load),
        .weight_row  (m2_weight_row), .weight_col (m2_weight_col),
        .result_out  (m2_result_out), .result_valid (m2_result_valid),
        .result_sop  (m2_result_sop), .result_eop   (m2_result_eop),
        .busy        (m2_busy)
    );

    // =========================================================================
    //  TB CRC-16/CCITT-FALSE reference FSM (init 0xFFFF, poly 0x1021,
    //  MSB-first, no final XOR) — validated against tb_fabric.v vectors.
    // =========================================================================
    reg [15:0] tb_crc;
    integer    tb_i;

    task crc_reset;
        begin
            tb_crc = 16'hFFFF;
        end
    endtask

    task crc_byte;
        input [7:0] b;
        reg [15:0] c;
        integer k;
        begin
            c = tb_crc ^ (b << 8);
            for (k = 0; k < 8; k = k + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            tb_crc = c;
        end
    endtask

    // BF16 encoding of the small integer constants used by the data scheme:
    // 1.0 = 0x3F80, 2.0 = 0x4000, 3.0 = 0x4040, 6.0 = 0x40C0, 9.0 = 0x4110
    function automatic [15:0] bf16_of;
        input integer v;
        begin
            case (v)
                1:      bf16_of = 16'h3F80;
                2:      bf16_of = 16'h4000;
                3:      bf16_of = 16'h4040;
                6:      bf16_of = 16'h40C0;
                9:      bf16_of = 16'h4110;
                default: bf16_of = 16'h0000;
            endcase
        end
    endfunction

    // =========================================================================
    //  RAM preload + CRC self-check + reset release
    //
    //  Runs at t=0 while rst_n is still low, so the chip's clocked FSMs all
    //  hold reset.  It checks the TB CRC reference against the tb_fabric
    //  vectors, fills the RAM regions through the stub's write port (which
    //  has no reset guard — writes land even while rst_n=0), and only then
    //  deasserts rst_n.  One full cycle is reserved for each word.
    // =========================================================================
    integer crc_ok;
    integer pre_i, pre_e, pre_r, pre_c, pre_k;

    initial begin
        // ---- CRC self-check (abort on mismatch before anything else) ----
        crc_ok = 1;
        crc_reset; crc_byte(8'h35); crc_byte(8'h80); crc_byte(8'h02);
        crc_byte(8'h00); crc_byte(8'hAA); crc_byte(8'hBB);
        if (tb_crc != 16'h4920) begin
            $display("[FAIL] CRC vector 1: got %04h exp 4920", tb_crc);
            crc_ok = 0;
        end
        crc_reset; crc_byte(8'h77); crc_byte(8'h80); crc_byte(8'h02);
        crc_byte(8'h00); crc_byte(8'hCC); crc_byte(8'hDD);
        if (tb_crc != 16'h059C) begin
            $display("[FAIL] CRC vector 2: got %04h exp 059C", tb_crc);
            crc_ok = 0;
        end
        crc_reset; crc_byte(8'h25); crc_byte(8'hC0); crc_byte(8'h01);
        crc_byte(8'h00); crc_byte(8'h5A);
        if (tb_crc != 16'h45C4) begin
            $display("[FAIL] CRC vector 3: got %04h exp 45C4", tb_crc);
            crc_ok = 0;
        end
        crc_reset; crc_byte(8'h53); crc_byte(8'hC0); crc_byte(8'h01);
        crc_byte(8'h00); crc_byte(8'h6B);
        if (tb_crc != 16'hB3B5) begin
            $display("[FAIL] CRC vector 4: got %04h exp B3B5", tb_crc);
            crc_ok = 0;
        end
        if (crc_ok)
            $display("[OK] CRC reference FSM matches Go crc16() (4920 059C 45C4 B3B5)");
        else begin
            $display("[FAIL] CRC self-check failed — aborting");
            $finish;
        end

        // ---- preload the RAM (rst_n still low; write port owned by us) ----
        pre_wr_en = 1'b0; pre_wr_addr = {ADDR_W{1'b0}}; pre_wr_data = 16'h0000;

        // gating weights: 16 experts x 64; gating_w[e][i] = 2.0 iff i==e
        for (pre_i = 0; pre_i < 1024; pre_i = pre_i + 1) begin
            @(posedge clk);
            pre_wr_en   = 1'b1;
            pre_wr_addr = GATING_W_BASE + pre_i;
            pre_wr_data = (pre_i[5:0] == pre_i[9:6]) ? 16'h4000 : 16'h3F80;
        end

        // expert matrices: node e holds expert e's W_e = (e+1)*I_16
        for (pre_e = 0; pre_e < 3; pre_e = pre_e + 1) begin
            for (pre_r = 0; pre_r < 16; pre_r = pre_r + 1) begin
                for (pre_c = 0; pre_c < 16; pre_c = pre_c + 1) begin
                    @(posedge clk);
                    pre_wr_en   = 1'b1;
                    pre_wr_addr = EXPERT_W_BASE + pre_e*256 + pre_r*16 + pre_c;
                    pre_wr_data = (pre_r == pre_c) ?
                        ((pre_e == 0) ? 16'h3F80 :
                         (pre_e == 1) ? 16'h4000 : 16'h4040) : 16'h0000;
                end
            end
        end

        // hidden vectors: token k hidden has 3.0 at index k, else 1.0
        for (pre_k = 0; pre_k < 3; pre_k = pre_k + 1) begin
            for (pre_i = 0; pre_i < 64; pre_i = pre_i + 1) begin
                @(posedge clk);
                pre_wr_en   = 1'b1;
                pre_wr_addr = HIDDEN_BASE + pre_k*64 + pre_i;
                pre_wr_data = (pre_i == pre_k) ? 16'h4040 : 16'h3F80;
            end
        end

        // zero the output store region
        for (pre_i = 0; pre_i < 48; pre_i = pre_i + 1) begin
            @(posedge clk);
            pre_wr_en   = 1'b1;
            pre_wr_addr = OUTPUT_BASE + pre_i;
            pre_wr_data = 16'h0000;
        end

        // one extra posedge commits the final write, then release reset
        @(posedge clk);
        pre_wr_en = 1'b0;
        #1 rst_n = 1;
        $display("[OK] RAM preloaded at cycle %0d (gating 1024 + expert 768 + hidden 192 + output 48)",
                 cycle);
    end

    // =========================================================================
    //  Boot loader: stream the 16x64 gating weights out of the RAM stub into
    //  moe_gating's weight port.
    //
    //  Requests are pipelined (one per cycle, addresses 0..1023), so the RAM
    //  stub's in-order 4-cycle pipeline delivers the k-th rd_valid for word k.
    //  The weight write is issued one cycle after each valid (the write lands
    //  on the posedge where weight_load=1, which is the cycle after the
    //  capture), and boot_done is deferred one further cycle so the final
    //  write gets its own slot.  The expert coordinate (layer=1,
    //  module={e>>2,e&3}) is held per 64-word row via the address itself.
    // =========================================================================
    reg        boot_done;
    reg        boot_done_q;
    reg        boot_iss_done;
    reg [9:0]  boot_req;          // number of words requested so far (0..1023)
    reg [9:0]  boot_cap;          // number of words captured so far (0..1023)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_rd_req       <= 1'b0;
            boot_rd_addr      <= {ADDR_W{1'b0}};
            boot_req          <= 10'd0;
            boot_cap          <= 10'd0;
            boot_done         <= 1'b0;
            boot_done_q       <= 1'b0;
            boot_iss_done     <= 1'b0;
            gate_weight_load  <= 1'b0;
            gate_weight_addr  <= 10'd0;
            gate_weight_data  <= 16'h0000;
            gate_moe_layer_in <= 8'd1;
            gate_moe_module_in<= 8'h00;
        end else if (!boot_done) begin
            // ---- pipelined requests: one per cycle for words 0..1023 ----
            if (!boot_iss_done) begin
                boot_rd_req  <= 1'b1;
                boot_rd_addr <= GATING_W_BASE + boot_req;
                if (boot_req == 10'd1023)
                    boot_iss_done <= 1'b1;
                boot_req <= boot_req + 10'd1;
            end else begin
                boot_rd_req <= 1'b0;
            end

            // ---- weight write, one cycle after each rd_valid ----
            if (ram_rd_valid) begin
                gate_weight_load   <= 1'b1;
                gate_weight_addr   <= boot_cap;
                gate_weight_data   <= ram_rd_data;
                gate_moe_module_in <= {boot_cap[9:8], boot_cap[7:6]};
                boot_cap <= boot_cap + 10'd1;
                if (boot_cap == 10'd1023)
                    boot_done_q <= 1'b1;
            end else begin
                gate_weight_load <= 1'b0;
            end

            // ---- boot_done one cycle after the final capture ----
            if (boot_done_q)
                boot_done <= 1'b1;
        end else begin
            boot_rd_req      <= 1'b0;
            gate_weight_load <= 1'b0;
        end
    end

    // =========================================================================
    //  Node controllers 0..2: per-node FSM (one shared always block over the
    //  node index), plus the combinational RAM/MAC drives.
    //
    //   NC_IDLE   : wait for this node's doorbell fire
    //   NC_LOADW  : request 256 weight words from RAM -> stream into the MAC
    //   NC_LOADH  : request the token's 16 hidden words from RAM
    //   NC_FIRE   : drive act_in/act_valid for exactly one cycle
    //   NC_WAIT   : wait for the MAC's result_valid, capture result_out
    //   NC_STORE  : write 16 output words to the RAM output region
    //   NC_UNLOAD : 256 zero-fill weight writes (mass erase)
    //   NC_DONE   : pulse node_done, back to idle
    // =========================================================================
    localparam NC_IDLE   = 3'd0;
    localparam NC_LOADW  = 3'd1;
    localparam NC_LOADH  = 3'd2;
    localparam NC_FIRE   = 3'd3;
    localparam NC_WAIT   = 3'd4;
    localparam NC_STORE  = 3'd5;
    localparam NC_UNLOAD = 3'd6;
    localparam NC_DONE   = 3'd7;

    reg [2:0]  nc_state  [0:2];
    reg [8:0]  nc_wreq   [0:2];   // weight words requested (count 0..256)
    reg [7:0]  nc_wcap   [0:2];   // weight words captured (the write index)
    reg [4:0]  nc_hreq   [0:2];   // hidden words requested (count 0..16)
    reg [3:0]  nc_hcap   [0:2];   // hidden words captured
    reg [15:0] nc_hbuf   [0:2][0:15];
    reg [3:0]  nc_sidx   [0:2];   // output store index 0..15
    reg [7:0]  nc_ucnt   [0:2];   // unload count 0..255
    reg        node_done [0:2];
    reg [255:0] mac_result_cap [0:2];

    integer nc_n;
    integer nc_hw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (nc_n = 0; nc_n < 3; nc_n = nc_n + 1) begin
                nc_state[nc_n]  <= NC_IDLE;
                nc_wreq[nc_n]   <= 9'd0;
                nc_wcap[nc_n]   <= 8'd0;
                nc_hreq[nc_n]   <= 5'd0;
                nc_hcap[nc_n]   <= 4'd0;
                nc_sidx[nc_n]   <= 4'd0;
                nc_ucnt[nc_n]   <= 8'd0;
                node_done[nc_n] <= 1'b0;
                mac_result_cap[nc_n] <= 256'd0;
                for (nc_hw = 0; nc_hw < 16; nc_hw = nc_hw + 1)
                    nc_hbuf[nc_n][nc_hw] <= 16'h0000;
            end
        end else begin
            for (nc_n = 0; nc_n < 3; nc_n = nc_n + 1) begin
                node_done[nc_n] <= 1'b0;
                case (nc_state[nc_n])
                    NC_IDLE: begin
                        if (nc_n == 0 && db0_fire)      nc_state[nc_n] <= NC_LOADW;
                        else if (nc_n == 1 && db1_fire) nc_state[nc_n] <= NC_LOADW;
                        else if (nc_n == 2 && db2_fire) nc_state[nc_n] <= NC_LOADW;
                    end
                    NC_LOADW: begin
                        // one read request per cycle; 256 requests total
                        if (nc_wreq[nc_n] < 9'd256)
                            nc_wreq[nc_n] <= nc_wreq[nc_n] + 9'd1;
                        // capture each completed read; the write index is
                        // nc_wcap (pre-increment value = this word's index)
                        if (ram_rd_valid) begin
                            nc_wcap[nc_n] <= nc_wcap[nc_n] + 8'd1;
                            if (nc_wcap[nc_n] == 8'd255) begin
                                nc_state[nc_n] <= NC_LOADH;
                                nc_hreq[nc_n] <= 5'd0;
                                nc_hcap[nc_n] <= 4'd0;
                            end
                        end
                    end
                    NC_LOADH: begin
                        // 16 hidden-word requests
                        if (nc_hreq[nc_n] < 5'd16)
                            nc_hreq[nc_n] <= nc_hreq[nc_n] + 5'd1;
                        if (ram_rd_valid) begin
                            nc_hbuf[nc_n][nc_hcap[nc_n]] <= ram_rd_data;
                            nc_hcap[nc_n] <= nc_hcap[nc_n] + 4'd1;
                            if (nc_hcap[nc_n] == 4'd15) begin
                                // guard: the array must be idle before firing
                                if ((nc_n == 0 && !m0_busy) ||
                                    (nc_n == 1 && !m1_busy) ||
                                    (nc_n == 2 && !m2_busy))
                                    nc_state[nc_n] <= NC_FIRE;
                            end
                        end
                    end
                    NC_FIRE: begin
                        // act_valid (combinational) is high for this cycle
                        nc_state[nc_n] <= NC_WAIT;
                    end
                    NC_WAIT: begin
                        // capture the array result on the result_valid edge
                        if ((nc_n == 0 && m0_result_valid) ||
                            (nc_n == 1 && m1_result_valid) ||
                            (nc_n == 2 && m2_result_valid)) begin
                            if (nc_n == 0)      mac_result_cap[0] <= m0_result_out;
                            else if (nc_n == 1) mac_result_cap[1] <= m1_result_out;
                            else                mac_result_cap[2] <= m2_result_out;
                            nc_sidx[nc_n] <= 4'd0;
                            nc_state[nc_n] <= NC_STORE;
                        end
                    end
                    NC_STORE: begin
                        // 16 output words (combinational write, see store mux)
                        if (nc_sidx[nc_n] == 4'd15) begin
                            nc_ucnt[nc_n] <= 8'd0;
                            nc_state[nc_n] <= NC_UNLOAD;
                        end else begin
                            nc_sidx[nc_n] <= nc_sidx[nc_n] + 4'd1;
                        end
                    end
                    NC_UNLOAD: begin
                        // 256 zero-fill weight writes (combinational)
                        if (nc_ucnt[nc_n] == 8'd255)
                            nc_state[nc_n] <= NC_DONE;
                        else
                            nc_ucnt[nc_n] <= nc_ucnt[nc_n] + 8'd1;
                    end
                    NC_DONE: begin
                        node_done[nc_n] <= 1'b1;
                        nc_state[nc_n] <= NC_IDLE;
                    end
                    default: nc_state[nc_n] <= NC_IDLE;
                endcase
            end
        end
    end

    // ---- combinational node drives: RAM reads, weights, acts, store ----

    // node RAM read requests (PH_NODE); only one node is active per token
    always @(*) begin
        node_rd_req  = 1'b0;
        node_rd_addr = {ADDR_W{1'b0}};
        if (nc_state[0] == NC_LOADW) begin
            node_rd_req  = (nc_wreq[0] < 9'd256);
            node_rd_addr = EXPERT_W_BASE + nc_wreq[0][7:0];
        end else if (nc_state[0] == NC_LOADH) begin
            node_rd_req  = (nc_hreq[0] < 5'd16);
            node_rd_addr = HIDDEN_BASE + {1'b0, nc_hreq[0][3:0]};
        end else if (nc_state[1] == NC_LOADW) begin
            node_rd_req  = (nc_wreq[1] < 9'd256);
            node_rd_addr = EXPERT_W_BASE + 9'd256 + nc_wreq[1][7:0];
        end else if (nc_state[1] == NC_LOADH) begin
            node_rd_req  = (nc_hreq[1] < 5'd16);
            node_rd_addr = HIDDEN_BASE + 9'd64 + {1'b0, nc_hreq[1][3:0]};
        end else if (nc_state[2] == NC_LOADW) begin
            node_rd_req  = (nc_wreq[2] < 9'd256);
            node_rd_addr = EXPERT_W_BASE + 10'd512 + nc_wreq[2][7:0];
        end else if (nc_state[2] == NC_LOADH) begin
            node_rd_req  = (nc_hreq[2] < 5'd16);
            node_rd_addr = HIDDEN_BASE + 9'd128 + {1'b0, nc_hreq[2][3:0]};
        end
    end

    // MAC weight drives: capture RAM words during LOADW (row/col from the
    // pre-increment capture counter), zero-fill during UNLOAD
    always @(*) begin
        m0_weight_load = 1'b0; m0_weight_in = 16'h0000;
        m0_weight_row  = 8'h00; m0_weight_col = 8'h00;
        m1_weight_load = 1'b0; m1_weight_in = 16'h0000;
        m1_weight_row  = 8'h00; m1_weight_col = 8'h00;
        m2_weight_load = 1'b0; m2_weight_in = 16'h0000;
        m2_weight_row  = 8'h00; m2_weight_col = 8'h00;

        if (nc_state[0] == NC_LOADW) begin
            if (ram_rd_valid) begin
                m0_weight_load = 1'b1;
                m0_weight_in   = ram_rd_data;
                m0_weight_row  = {4'h0, nc_wcap[0][7:4]};
                m0_weight_col  = {4'h0, nc_wcap[0][3:0]};
            end
        end else if (nc_state[0] == NC_UNLOAD) begin
            m0_weight_load = 1'b1;
            m0_weight_in   = 16'h0000;
            m0_weight_row  = {4'h0, nc_ucnt[0][7:4]};
            m0_weight_col  = {4'h0, nc_ucnt[0][3:0]};
        end

        if (nc_state[1] == NC_LOADW) begin
            if (ram_rd_valid) begin
                m1_weight_load = 1'b1;
                m1_weight_in   = ram_rd_data;
                m1_weight_row  = {4'h0, nc_wcap[1][7:4]};
                m1_weight_col  = {4'h0, nc_wcap[1][3:0]};
            end
        end else if (nc_state[1] == NC_UNLOAD) begin
            m1_weight_load = 1'b1;
            m1_weight_in   = 16'h0000;
            m1_weight_row  = {4'h0, nc_ucnt[1][7:4]};
            m1_weight_col  = {4'h0, nc_ucnt[1][3:0]};
        end

        if (nc_state[2] == NC_LOADW) begin
            if (ram_rd_valid) begin
                m2_weight_load = 1'b1;
                m2_weight_in   = ram_rd_data;
                m2_weight_row  = {4'h0, nc_wcap[2][7:4]};
                m2_weight_col  = {4'h0, nc_wcap[2][3:0]};
            end
        end else if (nc_state[2] == NC_UNLOAD) begin
            m2_weight_load = 1'b1;
            m2_weight_in   = 16'h0000;
            m2_weight_row  = {4'h0, nc_ucnt[2][7:4]};
            m2_weight_col  = {4'h0, nc_ucnt[2][3:0]};
        end
    end

    // MAC activation drives: full 16-word vector (act_in[N*16 +: 16] = hbuf[N])
    // sampled by the array's accept edge during NC_FIRE
    always @(*) begin
        m0_act_in = 256'd0; m0_act_valid = 1'b0; m0_act_sop = 1'b0; m0_act_eop = 1'b0;
        m1_act_in = 256'd0; m1_act_valid = 1'b0; m1_act_sop = 1'b0; m1_act_eop = 1'b0;
        m2_act_in = 256'd0; m2_act_valid = 1'b0; m2_act_sop = 1'b0; m2_act_eop = 1'b0;

        if (nc_state[0] == NC_FIRE) begin
            m0_act_valid = 1'b1; m0_act_sop = 1'b1; m0_act_eop = 1'b1;
            m0_act_in = {nc_hbuf[0][15], nc_hbuf[0][14], nc_hbuf[0][13], nc_hbuf[0][12],
                         nc_hbuf[0][11], nc_hbuf[0][10], nc_hbuf[0][9],  nc_hbuf[0][8],
                         nc_hbuf[0][7],  nc_hbuf[0][6],  nc_hbuf[0][5],  nc_hbuf[0][4],
                         nc_hbuf[0][3],  nc_hbuf[0][2],  nc_hbuf[0][1],  nc_hbuf[0][0]};
        end
        if (nc_state[1] == NC_FIRE) begin
            m1_act_valid = 1'b1; m1_act_sop = 1'b1; m1_act_eop = 1'b1;
            m1_act_in = {nc_hbuf[1][15], nc_hbuf[1][14], nc_hbuf[1][13], nc_hbuf[1][12],
                         nc_hbuf[1][11], nc_hbuf[1][10], nc_hbuf[1][9],  nc_hbuf[1][8],
                         nc_hbuf[1][7],  nc_hbuf[1][6],  nc_hbuf[1][5],  nc_hbuf[1][4],
                         nc_hbuf[1][3],  nc_hbuf[1][2],  nc_hbuf[1][1],  nc_hbuf[1][0]};
        end
        if (nc_state[2] == NC_FIRE) begin
            m2_act_valid = 1'b1; m2_act_sop = 1'b1; m2_act_eop = 1'b1;
            m2_act_in = {nc_hbuf[2][15], nc_hbuf[2][14], nc_hbuf[2][13], nc_hbuf[2][12],
                         nc_hbuf[2][11], nc_hbuf[2][10], nc_hbuf[2][9],  nc_hbuf[2][8],
                         nc_hbuf[2][7],  nc_hbuf[2][6],  nc_hbuf[2][5],  nc_hbuf[2][4],
                         nc_hbuf[2][3],  nc_hbuf[2][2],  nc_hbuf[2][1],  nc_hbuf[2][0]};
        end
    end

    // RAM output-store writes from the active node's NC_STORE
    always @(*) begin
        nc_wr_en   = 1'b0;
        nc_wr_addr = {ADDR_W{1'b0}};
        nc_wr_data = 16'h0000;
        if (nc_state[0] == NC_STORE) begin
            nc_wr_en   = 1'b1;
            nc_wr_addr = OUTPUT_BASE + {9'd0, nc_sidx[0]};
            nc_wr_data = mac_result_cap[0][nc_sidx[0]*16 +: 16];
        end else if (nc_state[1] == NC_STORE) begin
            nc_wr_en   = 1'b1;
            nc_wr_addr = OUTPUT_BASE + 9'd16 + {8'd0, nc_sidx[1]};
            nc_wr_data = mac_result_cap[1][nc_sidx[1]*16 +: 16];
        end else if (nc_state[2] == NC_STORE) begin
            nc_wr_en   = 1'b1;
            nc_wr_addr = OUTPUT_BASE + 9'd32 + {8'd0, nc_sidx[2]};
            nc_wr_data = mac_result_cap[2][nc_sidx[2]*16 +: 16];
        end
    end

    // =========================================================================
    //  Token sequencer: boot wait -> per-token gating -> flit -> node -> next
    // =========================================================================
    localparam T_IDLE   = 3'd0;
    localparam T_START  = 3'd1;   // assert gate start for 1 cycle
    localparam T_HIDDEN = 3'd2;   // stream 64 hidden words into the gating unit
    localparam T_GATE   = 3'd3;   // wait for gate done
    localparam T_FLIT   = 3'd4;   // wait for the flit sender to finish
    localparam T_NODE   = 3'd5;   // wait for the visited node's completion
    localparam T_ALL    = 3'd6;   // all tokens done; hold for readback

    reg [2:0] t_state;
    reg [1:0] tok;
    reg       token_done [0:2];
    integer   hid_req_i;          // hidden words requested (0..64)
    integer   hid_cap_i;          // hidden words captured (0..64)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_state          <= T_IDLE;
            tok              <= 2'd0;
            token_done[0]    <= 1'b0;
            token_done[1]    <= 1'b0;
            token_done[2]    <= 1'b0;
            gate_start       <= 1'b0;
            gate_hidden_valid<= 1'b0;
            gate_hidden_data <= 16'h0000;
            gate_rd_req      <= 1'b0;
            gate_rd_addr     <= {ADDR_W{1'b0}};
            hid_req_i        <= 0;
            hid_cap_i        <= 0;
            ram_phase        <= PH_BOOT;
        end else begin
            gate_start        <= 1'b0;
            gate_hidden_valid <= 1'b0;

            case (t_state)
                T_IDLE: begin
                    if (boot_done) begin
                        tok     <= 2'd0;
                        t_state <= T_START;
                    end
                end

                T_START: begin
                    gate_start <= 1'b1;          // exactly 1 cycle
                    ram_phase  <= PH_GATE;       // one cycle early: the first
                                                 // hidden request must already
                                                 // be visible to the arbiter
                    t_state    <= T_HIDDEN;
                end

                T_HIDDEN: begin
                    // pipelined requests for the token's 64 hidden words
                    if (hid_req_i < 64) begin
                        gate_rd_req  <= 1'b1;
                        gate_rd_addr <= HIDDEN_BASE + tok*8'd64 + hid_req_i[5:0];
                        hid_req_i    <= hid_req_i + 1;
                    end else begin
                        gate_rd_req <= 1'b0;
                    end
                    // feed each completed read into the gating unit
                    if (ram_rd_valid) begin
                        gate_hidden_valid <= 1'b1;
                        gate_hidden_data  <= ram_rd_data;
                        if (hid_cap_i == 63) begin
                            // 64th hidden word: done feeding
                            t_state   <= T_GATE;
                            hid_req_i <= 0;
                            hid_cap_i <= 0;
                        end else begin
                            hid_cap_i <= hid_cap_i + 1;
                        end
                    end
                end

                T_GATE: begin
                    gate_rd_req <= 1'b0;
                    if (gate_done) begin
                        // combinational top-1 reads are valid after done
                        $display("        token %0d: top-1 expert %0d -> module %02h (logit %04h) at cycle %0d",
                                 tok,
                                 gate_idx_packed[7:0],
                                 gate_module_packed[7:0],
                                 gate_logit_packed[15:0],
                                 cycle);
                        ram_phase <= PH_NODE;
                        t_state   <= T_FLIT;
                    end
                end

                T_FLIT: begin
                    // wait for the byte-serial injector to finish; the flit
                    // will reach the routed node's doorbell after the fabric
                    // pipeline latency (~17 cycles)
                    if (fl_state == FL_DONE)
                        t_state <= T_NODE;
                end

                T_NODE: begin
                    if ((tok == 2'd0 && node_done[0]) ||
                        (tok == 2'd1 && node_done[1]) ||
                        (tok == 2'd2 && node_done[2])) begin
                        token_done[tok] <= 1'b1;
                        if (tok == 2'd2)
                            t_state <= T_ALL;
                        else begin
                            tok     <= tok + 2'd1;
                            t_state <= T_START;
                        end
                    end
                end

                T_ALL: begin
                    ram_phase <= PH_READBACK;    // readback owns the read port
                end

                default: t_state <= T_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Flit sender: builds the 9-byte spine flit and injects it on VC=2
    // =========================================================================
    // bytes: LAYER_ID=1, MODULE_ID(= top-1 expert module), CTRL=0x80,
    //        LEN_LO=2, LEN_HI=0, pay0=0, pay1=token, CRC_HI, CRC_LO
    // CRC over [MODULE_ID, CTRL, LEN_LO, LEN_HI, pay0, pay1]
    localparam FL_IDLE = 3'd0;
    localparam FL_CRC  = 3'd1;   // compute CRC (6 bytes)
    localparam FL_SEND = 3'd2;   // inject 9 bytes
    localparam FL_DONE = 3'd3;

    reg [2:0]  fl_state;
    reg [3:0]  fl_byte_idx;
    reg [7:0]  flit_bytes [0:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fl_state    <= FL_IDLE;
            fl_byte_idx <= 3'd0;
            spin_data   <= 8'h00;
            spin_valid  <= 1'b0;
            spin_sop    <= 1'b0;
            spin_eop    <= 1'b0;
            spin_vc     <= 2'b10;   // VC_SPINE_DESCENT
        end else begin
            case (fl_state)
                FL_IDLE: begin
                    if (t_state == T_FLIT) begin
                        // read the top-1 module straight off the (combinational,
                        // stable) gate output — no race with the sequencer
                        flit_bytes[0] <= 8'd1;                    // LAYER_ID
                        flit_bytes[1] <= gate_module_packed[7:0]; // MODULE_ID
                        flit_bytes[2] <= 8'h80;                   // CTRL compute
                        flit_bytes[3] <= 8'd2;                    // LEN_LO
                        flit_bytes[4] <= 8'h00;                   // LEN_HI
                        flit_bytes[5] <= 8'h00;                   // pay0 = tok>>8
                        flit_bytes[6] <= tok;                     // pay1 = tok
                        crc_reset;
                        fl_byte_idx <= 4'd1;
                        fl_state    <= FL_CRC;
                    end
                end

                FL_CRC: begin
                    // feed bytes 1..6 (MODULE_ID..pay1) into the CRC
                    if (fl_byte_idx <= 4'd6) begin
                        crc_byte(flit_bytes[fl_byte_idx]);
                        fl_byte_idx <= fl_byte_idx + 4'd1;
                    end else begin
                        flit_bytes[7] <= tb_crc[15:8];
                        flit_bytes[8] <= tb_crc[7:0];
                        fl_byte_idx  <= 4'd0;
                        fl_state     <= FL_SEND;
                    end
                end

                FL_SEND: begin
                    // one byte per cycle, SOP on byte 0, EOP on byte 8
                    spin_data  <= flit_bytes[fl_byte_idx];
                    spin_valid <= 1'b1;
                    spin_sop   <= (fl_byte_idx == 4'd0);
                    spin_eop   <= (fl_byte_idx == 4'd8);
                    if (fl_byte_idx == 4'd8)
                        fl_state <= FL_DONE;
                    else
                        fl_byte_idx <= fl_byte_idx + 4'd1;
                end

                FL_DONE: begin
                    spin_valid <= 1'b0;
                    spin_sop   <= 1'b0;
                    spin_eop   <= 1'b0;
                    fl_state   <= FL_IDLE;
                end

                default: fl_state <= FL_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Assertion monitors / final readback
    // =========================================================================
    integer errors;
    initial errors = 0;

    always @(posedge clk) begin
        if (db0_node_err) begin
            $display("[FAIL] node 0 doorbell refused a message");
            errors = errors + 1;
        end
        if (db1_node_err) begin
            $display("[FAIL] node 1 doorbell refused a message");
            errors = errors + 1;
        end
        if (db2_node_err) begin
            $display("[FAIL] node 2 doorbell refused a message");
            errors = errors + 1;
        end
    end

    // Final response: once all three tokens are complete, read the output
    // store back out of the RAM stub, verify every word against the closed
    // form, and emit the decoded response string.
    reg [15:0] out_data [0:47];
    integer    rb_i, rb_n, rb_j, rb_errors, rb_exp;

    initial begin
        rb_errors = 0;
        wait (t_state == T_ALL && token_done[0] && token_done[1] && token_done[2]);
        wait (ram_phase == PH_READBACK);

        for (rb_i = 0; rb_i < 48; rb_i = rb_i + 1) begin
            readback_rd_req  <= 1'b1;
            readback_rd_addr <= OUTPUT_BASE + rb_i;
            @(posedge clk);
            readback_rd_req <= 1'b0;
            wait (ram_rd_valid);
            @(posedge clk);
            out_data[rb_i] = ram_rd_data;
        end

        $display("========================================================");
        $display("EXPERT LOOP COMPLETE at cycle %0d", cycle);
        $display("  doorbell activations: %0d %0d %0d (expect 1 1 1)",
                 db0_activations, db1_activations, db2_activations);
        $display("  doorbell rejections : %0d %0d %0d (expect 0 0 0)",
                 db0_rejections, db1_rejections, db2_rejections);

        for (rb_n = 0; rb_n < 3; rb_n = rb_n + 1) begin
            $display("  node %0d outputs:", rb_n);
            for (rb_j = 0; rb_j < 16; rb_j = rb_j + 1)
                $write("%04h ", out_data[rb_n*16 + rb_j]);
            $display("");
            for (rb_j = 0; rb_j < 16; rb_j = rb_j + 1) begin
                rb_exp = (rb_j == rb_n) ? (rb_n+1)*3 : (rb_n+1);
                if (out_data[rb_n*16 + rb_j] != bf16_of(rb_exp)) begin
                    $display("[FAIL] token %0d output[%0d] = %04h (exp %04h)",
                             rb_n, rb_j, out_data[rb_n*16 + rb_j], bf16_of(rb_exp));
                    rb_errors = rb_errors + 1;
                end
            end
        end

        if (db0_activations != 32'd1 || db1_activations != 32'd1 ||
            db2_activations != 32'd1) rb_errors = rb_errors + 1;
        if (db0_rejections != 32'd0 || db1_rejections != 32'd0 ||
            db2_rejections != 32'd0) rb_errors = rb_errors + 1;

        $display("--------------------------------------------------------");
        if (rb_errors == 0 && errors == 0)
            $display("*** EXPERT LOOP TEST PASSED ***");
        else
            $display("*** EXPERT LOOP TEST FAILED (errors=%0d, readback=%0d) ***",
                     errors, rb_errors);
        $display("FULL RESPONSE: token_0000 token_0001 token_0002");
        $display("========================================================");
        $finish;
    end

endmodule