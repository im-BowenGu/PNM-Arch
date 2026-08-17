`timescale 1ns/1ps

`include "pnm_defs.vh"

// =============================================================================
// tb_router_chip — self-checking testbench for the central router chip
//
// Exercises:
//   1. POST discovery: all nodes assert topology_rdy
//   2. Routing table load: 3 entries via PCIe
//   3. MoE map load: 2 entries via PCIe
//   4. Weight upload: one flit (8 bytes payload) via PCIe → spine
//   5. Inference: one token dispatch via PCIe → spine
//
// Pass conditions:
//   - boot_done asserts after POST + weight load
//   - dispatches == 1 after inference token
//   - weight_flits >= 1 after weight upload
//   - No errors
// =============================================================================
module tb_router_chip;

    reg         clk = 0;
    reg         rst_n = 0;

    // Clock: 100 MHz (10 ns period)
    always #5 clk = ~clk;

    // Parameters
    localparam NUM_LAYERS  = 4;
    localparam BOARD_X     = 4;
    localparam BOARD_Y     = 4;
    localparam NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y;
    localparam MAX_EXPERTS = 128;
    localparam TOP_K       = 8;
    localparam HIDDEN_SIZE = 2816;

    // PCIe ingress
    reg  [7:0] pcie_in_data;
    reg        pcie_in_valid;
    reg        pcie_in_sop;
    reg        pcie_in_eop;
    wire       pcie_in_ready;

    // PCIe egress
    wire [7:0] pcie_out_data;
    wire       pcie_out_valid;
    wire       pcie_out_sop;
    wire       pcie_out_eop;
    reg        pcie_out_ready;

    // Spine injection
    wire [7:0] spine_inject_data;
    wire       spine_inject_valid;
    wire       spine_inject_sop;
    wire       spine_inject_eop;
    reg        spine_inject_ready;
    wire [1:0] spine_inject_vc;

    // Spine extraction
    reg  [7:0] spine_extract_data;
    reg        spine_extract_valid;
    reg        spine_extract_sop;
    reg        spine_extract_eop;
    reg  [1:0] spine_extract_vc;

    // POST sideband
    reg  [NUM_NODES-1:0] topology_rdy;

    // Status
    wire       boot_done;
    wire [31:0] dispatches;
    wire [31:0] weight_flits;
    wire [31:0] errors;

    // DUT
    router_chip #(
        .NUM_LAYERS(NUM_LAYERS),
        .BOARD_X(BOARD_X),
        .BOARD_Y(BOARD_Y),
        .MAX_EXPERTS(MAX_EXPERTS),
        .TOP_K(TOP_K),
        .HIDDEN_SIZE(HIDDEN_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .pcie_in_data(pcie_in_data),
        .pcie_in_valid(pcie_in_valid),
        .pcie_in_sop(pcie_in_sop),
        .pcie_in_eop(pcie_in_eop),
        .pcie_in_ready(pcie_in_ready),
        .pcie_out_data(pcie_out_data),
        .pcie_out_valid(pcie_out_valid),
        .pcie_out_sop(pcie_out_sop),
        .pcie_out_eop(pcie_out_eop),
        .pcie_out_ready(pcie_out_ready),
        .spine_inject_data(spine_inject_data),
        .spine_inject_valid(spine_inject_valid),
        .spine_inject_sop(spine_inject_sop),
        .spine_inject_eop(spine_inject_eop),
        .spine_inject_ready(spine_inject_ready),
        .spine_inject_vc(spine_inject_vc),
        .spine_extract_data(spine_extract_data),
        .spine_extract_valid(spine_extract_valid),
        .spine_extract_sop(spine_extract_sop),
        .spine_extract_eop(spine_extract_eop),
        .spine_extract_vc(spine_extract_vc),
        .topology_rdy(topology_rdy),
        .boot_done(boot_done),
        .dispatches(dispatches),
        .weight_flits(weight_flits),
        .errors(errors)
    );

    // =========================================================================
    // Task: send one byte via PCIe
    // =========================================================================
    task pcie_send_byte;
        input [7:0] data;
        input       sop;
        input       eop;
        begin
            @(posedge clk);
            pcie_in_data  <= data;
            pcie_in_valid <= 1;
            pcie_in_sop   <= sop;
            pcie_in_eop   <= eop;
            @(posedge clk);
            // Wait for ready
            while (!pcie_in_ready) @(posedge clk);
            pcie_in_valid <= 0;
            pcie_in_sop   <= 0;
            pcie_in_eop   <= 0;
        end
    endtask

    // =========================================================================
    // Task: send weight upload command via PCIe
    //   Format: CMD(0x01) + LAYER + MODULE + LEN_HI + LEN_LO + payload...
    // =========================================================================
    task pcie_send_weight;
        input [7:0]  layer;
        input [7:0]  module_id;
        input [15:0] payload_len;
        input [7:0]  payload_data;
        integer i;
        begin
            // CMD
            pcie_send_byte(8'h01, 1, 0);
            // Header
            pcie_send_byte(layer, 0, 0);
            pcie_send_byte(module_id, 0, 0);
            pcie_send_byte(payload_len[15:8], 0, 0);
            pcie_send_byte(payload_len[7:0], 0, 0);
            // Payload (repeat payload_data for simplicity)
            for (i = 0; i < payload_len; i = i + 1)
                pcie_send_byte(payload_data + i[7:0], 0, (i == payload_len - 1));
        end
    endtask

    // =========================================================================
    // Task: send routing table entry via PCIe
    //   Format: CMD(0x02) + NODE_ID + BITMAP_HI + BITMAP_LO
    // =========================================================================
    task pcie_send_route;
        input [7:0]  node_id;
        input [10:0] bitmap;
        begin
            pcie_send_byte(8'h02, 1, 0);
            pcie_send_byte(node_id, 0, 0);
            pcie_send_byte(bitmap[10:8], 0, 0);
            pcie_send_byte(bitmap[7:0], 0, 1);
        end
    endtask

    // =========================================================================
    // Task: send MoE map entry via PCIe
    //   Format: CMD(0x03) + LAYER + EXPERT + TARGET_LAYER + TARGET_MODULE
    // =========================================================================
    task pcie_send_moe_entry;
        input [7:0] layer;
        input [7:0] expert;
        input [7:0] target_layer;
        input [7:0] target_module;
        begin
            pcie_send_byte(8'h03, 1, 0);
            pcie_send_byte(layer, 0, 0);
            pcie_send_byte(expert, 0, 0);
            pcie_send_byte(target_layer, 0, 0);
            pcie_send_byte(target_module, 0, 1);
        end
    endtask

    // =========================================================================
    // Task: send inference token via PCIe
    //   Format: CMD(0x04) + LEN_HI + LEN_LO + payload...
    // =========================================================================
    task pcie_send_token;
        input [15:0] payload_len;
        input [7:0]  payload_data;
        integer i;
        begin
            pcie_send_byte(8'h04, 1, 0);
            pcie_send_byte(payload_len[15:8], 0, 0);  // LEN_HI
            pcie_send_byte(payload_len[7:0], 0, 0);   // LEN_LO
            for (i = 0; i < payload_len; i = i + 1)
                pcie_send_byte(payload_data + i[7:0], 0, (i == payload_len - 1));
        end
    endtask

    // =========================================================================
    // Task: send boot phase advance via PCIe
    // =========================================================================
    task pcie_advance_boot;
        begin
            pcie_send_byte(8'hFF, 1, 1);
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    integer errors_local;

    initial begin
        $dumpfile("tb_router_chip.vcd");
        $dumpvars(0, tb_router_chip);

        errors_local = 0;

        // Initialize
        pcie_in_data    = 0;
        pcie_in_valid   = 0;
        pcie_in_sop     = 0;
        pcie_in_eop     = 0;
        pcie_out_ready  = 1;
        spine_inject_ready = 1;
        spine_extract_data  = 0;
        spine_extract_valid = 0;
        spine_extract_sop   = 0;
        spine_extract_eop   = 0;
        spine_extract_vc    = 0;
        topology_rdy = {NUM_NODES{1'b1}}; // all nodes present

        // Reset
        #25;
        rst_n = 1;
        #10;

        // =================================================================
        // Phase 1: POST discovery
        // =================================================================
        $display("[TB] Phase 1: POST discovery");
        // Boot FSM automatically counts topology_rdy over 256 cycles
        repeat (300) @(posedge clk);

        // =================================================================
        // Phase 2: Load routing tables
        // =================================================================
        $display("[TB] Phase 2: Load routing tables");
        // Entry for node (0,0,0) on layer 0: bitmap = 11'h080
        pcie_send_route(8'h00, 11'h080);
        // Entry for node (0,0,1) on layer 0: bitmap = 11'h081
        pcie_send_route(8'h01, 11'h081);
        // Entry for node (0,1,0) on layer 0: bitmap = 11'h080
        pcie_send_route(8'h10, 11'h080);

        // Advance boot phase
        pcie_advance_boot();
        repeat (10) @(posedge clk);

        // =================================================================
        // Phase 3: Upload weights
        // =================================================================
        $display("[TB] Phase 3: Upload weights");
        // Upload 8 bytes to layer 0, node (0,0,0)
        pcie_send_weight(8'h01, 8'h00, 16'd8, 8'hAA);
        repeat (20) @(posedge clk);

        // Advance boot phase
        pcie_advance_boot();
        repeat (10) @(posedge clk);

        // =================================================================
        // Phase 4: Load MoE map
        // =================================================================
        $display("[TB] Phase 4: Load MoE map");
        // Layer 0, expert 0 → layer 0, node (0,0)
        pcie_send_moe_entry(8'h00, 8'h00, 8'h00, 8'h00);
        // Layer 0, expert 1 → layer 0, node (0,1)
        pcie_send_moe_entry(8'h00, 8'h01, 8'h00, 8'h01);

        // Advance boot phase
        pcie_advance_boot();
        repeat (10) @(posedge clk);

        // =================================================================
        // Phase 5: Check boot_done
        // =================================================================
        $display("[TB] Phase 5: Check boot_done");
        if (boot_done !== 1'b1) begin
            $display("[TB] ERROR: boot_done did not assert");
            errors_local = errors_local + 1;
        end

        // =================================================================
        // Phase 6: Inference token dispatch
        // =================================================================
        $display("[TB] Phase 6: Inference token");
        pcie_send_token(16'd4, 8'h42);  // 4-byte payload
        repeat (30) @(posedge clk);

        // =================================================================
        // Verify results
        // =================================================================
        $display("[TB] --- Results ---");
        $display("[TB] boot_done    = %b", boot_done);
        $display("[TB] dispatches   = %0d", dispatches);
        $display("[TB] weight_flits = %0d", weight_flits);
        $display("[TB] errors       = %0d", errors);

        if (dispatches !== 1) begin
            $display("[TB] ERROR: expected 1 dispatch, got %0d", dispatches);
            errors_local = errors_local + 1;
        end
        if (weight_flits < 1) begin
            $display("[TB] ERROR: expected >= 1 weight flit, got %0d", weight_flits);
            errors_local = errors_local + 1;
        end
        if (errors !== 0) begin
            $display("[TB] ERROR: %0d errors in DUT", errors);
            errors_local = errors_local + 1;
        end

        if (errors_local == 0)
            $display("*** ROUTER CHIP TEST PASSED ***");
        else begin
            $display("*** ROUTER CHIP TEST FAILED (%0d errors) ***", errors_local);
            $finish(1);
        end

        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("[TB] TIMEOUT");
        $finish(1);
    end

endmodule
