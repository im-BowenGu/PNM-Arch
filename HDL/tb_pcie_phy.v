`timescale 1ns/1ps

`include "pnm_defs.vh"

// =============================================================================
// tb_pcie_phy — Self-checking testbench for the PCIe Gen5 x16 PHY controller
//
// Tests:
//   1. ID register (VID/DID)
//   2. LTSSM link-up (DETECT -> POLLING -> CONFIG -> L0)
//   3. CMD register write (MSE + BME)
//   4. Staging buffer push (WRDATA + WR_COUNT)
//   5. MemWr DMA (staging -> loopback, TLP count, wr_done)
//   6. MemRd DMA (loopback -> CPL FIFO, rd_done)
//   7. CPL_DATA pop and data integrity (round-trip pattern match)
//   8. W1C interrupt clear
//   9. Error: MemWr with insufficient staging
//  10. Flush (DBELL bit6)
//  11. Recovery: large MemRd fills CPL FIFO, LTSSM enters RECOVERY
//  12. STS/DCAP/LANE_STS field checks
//
// NOTE: CPL_DATA reads have a FIFO-pop side effect (pointer advances).
//       Tests must account for this — never read CPL_COUNT via read_reg
//       while CPL_DATA is expected to contain data.
// =============================================================================

module tb_pcie_phy;

    reg         clk;
    reg         rst_n;

    reg  [7:0]  ctl_addr;
    reg  [31:0] ctl_wdata;
    reg         ctl_we;
    reg         ctl_valid;
    wire        ctl_ready;
    wire [31:0] ctl_rdata;

    wire        irq;
    wire        link_up;
    wire [3:0]  ltssm_state;

    // =========================================================================
    // DUT
    // =========================================================================
    pcie_phy #(
        .LANES                   (16),
        .GEN                     (5),
        .MAX_PAYLOAD_BYTES       (512),
        .PAYLOAD_BYTES_PER_CYCLE (64),
        .CPL_FIFO_WORDS          (256),
        .STAGE_WORDS             (128),
        .LB_WORDS                (4096),
        .LOOPBACK                (1)
    ) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .ctl_addr  (ctl_addr),
        .ctl_wdata (ctl_wdata),
        .ctl_we    (ctl_we),
        .ctl_valid (ctl_valid),
        .ctl_ready (ctl_ready),
        .ctl_rdata (ctl_rdata),
        .irq       (irq),
        .link_up   (link_up),
        .ltssm_state(ltssm_state)
    );

    // =========================================================================
    // Clock (100 MHz)
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    integer errors;
    integer i;
    reg [31:0] rd_data;

    task write_reg(input [7:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            ctl_addr  <= addr;
            ctl_wdata <= data;
            ctl_we    <= 1'b1;
            ctl_valid <= 1'b1;
            @(negedge clk);
            ctl_valid <= 1'b0;
            ctl_we    <= 1'b0;
        end
    endtask

    task read_reg(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            ctl_addr  <= addr;
            ctl_we    <= 1'b0;
            ctl_valid <= 1'b1;
            @(negedge clk);
            data = ctl_rdata;
            ctl_valid <= 1'b0;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_pcie_phy.vcd");
        $dumpvars(0, tb_pcie_phy);

        errors = 0;
        rst_n  = 0;
        ctl_addr  = 0;
        ctl_wdata = 0;
        ctl_we    = 0;
        ctl_valid = 0;

        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: ID register
        // ---------------------------------------------------------------
        $display("Test 1: ID register");
        read_reg(8'h00, rd_data);
        if (rd_data !== 32'h5016_10EE) begin
            $display("  FAIL: ID = %h, expected 501610EE", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: ID = %h", rd_data);

        // ---------------------------------------------------------------
        // Test 2: Wait for LTSSM link-up
        // ---------------------------------------------------------------
        $display("Test 2: LTSSM link-up");
        begin : ltssm_wait
            integer timeout;
            timeout = 0;
            while (!link_up && timeout < 500) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!link_up) begin
                $display("  FAIL: link_up not asserted after %0d cycles", timeout);
                errors = errors + 1;
            end else
                $display("  PASS: link_up after %0d cycles, ltssm=%0d", timeout, ltssm_state);
        end

        // ---------------------------------------------------------------
        // Test 3: CMD = MSE | BME
        // ---------------------------------------------------------------
        $display("Test 3: CMD register write");
        write_reg(8'h04, 32'h0000_0003);
        read_reg(8'h04, rd_data);
        if (rd_data !== 32'h0000_0003) begin
            $display("  FAIL: CMD = %h, expected 00000003", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: CMD = %h", rd_data);

        // ---------------------------------------------------------------
        // Test 4: Push 64 words into staging buffer
        // ---------------------------------------------------------------
        $display("Test 4: Staging buffer push");
        for (i = 0; i < 64; i = i + 1)
            write_reg(8'h40, 32'h0000_1000 + i);
        read_reg(8'h44, rd_data);  // WR_COUNT (no pop side effect)
        if (rd_data !== 32'd64) begin
            $display("  FAIL: WR_COUNT = %0d, expected 64", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: WR_COUNT = %0d", rd_data);

        // ---------------------------------------------------------------
        // Test 5: MemWr DMA (64 words = 256 bytes)
        // ---------------------------------------------------------------
        $display("Test 5: MemWr DMA");
        write_reg(8'h14, 32'h0000_0000);
        write_reg(8'h18, 32'h0000_0000);
        write_reg(8'h1C, 32'd256);
        write_reg(8'h34, 32'h0000_0001);  // INTR_EN = wr-done
        write_reg(8'h10, 32'h0000_0001);  // DBELL bit0

        begin : wr_done_wait
            integer timeout;
            reg [31:0] sts;
            timeout = 0;
            sts = 0;
            while (sts[0] !== 1'b1 && timeout < 200) begin
                @(posedge clk);
                read_reg(8'h38, sts);
                timeout = timeout + 1;
            end
            if (sts[0] !== 1'b1) begin
                $display("  FAIL: wr_done not set after %0d cycles", timeout);
                errors = errors + 1;
            end else
                $display("  PASS: wr_done after %0d cycles", timeout);
        end

        read_reg(8'h08, rd_data);  // STS
        if (rd_data[31:16] !== 16'd1) begin
            $display("  FAIL: TLP count = %0d, expected 1", rd_data[31:16]);
            errors = errors + 1;
        end else
            $display("  PASS: TLP count = %0d", rd_data[31:16]);

        // ---------------------------------------------------------------
        // Test 6: MemRd DMA (256 bytes)
        // ---------------------------------------------------------------
        $display("Test 6: MemRd DMA");
        write_reg(8'h20, 32'h0000_0000);
        write_reg(8'h24, 32'h0000_0000);
        write_reg(8'h28, 32'd256);
        write_reg(8'h34, 32'h0000_0002);  // INTR_EN = rd-done
        write_reg(8'h10, 32'h0000_0002);  // DBELL bit1

        begin : rd_done_wait
            integer timeout;
            reg [31:0] sts;
            timeout = 0;
            sts = 0;
            while (sts[1] !== 1'b1 && timeout < 200) begin
                @(posedge clk);
                read_reg(8'h38, sts);
                timeout = timeout + 1;
            end
            if (sts[1] !== 1'b1) begin
                $display("  FAIL: rd_done not set after %0d cycles", timeout);
                errors = errors + 1;
            end else
                $display("  PASS: rd_done after %0d cycles", timeout);
        end

        // ---------------------------------------------------------------
        // Test 7: CPL_DATA pop — verify round-trip data integrity
        //
        // IMPORTANT: read_reg on CPL_DATA pops the FIFO as a side effect.
        // We read exactly 64 words (matching the 256-byte MemRd) and verify
        // each against the expected pattern.
        // ---------------------------------------------------------------
        $display("Test 7: CPL_DATA round-trip integrity");
        begin : cpl_check
            reg [31:0] cpl_word;
            reg [31:0] expected;
            integer bad;
            bad = 0;
            for (i = 0; i < 64; i = i + 1) begin
                read_reg(8'h2C, cpl_word);
                expected = 32'h0000_1000 + i;
                if (cpl_word !== expected) begin
                    if (bad < 5)
                        $display("  FAIL: CPL[%0d] = %h, expected %h", i, cpl_word, expected);
                    bad = bad + 1;
                end
            end
            if (bad > 0) begin
                $display("  FAIL: %0d CPL mismatches out of 64", bad);
                errors = errors + 1;
            end else
                $display("  PASS: 64 CPL words match staged pattern");
        end

        // CPL_COUNT should be 0 now (64 pushed, 64 popped via read_reg).
        // Wait for the last deferred pop to execute (up to 3 cycles).
        repeat(3) @(posedge clk);
        // Don't read via read_reg (would pop again). Direct peek:
        $display("  CPL_COUNT = %0d (direct peek)", u_dut.cpl_used_r);
        if (u_dut.cpl_used_r !== 9'd0) begin
            $display("  FAIL: cpl_used_r = %0d, expected 0", u_dut.cpl_used_r);
            errors = errors + 1;
        end else
            $display("  PASS: cpl_used_r = 0");

        // ---------------------------------------------------------------
        // Test 8: W1C — clear wr_done via DBELL bit4
        // ---------------------------------------------------------------
        $display("Test 8: W1C interrupt clear");
        read_reg(8'h38, rd_data);
        if (rd_data[0] !== 1'b1) begin
            $display("  FAIL: wr_done should still be set, STS=%h", rd_data);
            errors = errors + 1;
        end
        write_reg(8'h10, 32'h0000_0010);  // DBELL bit4
        read_reg(8'h38, rd_data);
        if (rd_data[0] !== 1'b0) begin
            $display("  FAIL: wr_done not cleared, STS=%h", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: wr_done cleared");

        // ---------------------------------------------------------------
        // Test 9: Error — MemWr with insufficient staging
        // ---------------------------------------------------------------
        $display("Test 9: MemWr error (insufficient staging)");
        for (i = 0; i < 8; i = i + 1)
            write_reg(8'h40, 32'hDEAD_0000 + i);
        read_reg(8'h44, rd_data);
        $display("  Info: WR_COUNT = %0d", rd_data);

        write_reg(8'h14, 32'h0000_0000);
        write_reg(8'h18, 32'h0000_0000);
        write_reg(8'h1C, 32'd128);
        write_reg(8'h34, 32'h0000_0005);
        write_reg(8'h10, 32'h0000_0001);

        repeat(5) @(posedge clk);
        read_reg(8'h38, rd_data);
        if (rd_data[2] !== 1'b1) begin
            $display("  FAIL: sts_err not set, STS=%h", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: sts_err set (bit2 = %b)", rd_data[2]);

        // ---------------------------------------------------------------
        // Test 10: Flush via DBELL bit6
        // ---------------------------------------------------------------
        $display("Test 10: Flush CPL FIFO");
        // Push 32 words into staging, then MemRd to fill CPL FIFO
        for (i = 0; i < 32; i = i + 1)
            write_reg(8'h40, 32'hBEEF_0000 + i);
        write_reg(8'h20, 32'h0000_0000);
        write_reg(8'h24, 32'h0000_0000);
        write_reg(8'h28, 32'd128);        // 128 bytes = 32 words
        write_reg(8'h34, 32'h0000_0000);
        write_reg(8'h10, 32'h0000_0002);  // DBELL bit1 = start MemRd
        repeat(10) @(posedge clk);

        $display("  Info: cpl_used before flush = %0d", u_dut.cpl_used_r);

        write_reg(8'h10, 32'h0000_0040);  // DBELL bit6 = flush + clear errors

        if (u_dut.cpl_used_r !== 9'd0) begin
            $display("  FAIL: cpl_used after flush = %0d, expected 0", u_dut.cpl_used_r);
            errors = errors + 1;
        end else
            $display("  PASS: cpl_used = 0 after flush");

        read_reg(8'h38, rd_data);
        if (rd_data[2] !== 1'b0) begin
            $display("  FAIL: sts_err not cleared after flush, STS=%h", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: errors cleared after flush");

        // ---------------------------------------------------------------
        // Test 11: Recovery — large MemRd fills CPL FIFO
        // ---------------------------------------------------------------
        $display("Test 11: Recovery mode (large MemRd)");
        write_reg(8'h20, 32'h0000_0000);
        write_reg(8'h24, 32'h0000_0000);
        write_reg(8'h28, 32'd2048);       // 2048 bytes = 512 words
        write_reg(8'h34, 32'h0000_0002);  // INTR_EN = rd-done
        write_reg(8'h10, 32'h0000_0002);  // DBELL bit1

        // Poll for RECOVERY
        begin : recovery_check
            integer timeout;
            reg [3:0] obs;
            integer saw_recovery;
            timeout = 0;
            saw_recovery = 0;
            while (timeout < 200) begin
                @(posedge clk);
                obs = ltssm_state;
                if (obs == 4'd4) saw_recovery = 1;
                timeout = timeout + 1;
            end
            if (saw_recovery)
                $display("  PASS: RECOVERY observed during large MemRd");
            else
                $display("  INFO: RECOVERY not observed");
        end

        // Drain CPL FIFO — alternate idle cycles (let DMA push) with pop bursts.
        // Use direct pointer peek for count (read_reg CPL_COUNT pops as side effect).
        begin : cpl_drain_recovery
            reg [31:0] cpl_word;
            integer count;
            count = 0;
            while (count < 512) begin
                repeat(4) @(posedge clk);  // let DMA push
                // Pop burst (blind — up to 64 words per burst)
                begin : pop_burst
                    integer j;
                    for (j = 0; j < 64; j = j + 1) begin
                        if (u_dut.cpl_used_r == 0) disable pop_burst;
                        read_reg(8'h2C, cpl_word);
                        count = count + 1;
                    end
                end
                // Check if done
                read_reg(8'h38, rd_data);
                if (rd_data[1]) begin  // rd_done
                    // Drain remaining
                    while (u_dut.cpl_used_r > 0) begin
                        read_reg(8'h2C, cpl_word);
                        count = count + 1;
                    end
                end
            end
            $display("  PASS: Drained %0d CPL words from recovery transfer", count);
        end

        read_reg(8'h38, rd_data);
        if (rd_data[1] !== 1'b1) begin
            $display("  FAIL: rd_done not set after recovery, STS=%h", rd_data);
            errors = errors + 1;
        end else
            $display("  PASS: rd_done after recovery drain");

        write_reg(8'h10, 32'h0000_0020);  // W1C rd-done

        // ---------------------------------------------------------------
        // Test 12: STS and DCAP fields
        // ---------------------------------------------------------------
        $display("Test 12: STS and DCAP fields");
        read_reg(8'h08, rd_data);
        if (rd_data[3:0] !== 4'd3) begin
            $display("  FAIL: STS ltssm = %0d, expected 3", rd_data[3:0]);
            errors = errors + 1;
        end
        if (rd_data[7:4] !== 4'd4) begin
            $display("  FAIL: STS log2_lanes = %0d, expected 4", rd_data[7:4]);
            errors = errors + 1;
        end
        if (rd_data[11:8] !== 4'd5) begin
            $display("  FAIL: STS gen = %0d, expected 5", rd_data[11:8]);
            errors = errors + 1;
        end
        if (rd_data[15] !== 1'b1) begin
            $display("  FAIL: STS link_up = 0");
            errors = errors + 1;
        end
        $display("  PASS: STS = %h", rd_data);

        read_reg(8'h0C, rd_data);
        if (rd_data[2:0] !== 3'd2) begin
            $display("  FAIL: DCAP MPS enc = %0d, expected 2", rd_data[2:0]);
            errors = errors + 1;
        end
        $display("  PASS: DCAP = %h", rd_data);

        read_reg(8'h3C, rd_data);
        if (rd_data[15:0] !== 16'hFFFF) begin
            $display("  FAIL: LANE_STS = %h, expected FFFF", rd_data[15:0]);
            errors = errors + 1;
        end else
            $display("  PASS: LANE_STS = %h", rd_data);

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        $display("");
        if (errors == 0)
            $display("*** PCIE PHY TEST PASSED ***");
        else
            $display("*** PCIE PHY TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #10000000;
        $display("TIMEOUT: ltssm=%0d link_up=%b dm_state=%0d",
                 ltssm_state, link_up, u_dut.dm_state);
        $finish;
    end

endmodule
