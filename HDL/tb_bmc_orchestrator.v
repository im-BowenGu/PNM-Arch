`timescale 1ns/1ps

// =============================================================================
// tb_bmc_orchestrator — Testbench for RISC-V BMC Router Chip SoC
//
// Test program (stored in ROM):
//   LUI  x1, 0x10000      // x1 = 0x10000000 (UART base)
//   LUI  x2, 0x00048      // x2 = 0x00048000 -> 'H' = 0x48
//   ADDI x2, x2, 0x48     // x2 = 'H'
//   SW   x2, 0(x1)        // UART THR = 'H'
//   LUI  x3, 0xF0000      // x3 = 0xF0000000 (PNM base)
//   LUI  x4, 0x80000      // x4 = 0x80000000 (SRAM base)
//   ADDI x5, x0, 1        // x5 = 1
//   SW   x5, 0(x3)        // PNM CTRL = 1 (start injection)
//   NOP (loop forever)
//   JAL  x0, 0 (self-loop)
// =============================================================================

`include "pnm_defs.vh"

module tb_bmc_orchestrator;

    reg        clk;
    reg        rst_n;
    reg        uart_rx;
    wire       uart_tx;
    reg [15:0] ext_irq;
    wire       boot_done;

    // Spine signals (stub — no fabric connected)
    wire [7:0]  spine_inject_data;
    wire        spine_inject_valid;
    wire        spine_inject_sop;
    wire        spine_inject_eop;
    reg         spine_inject_ready;
    wire [1:0]  spine_inject_vc;

    reg [7:0]  spine_extract_data;
    reg        spine_extract_valid;
    reg        spine_extract_sop;
    reg        spine_extract_eop;
    reg [1:0]  spine_extract_vc;

    // DUT
    bmc_orchestrator_top #(
        .CLK_FREQ(100_000),
        .BAUD_RATE(9600),
        .NUM_LAYERS(2),
        .BOARD_X(2),
        .BOARD_Y(2)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .uart_rx          (uart_rx),
        .uart_tx          (uart_tx),
        .topology_rdy     (8'hFF),
        .spine_inject_data  (spine_inject_data),
        .spine_inject_valid (spine_inject_valid),
        .spine_inject_sop   (spine_inject_sop),
        .spine_inject_eop   (spine_inject_eop),
        .spine_inject_ready (spine_inject_ready),
        .spine_inject_vc    (spine_inject_vc),
        .spine_extract_data  (spine_extract_data),
        .spine_extract_valid (spine_extract_valid),
        .spine_extract_sop   (spine_extract_sop),
        .spine_extract_eop   (spine_extract_eop),
        .spine_extract_vc    (spine_extract_vc),
        .ext_irq          (ext_irq),
        .boot_done        (boot_done)
    );

    // Clock: 100 MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // ROM initialization: load test program
    // =========================================================================
    // RV32 instruction encoding helpers:
    function [31:0] lui_inst;
        input [4:0] rd;
        input [19:0] imm;
        begin
            lui_inst = {imm, rd, 7'b0110111};
        end
    endfunction

    function [31:0] addi_inst;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            addi_inst = {imm, rs1, 3'b000, rd, 7'b0010011};
        end
    endfunction

    function [31:0] sw_inst;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] imm;
        reg [4:0] imm_11_5;
        reg [4:0] imm_4_0;
        begin
            imm_11_5 = imm[11:5];
            imm_4_0  = imm[4:0];
            sw_inst = {imm_11_5, rs2, rs1, 3'b010, imm_4_0, 7'b0100011};
        end
    endfunction

    function [31:0] add_inst;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            add_inst = {7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011};
        end
    endfunction

    function [31:0] j_inst;
        input [4:0] rd;
        input [31:0] offset;
        reg [20:0] enc;
        begin
            // JAL encoding: imm[20|10:1|11|19:12]
            enc = {offset[20], offset[10:1], offset[11], offset[19:12]};
            j_inst = {enc, rd, 7'b1101111};
        end
    endfunction

    integer i;
    integer errors;
    reg [7:0] captured_uart;

    // UART TX byte decoder (validates actual transmitted bytes, not just toggling)
    localparam UART_BITW   = 10;     // 100 kHz / 9600 baud -> 10 clocks per bit
    localparam UART_NBYTES = 1;      // validate the first banner byte (HIGH #25 regression)
    reg [15:0]         uart_cyc;
    reg [3:0]          uart_biti;
    reg [7:0]          uart_data;
    reg                uart_in_frame;
    integer            uart_nframes;
    integer            uart_errors;
    reg [7:0]          uart_expect[0:UART_NBYTES-1];

    initial begin
        // Initialize signals
        rst_n = 1'b0;
        uart_rx = 1'b1;
        ext_irq = 16'h0;
        spine_inject_ready = 1'b1;
        spine_extract_data = 8'h0;
        spine_extract_valid = 1'b0;
        spine_extract_sop = 1'b0;
        spine_extract_eop = 1'b0;
        spine_extract_vc = 2'b00;
        errors = 0;
        captured_uart = 8'h0;
        uart_cyc = 0; uart_biti = 0; uart_data = 0; uart_in_frame = 0;
        uart_nframes = 0; uart_errors = 0;
        // Expected transmitted banner bytes.  Only the first ('H') is validated
        // deterministically: the simplified UART holds one pending byte (no TX
        // FIFO), so later bytes written back-to-back without LSR[5] flow control
        // are legitimately overwritten.  Validating the first byte is exactly the
        // regression test for the "first byte written to THR lost" bug.
        uart_expect[0] = 8'h48;

        // Load test program into ROM
        // Address 0x00: LUI  x1, 0x10000    (UART base)
        u_dut.rom[0] = lui_inst(5'd1, 20'h10000);
        // Address 0x04: LUI  x2, 0x00048    (high bits of 'H' = 0x48)
        u_dut.rom[1] = lui_inst(5'd2, 20'h00048);
        // Address 0x08: ADDI x2, x2, 0x48   (x2 = 'H')
        u_dut.rom[2] = addi_inst(5'd2, 5'd2, 12'h048);
        // Address 0x0C: SW   x2, 0(x1)      (UART THR = 'H')
        u_dut.rom[3] = sw_inst(5'd2, 5'd1, 12'h000);
        // Address 0x10: LUI  x3, 0xF0000    (PNM base)
        u_dut.rom[4] = lui_inst(5'd3, 20'hF0000);
        // Address 0x14: LUI  x4, 0x80000    (SRAM base)
        u_dut.rom[5] = lui_inst(5'd4, 20'h80000);
        // Address 0x18: ADDI x5, x0, 1      (x5 = 1)
        u_dut.rom[6] = addi_inst(5'd5, 5'd0, 12'h001);
        // Address 0x1C: SW   x5, 0(x3)      (PNM CTRL = 1)
        u_dut.rom[7] = sw_inst(5'd5, 5'd3, 12'h000);
        // Address 0x20: ADDI x6, x0, 0x20   (x6 = 0x20 = ' ')
        u_dut.rom[8] = addi_inst(5'd6, 5'd0, 12'h020);
        // Address 0x24: SW   x6, 0(x1)      (UART THR = ' ')
        u_dut.rom[9] = sw_inst(5'd6, 5'd1, 12'h000);
        // Address 0x28: SW   x6, 4(x1)      (UART THR = ' ' again)
        u_dut.rom[10] = sw_inst(5'd6, 5'd1, 12'h004);
        // Address 0x2C: LUI  x7, 0x00050    (x7 = 0x50 = 'P')
        u_dut.rom[11] = lui_inst(5'd7, 20'h00050);
        // Address 0x30: ADDI x7, x7, 0x030  (x7 = 'P' = 0x50)
        u_dut.rom[12] = addi_inst(5'd7, 5'd7, 12'h030);
        // Address 0x34: SW   x7, 0(x1)      (UART THR = 'P')
        u_dut.rom[13] = sw_inst(5'd7, 5'd1, 12'h000);
        // Address 0x38: ADDI x8, x0, 4      (x8 = 4, boot_done flag = bit 2)
        u_dut.rom[14] = addi_inst(5'd8, 5'd0, 12'h004);
        // Address 0x3C: SW   x8, 0(x3)      (PNM CTRL = boot_done=1)
        u_dut.rom[15] = sw_inst(5'd8, 5'd3, 12'h000);
        // Address 0x40: self-loop
        u_dut.rom[16] = j_inst(5'd0, 32'h40);
        // Fill rest with NOPs (ADDI x0, x0, 0)
        for (i = 17; i < 16384; i = i + 1)
            u_dut.rom[i] = 32'h00000013;  // NOP

        // Release reset
        #100;
        rst_n = 1'b1;

        // Wait for boot_done
        wait (boot_done === 1'b1);
        $display("[TB] boot_done asserted");

        // Wait for UART transmission (banner is 4 bytes; allow several frames)
        #500000;

        // Check PNM dispatch counter
        if (u_dut.route_dispatches != 0)
            $display("[TB] PNM dispatches = %0d", u_dut.route_dispatches);
        else
            $display("[TB] PNM dispatches = 0 (expected for short test)");

        // Validate transmitted UART bytes were decoded correctly by the receiver
        if (uart_nframes < 1) begin
            $display("[TB] UART ERROR: no TX frame received");
            errors = errors + 1;
        end
        if (uart_errors != 0) begin
            $display("[TB] UART byte mismatch errors = %0d", uart_errors);
            errors = errors + uart_errors;
        end

        // Summary
        $display("");
        if (errors == 0)
            $display("*** BMC ROUTER CHIP TEST PASSED ***");
        else begin
            $display("*** BMC ROUTER CHIP TEST FAILED (%0d errors) ***", errors);
        end
        $finish;
    end

    // Timeout watchdog
    initial begin
        #2000000;
        $display("[TB] TIMEOUT — test did not complete in time");
        $finish;
    end

    // UART TX byte decoder: frames start+8N1+stop and validates transmitted bytes.
    // This detects lost/stale first-byte bugs (e.g. THR write racing the TX start)
    // that a simple "TX toggled" check cannot see.  Sampling is aligned to the
    // falling edge of each start bit so back-to-back frames decode correctly.
    reg uart_tx_d;
    always @(posedge clk)
        uart_tx_d <= uart_tx;

    always @(posedge clk) begin
        if (!uart_in_frame) begin
            if (uart_tx_d && !uart_tx) begin   // falling edge = start bit
                uart_in_frame <= 1'b1;
                uart_cyc <= 0;
                uart_biti <= 0;
                uart_data <= 8'h0;
            end
        end else begin
            uart_cyc <= uart_cyc + 1;
            // Sample at the middle of each bit; bit period = UART_BITW clocks.
            case (uart_biti)
                0: if (uart_cyc == (UART_BITW >> 1)) uart_biti <= 1;            // start mid
                1: if (uart_cyc == UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[0] <= uart_tx; uart_biti <= 2;
                   end
                2: if (uart_cyc == 2*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[1] <= uart_tx; uart_biti <= 3;
                   end
                3: if (uart_cyc == 3*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[2] <= uart_tx; uart_biti <= 4;
                   end
                4: if (uart_cyc == 4*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[3] <= uart_tx; uart_biti <= 5;
                   end
                5: if (uart_cyc == 5*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[4] <= uart_tx; uart_biti <= 6;
                   end
                6: if (uart_cyc == 6*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[5] <= uart_tx; uart_biti <= 7;
                   end
                7: if (uart_cyc == 7*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[6] <= uart_tx; uart_biti <= 8;
                   end
                8: if (uart_cyc == 8*UART_BITW + (UART_BITW >> 1)) begin
                       uart_data[7] <= uart_tx; uart_biti <= 9;
                   end
                9: if (uart_cyc == 9*UART_BITW + (UART_BITW >> 1)) begin
                       // stop bit should be high
                       if (uart_tx != 1'b1) begin
                           $display("[TB] UART stop bit error for byte %02x", uart_data);
                           uart_errors = uart_errors + 1;
                       end
                       uart_nframes = uart_nframes + 1;
                       if (uart_nframes <= UART_NBYTES &&
                           uart_data != uart_expect[uart_nframes-1]) begin
                           $display("[TB] UART byte %0d: expected %02x got %02x",
                                    uart_nframes, uart_expect[uart_nframes-1], uart_data);
                           uart_errors = uart_errors + 1;
                       end
                       uart_in_frame <= 1'b0;
                       uart_biti <= 0;
                       uart_cyc <= 0;
                   end
            endcase
        end
    end

endmodule
