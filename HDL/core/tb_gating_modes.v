`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The gating ASIC has two managers.
//
//   mode A (mgmt_sel = 1): the *embedded management node* on the node board
//     -- an MCU or a Raspberry Pi Compute Module -- drives the register bus
//     directly.  It also owns the node's memory, so it stages the gating
//     weights locally and reads the token's hidden state from local DRAM: the
//     per-token decision never leaves the board.
//
//   mode B (mgmt_sel = 0): the *host* owns the machine.  The host's gating
//     programming arrives over the fabric as a byte stream and is decoded into
//     the same register map (3 bytes per write: [reg][data_lo][data_hi]).
//     Every decision and every byte of the token's routing round-trips
//     through the fabric, which is exactly the bottleneck mode A removes.
//
// The silicon is the same in both modes; only the manager changes.  This
// testbench programs the same weights and the same hidden state through each
// path and requires the same decision.
// ---------------------------------------------------------------------------

module tb_gating_modes;

    localparam NUM_EXPERTS = 8;
    localparam HIDDEN_DIM  = 16;
    localparam TOP_K       = 2;
    localparam ADDR_BITS   = 8;   // covers NUM_EXPERTS*HIDDEN_DIM = 128
    localparam ARRAY_SIZE  = 4;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;

    // the chip's local bus (mode B's idle path)
    reg  [15:0] bus_addr = 16'd0;
    reg  [15:0] bus_wdata = 16'd0;
    wire [15:0] bus_rdata;
    reg         bus_we = 1'b0;
    reg         bus_valid = 1'b0;
    wire        bus_ready;

    // the embedded management node's bus (mode A)
    reg         mgmt_sel = 1'b0;
    reg  [15:0] mgmt_addr = 16'd0;
    reg  [15:0] mgmt_wdata = 16'd0;
    wire [15:0] mgmt_rdata;
    reg         mgmt_we = 1'b0;
    reg         mgmt_valid = 1'b0;
    wire        mgmt_ready;

    // the fabric programming stream (mode B)
    reg  [7:0]  prog_data = 8'd0;
    reg  [15:0] prog_raddr = 16'd0;
    reg         prog_rvalid = 1'b0;
    wire        prog_rready;
    wire [15:0] prog_rdata;
    reg         prog_valid = 1'b0;
    reg         prog_sop = 1'b0;
    reg         prog_eop = 1'b0;

    wire [TOP_K*8-1:0]  expert_idx;
    wire [TOP_K*16-1:0] expert_logit;
    wire [TOP_K*8-1:0]  expert_layer;
    wire [TOP_K*8-1:0]  expert_module;
    wire                 result_valid;
    wire                 busy;
    wire                 done;
    wire [31:0]          cycle_count;

    gating_asic #(
        .NUM_EXPERTS(NUM_EXPERTS),
        .HIDDEN_DIM(HIDDEN_DIM),
        .TOP_K(TOP_K),
        .ADDR_BITS(ADDR_BITS),
        .ARRAY_SIZE(ARRAY_SIZE),
        .WEIGHT_DEPTH(NUM_EXPERTS*HIDDEN_DIM),
        .HIDDEN_DEPTH(HIDDEN_DIM)
    ) u_asic (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_we(bus_we), .bus_valid(bus_valid), .bus_ready(bus_ready),
        .mgmt_sel(mgmt_sel), .mgmt_addr(mgmt_addr), .mgmt_wdata(mgmt_wdata),
        .mgmt_rdata(mgmt_rdata), .mgmt_we(mgmt_we), .mgmt_valid(mgmt_valid),
        .mgmt_ready(mgmt_ready),
        .prog_data(prog_data), .prog_valid(prog_valid),
        .prog_sop(prog_sop), .prog_eop(prog_eop),
        .prog_raddr(prog_raddr), .prog_rvalid(prog_rvalid),
        .prog_rready(prog_rready), .prog_rdata(prog_rdata),
        .expert_idx(expert_idx), .expert_logit(expert_logit),
        .expert_layer(expert_layer), .expert_module(expert_module),
        .result_valid(result_valid),
        .busy(busy), .done(done), .cycle_count(cycle_count)
    );

    // Register map (byte offsets).
    localparam [15:0] REG_CTRL      = 16'h0000;
    localparam [15:0] REG_STATUS    = 16'h0002;
    localparam [15:0] REG_WGHT_ADDR_LO = 16'h0010;
    localparam [15:0] REG_WGHT_ADDR_HI = 16'h0011;
    localparam [15:0] REG_WGHT_DATA = 16'h0012;
    localparam [15:0] REG_HID_ADDR_LO = 16'h0014;
    localparam [15:0] REG_HID_ADDR_HI = 16'h0015;
    localparam [15:0] REG_HID_DATA  = 16'h0016;
    localparam [15:0] REG_COORD_L   = 16'h0018;
    localparam [15:0] REG_COORD_M   = 16'h001A;
    localparam [15:0] REG_RES_IDX0  = 16'h0020;
    localparam [15:0] REG_RES_LOG0  = 16'h0024;
    localparam [15:0] REG_RANK_IDX  = 16'h0200;
    localparam [15:0] REG_RANK_LOG  = 16'h0280;
    localparam [15:0] REG_LOGIT     = 16'h0030;

    // BF16 "greater than", using the library's own comparator so the
    // negative values (whose sign is the MSB) order correctly.
    function bf16_gt;
        input [15:0] a;
        input [15:0] b;
        begin
            if (a[15] != b[15])
                bf16_gt = ~a[15] & ((a[14:7] != 0) | (b[14:7] != 0));
            else if (a[14:7] == 0)
                bf16_gt = 1'b0;
            else if (b[14:7] == 0)
                bf16_gt = ~a[15];
            else if (a[15])
                bf16_gt = (a[14:0] < b[14:0]);
            else
                bf16_gt = (a[14:0] > b[14:0]);
        end
    endfunction

    // A small table of easy BF16 constants: 1, 2, 3, 4, 0.5, 0.25 and their
    // negatives.  The weights are distinct per expert so the top-k is not
    // degenerate.
    function [15:0] pick;
        input integer k;
        begin
            case (k % 10)
                0: pick = 16'h3F80;  //  1.0
                1: pick = 16'h4000;  //  2.0
                2: pick = 16'hC000;  // -2.0
                3: pick = 16'h3F00;  //  0.5
                4: pick = 16'hBF80;  // -1.0
                5: pick = 16'h4040;  //  3.0
                6: pick = 16'h3E80;  //  0.25
                7: pick = 16'h4080;  //  4.0
                8: pick = 16'hBF00;  // -0.5
                default: pick = 16'h3F80;
            endcase
        end
    endfunction

    integer e, h, i;
    reg [15:0] rd_idx, rd_log, peek_max;
    reg [15:0] idx_a [0:TOP_K-1];
    reg [15:0] idx_b [0:TOP_K-1];
    reg [15:0] log_a [0:TOP_K-1];
    reg [15:0] log_b [0:TOP_K-1];
    integer errors = 0;

    // ---------------------------------------------------------------------
    // Bus helpers.
    //
    // The bus accepts one transaction per edge while valid is high: ready is
    // a registered copy of valid, so the first edge after valid rises only
    // arms the handshake and every edge after that is one transaction.  The
    // client therefore keeps valid high across a burst of writes and drops it
    // for an idle edge in between (exactly what tb_gating_server.v does).
    // ---------------------------------------------------------------------
    task mgmt_xfer;
        input [15:0] addr;
        input [15:0] wdata;
        input        we;
        begin
            #1;
            mgmt_addr  = addr;
            mgmt_wdata = wdata;
            mgmt_we    = we;
            mgmt_valid = 1'b1;
            @(posedge clk);
        end
    endtask

    // Arm the handshake with a harmless control write and keep valid high.
    task mgmt_start_burst;
        begin
            mgmt_prime;
        end
    endtask

    // Drop valid for one idle edge (the handshake drains).
    task mgmt_idle;
        begin
            #1;
            mgmt_valid = 1'b0;
            mgmt_we    = 1'b0;
            @(posedge clk);
        end
    endtask

    // Arm the handshake: one harmless control write, then keep valid high so
    // the burst continues (ready stays asserted while valid is high).
    task mgmt_prime;
        begin
            #1;
            mgmt_addr  = REG_CTRL;
            mgmt_wdata = 16'd0;
            mgmt_we    = 1'b1;
            mgmt_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    // A single read on the embedded management node's bus.  It needs the
    // same priming as a write: ready is a registered copy of valid, so the
    // first edge only arms the handshake and the second fires the
    // transaction.
    task mgmt_read;
        input  [15:0] addr;
        output [15:0] rdata;
        begin
            mgmt_prime;
            mgmt_xfer(addr, 16'd0, 1'b0);
            mgmt_idle;
            rdata = mgmt_rdata;
        end
    endtask

    // A single write on the embedded management node's bus.
    task mgmt_write;
        input [15:0] addr;
        input [15:0] wdata;
        begin
            mgmt_prime;
            mgmt_xfer(addr, wdata, 1'b1);
            mgmt_idle;
        end
    endtask

    // ---------------------------------------------------------------------
    // The fabric programming stream (mode B): three bytes per register
    // write, [reg_addr][data_lo][data_hi].  The address is a byte offset, so
    // only the low register block (control + weight/hidden programming) is
    // reachable this way; the logit window stays read-only on the bus.
    // ---------------------------------------------------------------------
    task prog_byte;
        input [7:0] b;
        begin
            prog_data  = b;
            prog_valid = 1'b1;
            @(posedge clk);
        end
    endtask

    task prog_write;
        input [15:0] addr;
        input [15:0] wdata;
        begin
            prog_byte(addr[7:0]);
            prog_byte(wdata[7:0]);
            prog_byte(wdata[15:8]);
            prog_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            @(posedge clk);
            @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // Wait for the gating engine to finish.
    task wait_done;
        integer guard;
        begin
            guard = 0;
            while (!done && guard < 10000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 10000) begin
                $display("FAIL: the gating engine did not finish");
                errors = errors + 1;
            end
        end
    endtask

    // Program the whole weight matrix and the hidden vector on the embedded
    // management node's bus (mode A).
    task program_mode_a;
        begin
            mgmt_write(REG_COORD_L, 16'd3);
            mgmt_write(REG_COORD_M, 16'd5);
            mgmt_prime;
            for (e = 0; e < NUM_EXPERTS; e = e + 1) begin
                mgmt_xfer(REG_WGHT_ADDR_LO, e * HIDDEN_DIM, 1'b1);
                mgmt_xfer(REG_WGHT_ADDR_HI, 16'd0, 1'b1);
                for (h = 0; h < HIDDEN_DIM; h = h + 1)
                    mgmt_xfer(REG_WGHT_DATA, pick(e * HIDDEN_DIM + h + 1), 1'b1);
            end
            mgmt_xfer(REG_HID_ADDR_LO, 16'd0, 1'b1);
            mgmt_xfer(REG_HID_ADDR_HI, 16'd0, 1'b1);
            for (h = 0; h < HIDDEN_DIM; h = h + 1)
                mgmt_xfer(REG_HID_DATA, pick(h + 2), 1'b1);
            mgmt_idle;
        end
    endtask

    // The same programming over the fabric (mode B).
    task program_mode_b;
        begin
            prog_write(REG_COORD_L, 16'd3);
            prog_write(REG_COORD_M, 16'd5);
            for (e = 0; e < NUM_EXPERTS; e = e + 1) begin
                prog_write(REG_WGHT_ADDR_LO, e * HIDDEN_DIM);
                prog_write(REG_WGHT_ADDR_HI, 16'd0);
                for (h = 0; h < HIDDEN_DIM; h = h + 1)
                    prog_write(REG_WGHT_DATA, pick(e * HIDDEN_DIM + h + 1));
            end
            prog_write(REG_HID_ADDR_LO, 16'd0);
            prog_write(REG_HID_ADDR_HI, 16'd0);
            for (h = 0; h < HIDDEN_DIM; h = h + 1)
                prog_write(REG_HID_DATA, pick(h + 2));
        end
    endtask

    initial begin
        $display("=== gating ASIC: the two management modes ===");

        // ---------------- mode A: the embedded management node ----------------
        mgmt_sel = 1'b1;
        do_reset;
        program_mode_a;
        mgmt_write(REG_CTRL, 16'h0001);
        wait_done;
        for (i = 0; i < TOP_K; i = i + 1) begin
            idx_a[i] = expert_idx[i*8 +: 8];
            log_a[i] = expert_logit[i*16 +: 16];
        end
        $display("mode A (embedded management node): top-%0d = %0d, %0d", TOP_K,
                 idx_a[0], idx_a[1]);

        // The management node must be able to read the decision back over
        // its own bus -- that is the whole point of mode A.  Check every
        // rank through the rank window, and check the logit peek window
        // too: the peek index has to follow the *effective* bus, or in mode A
        // it would be stuck on expert 0.
        for (i = 0; i < TOP_K; i = i + 1) begin
            mgmt_read(REG_RANK_IDX + 2*i, rd_idx);
            mgmt_read(REG_RANK_LOG + 2*i, rd_log);
            if (rd_idx[7:0] !== idx_a[i]) begin
                $display("FAIL: rank %0d id over the bus: %0d != %0d",
                         i, rd_idx[7:0], idx_a[i]);
                errors = errors + 1;
            end
            if (rd_log !== log_a[i]) begin
                $display("FAIL: rank %0d logit over the bus: %h != %h",
                         i, rd_log, log_a[i]);
                errors = errors + 1;
            end
        end
        // The logit peek window must address the expert the manager asked
        // for.  The invariant that catches it: scanning the whole window,
        // the largest logit must be the rank-0 logit the engine selected.
        // If the peek index followed the chip's idle bus instead of the
        // effective one, every read would return expert 0 and the maximum
        // would not match.
        peek_max = 16'hFF80;   // negative infinity: the minimum BF16
        for (i = 0; i < NUM_EXPERTS; i = i + 1) begin
            mgmt_read(REG_LOGIT + 2*i, rd_log);
            if (rd_log === 16'hxxxx || rd_log === 16'hzzzz) begin
                $display("FAIL: logit peek window is unreadable at expert %0d", i);
                errors = errors + 1;
                i = NUM_EXPERTS;   // one report is enough
            end else if (bf16_gt(rd_log, peek_max)) begin
                peek_max = rd_log;
            end
        end
        if (bf16_gt(peek_max, log_a[0]) || bf16_gt(log_a[0], peek_max)) begin
            $display("FAIL: the logit peek window's maximum %h is not the selected rank-0 logit %h",
                     peek_max, log_a[0]);
            errors = errors + 1;
        end

        // ---------------- mode B: the host over the fabric ----------------
        mgmt_sel = 1'b0;
        do_reset;
        program_mode_b;
        prog_write(REG_CTRL, 16'h0001);
        wait_done;
        for (i = 0; i < TOP_K; i = i + 1) begin
            idx_b[i] = expert_idx[i*8 +: 8];
            log_b[i] = expert_logit[i*16 +: 16];
        end
        $display("mode B (host over the fabric):      top-%0d = %0d, %0d", TOP_K,
                 idx_b[0], idx_b[1]);

        // The mode-B manager reads the decision back over the fabric-side
        // read channel.  Without it a manager that is not the management
        // node could program the gating engine but never read its decision.
        begin : mode_b_read
            reg [15:0] r;
            integer kk;
            for (kk = 0; kk < TOP_K; kk = kk + 1) begin
                prog_raddr  = 16'h0200 + 16'd2 * kk[15:0];
                prog_rvalid = 1'b1;
                #1;
                r = prog_rdata;
                prog_rvalid = 1'b0;
                if (r[7:0] !== idx_b[kk][7:0]) begin
                    $display("FAIL: mode B read rank %0d id %h, expected %h",
                             kk, r[7:0], idx_b[kk][7:0]);
                    errors = errors + 1;
                end
                prog_raddr  = 16'h0280 + 16'd2 * kk[15:0];
                prog_rvalid = 1'b1;
                #1;
                r = prog_rdata;
                prog_rvalid = 1'b0;
                if (r !== log_b[kk]) begin
                    $display("FAIL: mode B read rank %0d logit %h, expected %h",
                             kk, r, log_b[kk]);
                    errors = errors + 1;
                end
            end
            $display("ok: the mode-B manager read the decision back over the fabric-side channel");
        end

        // ---------------- the two modes must agree ----------------
        for (i = 0; i < TOP_K; i = i + 1) begin
            if (idx_a[i] !== idx_b[i]) begin
                $display("FAIL: rank %0d differs: %0d vs %0d", i, idx_a[i], idx_b[i]);
                errors = errors + 1;
            end
            if (log_a[i] !== log_b[i]) begin
                $display("FAIL: rank %0d logit differs: %h vs %h", i, log_a[i], log_b[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("*** GATING MODE TEST PASSED ***");
        else
            $display("*** GATING MODE TEST FAILED (%0d) ***", errors);
        $finish;
    end

endmodule
