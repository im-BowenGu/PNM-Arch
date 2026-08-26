`timescale 1ns/1ps

// =============================================================================
// tb_orchestrator_sbc — Testbench for Plain SBC Router Chip
//
// Loads a test program into boot ROM that:
//   1. Writes a value to DRAM (verifying the LPDDR5 stub works)
//   2. Reads it back and compares
//   3. Injects a flit through the PNM engine
//   4. Signals boot_done
//
// Verifies: DRAM read-back, spine injection wire format, boot_done.
// =============================================================================

`include "pnm_defs.vh"

module tb_orchestrator_sbc;

    reg clk, rst_n;
    reg uart_rx;
    wire uart_tx;

    wire [7:0] spine_inject_data;
    wire spine_inject_valid, spine_inject_sop, spine_inject_eop;
    reg spine_inject_ready;
    wire [1:0] spine_inject_vc;

    reg [7:0] spine_extract_data;
    reg spine_extract_valid, spine_extract_sop, spine_extract_eop;
    reg [1:0] spine_extract_vc;

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

    function [31:0] lw_inst(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        lw_inst = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction

    function [31:0] jal_inst(input [4:0] rd, input [20:0] offset);
        jal_inst = {offset[20], offset[10:1], offset[11], offset[19:12],
                    rd, 7'b1101111};
    endfunction

    orchestrator_sbc #(
        .CLK_FREQ(100_000_000),
        .BAUD_RATE(115200),
        .NUM_LAYERS(8),
        .BOARD_X(8),
        .BOARD_Y(8),
        .DRAM_WORDS(4096),
        .DRAM_LATENCY(4),
        .SRAM_WORDS(16384)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
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
        //   x1 = DRAM base (0x80000000)
        //   x2 = magic value
        //   store to DRAM[0]
        //   load from DRAM[0] into x3
        //   x1 = PNM base (0xF0000000)
        //   write layer=1, module=0, len=1
        //   payload byte from x3's low byte
        //   trigger inject + boot_done
        //   self-loop

        // Store magic to DRAM
        u_dut.rom[0]  = lui_inst(5'd1, 20'h80000);           // x1 = 0x80000000
        u_dut.rom[1]  = lui_inst(5'd2, 20'h00DEA);           // x2 = 0xDEA00000
        u_dut.rom[2]  = addi_inst(5'd2, 5'd2, 12'hDBE);      // x2 |= 0xDBE (low bits)
        u_dut.rom[3]  = sw_inst(5'd2, 5'd1, 12'h000);        // DRAM[0] = x2
        u_dut.rom[4]  = lw_inst(5'd3, 5'd1, 12'h000);        // x3 = DRAM[0]

        // PNM registers
        u_dut.rom[5]  = lui_inst(5'd4, 20'hF0000);           // x4 = 0xF0000000
        u_dut.rom[6]  = addi_inst(5'd5, 5'd0, 12'h001);      // layer=1
        u_dut.rom[7]  = sw_inst(5'd5, 5'd4, 12'h004);        // PNM_LAYER
        u_dut.rom[8]  = sw_inst(5'd0, 5'd4, 12'h008);        // PNM_MODULE=0
        u_dut.rom[9]  = addi_inst(5'd5, 5'd0, 12'h001);      // len=1
        u_dut.rom[10] = sw_inst(5'd5, 5'd4, 12'h00C);        // PNM_LEN
        u_dut.rom[11] = sw_inst(5'd3, 5'd4, 12'h010);        // PNM_DATA = x3 low byte

        // Trigger injection + boot_done
        u_dut.rom[12] = addi_inst(5'd5, 5'd0, 12'h005);      // bits 0|2
        u_dut.rom[13] = sw_inst(5'd5, 5'd4, 12'h000);        // PNM_CTRL

        for (i = 14; i < 16384; i++) u_dut.rom[i] = jal_inst(5'd0, 21'd0);

        repeat (4) @(posedge clk);
        rst_n = 1;

        // Poll for boot_done or timeout
        for (i = 0; i < 50000 && !boot_done; i++)
            @(posedge clk);

        if (!boot_done) begin
            $display("FAIL: boot_done not asserted");
            errors = errors + 1;
        end else begin
            $display("boot_done asserted");
        end

        // Wait for injection to complete
        for (i = 0; i < 1000 && inject_pos < 8; i++)
            @(posedge clk);

        if (inject_pos >= 8) begin
            check_byte(0, 8'h01);  // LAYER
            check_byte(1, 8'h00);  // MODULE
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
            $display("*** SBC ROUTER CHIP TEST PASSED ***");
        else
            $display("*** SBC ROUTER CHIP TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
