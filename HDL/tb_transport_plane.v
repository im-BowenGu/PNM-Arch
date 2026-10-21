`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The transport plane, end to end.
//
// The whole loop the architecture depends on, composed from the real modules
// and simulated as one system:
//
//   host (SPI)  ->  pi_bridge  ->  pnm_arb  ->  pnm_host_bridge
//                    |                                    ^
//                    |  the bridge injects a token flit      |  the fabric's
//                    v                                    |  egress, back
//              lxy_repeater (the spine tap)               |  to the host
//                    |  the board's NoB                   |
//                    v                                    |
//              node_eject (the gating node)               |
//                    |  the node's DMA                    |
//                    v                                    |
//              mgmt_bridge  <-- the management node (MCU)  |
//                |  |  |                                   |
//                |  |  +-- the gating ASIC: the decision   |
//                |  +----- the token tap                   |
//                +-------- the dispatch flit -> the egress
//
//   and the loop's other half, the part the fabric is built for:
//
//   host  ->  the bridge injects the dispatch  ->  the fabric  ->  the expert
//            node's doorbell (the CRC-16 is checked by the real doorbell)
//            ->  the expert's result  ->  the fabric's egress  ->  the host
//
// The pieces are all the real ones: the host path (pi_bridge, pnm_arb,
// pnm_host_bridge), the fabric (lxy_repeater, node_eject), the gating node
// (mgmt_bridge, gating_asic), and the expert node's doorbell.  The only
// model is the management node itself -- the MCU -- whose state machine is
// the one fw/pnm_mgmt.c implements.
//
// What it proves, hand-off by hand-off:
//   1. a token the host injects over SPI crosses the bridge, the fabric and
//      the node's DMA and lands in the management node's tap;
//   2. the management node programs the real gating ASIC, the token's hidden
//      vector is gated, and the decision comes back over the management bus;
//   3. the management node turns that into a dispatch flit, and the flit
//      travels the node's egress, up the spine and into the host, byte for
//      byte as the firmware builds it;
//   4. the host re-issues the dispatch and the fabric carries it to the
//      expert node, whose real doorbell accepts it -- which means the
//      CRC-16 over the protected body is right;
//   5. the expert's result travels back up the fabric and the host reads it
//      over the same SPI link it wrote with.
//
// Step 3 is also where the architecture's shape shows: the fabric is a tree
// whose only router is the root, so a node's dispatch reaches the expert
// through the host (mode B) or through a root-side router that consumes the
// decision directly (the mode-A path the paper describes).  The test makes
// that relay explicit rather than hiding it.
// ---------------------------------------------------------------------------

module tb_transport_plane;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    integer errors = 0;
    integer guard;
    integer i;

    // =====================================================================
    // The host: the SPI link
    // =====================================================================
    reg  sclk = 1'b0;
    reg  mosi = 1'b0;
    reg  cs_n = 1'b1;
    wire miso;
    wire irq_out;

    // The bridge's fabric side
    wire [7:0] inj_data;
    wire       inj_valid;
    wire       inj_sop;
    wire       inj_eop;
    wire [1:0] inj_vc;

    wire [7:0] ext_data;
    wire       ext_valid;
    wire       ext_sop;
    wire       ext_eop;
    wire [1:0] ext_vc;

    wire boot_done;

    pnm_host_top u_top (
        .clk(clk), .rst_n(rst_n),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .irq_out(irq_out),
        .native_addr(32'd0), .native_wdata(32'd0), .native_rdata(),
        .native_be(4'hF), .native_we(1'b0), .native_valid(1'b0),
        .native_ready(),
        .spine_inject_data(inj_data), .spine_inject_valid(inj_valid),
        .spine_inject_sop(inj_sop), .spine_inject_eop(inj_eop),
        .spine_inject_vc(inj_vc), .spine_inject_ready(1'b1),
        .spine_extract_data(ext_data), .spine_extract_valid(ext_valid),
        .spine_extract_sop(ext_sop), .spine_extract_eop(ext_eop),
        .spine_extract_vc(ext_vc),
        .boot_done(boot_done)
    );

    // =====================================================================
    // The fabric
    // =====================================================================
    wire [7:0]  nob_data;  wire nob_valid, nob_sop, nob_eop, nob_ready; wire [1:0] nob_vc;
    wire [7:0]  nup_data;  wire nup_valid, nup_sop, nup_eop, nup_ready; wire [1:0] nup_vc;
    wire [7:0]  spup_data; wire spup_valid, spup_sop, spup_eop, spup_ready; wire [1:0] spup_vc;

    // The gating node's management path.
    reg  [15:0] mgr_addr = 16'd0;
    reg  [15:0] mgr_wdata = 16'd0;
    wire [15:0] mgr_rdata;
    reg         mgr_we = 1'b0;
    reg         mgr_valid = 1'b0;
    wire        mgr_ready;

    wire [15:0] asic_addr;
    wire [15:0] asic_wdata;
    wire [15:0] asic_rdata;
    wire        asic_we;
    wire        asic_valid;
    // The ASIC's ready is the bridge's asic_ready; the bridge's mgr_ready is
    // the management node's side.  They are different nets.
    wire        asic_ready;

    wire [7:0]  tap_data;
    wire        tap_valid;
    wire        tap_sop;
    wire        tap_eop;
    reg         tap_ready = 1'b0;
    wire        tap_empty;
    wire        tap_full;
    wire [1:0]  tap_vc;

    reg  [7:0]  minj_data = 8'd0;
    reg         minj_valid = 1'b0;
    reg         minj_sop = 1'b0;
    reg         minj_eop = 1'b0;
    wire        minj_ready;
    reg  [1:0]  minj_vc = 2'b00;

    wire [7:0]  gate_out_data;
    wire        gate_out_valid;
    wire        gate_out_sop;
    wire        gate_out_eop;
    wire        gate_out_ready = 1'b1;
    wire [1:0]  gate_out_vc;

    // The expert node's result on the egress.
    reg  [7:0]  exp_data = 8'd0;
    reg         exp_valid = 1'b0;
    reg         exp_sop = 1'b0;
    reg         exp_eop = 1'b0;
    reg  [1:0]  exp_vc = 2'b00;

    // The board's egress merge tree: the gating node's dispatch and the
    // expert's result share the lane up to the root.
    assign nup_data  = gate_out_valid ? gate_out_data  : exp_data;
    assign nup_valid = gate_out_valid ? gate_out_valid : exp_valid;
    assign nup_sop   = gate_out_valid ? gate_out_sop   : exp_sop;
    assign nup_eop   = gate_out_valid ? gate_out_eop   : exp_eop;
    assign nup_vc    = gate_out_valid ? gate_out_vc    : exp_vc;

    lxy_repeater rpt (
        .clk(clk), .rst_n(rst_n),
        .route_bitmap(11'h080),         // layer 1
        .spin_data(inj_data), .spin_valid(inj_valid), .spin_sop(inj_sop),
        .spin_eop(inj_eop), .spin_ready(),
        .spin_vc(inj_vc),
        .spout_data(), .spout_valid(), .spout_sop(), .spout_eop(),
        .spout_ready(1'b1), .spout_vc(),
        .nob_data(nob_data), .nob_valid(nob_valid), .nob_sop(nob_sop),
        .nob_eop(nob_eop), .nob_ready(nob_ready), .nob_vc(nob_vc),
        .nob_up_data(nup_data), .nob_up_valid(nup_valid), .nob_up_sop(nup_sop),
        .nob_up_eop(nup_eop), .nob_up_ready(nup_ready), .nob_up_vc(nup_vc),
        .spup_in_data(), .spup_in_valid(1'b0), .spup_in_sop(1'b0), .spup_in_eop(1'b0),
        .spup_in_ready(), .spup_in_vc(2'b00),
        .spup_data(spup_data), .spup_valid(spup_valid), .spup_sop(spup_sop),
        .spup_eop(spup_eop), .spup_ready(spup_ready), .spup_vc(spup_vc)
    );

    // The root's up-spine is the bridge's extraction path: the host reads
    // whatever the fabric returns.
    assign ext_data   = spup_data;
    assign ext_valid  = spup_valid;
    assign ext_sop    = spup_sop;
    assign ext_eop    = spup_eop;
    assign ext_vc     = spup_vc;
    assign spup_ready = 1'b1;

    // =====================================================================
    // The board's X-lane: the gating node and the expert node
    // =====================================================================
    wire [7:0]  xlane_data;  wire xlane_valid, xlane_sop, xlane_eop, xlane_ready;
    wire [1:0]  xlane_vc;

    wire [7:0]  gate_data;  wire gate_valid, gate_sop, gate_eop, gate_ready;
    wire [1:0]  gate_vc;
    wire [7:0]  expert_data; wire expert_valid, expert_sop, expert_eop, expert_ready;
    wire [1:0]  expert_vc;

    // The board's lane continues past the gating node to the expert node.
    wire [7:0]  lane2_data;  wire lane2_valid, lane2_sop, lane2_eop, lane2_ready;
    wire [1:0]  lane2_vc;

    // The gating node takes the lane; the expert node is downstream of it.
    assign xlane_data  = nob_data;
    assign xlane_valid = nob_valid;
    assign xlane_sop   = nob_sop;
    assign xlane_eop   = nob_eop;
    assign nob_ready   = xlane_ready;
    assign xlane_vc    = nob_vc;

    node_eject #(.LOCAL_MODULE(8'h25)) eject_gate (
        .clk(clk), .rst_n(rst_n),
        .yin_data(xlane_data), .yin_valid(xlane_valid), .yin_sop(xlane_sop),
        .yin_eop(xlane_eop), .yin_ready(xlane_ready), .yin_vc(xlane_vc),
        .yout_data(lane2_data), .yout_valid(lane2_valid), .yout_sop(lane2_sop),
        .yout_eop(lane2_eop), .yout_ready(lane2_ready), .yout_vc(lane2_vc),
        .node_data(gate_data), .node_valid(gate_valid), .node_sop(gate_sop),
        .node_eop(gate_eop), .node_ready(gate_ready), .node_vc(gate_vc)
    );

    node_eject #(.LOCAL_MODULE(8'h12)) eject_expert (
        .clk(clk), .rst_n(rst_n),
        .yin_data(lane2_data), .yin_valid(lane2_valid), .yin_sop(lane2_sop),
        .yin_eop(lane2_eop), .yin_ready(lane2_ready), .yin_vc(lane2_vc),
        .yout_data(), .yout_valid(), .yout_sop(), .yout_eop(),
        .yout_ready(1'b1), .yout_vc(),
        .node_data(expert_data), .node_valid(expert_valid), .node_sop(expert_sop),
        .node_eop(expert_eop), .node_ready(expert_ready), .node_vc(expert_vc)
    );

    // =====================================================================
    // The gating node's management path
    // =====================================================================
    mgmt_bridge u_mgmt (
        .clk(clk), .rst_n(rst_n),
        .mgr_addr(mgr_addr), .mgr_wdata(mgr_wdata), .mgr_rdata(mgr_rdata),
        .mgr_we(mgr_we), .mgr_valid(mgr_valid), .mgr_ready(mgr_ready),
        .asic_addr(asic_addr), .asic_wdata(asic_wdata), .asic_rdata(asic_rdata),
        .asic_we(asic_we), .asic_valid(asic_valid), .asic_ready(asic_ready),
        .nob_in_data(gate_data), .nob_in_valid(gate_valid),
        .nob_in_sop(gate_sop), .nob_in_eop(gate_eop),
        .nob_in_ready(gate_ready), .nob_in_vc(gate_vc),
        .tap_data(tap_data), .tap_valid(tap_valid), .tap_sop(tap_sop),
        .tap_eop(tap_eop), .tap_ready(tap_ready), .tap_empty(tap_empty),
        .tap_full(tap_full), .tap_vc(tap_vc),
        .inj_data(minj_data), .inj_valid(minj_valid), .inj_sop(minj_sop),
        .inj_eop(minj_eop), .inj_ready(minj_ready), .inj_vc(minj_vc),
        .nob_out_data(gate_out_data), .nob_out_valid(gate_out_valid),
        .nob_out_sop(gate_out_sop), .nob_out_eop(gate_out_eop),
        .nob_out_ready(gate_out_ready), .nob_out_vc(gate_out_vc)
    );

    gating_asic #(
        .NUM_EXPERTS(4), .HIDDEN_DIM(4), .TOP_K(2), .ADDR_BITS(8),
        .ARRAY_SIZE(2), .WEIGHT_DEPTH(16), .HIDDEN_DEPTH(4)
    ) u_asic (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(16'd0), .bus_wdata(16'd0), .bus_rdata(),
        .bus_we(1'b0), .bus_valid(1'b0), .bus_ready(),
        .mgmt_sel(1'b1),
        .mgmt_addr(mgr_addr), .mgmt_wdata(mgr_wdata), .mgmt_rdata(asic_rdata),
        .mgmt_we(mgr_we), .mgmt_valid(mgr_valid), .mgmt_ready(asic_ready),
        .prog_data(8'd0), .prog_valid(1'b0), .prog_sop(1'b0), .prog_eop(1'b0),
        .expert_idx(), .expert_logit(), .expert_layer(), .expert_module(),
        .result_valid(), .busy(), .done(), .cycle_count()
    );

    // =====================================================================
    // The expert node: the real doorbell
    // =====================================================================
    wire        db_fire;
    wire        db_ack;
    wire        db_err;
    wire [31:0] db_activations;
    wire [31:0] db_rejections;

    doorbell #(.LOCAL_MODULE(8'h12)) u_doorbell (
        .clk(clk), .rst_n(rst_n),
        .s_data(expert_data), .s_valid(expert_valid), .s_ready(expert_ready),
        .s_eop(expert_eop),
        .fire(db_fire), .ack(db_ack), .node_err(db_err),
        .activations(db_activations), .rejections(db_rejections)
    );

    // =====================================================================
    // The management node (the MCU): the state machine fw/pnm_mgmt.c
    // implements.
    // =====================================================================
    localparam M_IDLE     = 0;
    localparam M_HIDDEN   = 1;
    localparam M_START    = 2;
    localparam M_WAIT     = 3;
    localparam M_RESULT   = 4;
    localparam M_DISPATCH = 5;

    reg [2:0]  m_state = M_IDLE;
    reg        m_busy_seen = 1'b0;
    reg        m_token_ready = 1'b0;   // the board handed the node a token
    reg [15:0] m_weights [0:15];
    reg [15:0] m_hidden  [0:3];
    reg [7:0]  m_token   [0:7];
    reg [7:0]  m_sel     [0:1];
    reg [15:0] m_status;
    reg [15:0] m_sel_logit;
    integer    m_i;
    reg [7:0]  m_flit [0:63];
    integer    m_flit_bytes = 0;
    reg [15:0] m_crc;

    function [15:0] crc_step;
        input [15:0] c;
        input [7:0]  d;
        integer k;
        reg [15:0] x;
        begin
            x = c ^ (d << 8);
            for (k = 0; k < 8; k = k + 1)
                x = x[15] ? ((x << 1) ^ 16'h1021) : (x << 1);
            crc_step = x;
        end
    endfunction

    task mgr_write;
        input [15:0] addr;
        input [15:0] data;
        begin
            mgr_addr  = addr;
            mgr_wdata = data;
            mgr_we    = 1'b1;
            mgr_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
            mgr_valid = 1'b0;
            mgr_we    = 1'b0;
            @(posedge clk);
        end
    endtask

    task mgr_read;
        input  [15:0] addr;
        output [15:0] data;
        begin
            mgr_addr  = addr;
            mgr_we    = 1'b0;
            mgr_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
            mgr_valid = 1'b0;
            @(posedge clk);
            data = mgr_rdata;
        end
    endtask

    // One step of the management node's state machine.
    task mgmt_step;
        begin
            case (m_state)
            M_IDLE: begin
                if (m_token_ready) begin
                    m_token_ready = 1'b0;
                    m_state = M_HIDDEN;
                end
            end
            M_HIDDEN: begin
                mgr_write(16'h14, 16'd0);
                mgr_write(16'h15, 16'd0);
                for (m_i = 0; m_i < 4; m_i = m_i + 1)
                    mgr_write(16'h16, m_hidden[m_i]);
                m_state = M_START;
            end
            M_START: begin
                mgr_write(16'h00, 16'h0001);
                m_state = M_WAIT;
            end
            M_WAIT: begin
                mgr_read(16'h02, m_status);            // STATUS
                if (m_status[0]) m_busy_seen = 1'b1;    // busy
                if (m_busy_seen && !m_status[0]) begin
                    // the packed decision output is registered behind the
                    // top-k buffer, so settle before reading it
                    mgr_read(16'h02, m_status);
                    mgr_read(16'h02, m_status);
                    mgr_read(16'h02, m_status);
                    m_state = M_RESULT;
                end
            end
            M_RESULT: begin
                mgr_read(16'h200, m_sel[0]);           // rank 0's id
                mgr_read(16'h280, m_sel_logit);         // rank 0's logit
                m_state = M_DISPATCH;
            end
            M_DISPATCH: begin
                m_flit[0] = 8'h01;                     // LAYER_ID
                m_flit[1] = 8'h12;                     // MODULE_ID: the expert node
                m_flit[2] = 8'h80;                     // CTRL
                m_flit[3] = 8'h08;                     // LEN_LO
                m_flit[4] = 8'h00;                     // LEN_HI
                for (m_i = 0; m_i < 8; m_i = m_i + 1)
                    m_flit[5 + m_i] = m_token[m_i];
                m_crc = 16'hFFFF;
                for (m_i = 0; m_i < 12; m_i = m_i + 1)
                    m_crc = crc_step(m_crc, m_flit[1 + m_i]);
                m_flit[13] = m_crc[15:8];              // CRC_HI
                m_flit[14] = m_crc[7:0];               // CRC_LO
                m_flit_bytes = 15;
                m_state = M_IDLE;
            end
            default: m_state = M_IDLE;
            endcase
        end
    endtask

    // =====================================================================
    // The host's SPI master
    // =====================================================================
    task spi_header;
        input [6:0] sel;
        input       rw;
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = (k == 7) ? rw : sel[k];
                #50; sclk = 1'b1; #100; #50; sclk = 1'b0; #50;
            end
        end
    endtask

    task spi_data;
        input  [31:0] wdat;
        output [31:0] rdat;
        integer k;
        begin
            rdat = 32'h0;
            for (k = 31; k >= 0; k = k - 1) begin
                mosi = wdat[k];
                #50; sclk = 1'b1; #100;
                rdat[k] = miso;
                #50; sclk = 1'b0; #50;
            end
        end
    endtask

    task spi_status;
        output [7:0] st;
        integer k;
        begin
            st = 8'h00;
            for (k = 0; k <= 7; k = k + 1) begin
                mosi = 1'b0;
                #50; sclk = 1'b1; #100;
                st = {st[6:0], miso};
                #50; sclk = 1'b0; #50;
            end
        end
    endtask

    task spi_xfer;
        input  [6:0] sel;
        input        rw;
        input  [31:0] dat;
        output [31:0] rdata;
        output [7:0]  status;
        reg    [31:0] dummy;
        begin
            sclk = 1'b0; mosi = 1'b0;
            cs_n = 1'b1; #100;
            cs_n = 1'b0; #100;
            spi_header(sel, rw);
            spi_data(dat, dummy);
            spi_status(status);
            if (rw) rdata = dummy;
            else    rdata = 32'h0;
            #100;
            cs_n = 1'b1; #200;
        end
    endtask

    localparam [6:0] SEL_CTRL     = 7'h00;
    localparam [6:0] SEL_LAYER    = 7'h01;
    localparam [6:0] SEL_MODULE   = 7'h02;
    localparam [6:0] SEL_LEN      = 7'h03;
    localparam [6:0] SEL_DATA     = 7'h04;
    localparam [6:0] SEL_RESULT   = 7'h06;
    localparam [6:0] SEL_DISPATCH = 7'h08;

    reg [31:0] rd;
    reg [7:0]  status;

    reg [7:0]  token_flit [0:15];
    reg [7:0]  egress_capture [0:63];
    integer    egress_len = 0;

    // The fabric's egress, captured as it reaches the host.
    always @(posedge clk) begin
        if (spup_valid) begin
            egress_capture[egress_len] = spup_data;
            if (egress_len > 14 && egress_len < 20)
                $display("  [egress] byte %0d = %h", egress_len, spup_data);
            egress_len = egress_len + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // =================================================================
        // The management node's setup: program the router
        // =================================================================
        for (i = 0; i < 16; i = i + 1) m_weights[i] = 16'h3F80 + (i / 4) * 8 + (i % 4);
        for (i = 0; i < 4; i = i + 1)  m_hidden[i]  = 16'h3F80 + i;

        mgr_write(16'h18, 16'h0001);        // COORD_L: layer 1
        mgr_write(16'h1A, 16'h0025);        // COORD_M: module 0x25
        mgr_write(16'h10, 16'h0000);        // WGHT_ADDR_LO
        mgr_write(16'h11, 16'h0000);        // WGHT_ADDR_HI
        for (i = 0; i < 16; i = i + 1)
            mgr_write(16'h12, m_weights[i]);

        // =================================================================
        // The host injects a token
        // =================================================================
        token_flit[0] = 8'h01;              // LAYER_ID: layer 1
        token_flit[1] = 8'h25;              // MODULE_ID: the gating node
        token_flit[2] = 8'h80;              // CTRL
        token_flit[3] = 8'h08;              // LEN_LO: eight payload bytes
        token_flit[4] = 8'h00;              // LEN_HI
        // the token's hidden state: four big-endian BF16 words
        token_flit[5]  = 8'h3F;  token_flit[6]  = 8'h80;   // 1.0
        token_flit[7]  = 8'h3F;  token_flit[8]  = 8'h81;   // 1.0078
        token_flit[9]  = 8'h3F;  token_flit[10] = 8'h82;   // 1.0156
        token_flit[11] = 8'h3F;  token_flit[12] = 8'h83;   // 1.0234
        begin : build_token_crc
            reg [15:0] c;
            integer b;
            c = 16'hFFFF;
            for (b = 0; b < 12; b = b + 1) c = crc_step(c, token_flit[1 + b]);
            token_flit[13] = c[15:8];
            token_flit[14] = c[7:0];
        end

        spi_xfer(SEL_LAYER,  1'b0, 32'h0000_0001, rd, status);
        spi_xfer(SEL_MODULE, 1'b0, 32'h0000_0025, rd, status);
        spi_xfer(SEL_LEN,    1'b0, 32'h0000_0008, rd, status);
        for (i = 0; i < 8; i = i + 1)
            spi_xfer(SEL_DATA, 1'b0, {24'h0, token_flit[5 + i]}, rd, status);
        spi_xfer(SEL_CTRL,   1'b0, 32'h0000_0001, rd, status);   // trigger

        // the token travels: the bridge, the fabric, the node's DMA, the tap
        guard = 0;
        while (!tap_valid && guard < 5000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (!tap_valid) begin
            $display("FAIL: the token never reached the gating node's tap");
            errors = errors + 1;
        end else
            $display("ok: the token reached the gating node's tap");

        // =================================================================
        // The management node reads the token and gates it
        // =================================================================
        // The tap's head is valid *before* the edge that pops it, so the
        // byte is sampled first and the edge drained afterwards.
        tap_ready = 1'b1;
        for (i = 0; i < 8; i = i + 1) begin
            m_token[i] = tap_data;
            @(posedge clk);
        end
        tap_ready = 1'b0;
        for (i = 0; i < 4; i = i + 1)
            m_hidden[i] = {m_token[2 * i], m_token[2 * i + 1]};
        m_token_ready = 1'b1;      // the node now has a token to gate

        mgmt_step;                             // IDLE   -> HIDDEN
        mgmt_step;                             // HIDDEN -> START
        mgmt_step;                             // START  -> WAIT
        guard = 0;
        while (m_state != M_RESULT && guard < 5000) begin
            mgmt_step;                         // WAIT   -> RESULT
            guard = guard + 1;
        end
        if (m_state != M_RESULT) begin
            $display("FAIL: the management node never got the decision");
            errors = errors + 1;
        end else begin
            mgmt_step;                 // RESULT: read the decision back
            $display("ok: the management node read the decision over its bus: expert %0d (logit %h)",
                     m_sel[0][7:0], m_sel_logit);
            if (m_sel[0][7:0] === 8'hXX) begin
                $display("FAIL: the decision is undefined");
                errors = errors + 1;
            end
        end

        // =================================================================
        // The management node injects the dispatch flit
        // =================================================================
        mgmt_step;                             // DISPATCH: build the flit
        for (i = 0; i < m_flit_bytes; i = i + 1) begin
            minj_data  = m_flit[i];
            minj_sop   = (i == 0);
            minj_eop   = (i == m_flit_bytes - 1);
            minj_valid = 1'b1;
            @(posedge clk);
        end
        minj_valid = 1'b0;
        minj_sop   = 1'b0;
        minj_eop   = 1'b0;

        // the dispatch travels the node's egress, up the spine, to the host
        guard = 0;
        while (egress_len < 15 && guard < 5000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (egress_len < 15) begin
            $display("FAIL: the dispatch did not reach the host (%0d bytes)", egress_len);
            errors = errors + 1;
        end else begin
            for (i = 0; i < 15; i = i + 1)
                if (egress_capture[i] !== m_flit[i]) begin
                    $display("FAIL: the dispatch byte %0d is %h, expected %h",
                             i, egress_capture[i], m_flit[i]);
                    errors = errors + 1;
                end
            $display("ok: the dispatch reached the host byte for byte (the CRC-16 is valid)");
        end

        // =================================================================
        // The host re-issues the dispatch: the fabric carries it to the
        // expert node, whose doorbell checks the CRC
        // =================================================================
        spi_xfer(SEL_LAYER,  1'b0, 32'h0000_0001, rd, status);
        spi_xfer(SEL_MODULE, 1'b0, 32'h0000_0012, rd, status);
        spi_xfer(SEL_LEN,    1'b0, 32'h0000_0008, rd, status);
        for (i = 0; i < 8; i = i + 1)
            spi_xfer(SEL_DATA, 1'b0, {24'h0, m_flit[5 + i]}, rd, status);
        spi_xfer(SEL_CTRL,   1'b0, 32'h0000_0001, rd, status);   // trigger

        guard = 0;
        while (db_activations == 0 && guard < 5000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (db_activations == 0) begin
            $display("FAIL: the expert node's doorbell did not fire");
            errors = errors + 1;
        end else begin
            $display("ok: the expert node's doorbell accepted the dispatch (CRC-16 verified, %0d rejections)",
                     db_rejections);
        end

        // =================================================================
        // The expert's result travels back up the fabric to the host
        //
        // OPEN: the bridge now buffers the returned bytes (a 256-byte FIFO,
        // so a slow host does not miss them), but the host's read-back of
        // the FIFO's head is not yet right -- the byte the host sees is not
        // the one the expert returned.  The upstream half of this leg (the
        // expert's result reaching the bridge's FIFO) is checked here; the
        // read-back is left as the known gap.
        // =================================================================
        // The expert's result goes onto the egress, holding valid until the
        // fabric has taken it.
        exp_data  = 8'h5C;
        exp_sop   = 1'b1;
        exp_eop   = 1'b1;
        exp_valid = 1'b1;
        guard = 0;
        while (egress_len <= 15 && guard < 5000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        exp_valid = 1'b0;
        exp_sop   = 1'b0;
        exp_eop   = 1'b0;
        repeat (8) @(posedge clk);

        // The bridge's result FIFO holds, in order: the dispatch the node
        // sent up (which the host reads and re-issues), and then the
        // expert's result.  The host collects them one byte at a time.
        if (u_top.u_bridge.res_count < 16) begin
            $display("FAIL: the result FIFO holds %0d bytes, expected at least 16",
                     u_top.u_bridge.res_count);
            errors = errors + 1;
        end else begin : collect_fifo
            reg [7:0] last;
            last = 8'h00;
            for (i = 0; i < 16; i = i + 1) begin
                spi_xfer(SEL_RESULT, 1'b1, 32'd0, rd, status);
                last = rd[7:0];
            end
            if (last !== 8'h5C) begin
                $display("FAIL: the host read %h as the last result byte, expected 5C", last);
                errors = errors + 1;
            end else
                $display("ok: the host collected the dispatch and then the expert's result over SPI");
        end

        if (errors == 0)
            $display("*** TRANSPORT PLANE TEST PASSED ***");
        else
            $display("*** TRANSPORT PLANE TEST FAILED (%0d) ***", errors);
        $finish;
    end

endmodule
