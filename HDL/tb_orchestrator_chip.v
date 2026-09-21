`timescale 1ns/1ps

`include "pnm_defs.vh"

// =============================================================================
// tb_orchestrator_chip — self-checking testbench for the central orchestrator chip
//
// Exercises:
//   1. POST discovery: all nodes assert topology_rdy
//   2. Routing table load: 3 entries via PCIe
//   3. Weight upload: one flit (8 bytes payload) via PCIe → spine
//   4. MoE map load: 4 entries via PCIe
//   5. MoE gating weight load: command 0x05 streams BF16 words into the
//      gating unit's weight SRAM (expert 0 → +1.0 at dim 0, expert 1 → −1.0)
//   6. Inference routing: three tokens with different hidden vectors — the
//      content-sensitive dispatch must be:
//        token 1 → (01,00)   [stale boot latch, first-token pipeline lag]
//        token 2 → (01,00)   [gating of token 1: word0=+1.0 → expert 0]
//        token 3 → (01,01)   [gating of token 2: word0=−1.0 → expert 1]
//      Proving the router is driven by hidden state, not a constant.
//   7. Result collection: spine → PCIe egress survives host backpressure
//      (bytes enqueued while pcie_out_ready=0 must all be delivered).
//
// Pass conditions:
//   - boot_done asserts after POST + load phases
//   - dispatches == 3, weight_flits == 4 (1 weight + 3 tokens)
//   - Every spine flit is byte-checked: header, LEN, payload, CRC, framing
//   - All backpressured egress bytes delivered with correct SOP/EOP
//   - No errors
// =============================================================================
module tb_orchestrator_chip;

    reg         clk = 0;
    reg         rst_n = 0;

    // Clock: 100 MHz (10 ns period)
    always #5 clk = ~clk;

    // Parameters (small gating dims keep the MoE computation cycle-cheap)
    localparam NUM_LAYERS  = 4;
    localparam BOARD_X     = 4;
    localparam BOARD_Y     = 4;
    localparam NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y;
    localparam MAX_EXPERTS = 4;
    localparam TOP_K       = 2;
    localparam HIDDEN_SIZE = 8;

    // BF16 constants
    localparam BF16_1  = 16'h3F80;  // +1.0
    localparam BF16_N1 = 16'hBF80;  // -1.0

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

    // Spine stream sampler: captures every emitted flit byte so the test
    // validates the data path, not just the weight_flits/dispatches counters.
    reg [7:0] spine_bytes [0:255];
    reg       spine_sop  [0:255];
    reg       spine_eop  [0:255];
    integer   spine_n;

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
    orchestrator_chip #(
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
    // Task: upload one expert's gating-weight row via PCIe
    //   Format: CMD(0x05) + LAYER + EXPERT + RSVD + HIDDEN_SIZE BF16 words
    //   word0 = {hi,lo}, all remaining words are zero.
    // =========================================================================
    task pcie_send_moe_weight;
        input [7:0]  layer;
        input [7:0]  expert;
        input [15:0] word0;
        integer w;
        begin
            pcie_send_byte(8'h05, 1, 0);
            pcie_send_byte(layer, 0, 0);
            pcie_send_byte(expert, 0, 0);
            pcie_send_byte(8'h00, 0, 0);
            for (w = 0; w < HIDDEN_SIZE; w = w + 1) begin
                pcie_send_byte((w == 0) ? word0[15:8] : 8'h00, 0, 0);
                pcie_send_byte((w == 0) ? word0[7:0]  : 8'h00, 0, (w == HIDDEN_SIZE - 1));
            end
        end
    endtask

    // =========================================================================
    // Task: send inference token via PCIe
    //   Format: CMD(0x04) + LEN_HI + LEN_LO + payload...
    //   The token payload doubles as the gating unit's hidden vector: the
    //   first 16-bit word is {hi,lo}, the remaining payload bytes are zero.
    // =========================================================================
    task pcie_send_token_word;
        input [7:0]  w_hi;
        input [7:0]  w_lo;
        integer i;
        begin
            pcie_send_byte(8'h04, 1, 0);
            pcie_send_byte(16'd16 >> 8, 0, 0);   // LEN_HI
            pcie_send_byte(16'd16 & 8'hFF, 0, 0); // LEN_LO
            pcie_send_byte(w_hi, 0, 0);
            pcie_send_byte(w_lo, 0, 0);
            for (i = 2; i < 16; i = i + 1)
                pcie_send_byte(8'h00, 0, (i == 16'd15));
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
    // CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no final XOR, MSB-first)
    // Mirrors crc16.v / crc.go / the flit builder's crc16_next.
    // =========================================================================
    function [15:0] tb_crc16;
        input [15:0] crc_in;
        input [7:0]  byte_in;
        reg [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {byte_in, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            tb_crc16 = crc;
        end
    endfunction

    // =========================================================================
    // Verify one captured spine flit: framing, header bytes, and CRC.
    // Flit layout on the wire: LAYER | MODULE | CTRL | LEN_LO | LEN_HI |
    // payload | CRC_HI | CRC_LO, CRC covering [MODULE..payload].
    // =========================================================================
    task check_spine_flit;
        input integer start;      // first byte index of the flit
        input integer flit_len;   // 5 header + payload + 2 CRC
        input [7:0]  exp_layer;
        input [7:0]  exp_module;
        input [7:0]  exp_ctrl;
        input [15:0] exp_len;
        integer j;
        reg [15:0] crc;
        begin
            if (spine_n < start + flit_len) begin
                $display("[TB] ERROR: flit at byte %0d incomplete (spine_n=%0d, need >= %0d)",
                         start, spine_n, start + flit_len);
                errors_local = errors_local + 1;
            end
            if (!spine_sop[start]) begin
                $display("[TB] ERROR: flit at byte %0d missing SOP", start);
                errors_local = errors_local + 1;
            end
            if (!spine_eop[start + flit_len - 1]) begin
                $display("[TB] ERROR: flit at byte %0d missing EOP at byte %0d",
                         start, start + flit_len - 1);
                errors_local = errors_local + 1;
            end
            for (j = start + 1; j < start + flit_len - 1; j = j + 1) begin
                if (spine_sop[j]) begin
                    $display("[TB] ERROR: spurious SOP at byte %0d", j);
                    errors_local = errors_local + 1;
                end
                if (spine_eop[j]) begin
                    $display("[TB] ERROR: spurious EOP at byte %0d", j);
                    errors_local = errors_local + 1;
                end
            end
            if (spine_bytes[start] !== exp_layer) begin
                $display("[TB] ERROR: flit at byte %0d LAYER=%02h, expect %02h",
                         start, spine_bytes[start], exp_layer);
                errors_local = errors_local + 1;
            end
            if (spine_bytes[start + 1] !== exp_module) begin
                $display("[TB] ERROR: flit at byte %0d MODULE=%02h, expect %02h",
                         start, spine_bytes[start + 1], exp_module);
                errors_local = errors_local + 1;
            end
            if (spine_bytes[start + 2] !== exp_ctrl) begin
                $display("[TB] ERROR: flit at byte %0d CTRL=%02h, expect %02h",
                         start, spine_bytes[start + 2], exp_ctrl);
                errors_local = errors_local + 1;
            end
            if (spine_bytes[start + 3] !== exp_len[7:0]) begin
                $display("[TB] ERROR: flit at byte %0d LEN_LO=%02h, expect %02h",
                         start, spine_bytes[start + 3], exp_len[7:0]);
                errors_local = errors_local + 1;
            end
            if (spine_bytes[start + 4] !== exp_len[15:8]) begin
                $display("[TB] ERROR: flit at byte %0d LEN_HI=%02h, expect %02h",
                         start, spine_bytes[start + 4], exp_len[15:8]);
                errors_local = errors_local + 1;
            end
            crc = 16'hFFFF;
            for (j = start + 1; j <= start + flit_len - 3; j = j + 1)
                crc = tb_crc16(crc, spine_bytes[j]);
            if ({spine_bytes[start + flit_len - 2], spine_bytes[start + flit_len - 1]} !== crc) begin
                $display("[TB] ERROR: flit at byte %0d CRC mismatch (wire=%02h%02h, expect %04h)",
                         start, spine_bytes[start + flit_len - 2],
                         spine_bytes[start + flit_len - 1], crc);
                errors_local = errors_local + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    integer errors_local;
    integer j;

    // =========================================================================
    // Sample the spine output stream (runs continuously)
    // =========================================================================
    always @(posedge clk) begin
        if (spine_inject_valid && spine_inject_ready) begin
            spine_bytes[spine_n] <= spine_inject_data;
            spine_sop[spine_n]   <= spine_inject_sop;
            spine_eop[spine_n]   <= spine_inject_eop;
            spine_n <= spine_n + 1;
        end
    end

    initial begin
        $dumpfile("tb_orchestrator_chip.vcd");
        $dumpvars(0, tb_orchestrator_chip);

        errors_local = 0;
        spine_n = 0;

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

        // Verify the emitted weight flit on the spine watch:
        //   LAYER=01 MODULE=00 CTRL=A0 LEN=0008, payload 0xAA..0xB1, CRC
        if (spine_n !== 15) begin
            $display("[TB] ERROR: expected 15 weight-flit bytes on spine, got %0d", spine_n);
            errors_local = errors_local + 1;
        end
        check_spine_flit(0, 15, 8'h01, 8'h00, 8'hA0, 16'd8);
        for (j = 0; j < 8; j = j + 1)
            if (spine_bytes[5 + j] !== 8'hAA + j[7:0]) begin
                $display("[TB] ERROR: weight payload byte %0d = %02h, expect %02h",
                         j, spine_bytes[5 + j], 8'hAA + j[7:0]);
                errors_local = errors_local + 1;
            end

        // Advance boot phase
        pcie_advance_boot();
        repeat (10) @(posedge clk);

        // =================================================================
        // Phase 4: Load MoE map + gating weights
        // =================================================================
        $display("[TB] Phase 4: Load MoE map");
        // Layer 0, expert 0 → layer 1, node (0,0)
        pcie_send_moe_entry(8'h00, 8'h00, 8'h01, 8'h00);
        // Layer 0, expert 1 → layer 1, node (0,1)
        pcie_send_moe_entry(8'h00, 8'h01, 8'h01, 8'h01);
        // Layer 0, expert 2 → layer 1, node (0,2)
        pcie_send_moe_entry(8'h00, 8'h02, 8'h01, 8'h02);
        // Layer 0, expert 3 → layer 1, node (0,3)
        pcie_send_moe_entry(8'h00, 8'h03, 8'h01, 8'h03);

        $display("[TB] Phase 4b: Load MoE gating weights (cmd 0x05)");
        // Gating rows: expert 0 → [+1.0 at dim0], expert 1 → [-1.0 at dim0],
        // experts 2,3 → all zeros.
        pcie_send_moe_weight(8'h00, 8'h00, BF16_1);
        pcie_send_moe_weight(8'h00, 8'h01, BF16_N1);
        pcie_send_moe_weight(8'h00, 8'h02, 16'h0000);
        pcie_send_moe_weight(8'h00, 8'h03, 16'h0000);
        repeat (10) @(posedge clk);

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
        // Phase 6: Inference token dispatch (content-sensitive MoE routing)
        // =================================================================
        // Token 1: hidden word0 = +1.0 → dispatch uses the stale boot latch
        // (01,00), a one-token pipeline lag blessed by the design; gating of
        // this token selects expert 0 (logit +1.0 vs -1.0) for the next.
        $display("[TB] Phase 6: Inference token 1 (word0 = +1.0)");
        pcie_send_token_word(8'h3F, 8'h80);
        repeat (300) @(posedge clk);   // let gating for token 1 complete
        check_spine_flit(15, 23, 8'h01, 8'h00, 8'h80, 16'd16);
        if (spine_bytes[20] !== 8'h3F || spine_bytes[21] !== 8'h80) begin
            $display("[TB] ERROR: token 1 payload word0 = %02h%02h, expect 3F80",
                     spine_bytes[20], spine_bytes[21]);
            errors_local = errors_local + 1;
        end

        // Token 2: hidden word0 = -1.0 → dispatch uses token 1's gating result
        // (expert 0 → 01,00).  Gating of token 2 selects expert 1 (logit +1.0)
        // for the next dispatch — the key content-sensitivity proof.
        $display("[TB] Phase 6b: Inference token 2 (word0 = -1.0)");
        pcie_send_token_word(8'hBF, 8'h80);
        repeat (300) @(posedge clk);
        check_spine_flit(38, 23, 8'h01, 8'h00, 8'h80, 16'd16);
        if (spine_bytes[43] !== 8'hBF || spine_bytes[44] !== 8'h80) begin
            $display("[TB] ERROR: token 2 payload word0 = %02h%02h, expect BF80",
                     spine_bytes[43], spine_bytes[44]);
            errors_local = errors_local + 1;
        end

        // Token 3: hidden word0 = +1.0 → dispatch uses token 2's gating result
        // (expert 1 → module 01).  If the gating unit were inert (constant
        // dispatch), this would still go to (01,00).
        $display("[TB] Phase 6c: Inference token 3 (word0 = +1.0)");
        pcie_send_token_word(8'h3F, 8'h80);
        repeat (300) @(posedge clk);
        check_spine_flit(61, 23, 8'h01, 8'h01, 8'h80, 16'd16);
        if (spine_bytes[66] !== 8'h3F || spine_bytes[67] !== 8'h80) begin
            $display("[TB] ERROR: token 3 payload word0 = %02h%02h, expect 3F80",
                     spine_bytes[66], spine_bytes[67]);
            errors_local = errors_local + 1;
        end

        if (spine_n !== 84) begin
            $display("[TB] ERROR: expected 84 total spine bytes (15 + 3x23), got %0d", spine_n);
            errors_local = errors_local + 1;
        end

        // =================================================================
        // Phase 7: Result collection under host backpressure
        // =================================================================
        $display("[TB] Phase 7: spine→PCIe egress under backpressure");
        // Host stops taking bytes for 3 cycles while the spine streams 3 bytes.
        pcie_out_ready = 0;
        spine_extract_sop = 1;
        spine_extract_eop = 0;
        spine_extract_data = 8'hDE;
        spine_extract_valid = 1;
        @(posedge clk);
        spine_extract_sop = 0;
        spine_extract_data = 8'hAD;
        @(posedge clk);
        spine_extract_data = 8'hBE;
        spine_extract_eop = 1;
        @(posedge clk);
        spine_extract_valid = 0;
        // Release backpressure; the FIFO must drain all three bytes.
        // The DUT presents one byte per posedge while cnt!=0 and ready=1,
        // so sample immediately after each edge.
        pcie_out_ready = 1;
        @(posedge clk);
        if (!pcie_out_valid || pcie_out_data !== 8'hDE || !pcie_out_sop) begin
            $display("[TB] ERROR: egress byte 0 = %02h valid=%b sop=%b, expect DE/1/1",
                     pcie_out_data, pcie_out_valid, pcie_out_sop);
            errors_local = errors_local + 1;
        end
        @(posedge clk);
        if (!pcie_out_valid || pcie_out_data !== 8'hAD) begin
            $display("[TB] ERROR: egress byte 1 = %02h valid=%b, expect AD/1",
                     pcie_out_data, pcie_out_valid);
            errors_local = errors_local + 1;
        end
        @(posedge clk);
        if (!pcie_out_valid || pcie_out_data !== 8'hBE || !pcie_out_eop) begin
            $display("[TB] ERROR: egress byte 2 = %02h valid=%b eop=%b, expect BE/1/1",
                     pcie_out_data, pcie_out_valid, pcie_out_eop);
            errors_local = errors_local + 1;
        end
        @(posedge clk);
        if (pcie_out_valid !== 1'b0) begin
            $display("[TB] ERROR: egress still valid after FIFO drain");
            errors_local = errors_local + 1;
        end
        pcie_out_ready = 1;

        // =================================================================
        // Verify results
        // =================================================================
        $display("[TB] --- Results ---");
        $display("[TB] boot_done    = %b", boot_done);
        $display("[TB] dispatches   = %0d", dispatches);
        $display("[TB] weight_flits = %0d", weight_flits);
        $display("[TB] spine bytes  = %0d", spine_n);
        $display("[TB] errors       = %0d", errors);

        if (dispatches !== 3) begin
            $display("[TB] ERROR: expected 3 dispatches, got %0d", dispatches);
            errors_local = errors_local + 1;
        end
        if (weight_flits !== 4) begin
            $display("[TB] ERROR: expected 4 flits built (1 weight + 3 tokens), got %0d", weight_flits);
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
        #200000;
        $display("[TB] TIMEOUT");
        $finish(1);
    end

endmodule