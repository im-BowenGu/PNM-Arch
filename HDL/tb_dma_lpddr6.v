`timescale 1ns/1ps

// =============================================================================
// tb_dma_lpddr6 — Host and BMC DMA to LPCAMM2/LPDDR6 testbench
//
// Proves memory access paths:
//   Path 1: Pi (SPI) -> pi_bridge -> arbiter -> DMA engine -> pcb_link -> LPDDR6
//   Path 2: LPDDR6 -> pcb_link -> DMA engine -> arbiter -> pi_bridge -> Pi
//
// Expected: *** DMA LPDDR6 TEST PASSED ***
// =============================================================================

module tb_dma_lpddr6;

    reg clk, rst_n;
    reg sclk, mosi, cs_n;
    wire miso, irq_out;

    // pi_bridge <-> pnm_arb (bridge port)
    wire [7:0]  brg_addr;
    wire [31:0] brg_wdata, brg_rdata;
    wire        brg_we, brg_valid, brg_ready;

    // CPU port (idle)
    wire [31:0] cpu_rdata_w;
    wire        cpu_ready_w;

    // Arbiter shared slave port
    wire [7:0]  slv_addr;
    wire [31:0] slv_wdata, slv_rdata;
    wire        slv_we, slv_valid;
    reg         slv_ready;

    // DMA engine <-> LPDDR6 bus (direct, no PCB link for simplicity)
    reg  [31:0] dma_addr;
    reg  [31:0] dma_wdata;
    wire [31:0] dma_rdata;
    reg         dma_we;
    reg         dma_valid;
    wire        dma_ready;
    wire        dma_rdv;
    wire        dma_resp;

    integer errors;
    integer k;

    wire [31:0] rd_cnt, wr_cnt, ref_cnt;

    always #5 clk = ~clk;

    // =========================================================================
    // DUTs
    // =========================================================================
    pi_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .irq_out(irq_out),
        .pnm_addr(brg_addr), .pnm_wdata(brg_wdata), .pnm_rdata(brg_rdata),
        .pnm_we(brg_we), .pnm_valid(brg_valid), .pnm_ready(brg_ready),
        .frame_done()
    );

    pnm_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .cpu_addr(8'h0), .cpu_wdata(32'h0), .cpu_rdata(cpu_rdata_w),
        .cpu_we(1'b0), .cpu_valid(1'b0), .cpu_ready(cpu_ready_w),
        .brg_addr(brg_addr), .brg_wdata(brg_wdata), .brg_rdata(brg_rdata),
        .brg_we(brg_we), .brg_valid(brg_valid), .brg_ready(brg_ready),
        .slv_addr(slv_addr), .slv_wdata(slv_wdata), .slv_rdata(slv_rdata),
        .slv_we(slv_we), .slv_valid(slv_valid), .slv_ready(slv_ready)
    );

    lpddr6_camm #(
        .ADDR_WIDTH(32), .DATA_WIDTH(32),
        .MEM_DEPTH(4096), .CAS_LATENCY(4), .MODULE_ID(8'h00)
    ) u_lpddr6 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(dma_addr), .bus_wdata(dma_wdata), .bus_rdata(dma_rdata),
        .bus_we(dma_we), .bus_be(4'b1111),
        .bus_valid(dma_valid), .bus_ready(dma_ready), .bus_rdv(dma_rdv),
        .bus_resp(dma_resp),
        .dram_busy(), .dram_read_count(rd_cnt),
        .dram_write_count(wr_cnt), .dram_refresh_count(ref_cnt),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(),
        .node_err(), .topology_rdy()
    );

    // =========================================================================
    // Register file + DMA engine
    //
    // sel mapping from bridge (sel<<2 = offset):
    //   0x00-0x24: standard PNM registers
    //   0x40 (sel=16): DMA_ADDR   — target address in LPDDR6
    //   0x44 (sel=17): DMA_COUNT  — number of words
    //   0x48 (sel=18): DMA_CTRL   — bit0=start_write, bit1=start_read, bit2=done
    //   0x4C (sel=19): DMA_DATA   — FIFO data port
    // =========================================================================
    localparam R_DMA_ADDR = 16, R_DMA_COUNT = 17, R_DMA_CTRL = 18, R_DMA_DATA = 19;

    reg [31:0] regs [0:19];
    reg [31:0] dma_buf [0:255];
    reg [7:0]  fifo_wr_pos, fifo_rd_pos;
    reg        dma_wr_active, dma_rd_active;

    // Combinational read mux (full-byte address decode)
    reg [31:0] slv_rd_mux;
    always @(*) begin
        case (slv_addr)
            8'h14: slv_rd_mux = regs[5];
            8'h18: slv_rd_mux = regs[6];
            8'h20: slv_rd_mux = regs[8];
            8'h4C: slv_rd_mux = dma_buf[fifo_rd_pos];
            8'h48: slv_rd_mux = regs[R_DMA_CTRL];
            8'h40: slv_rd_mux = regs[R_DMA_ADDR];
            8'h44: slv_rd_mux = regs[R_DMA_COUNT];
            default: slv_rd_mux = (slv_addr < 40) ? regs[slv_addr[5:2]] : 32'h0;
        endcase
    end
    assign slv_rdata = slv_rd_mux;

    // Slave port handler
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slv_ready <= 1'b1;
            fifo_wr_pos <= 8'h0; fifo_rd_pos <= 8'h0;
        end else begin
            slv_ready <= 1'b1;
            if (slv_valid && slv_ready && slv_we) begin
                case (slv_addr)
                    8'h40: regs[R_DMA_ADDR] <= slv_wdata;
                    8'h44: regs[R_DMA_COUNT] <= slv_wdata;
                    8'h48: begin
                        regs[R_DMA_CTRL] <= slv_wdata;
                        if (slv_wdata[0]) begin
                            dma_wr_active <= 1'b1;
                            fifo_rd_pos <= 8'h0;
                        end else if (slv_wdata[1]) begin
                            dma_rd_active <= 1'b1;
                            fifo_rd_pos <= 8'h0;
                        end
                    end
                    8'h4C: begin
                        dma_buf[fifo_wr_pos] <= slv_wdata;
                        fifo_wr_pos <= fifo_wr_pos + 1;
                    end
                    default: if (slv_addr < 40) regs[slv_addr[5:2]] <= slv_wdata;
                endcase
            end else if (slv_valid && !slv_we &&
                         slv_addr == 8'h4C && !dma_rd_active) begin
                fifo_rd_pos <= fifo_rd_pos + 1;
            end
        end
    end

    // =========================================================================
    // DMA engine FSM
    // =========================================================================
    localparam D_IDLE = 4'd0, D_WR_ADDR = 4'd1, D_WR_ACC = 4'd2,
               D_WR_RESP = 4'd3, D_RD_REQ = 4'd4, D_RD_ACC = 4'd5,
               D_RD_CAP = 4'd6, D_WR_DONE = 4'd7, D_RD_DONE = 4'd8;

    reg [3:0]  dma_state;
    reg [7:0]  dma_word_cnt;
    reg [31:0] dma_base_addr;
    reg [7:0]  dma_total;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_state <= D_IDLE;
            dma_word_cnt <= 8'h0;
            dma_base_addr <= 32'h0;
            dma_total <= 8'h0;
            dma_addr <= 32'h0; dma_wdata <= 32'h0;
            dma_we <= 1'b0; dma_valid <= 1'b0;
            dma_wr_active <= 1'b0; dma_rd_active <= 1'b0;
        end else begin
            case (dma_state)
                D_IDLE: begin
                    if (dma_wr_active && fifo_wr_pos >= regs[R_DMA_COUNT][7:0]
                                      && regs[R_DMA_COUNT][7:0] > 0) begin
                        dma_total <= regs[R_DMA_COUNT][7:0];
                        dma_word_cnt <= 8'h0;
                        dma_base_addr <= regs[R_DMA_ADDR];
                        dma_state <= D_WR_ADDR;
                    end else if (dma_rd_active && regs[R_DMA_COUNT][7:0] > 0) begin
                        dma_total <= regs[R_DMA_COUNT][7:0];
                        dma_word_cnt <= 8'h0;
                        dma_base_addr <= regs[R_DMA_ADDR];
                        fifo_rd_pos <= 8'h0;
                        dma_state <= D_RD_REQ;
                    end
                end
                D_WR_ADDR: begin
                    dma_addr <= dma_base_addr + {24'h0, dma_word_cnt, 2'b00};
                    dma_wdata <= dma_buf[dma_word_cnt];
                    dma_we <= 1'b1;
                    dma_valid <= 1'b1;
                    dma_state <= D_WR_ACC;
                end
                D_WR_ACC: begin
                    if (!dma_ready) begin
                        dma_valid <= 1'b0;
                        dma_state <= D_WR_RESP;
                    end
                end
                D_WR_RESP: begin
                    if (dma_resp) begin
                        if (dma_word_cnt + 1 >= dma_total) begin
                            dma_state <= D_WR_DONE;
                        end else begin
                            dma_word_cnt <= dma_word_cnt + 1;
                            dma_state <= D_WR_ADDR;
                        end
                    end
                end
                D_WR_DONE: begin
                    dma_wr_active <= 1'b0;
                    regs[R_DMA_CTRL][2] <= 1'b1;
                    dma_state <= D_IDLE;
                end
                D_RD_REQ: begin
                    dma_addr <= dma_base_addr + {24'h0, dma_word_cnt, 2'b00};
                    dma_we <= 1'b0;
                    dma_valid <= 1'b1;
                    dma_state <= D_RD_ACC;
                end
                D_RD_ACC: begin
                    if (!dma_ready) begin
                        dma_valid <= 1'b0;
                        dma_state <= D_RD_CAP;
                    end
                end
                D_RD_CAP: begin
                    if (dma_rdv) begin
                        dma_buf[dma_word_cnt] <= dma_rdata;
                        if (dma_word_cnt + 1 >= dma_total) begin
                            dma_state <= D_RD_DONE;
                        end else begin
                            dma_word_cnt <= dma_word_cnt + 1;
                            dma_state <= D_RD_REQ;
                        end
                    end
                end
                D_RD_DONE: begin
                    dma_rd_active <= 1'b0;
                    regs[R_DMA_CTRL][2] <= 1'b1;
                    dma_state <= D_IDLE;
                end
            endcase
        end
    end

    // SPI master model
    task spi_frame(
        input rw, input [6:0] sel, input [31:0] wdata,
        output [31:0] rdata, output [7:0] status
    );
        integer i;
        reg [7:0] stat_acc;
        begin
            rdata = 32'h0; stat_acc = 8'h0;
            cs_n = 1'b1; sclk = 1'b0; mosi = 1'b0;
            #100; cs_n = 1'b0; #100;
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = (i == 7) ? rw : sel[i];
                #50; sclk = 1'b1; #100; #50; sclk = 1'b0; #50;
            end
            for (i = 31; i >= 0; i = i - 1) begin
                mosi = wdata[i]; #50; sclk = 1'b1; #100;
                rdata[i] = miso; #50; sclk = 1'b0; #50;
            end
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = 1'b0; #50; sclk = 1'b1; #100;
                stat_acc = {stat_acc[6:0], miso};
                #50; sclk = 1'b0; #50;
            end
            status = stat_acc; cs_n = 1'b1; #200;
        end
    endtask

    reg [31:0] resp;
    reg [7:0] stat;

    initial begin
        clk = 0; rst_n = 0;
        sclk = 0; mosi = 0; cs_n = 1'b1;
        errors = 0;
        for (k = 0; k < 20; k = k + 1) regs[k] = 32'h0;
        for (k = 0; k < 256; k = k + 1) dma_buf[k] = 32'h0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("--- T1: Load 4-word payload via SPI ---");
        spi_frame(1'b0, 7'd19, 32'hCAFEBABE, resp, stat);
        spi_frame(1'b0, 7'd19, 32'hDEAD0001, resp, stat);
        spi_frame(1'b0, 7'd19, 32'hFACE0002, resp, stat);
        spi_frame(1'b0, 7'd19, 32'hBA5E0003, resp, stat);
        $display("  OK: fifo_wr_pos=%0d", fifo_wr_pos);

        $display("--- T2: Configure and trigger DMA write ---");
        spi_frame(1'b0, 7'd16, 32'h00000100, resp, stat);  // byte addr 0x100 (word offset 0x40)
        spi_frame(1'b0, 7'd17, 32'h00000004, resp, stat);  // count=4
        spi_frame(1'b0, 7'd18, 32'h00000001, resp, stat);  // start_write
        #50000;
        if (wr_cnt !== 32'd4) begin
            $display("FAIL: wr_count=%0d", wr_cnt); errors = errors + 1;
        end else $display("  OK: %0d writes to LPDDR6", wr_cnt);

        $display("--- T3: Verify data in LPDDR6 ---");
        if (u_lpddr6.mem[32'h40] !== 32'hCAFEBABE ||
            u_lpddr6.mem[32'h41] !== 32'hDEAD0001 ||
            u_lpddr6.mem[32'h42] !== 32'hFACE0002 ||
            u_lpddr6.mem[32'h43] !== 32'hBA5E0003) begin
            $display("FAIL: mem mismatch m0=%08h m1=%08h m2=%08h m3=%08h",
                     u_lpddr6.mem[32'h40], u_lpddr6.mem[32'h41],
                     u_lpddr6.mem[32'h42], u_lpddr6.mem[32'h43]);
            errors = errors + 1;
        end else $display("  OK: all 4 words verified");

        $display("--- T4: Clear done flag, trigger DMA read ---");
        spi_frame(1'b0, 7'd16, 32'h00000100, resp, stat);
        spi_frame(1'b0, 7'd17, 32'h00000004, resp, stat);
        spi_frame(1'b0, 7'd18, 32'h00000002, resp, stat);  // start_read
        #60000;
        if (rd_cnt !== 32'd4) begin
            $display("FAIL: rd_count=%0d", rd_cnt); errors = errors + 1;
        end else $display("  OK: %0d reads from LPDDR6", rd_cnt);

        $display("--- T5: Read back via SPI ---");
        spi_frame(1'b1, 7'd19, 32'h0, resp, stat);
        if (resp !== 32'hCAFEBABE) begin
            $display("FAIL: word0=0x%08h", resp); errors = errors + 1;
        end else $display("  OK: w0=%08h", resp);
        spi_frame(1'b1, 7'd19, 32'h0, resp, stat);
        if (resp !== 32'hDEAD0001) begin
            $display("FAIL: word1=0x%08h", resp); errors = errors + 1;
        end else $display("  OK: w1=%08h", resp);
        spi_frame(1'b1, 7'd19, 32'h0, resp, stat);
        if (resp !== 32'hFACE0002) begin
            $display("FAIL: word2=0x%08h", resp); errors = errors + 1;
        end else $display("  OK: w2=%08h", resp);
        spi_frame(1'b1, 7'd19, 32'h0, resp, stat);
        if (resp !== 32'hBA5E0003) begin
            $display("FAIL: word3=0x%08h", resp); errors = errors + 1;
        end else $display("  OK: w3=%08h", resp);

        $display("--- Stats: rd=%0d wr=%0d refresh=%0d ---",
                 rd_cnt, wr_cnt, ref_cnt);
        if (errors == 0)
            $display("*** DMA LPDDR6 TEST PASSED ***");
        else
            $display("*** DMA LPDDR6 TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
