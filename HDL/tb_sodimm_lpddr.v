`timescale 1ns/1ps

// =============================================================================
// tb_sodimm_lpddr — Host/BMC DMA against SODIMM DDR4/DDR5 and CAMM2 LPDDR6
//
// Proves the memory-side modularity claim: the identical Pi -> pi_bridge ->
// pnm_arb -> DMA-engine protocol stack runs unchanged against three DRAM
// timing generations, selected at runtime by a 2-bit module mux:
//
//   sel  Profile        CAS_LATENCY  REFRESH_CYCLES  Notes
//   0    LPDDR6 CAMM2       4            1024         control (baseline)
//   1    DDR4 SODIMM       15             780         7.8 us avg refresh rate
//   2    DDR5 SODIMM       36             780         longer CAS, same tREFI
//
// Each iteration DMA-writes 4 words, verifies array contents and counters,
// then DMA-reads them back through the SPI FIFO.
//
// Expected: *** SODIMM LPDDR TEST PASSED ***
// =============================================================================

module tb_sodimm_lpddr;

    reg clk, rst_n;
    always #5 clk = ~clk;

    integer errors;

    reg sclk, mosi, cs_n;
    wire miso, irq_out;
    wire [7:0]  brg_addr;
    wire [31:0] brg_wdata, brg_rdata;
    wire        brg_we, brg_valid, brg_ready;
    wire [7:0]  slv_addr;
    wire [31:0] slv_wdata, slv_rdata;
    wire        slv_we, slv_valid;
    reg         slv_ready;
    wire [31:0] cpu_rdata_w;
    wire        cpu_ready_w;

    // ------------------------------------------------------------------
    // Three memory modules with generation-specific timing
    // ------------------------------------------------------------------
    localparam N_MOD = 3;

    reg  [31:0] dma_addr;
    reg  [31:0] dma_wdata;
    wire [31:0] dma_rdata;
    reg         dma_we;
    reg         dma_valid;
    wire        dma_ready;
    wire        dma_rdv;
    wire        dma_resp;

    wire        sel_rdy   [0:N_MOD-1];
    wire        sel_rdv   [0:N_MOD-1];
    wire        sel_resp  [0:N_MOD-1];
    wire [31:0] sel_rdata [0:N_MOD-1];
    wire [31:0] mod_rd_cnt [0:N_MOD-1];
    wire [31:0] mod_wr_cnt [0:N_MOD-1];
    wire [31:0] mod_ref_cnt [0:N_MOD-1];

    reg  [1:0] mod_sel;

    assign dma_ready  = sel_rdy[mod_sel];
    assign dma_rdv    = sel_rdv[mod_sel];
    assign dma_resp   = sel_resp[mod_sel];
    assign dma_rdata  = sel_rdata[mod_sel];

    lpddr6_camm #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .MEM_DEPTH(4096),
                  .CAS_LATENCY(4), .REFRESH_CYCLES(1024), .MODULE_ID(8'h00))
    u_lpddr6 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(dma_addr), .bus_wdata(dma_wdata), .bus_rdata(sel_rdata[0]),
        .bus_we(dma_we), .bus_be(4'b1111),
        .bus_valid(dma_valid && mod_sel == 2'd0), .bus_ready(sel_rdy[0]),
        .bus_rdv(sel_rdv[0]), .bus_resp(sel_resp[0]),
        .dram_busy(), .dram_read_count(mod_rd_cnt[0]),
        .dram_write_count(mod_wr_cnt[0]), .dram_refresh_count(mod_ref_cnt[0]),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(),
        .topology_rdy()
    );

    lpddr6_camm #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .MEM_DEPTH(2048),
                  .CAS_LATENCY(15), .REFRESH_CYCLES(780), .MODULE_ID(8'h01))
    u_ddr4 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(dma_addr), .bus_wdata(dma_wdata), .bus_rdata(sel_rdata[1]),
        .bus_we(dma_we), .bus_be(4'b1111),
        .bus_valid(dma_valid && mod_sel == 2'd1), .bus_ready(sel_rdy[1]),
        .bus_rdv(sel_rdv[1]), .bus_resp(sel_resp[1]),
        .dram_busy(), .dram_read_count(mod_rd_cnt[1]),
        .dram_write_count(mod_wr_cnt[1]), .dram_refresh_count(mod_ref_cnt[1]),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(),
        .topology_rdy()
    );

    lpddr6_camm #(.ADDR_WIDTH(32), .DATA_WIDTH(32), .MEM_DEPTH(2048),
                  .CAS_LATENCY(36), .REFRESH_CYCLES(780), .MODULE_ID(8'h02))
    u_ddr5 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(dma_addr), .bus_wdata(dma_wdata), .bus_rdata(sel_rdata[2]),
        .bus_we(dma_we), .bus_be(4'b1111),
        .bus_valid(dma_valid && mod_sel == 2'd2), .bus_ready(sel_rdy[2]),
        .bus_rdv(sel_rdv[2]), .bus_resp(sel_resp[2]),
        .dram_busy(), .dram_read_count(mod_rd_cnt[2]),
        .dram_write_count(mod_wr_cnt[2]), .dram_refresh_count(mod_ref_cnt[2]),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(),
        .topology_rdy()
    );

    // ------------------------------------------------------------------
    // Register file + DMA engine (same as tb_dma_lpddr6)
    // ------------------------------------------------------------------
    localparam R_DMA_ADDR = 16, R_DMA_COUNT = 17, R_DMA_CTRL = 18,
               R_DMA_DATA = 19;

    reg [31:0] regs [0:19];
    reg [31:0] dma_buf [0:255];
    reg [7:0]  fifo_wr_pos, fifo_rd_pos;
    reg        dma_wr_active, dma_rd_active;

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
                default: dma_state <= D_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // SPI master model
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Per-generation test sequence
    // ------------------------------------------------------------------
    reg [31:0] resp;
    reg [7:0]  stat;
    integer g, k;
    reg [31:0] pat0, wr_expect, rd_expect;
    reg [31:0] base_addr;

    // word index 0x40..0x43 = byte address 0x100
    task check_mem;
        input integer m;
        input [31:0] w0;
        begin
            wr_expect = w0;
            if (m == 0) begin
                if (u_lpddr6.mem[32'h40] !== wr_expect ||
                    u_lpddr6.mem[32'h41] !== wr_expect + 32'h00010001 ||
                    u_lpddr6.mem[32'h42] !== wr_expect + 32'h00020002 ||
                    u_lpddr6.mem[32'h43] !== wr_expect + 32'h00030003) begin
                    $display("FAIL: gen%0d mem mismatch m0=%08h",
                             g, u_lpddr6.mem[32'h40]);
                    errors = errors + 1;
                end
            end else if (m == 1) begin
                if (u_ddr4.mem[32'h40] !== wr_expect ||
                    u_ddr4.mem[32'h41] !== wr_expect + 32'h00010001 ||
                    u_ddr4.mem[32'h42] !== wr_expect + 32'h00020002 ||
                    u_ddr4.mem[32'h43] !== wr_expect + 32'h00030003) begin
                    $display("FAIL: gen%0d mem mismatch", g);
                    errors = errors + 1;
                end
            end else begin
                if (u_ddr5.mem[32'h40] !== wr_expect ||
                    u_ddr5.mem[32'h41] !== wr_expect + 32'h00010001 ||
                    u_ddr5.mem[32'h42] !== wr_expect + 32'h00020002 ||
                    u_ddr5.mem[32'h43] !== wr_expect + 32'h00030003) begin
                    $display("FAIL: gen%0d mem mismatch", g);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0;
        sclk = 0; mosi = 0; cs_n = 1'b1;
        errors = 0; mod_sel = 2'd0;
        for (k = 0; k < 20; k = k + 1) regs[k] = 32'h0;
        for (k = 0; k < 256; k = k + 1) dma_buf[k] = 32'h0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        for (g = 0; g < N_MOD; g = g + 1) begin
            mod_sel = g[1:0];
            pat0 = 32'hD0000000 + g;
            base_addr = 32'h00000100;
            fifo_wr_pos = 8'h0;
            regs[R_DMA_CTRL] = 32'h0;

            $display("--- Gen %0d (sel=%0d): load payload ---", g, g);
            spi_frame(1'b0, 7'd19, pat0,              resp, stat);
            spi_frame(1'b0, 7'd19, pat0 + 32'h00010001, resp, stat);
            spi_frame(1'b0, 7'd19, pat0 + 32'h00020002, resp, stat);
            spi_frame(1'b0, 7'd19, pat0 + 32'h00030003, resp, stat);

            $display("--- Gen %0d: DMA write ---", g);
            spi_frame(1'b0, 7'd16, base_addr, resp, stat);
            spi_frame(1'b0, 7'd17, 32'h00000004, resp, stat);
            spi_frame(1'b0, 7'd18, 32'h00000001, resp, stat);
            k = 0;
            while (regs[R_DMA_CTRL][2] !== 1'b1 && k < 20000) begin
                #1000; k = k + 1;
            end
            if (regs[R_DMA_CTRL][2] !== 1'b1 || mod_wr_cnt[g] !== 32'd4) begin
                $display("FAIL: gen%0d write done=%b wr_cnt=%0d",
                         g, regs[R_DMA_CTRL][2], mod_wr_cnt[g]);
                errors = errors + 1;
            end else $display("  OK: 4 words written");

            check_mem(g, pat0);

            $display("--- Gen %0d: DMA read back ---", g);
            spi_frame(1'b0, 7'd18, 32'h00000000, resp, stat);
            spi_frame(1'b0, 7'd16, base_addr, resp, stat);
            spi_frame(1'b0, 7'd17, 32'h00000004, resp, stat);
            spi_frame(1'b0, 7'd18, 32'h00000002, resp, stat);
            k = 0;
            while (regs[R_DMA_CTRL][2] !== 1'b1 && k < 20000) begin
                #1000; k = k + 1;
            end
            if (regs[R_DMA_CTRL][2] !== 1'b1 || mod_rd_cnt[g] !== 32'd4) begin
                $display("FAIL: gen%0d read done=%b rd_cnt=%0d",
                         g, regs[R_DMA_CTRL][2], mod_rd_cnt[g]);
                errors = errors + 1;
            end

            spi_frame(1'b1, 7'd19, 32'h0, resp, stat);
            rd_expect = pat0;
            if (resp !== rd_expect) begin
                $display("FAIL: gen%0d rb w0=%08h exp=%08h", g, resp, rd_expect);
                errors = errors + 1;
            end else $display("  OK: readback w0=%08h", resp);
        end

        $display("--- Stats: LPDDR6(refs=%0d) DDR4(refs=%0d) DDR5(refs=%0d) ---",
                 mod_ref_cnt[0], mod_ref_cnt[1], mod_ref_cnt[2]);
        if (errors == 0)
            $display("*** SODIMM LPDDR TEST PASSED ***");
        else
            $display("*** SODIMM LPDDR TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
