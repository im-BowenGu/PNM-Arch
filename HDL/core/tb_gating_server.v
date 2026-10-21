`timescale 1ns/1ps

// =============================================================================
// tb_gating_server — persistent Gating-ASIC server for the pnmgate harness.
//
// The harness (pnmgate) boots this process once per gated layer:
//   1. BOOT   : the real router.proj.weight rows for the layer are streamed
//               over the ASIC register bus into moe_gating's on-chip weight
//               SRAM ("load gating network into ram").  Address auto-increment
//               makes this one WGHT_DATA bus write per weight word.
//   2. SERVE  : loop over requests n = 0,1,2,...
//       * wait for file "req_<n>.go"  (written by the harness)
//       * $readmemh("h_<n>.hex") -> hidden words -> streamed into the hidden
//         SRAM over the bus (also auto-increment)
//       * write CTRL.start, wait moe_gating done
//       * read all NUM_EXPERTS logits via the LOGIT[REG_LOGIT+2*e] window
//       * write "res_<n>.txt" (top-k expert ids + all logits, BF16 hex) then
//         create "res_<n>.done" (completion marker; the harness reads the
//         .txt only after .done exists, so $fclose has flushed)
// The server runs until MAXREQ requests are served (MAXREQ=0 = forever, the
// harness kills the process when inference finishes).
//
// Bus discipline: every bus_op does exactly ONE bus transaction.  After each
// transaction the interface is drained (valid low for a cycle) so the ready
// latch resets; stream loops keep valid/ready asserted across N consecutive
// one-transaction-edges.  The WGHT_DATA and HIDDEN_DATA writes auto-increment
// the target SRAM address, so weights / hidden words load back-to-back.
// =============================================================================

module tb_gating_server;

    parameter NUM_EXPERTS  = 128;
    parameter HIDDEN_DIM   = 2816;
    parameter TOP_K        = 8;
    parameter ADDR_BITS    = 19;
    parameter LAYER        = 0;
    parameter MAXREQ       = 0;
    parameter CLK_PERIOD   = 10;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n = 0;

    reg [15:0] bus_addr  = 16'h0000;
    reg [15:0] bus_wdata = 16'h0000;
    wire [15:0] bus_rdata;
    reg        bus_we    = 0;
    reg        bus_valid = 0;
    wire       bus_ready;

    wire [TOP_K*8-1:0]   expert_idx;
    wire [TOP_K*16-1:0]  expert_logit;
    wire [TOP_K*8-1:0]   expert_layer;
    wire [TOP_K*8-1:0]   expert_module;
    wire                 result_valid;
    wire                 busy, done;
    wire [31:0]          cycle_count;

    localparam [15:0] REG_CTRL      = 16'h0000;
    localparam [15:0] REG_STATUS    = 16'h0002;
    localparam [15:0] REG_WGHT_DATA = 16'h0012;
    localparam [15:0] REG_HID_ADDR_LO = 16'h0014;
    localparam [15:0] REG_HID_DATA  = 16'h0016;
    localparam [15:0] REG_COORD_L   = 16'h0018;
    localparam [15:0] REG_COORD_M   = 16'h001A;
    localparam [15:0] REG_LOGIT     = 16'h0030;

    gating_asic #(
        .NUM_EXPERTS(NUM_EXPERTS),
        .HIDDEN_DIM(HIDDEN_DIM),
        .TOP_K(TOP_K),
        .ADDR_BITS(ADDR_BITS),
        .WEIGHT_DEPTH(NUM_EXPERTS*HIDDEN_DIM),
        .HIDDEN_DEPTH(HIDDEN_DIM)
    ) u_asic (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_we(bus_we), .bus_valid(bus_valid), .bus_ready(bus_ready),
        // the chip's local bus is the manager in this server; the embedded
        // management node's bus and the fabric stream are idle
        .mgmt_sel(1'b0), .mgmt_addr(16'd0), .mgmt_wdata(16'd0),
        .mgmt_rdata(), .mgmt_we(1'b0), .mgmt_valid(1'b0), .mgmt_ready(),
        .prog_data(8'd0), .prog_valid(1'b0), .prog_sop(1'b0), .prog_eop(1'b0),
        .expert_idx(expert_idx), .expert_logit(expert_logit),
        .expert_layer(expert_layer), .expert_module(expert_module),
        .result_valid(result_valid),
        .busy(busy), .done(done), .cycle_count(cycle_count)
    );

    // ---------------------------------------------------------------------
    reg [15:0] wmem  [0:NUM_EXPERTS*HIDDEN_DIM-1];
    reg [15:0] hmem  [0:HIDDEN_DIM-1];
    reg [255:0] fname_hex;
    reg [255:0] fname_go;
    reg [255:0] fname_res;
    reg [255:0] fname_done;
    reg [7:0]  layer_reg;
    reg [15:0] lmem [0:0];
    integer n, fd, e, i;

    // Exactly ONE bus transaction (valid&&ready both 1 on the 2nd edge, ready
    // having latched from a drained cold state).
    task bus_op;
        input [15:0] addr;
        input [15:0] wdata;
        input        we;
        begin
            bus_addr  = addr;
            bus_wdata = wdata;
            bus_we    = we;
            bus_valid = 1'b1;
            @(posedge clk);              // ready latches 1
            @(posedge clk);              // transaction fires
            bus_valid = 1'b0;
            bus_we    = 1'b0;
            @(posedge clk);              // drain -> ready latches 0
        end
    endtask

    // One stream write per call (valid/ready already hot from priming).
    task stream_data;
        input [15:0] addr;
        input [15:0] wdata;
        begin
            bus_addr  = addr;
            bus_wdata = wdata;
            bus_we    = 1'b1;
            bus_valid = 1'b1;
            @(posedge clk);              // one transaction (ready==1)
        end
    endtask

    // Prime the bus so one stream_data call == one transaction, without
    // disturbing the weight/hidden address pointers (CTRL write is harmless).
    task prime_bus;
        begin
            bus_addr  = REG_CTRL;
            bus_wdata = 16'h0000;
            bus_we    = 1'b1;
            bus_valid = 1'b1;
            @(posedge clk);              // ready latches 1
            @(posedge clk);              // harmless CTRL transaction
        end
    endtask

    task drain_bus;
        begin
            bus_valid = 1'b0;
            bus_we    = 1'b0;
            @(posedge clk);              // ready latches 0
        end
    endtask

    initial begin
        n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- BOOT: load the gating network into the ASIC weight SRAM ----
        layer_reg = LAYER;
        lmem[0] = 0;
        $readmemh("layer.hex", lmem);
        layer_reg = lmem[0][7:0];
        $readmemh("w_0.hex", wmem);
        bus_op(REG_COORD_L, {8'd0, layer_reg}, 1'b1);
        bus_op(REG_COORD_M, 16'h0000, 1'b1);
        // address registers are zero after reset; auto-increment handles the rest
        prime_bus;
        for (i = 0; i < NUM_EXPERTS*HIDDEN_DIM; i = i + 1)
            stream_data(REG_WGHT_DATA, wmem[i]);
        drain_bus;
        $display("ASIC-READY E=%0d W=%0d K=%0d L=%0d", NUM_EXPERTS, HIDDEN_DIM, TOP_K, LAYER);
        fd = $fopen("status.txt", "w");
        $fwrite(fd, "ready %0d %0d %0d %0d\n", NUM_EXPERTS, HIDDEN_DIM, TOP_K, layer_reg);
        $fclose(fd);

        // ---- SERVE -------------------------------------------------------
        forever begin
            $swrite(fname_go,  "req_%0d.go",  n);
            $swrite(fname_hex, "h_%0d.hex",  n);
            $swrite(fname_res, "res_%0d.txt", n);
            $swrite(fname_done,"res_%0d.done", n);

            // wait for the harness request marker
            fd = $fopen(fname_go, "r");
            while (fd == 0) begin
                #(CLK_PERIOD*8);
                fd = $fopen(fname_go, "r");
            end
            $fclose(fd);
            // hidden write pointer auto-wraps at HIDDEN_DIM, so streaming one
            // region's worth of words per request (re)loads from the base.

            // stream hidden words into the hidden SRAM
            $readmemh(fname_hex, hmem);
            prime_bus;
            for (i = 0; i < HIDDEN_DIM; i = i + 1)
                stream_data(REG_HID_DATA, hmem[i]);
            drain_bus;

            // start gating
            bus_op(REG_CTRL, 16'h0001, 1'b1);   // start = 1
            bus_op(REG_CTRL, 16'h0000, 1'b1);   // clear

            while (!done) @(posedge clk);
            @(posedge clk);
            @(posedge clk);

            // top-k ids (wires) + all logits (register window)
            fd = $fopen(fname_res, "w");
            $fwrite(fd, "idx");
            for (e = 0; e < TOP_K; e = e + 1)
                $fwrite(fd, " %0d", expert_idx[e*8 +: 8]);
            $fwrite(fd, "\n");
            for (e = 0; e < NUM_EXPERTS; e = e + 1) begin
                bus_op(REG_LOGIT + 2*e, 16'h0000, 1'b0);
                $fwrite(fd, "%04x ", bus_rdata);
            end
            $fwrite(fd, "\n");
            $fclose(fd);

            // completion marker (after $fclose has flushed)
            fd = $fopen(fname_done, "w");
            $fwrite(fd, "done %0d\n", n);
            $fclose(fd);

            $display("ASIC-RES %0d done cyc=%0d", n, cycle_count);
            n = n + 1;
            if (MAXREQ > 0 && n >= MAXREQ) begin
                $display("ASIC-QUIT served=%0d", MAXREQ);
                $finish;
            end
        end
    end

endmodule