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
        begin
            #1;
            mgmt_addr  = addr;
            mgmt_wdata = wdata;
            mgmt_we    = 1'b1;
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

    // A single write on the embedded management node's bus.
    task mgmt_write;
        input [15:0] addr;
        input [15:0] wdata;
        begin
            mgmt_prime;
            mgmt_xfer(addr, wdata);
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
                mgmt_xfer(REG_WGHT_ADDR_LO, e * HIDDEN_DIM);
                mgmt_xfer(REG_WGHT_ADDR_HI, 16'd0);
                for (h = 0; h < HIDDEN_DIM; h = h + 1)
                    mgmt_xfer(REG_WGHT_DATA, pick(e * HIDDEN_DIM + h + 1));
            end
            mgmt_xfer(REG_HID_ADDR_LO, 16'd0);
            mgmt_xfer(REG_HID_ADDR_HI, 16'd0);
            for (h = 0; h < HIDDEN_DIM; h = h + 1)
                mgmt_xfer(REG_HID_DATA, pick(h + 2));
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
