`timescale 1ns/1ps

// =============================================================================
// tb_orchestrator_sbc_moe — Testbench for SBC+MoE Router Chip
//
// Loads a test program into boot ROM that:
//   1. Writes gating weights to the 0x4000_0000 SRAM
//   2. Writes a hidden-state vector to PNM_GATING_HIDDEN_BASE
//   3. Triggers the MoE gating computation
//   4. Injects a flit through the PNM engine
//   5. Signals boot_done
//
// Verifies: gating weight SRAM write/read, spine injection, boot_done.
// The moe_gating unit is exercised structurally (start/done handshake)
// but top-K results are not numerically checked in this smoke test.
// =============================================================================

`include "pnm_defs.vh"

module tb_orchestrator_sbc_moe;

    reg clk, rst_n;
    reg uart_rx;
    wire uart_tx;

    reg [7:0] pcie_in_data;
    reg pcie_in_valid, pcie_in_sop, pcie_in_eop;
    wire pcie_in_ready;

    wire [7:0] pcie_out_data;
    wire pcie_out_valid, pcie_out_sop, pcie_out_eop;
    reg pcie_out_ready;

    wire [7:0] spine_inject_data;
    wire spine_inject_valid, spine_inject_sop, spine_inject_eop;
    reg spine_inject_ready;
    wire [1:0] spine_inject_vc;

    reg [7:0] spine_extract_data;
    reg spine_extract_valid, spine_extract_sop, spine_extract_eop;
    reg [1:0] spine_extract_vc;

    wire [63:0] topology_rdy;
    reg [15:0] ext_irq;
    wire boot_done;

    integer errors;
    integer inject_count;

    always #5 clk = ~clk;  // 100 MHz

    function [31:0] lui_inst(input [4:0] rd, input [19:0] imm);
        lui_inst = {imm, rd, 7'b0110111};
    endfunction

    function [31:0] addi_inst(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        addi_inst = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function [31:0] sw_inst(input [4:0] rs2, input [4:0] rs1, input [11:0] imm);
        sw_inst = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    function [31:0] jal_inst(input [4:0] rd, input [20:0] offset);
        jal_inst = {offset[20], offset[10:1], offset[11], offset[19:12],
                    rd, 7'b1101111};
    endfunction

    orchestrator_sbc_moe #(
        .CLK_FREQ(100_000_000),
        .BAUD_RATE(115200),
        .NUM_LAYERS(8),
        .BOARD_X(8),
        .BOARD_Y(8),
        .MAX_EXPERTS(16),
        .TOP_K(4),
        .HIDDEN_SIZE(64),
        .GATING_ENTRIES(1024),
        .DRAM_WORDS(4096),
        .DRAM_LATENCY(4),
        .ARRAY_SIZE(16)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
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
        .topology_rdy({512{1'b1}}),
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
        .ext_irq(ext_irq),
        .boot_done(boot_done)
    );

    reg [7:0] inject_log [0:15];
    reg [3:0] inject_pos;

    always @(posedge clk) begin
        if (spine_inject_valid && spine_inject_ready) begin
            if (inject_pos < 16) begin
                inject_log[inject_pos] <= spine_inject_data;
            end
            inject_pos <= inject_pos + 1;
            inject_count <= inject_count + 1;
        end
    end

    task check_byte(input [3:0] idx, input [7:0] expected);
        begin
            if (inject_log[idx] !== expected) begin
                $display("FAIL: byte[%0d]: expected 0x%02h got 0x%02h",
                         idx, expected, inject_log[idx]);
                errors = errors + 1;
            end else begin
                $display("  OK: [%0d] = 0x%02h", idx, inject_log[idx]);
            end
        end
    endtask

    integer i;
    initial begin
        clk = 0; rst_n = 0;
        uart_rx = 1'b1;
        pcie_in_data = 8'h0;
        pcie_in_valid = 0;
        pcie_in_sop = 0;
        pcie_in_eop = 0;
        pcie_out_ready = 1'b1;
        spine_inject_ready = 1'b1;
        spine_extract_valid = 0;
        spine_extract_eop = 0;
        spine_extract_data = 8'h0;
        spine_extract_vc = 2'b10;
        ext_irq = 16'h0;
        errors = 0;
        inject_count = 0;
        inject_pos = 0;

        // Test program:
        //   Write one BF16 weight to gating SRAM at 0x40000000
        //   Write one hidden value to PNM_GATING_HIDDEN_BASE (0xF0000030)
        //   Trigger gating via PNM_GATING_START (0xF0000034)
        //   Inject flit with layer=2, module=3, len=1, payload=0x42
        //   Signal boot_done

        u_dut.rom[0]  = lui_inst(5'd1, 20'h40000);            // x1 = 0x40000000
        u_dut.rom[1]  = lui_inst(5'd2, 20'h003C0);            // x2 = BF16 ~1.5
        u_dut.rom[2]  = sw_inst(5'd2, 5'd1, 12'h000);         // gate_sram[0] = x2

        u_dut.rom[3]  = lui_inst(5'd3, 20'hF0000);            // x3 = 0xF0000000
        u_dut.rom[4]  = addi_inst(5'd4, 5'd0, 12'h100);       // hidden value (BF16 exp)
        u_dut.rom[5]  = sw_inst(5'd4, 5'd3, 12'h030);         // HIDDEN_BASE[0]
        u_dut.rom[6]  = addi_inst(5'd4, 5'd0, 12'h001);       // trigger=1
        u_dut.rom[7]  = sw_inst(5'd4, 5'd3, 12'h034);         // GATING_START

        u_dut.rom[8]  = addi_inst(5'd4, 5'd0, 12'h002);       // layer=2
        u_dut.rom[9]  = sw_inst(5'd4, 5'd3, 12'h004);         // PNM_LAYER
        u_dut.rom[10] = addi_inst(5'd4, 5'd0, 12'h003);       // module=3
        u_dut.rom[11] = sw_inst(5'd4, 5'd3, 12'h008);         // PNM_MODULE
        u_dut.rom[12] = addi_inst(5'd4, 5'd0, 12'h001);       // len=1
        u_dut.rom[13] = sw_inst(5'd4, 5'd3, 12'h00C);         // PNM_LEN
        u_dut.rom[14] = addi_inst(5'd4, 5'd0, 12'h042);       // payload=0x42
        u_dut.rom[15] = sw_inst(5'd4, 5'd3, 12'h010);         // PNM_DATA

        u_dut.rom[16] = addi_inst(5'd4, 5'd0, 12'h005);       // bits 0|2
        u_dut.rom[17] = sw_inst(5'd4, 5'd3, 12'h000);         // PNM_CTRL

        for (i = 18; i < 16384; i++) u_dut.rom[i] = jal_inst(5'd0, 21'd0);

        repeat (4) @(posedge clk);
        rst_n = 1;

        for (i = 0; i < 50000 && !boot_done; i++)
            @(posedge clk);

        if (!boot_done) begin
            $display("FAIL: boot_done not asserted");
            errors = errors + 1;
        end else begin
            $display("boot_done asserted");
        end

        // Check gating SRAM received the write (upper halfword lands in sram[1])
        if (u_dut.gating_sram[1] === 16'h003C)
            $display("  OK: gating_sram[1] = 0x003C");
        else begin
            $display("FAIL: gating_sram[1] = 0x%04h", u_dut.gating_sram[1]);
            errors = errors + 1;
        end

        // Wait for injection
        for (i = 0; i < 1000 && inject_pos < 8; i++)
            @(posedge clk);

        if (inject_pos >= 8) begin
            check_byte(0, 8'h02);  // LAYER
            check_byte(1, 8'h03);  // MODULE
            check_byte(2, 8'h80);  // CTRL
            check_byte(3, 8'h01);  // LEN_LO
            check_byte(4, 8'h00);  // LEN_HI
            $display("payload: 0x%02h", inject_log[5]);
            $display("CRC: 0x%02h 0x%02h", inject_log[6], inject_log[7]);
        end else begin
            $display("FAIL: only %0d bytes injected", inject_pos);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** SBC+MOE ROUTER CHIP TEST PASSED ***");
        else
            $display("*** SBC+MOE ROUTER CHIP TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
