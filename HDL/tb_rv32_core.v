`timescale 1ns/1ps

// =============================================================================
// tb_rv32_core — self-checking testbench for the RV32 core, focused on the
// shift-right-arithmetic (SRAI) decode that HIGH #24 found broken.
//
// Program:
//   LUI   x1, 0xFFFFF      // x1 = 0xFFFFF000 = -4096 (negative)
//   SRAI  x2, x1, 4        // x2 = 0xFFFFFF00 (-256)  [arithmetic]
//   SRLI  x3, x1, 4        // x3 = 0x0FFFFF00 (4095)  [logical]
//   JAL   x0, <self>       // halt in a loop
//
// The bug forced alu_funct7_r = 0 for OP_OP_IMM, so SRAI was decoded as SRLI:
// x2 then came out 0x0FFFFF00 (logical) instead of 0xFFFFFF00 (arithmetic).
// =============================================================================

module tb_rv32_core;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    wire [31:0] bus_addr, bus_wdata, bus_rdata;
    reg  [31:0] rdata;
    wire        bus_we;
    wire [3:0]  bus_be;
    wire        bus_valid;
    reg         bus_ready = 1'b1;
    reg         bus_error = 1'b0;
    wire [15:0] irq = 16'h0;
    wire [31:0] fetch_addr;

    reg [31:0] rom [0:15];

    rv32_core #(.RESET_ADDR(32'h0), .NMINT(16)) u_core (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(rdata),
        .bus_we(bus_we), .bus_be(bus_be), .bus_valid(bus_valid), .bus_ready(bus_ready),
        .bus_error(bus_error), .irq(irq), .fetch_addr(fetch_addr)
    );

    // Combinational instruction ROM (like bmc_orchestrator_top)
    always @(*) rdata = rom[fetch_addr[15:2]];

    integer errors;

    initial begin
        errors = 0;

        rom[0] = 32'hFFFFF0B7;  // LUI  x1, 0xFFFFF
        rom[1] = 32'h4040D113;  // SRAI x2, x1, 4
        rom[2] = 32'h0040D193;  // SRLI x3, x1, 4
        rom[3] = 32'h0000006F;  // JAL  x0, 0 (self-loop) [use JAL x0,0 = 0x0000006F]

        #40 rst_n = 1;

        // Run enough cycles for fetch/decode/execute of the 4 instructions
        #(200);
        #20;

        $display("[TB] x1 = %08x (expect fffff000)", u_core.rf[1]);
        $display("[TB] x2 = %08x (expect ffffff00, SRAI)", u_core.rf[2]);
        $display("[TB] x3 = %08x (expect 0fffff00, SRLI)", u_core.rf[3]);

        if (u_core.rf[1] !== 32'hFFFFF000) begin
            $display("[TB] FAIL: x1 wrong"); errors = errors + 1;
        end
        if (u_core.rf[2] !== 32'hFFFFFF00) begin
            $display("[TB] FAIL: SRAI x2 = %08x, expected ffffff00", u_core.rf[2]);
            errors = errors + 1;
        end
        if (u_core.rf[3] !== 32'h0FFFFF00) begin
            $display("[TB] FAIL: SRLI x3 = %08x, expected 0fffff00", u_core.rf[3]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** RV32 CORE TEST PASSED ***");
        else
            $display("*** RV32 CORE TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin #5000; $display("[TB] TIMEOUT"); $finish(1); end

endmodule
