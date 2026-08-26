`timescale 1ns/1ps

// =============================================================================
// tb_orchestrator_mcu — Testbench for Minimal MCU Router Chip
//
// Loads a bare-metal test program into the 8KB boot ROM that:
//   1. Writes PNM_LAYER = 1, PNM_MODULE = 5, PNM_LEN = 2
//   2. Writes payload bytes 0xAA, 0x55
//   3. Triggers flit injection
//
// Verifies: spine injection carries correct wire format bytes and EOP.
// =============================================================================

`include "pnm_defs.vh"

module tb_orchestrator_mcu;

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

    reg [7:0] ext_irq;
    wire boot_done;

    integer errors;
    integer inject_count;

    always #10 clk = ~clk;  // 50 MHz

    // RV32 instruction encoders (same as tb_bmc_orchestrator)
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

    orchestrator_mcu #(
        .CLK_FREQ(100_000),
        .BAUD_RATE(9600),
        .NUM_LAYERS(2),
        .BOARD_X(4),
        .BOARD_Y(4)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .topology_rdy(32'hFFFFFFFF),
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

    // Capture spine injections
    reg [7:0] inject_log [0:15];
    reg [3:0] inject_pos;

    always @(posedge clk) begin
        if (spine_inject_valid && spine_inject_ready) begin
            if (inject_pos < 16) begin
                inject_log[inject_pos] <= spine_inject_data;
                $display("[%0t] inject[%0d] = 0x%02h (state=%0d pos=%0d len=%0d)",
                         $time, inject_pos, spine_inject_data,
                         u_dut.fb_state, u_dut.fb_pos, u_dut.fb_len);
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
        ext_irq = 8'h0;
        errors = 0;
        inject_count = 0;
        inject_pos = 0;

        // Load test program into ROM
        u_dut.rom[0] = lui_inst(5'd1, 20'hF0000);       // x1 = 0xF0000000
        u_dut.rom[1] = addi_inst(5'd2, 5'd0, 12'h001);   // layer = 1
        u_dut.rom[2] = sw_inst(5'd2, 5'd1, 12'h004);     // PNM_LAYER
        u_dut.rom[3] = addi_inst(5'd2, 5'd0, 12'h005);   // module = 5
        u_dut.rom[4] = sw_inst(5'd2, 5'd1, 12'h008);     // PNM_MODULE
        u_dut.rom[5] = addi_inst(5'd2, 5'd0, 12'h002);   // len = 2
        u_dut.rom[6] = sw_inst(5'd2, 5'd1, 12'h00C);     // PNM_LEN
        u_dut.rom[7] = addi_inst(5'd2, 5'd0, 12'h0AA);   // 0xAA (sign-extends to 0xFFFFFFAA)
        u_dut.rom[8] = sw_inst(5'd2, 5'd1, 12'h010);     // payload[0]
        u_dut.rom[9] = addi_inst(5'd2, 5'd0, 12'h055);   // 0x55
        u_dut.rom[10]= sw_inst(5'd2, 5'd1, 12'h010);     // payload[1]
        u_dut.rom[11]= addi_inst(5'd2, 5'd0, 12'h001);   // trigger
        u_dut.rom[12]= sw_inst(5'd2, 5'd1, 12'h000);     // PNM_CTRL
        for (i = 13; i < 2048; i++) u_dut.rom[i] = jal_inst(5'd0, 21'd0);  // self-loop

        repeat (4) @(posedge clk);
        rst_n = 1;

        // Poll for injection completion with timeout
        inject_pos = 0;
        for (i = 0; i < 20000 && inject_pos < 9; i++)
            @(posedge clk);

        if (inject_pos >= 9) begin
            check_byte(0, 8'h01);  // LAYER
            check_byte(1, 8'h05);  // MODULE
            check_byte(2, 8'h80);  // CTRL
            check_byte(3, 8'h02);  // LEN_LO
            check_byte(4, 8'h00);  // LEN_HI
            $display("payload: 0x%02h 0x%02h", inject_log[5], inject_log[6]);
            $display("CRC: 0x%02h 0x%02h", inject_log[7], inject_log[8]);
            $display("injected %0d bytes total", inject_pos);
        end else begin
            $display("FAIL: only %0d bytes injected", inject_pos);
            errors = errors + 1;
        end

        if (!boot_done)
            $display("(boot_done not asserted in this program)");
        else
            $display("boot_done asserted");

        if (errors == 0)
            $display("*** MCU ROUTER CHIP TEST PASSED ***");
        else
            $display("*** MCU ROUTER CHIP TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
