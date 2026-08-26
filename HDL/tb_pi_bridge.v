`timescale 1ns/1ps

// =============================================================================
// tb_pi_bridge — Testbench for SPI-to-PNM Bridge
//
// Simulates a Raspberry Pi acting as SPI master against a PNM register file
// modeled as an asynchronous read mux on the bridge's own pnm_addr output
// (same combinational-read convention as the orchestrator chips' ROM window).
//
//   1. Write LAYER  = 0x02, check register + write-ack status byte
//   2. Write MODULE = 0x07, check register + write-ack status byte
//   3. Write LAYER  = 0xDEADBEEF (32-bit path)
//   4. Read LAYER back through the bus -> expect 0xDEADBEEF
//   5. Read MODULE back through the bus -> expect 0x00000007
// =============================================================================

module tb_pi_bridge;

    reg clk, rst_n;
    reg sclk, mosi, cs_n;
    wire miso;
    wire irq_out;

    wire [7:0]  pnm_addr;
    wire [31:0] pnm_wdata;
    wire [31:0] pnm_rdata;
    wire        pnm_we;
    wire        pnm_valid;
    reg         pnm_ready;

    wire frame_done;

    integer errors;
    integer write_count;

    always #5 clk = ~clk;  // 100 MHz

    pi_bridge u_dut (
        .clk(clk), .rst_n(rst_n),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .irq_out(irq_out),
        .pnm_addr(pnm_addr),
        .pnm_wdata(pnm_wdata),
        .pnm_rdata(pnm_rdata),
        .pnm_we(pnm_we),
        .pnm_valid(pnm_valid),
        .pnm_ready(pnm_ready),
        .frame_done(frame_done)
    );

    reg [31:0] pnm_regs [0:15];
    assign pnm_rdata = pnm_regs[pnm_addr[5:2]];

    always @(posedge clk) begin
        if (pnm_valid && pnm_we) begin
            pnm_regs[pnm_addr[5:2]] <= pnm_wdata;
            $display("[%0t] PNM WRITE addr=0x%02h data=0x%08h",
                     $time, pnm_addr, pnm_wdata);
            write_count <= write_count + 1;
        end
    end

    task spi_frame(
        input         rw,
        input  [6:0]  sel,
        input  [31:0] wdata,
        output [31:0] rdata,
        output [7:0]  status
    );
        integer i;
        reg [7:0] stat_acc;
        begin
            rdata = 32'h0;
            stat_acc = 8'h0;
            cs_n = 1'b1;
            sclk = 1'b0;
            mosi = 1'b0;
            #100;
            cs_n = 1'b0;
            #100;

            for (i = 7; i >= 0; i = i - 1) begin
                mosi = (i == 7) ? rw : sel[i];
                #50;
                sclk = 1'b1;
                #100;
                #50;
                sclk = 1'b0;
                #50;
            end

            for (i = 31; i >= 0; i = i - 1) begin
                mosi = wdata[i];
                #50;
                sclk = 1'b1;
                #100;
                rdata[i] = miso;
                #50;
                sclk = 1'b0;
                #50;
            end

            for (i = 7; i >= 0; i = i - 1) begin
                mosi = 1'b0;
                #50;
                sclk = 1'b1;
                #100;
                stat_acc = {stat_acc[6:0], miso};
                #50;
                sclk = 1'b0;
                #50;
            end
            status = stat_acc;

            cs_n = 1'b1;
            #200;
        end
    endtask

    reg [31:0] resp;
    reg [7:0]  stat;

    initial begin
        clk = 0; rst_n = 0;
        sclk = 0; mosi = 0; cs_n = 1'b1;
        pnm_ready = 1'b1;
        errors = 0;
        write_count = 0;

        for (integer j = 0; j < 16; j = j + 1) pnm_regs[j] = 32'h0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("--- Test 1: Write LAYER=0x02 ---");
        spi_frame(1'b0, 7'h01, 32'h00000002, resp, stat);
        if (write_count !== 1 || pnm_regs[4'h1] !== 32'h00000002 || stat !== 8'h01) begin
            $display("FAIL: writes=%0d PNM_LAYER=0x%08h status=0x%02h",
                     write_count, pnm_regs[4'h1], stat);
            errors = errors + 1;
        end else
            $display("  OK: PNM_LAYER written, ack status=0x01");

        $display("--- Test 2: Write MODULE=0x07 ---");
        spi_frame(1'b0, 7'h02, 32'h00000007, resp, stat);
        if (write_count !== 2 || pnm_regs[4'h2] !== 32'h00000007 || stat !== 8'h01) begin
            $display("FAIL: writes=%0d PNM_MODULE=0x%08h status=0x%02h",
                     write_count, pnm_regs[4'h2], stat);
            errors = errors + 1;
        end else
            $display("  OK: PNM_MODULE written, ack status=0x01");

        $display("--- Test 3: Write LAYER=0xDEADBEEF ---");
        spi_frame(1'b0, 7'h01, 32'hDEADBEEF, resp, stat);
        if (write_count !== 3 || pnm_regs[4'h1] !== 32'hDEADBEEF || stat !== 8'h01) begin
            $display("FAIL: writes=%0d PNM_LAYER=0x%08h status=0x%02h",
                     write_count, pnm_regs[4'h1], stat);
            errors = errors + 1;
        end else
            $display("  OK: full 32-bit data field stored");

        $display("--- Test 4: Read LAYER back ---");
        spi_frame(1'b1, 7'h01, 32'h0, resp, stat);
        if (resp === 32'hDEADBEEF && stat === 8'h00)
            $display("  OK: read-back = 0x%08h", resp);
        else begin
            $display("FAIL: read-back = 0x%08h status=0x%02h (expected 0xDEADBEEF/0x00)",
                     resp, stat);
            errors = errors + 1;
        end

        $display("--- Test 5: Read MODULE back ---");
        spi_frame(1'b1, 7'h02, 32'h0, resp, stat);
        if (resp === 32'h00000007 && stat === 8'h00)
            $display("  OK: read-back = 0x%08h", resp);
        else begin
            $display("FAIL: read-back = 0x%08h status=0x%02h (expected 0x00000007/0x00)",
                     resp, stat);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("*** PI BRIDGE TEST PASSED ***");
        else
            $display("*** PI BRIDGE TEST FAILED (%0d errors) ***", errors);

        $finish;
    end

endmodule
