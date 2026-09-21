`timescale 1ns/1ps

// =============================================================================
// tb_rv32_core_load — self-checking testbench for RV32 LB/LH graphic lane
// extraction (the load-side twin of the SB/SH store-lane shifts).
//
// Program (ROM at 0x00000000, data SRAM at 0x00400000):
//   LUI  x1, 0x00400      // x1 = 0x00400000 (memory base)
//   LUI  x2, 0x11223      // x2 = 0x11223000
//   ADDI x2, x2, 0x344    // x2 = 0x11223344 (the stored word)
//   SW   x2, 0(x1)        // mem[0x400000]=0x11223344
//   LB   x3, 1(x1)        // x3 = sign-ext(byte 1) = 0x33
//   LBU  x4, 0(x1)        // x4 = 0x44
//   LH   x5, 2(x1)        // x5 = sign-ext(half 2) = 0x1122
//   LHU  x6, 2(x1)        // x6 = 0x00001122
//   LBU  x7, 3(x1)        // x7 = 0x00000011
//   JAL  x0, 0            // halt
//
// The old load path read mem_result[7:0]/[15:0] unconditionally (always lane 0),
// ignoring the addressed lane — LB @1 returned 0x44, LH @2 returned 0x3344.
// =============================================================================

module tb_rv32_core_load;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    wire [31:0] bus_addr, bus_wdata, bus_rdata;
    reg  [31:0] rdata;
    wire        bus_we;
    wire [3:0]  bus_be;
    wire        bus_valid;
    reg         bus_ready = 1'b0;
    reg         we_reg = 1'b0;
    reg [31:0]  addr_reg = 32'h0, wd_reg = 32'h0;
    reg [3:0]   be_reg = 4'h0;
    reg         bus_error = 1'b0;
    wire [15:0] irq = 16'h0;
    wire [31:0] fetch_addr;

    reg [31:0] rom  [0:15];
    reg [7:0]  mem  [0:1023];

    rv32_core #(.RESET_ADDR(32'h0), .NMINT(16)) u_core (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(rdata),
        .bus_we(bus_we), .bus_be(bus_be), .bus_valid(bus_valid), .bus_ready(bus_ready),
        .bus_error(bus_error), .irq(irq), .fetch_addr(fetch_addr)
    );

    // --- RV32 instruction encoding helpers --------------------------------
    function [31:0] lui_inst; input [4:0] rd; input [19:0] imm; begin
        lui_inst = {imm, rd, 7'b0110111}; end endfunction
    function [31:0] addi_inst; input [4:0] rd; input [4:0] rs1; input [11:0] imm; begin
        addi_inst = {imm, rs1, 3'b000, rd, 7'b0010011}; end endfunction
    function [31:0] sw_inst; input [4:0] rs2; input [4:0] rs1; input [11:0] imm;
        reg [4:0] imm_11_5; reg [4:0] imm_4_0; begin
            imm_11_5 = imm[11:5]; imm_4_0 = imm[4:0];
            sw_inst = {imm_11_5, rs2, rs1, 3'b010, imm_4_0, 7'b0100011}; end endfunction
    function [31:0] lb_inst; input [4:0] rd; input [4:0] rs1; input [11:0] imm; begin
        lb_inst = {imm, rs1, 3'b000, rd, 7'b0000011}; end endfunction
    function [31:0] lh_inst; input [4:0] rd; input [4:0] rs1; input [11:0] imm; begin
        lh_inst = {imm, rs1, 3'b001, rd, 7'b0000011}; end endfunction
    function [31:0] lbu_inst; input [4:0] rd; input [4:0] rs1; input [11:0] imm; begin
        lbu_inst = {imm, rs1, 3'b100, rd, 7'b0000011}; end endfunction
    function [31:0] lhu_inst; input [4:0] rd; input [4:0] rs1; input [11:0] imm; begin
        lhu_inst = {imm, rs1, 3'b101, rd, 7'b0000011}; end endfunction
    function [31:0] j_inst; input [4:0] rd; input [31:0] offset;
        reg [20:0] enc; begin
            enc = {offset[20], offset[10:1], offset[11], offset[19:12]};
            j_inst = {enc, rd, 7'b1101111}; end endfunction

    // Combinational read mux: data region 0x00400000 -> SRAM (addressed by the
    // bus, which carries the load address), else the instruction ROM decoded
    // from fetch_addr (= pc), matching the proven tb_rv32_core.v pattern.
    always @(*) begin
        if (bus_addr[31:20] == 12'h004)
            rdata = {mem[bus_addr[9:2]*4 + 3],
                     mem[bus_addr[9:2]*4 + 2],
                     mem[bus_addr[9:2]*4 + 1],
                     mem[bus_addr[9:2]*4 + 0]};
        else
            rdata = rom[fetch_addr[15:2]];
    end

    // Byte-enable honoring store on the data region. The core holds the
    // request (bus_valid/bus_we/bus_addr/bus_wdata) stable while bus_ready is
    // low, so assert bus_ready one cycle after a valid request and commit the
    // write on that settled cycle (avoids the NBA one-cycle window where the
    // core deasserts we on the same edge the SRAM would sample it).
    reg bus_ready_nxt;
    always @(posedge clk) begin
        if (rst_n && bus_valid)
            bus_ready <= 1'b1;
        else
            bus_ready <= 1'b0;
    end
    always @(posedge clk) begin
        // Capture the request while the core holds it stable.
        if (bus_valid && !bus_ready) begin
            we_reg    <= bus_we;
            addr_reg  <= bus_addr;
            wd_reg    <= bus_wdata;
            be_reg    <= bus_be;
        end
        // Commit on the ready-accept edge.
        if (we_reg && addr_reg[31:20] == 12'h004) begin
            if (be_reg[0]) mem[addr_reg[9:2]*4 + 0] <= wd_reg[7:0];
            if (be_reg[1]) mem[addr_reg[9:2]*4 + 1] <= wd_reg[15:8];
            if (be_reg[2]) mem[addr_reg[9:2]*4 + 2] <= wd_reg[23:16];
            if (be_reg[3]) mem[addr_reg[9:2]*4 + 3] <= wd_reg[31:24];
        end
    end

    integer errors;

    initial begin
        errors = 0;

        rom[0] = lui_inst(5'd1, 20'h00400);   // x1 = 0x00400000
        rom[1] = lui_inst(5'd2, 20'h11223);   // x2 = 0x11223000
        rom[2] = addi_inst(5'd2, 5'd2, 12'h344); // x2 = 0x11223344
        rom[3] = sw_inst(5'd2, 5'd1, 12'h000);   // mem[0x400000]=0x11223344
        rom[4] = lb_inst(5'd3, 5'd1, 12'h001);   // LB x3, 1(x1)
        rom[5] = lbu_inst(5'd4, 5'd1, 12'h000);  // LBU x4, 0(x1)
        rom[6] = lh_inst(5'd5, 5'd1, 12'h002);   // LH x5, 2(x1)
        rom[7] = lhu_inst(5'd6, 5'd1, 12'h002);  // LHU x6, 2(x1)
        rom[8] = lbu_inst(5'd7, 5'd1, 12'h003);  // LBU x7, 3(x1)
        rom[9] = j_inst(5'd0, 32'h0);            // JAL x0, 0

        #40 rst_n = 1;

        // Plenty of cycles for fetch/decode/execute of 10 instructions with
        // memory round-trips.
        #(1100); #20;

        $display("[TB] x3 = %08x (expect 00000033, LB @1 of 11223344)", u_core.rf[3]);
        $display("[TB] x4 = %08x (expect 00000044, LBU @0)", u_core.rf[4]);
        $display("[TB] x5 = %08x (expect 00001122, LH @2)", u_core.rf[5]);
        $display("[TB] x6 = %08x (expect 00001122, LHU @2)", u_core.rf[6]);
        $display("[TB] x7 = %08x (expect 00000011, LBU @3)", u_core.rf[7]);

        if (u_core.rf[3] !== 32'h00000033) begin
            $display("[TB] FAIL: LB @1 = %08x, expected 00000033", u_core.rf[3]);
            errors = errors + 1;
        end
        if (u_core.rf[4] !== 32'h00000044) begin
            $display("[TB] FAIL: LBU @0 = %08x, expected 00000044", u_core.rf[4]);
            errors = errors + 1;
        end
        if (u_core.rf[5] !== 32'h00001122) begin
            $display("[TB] FAIL: LH @2 = %08x, expected 00001122", u_core.rf[5]);
            errors = errors + 1;
        end
        if (u_core.rf[6] !== 32'h00001122) begin
            $display("[TB] FAIL: LHU @2 = %08x, expected 00001122", u_core.rf[6]);
            errors = errors + 1;
        end
        if (u_core.rf[7] !== 32'h00000011) begin
            $display("[TB] FAIL: LBU @3 = %08x, expected 00000011", u_core.rf[7]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** RV32 CORE LOAD TEST PASSED ***");
        else
            $display("*** RV32 CORE LOAD TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin #30000; $display("[TB] TIMEOUT"); $finish(1); end

endmodule
