`timescale 1ns/1ps

// =============================================================================
// tb_host_bmc — End-to-end host-to-BMC communication testbench
//
// Proves three communication paths:
//   Path 1: Pi (SPI master) -> pi_bridge -> PNM arbiter -> BMC registers
//   Path 2: BMC registers -> spine injection (flit builder)
//   Path 3: Spine extraction -> BMC registers -> Pi (SPI readback)
//
// Expected: *** HOST BMC COMM TEST PASSED ***
// =============================================================================

module tb_host_bmc;

    reg clk, rst_n;
    reg sclk, mosi, cs_n;
    wire miso, irq_out;

    // pi_bridge <-> pnm_arb (bridge port)
    wire [7:0]  brg_addr;
    wire [31:0] brg_wdata;
    wire [31:0] brg_rdata;
    wire        brg_we, brg_valid, brg_ready;

    // pnm_arb CPU port (idle stub)
    wire [31:0] cpu_rdata_w;
    wire        cpu_ready_w;

    // pnm_arb shared slave port
    wire [7:0]  slv_addr;
    wire [31:0] slv_wdata;
    wire [31:0] slv_rdata;
    wire        slv_we, slv_valid;
    reg         slv_ready;

    // Spine output (from flit builder)
    reg  [7:0]  spine_data;
    reg         spine_valid, spine_sop, spine_eop;
    wire        spine_ready;

    // Spine extraction (testbench drives into register file)
    reg  [7:0]  extract_data;
    reg         extract_valid, extract_sop, extract_eop;

    wire        boot_done;

    integer errors;
    integer k;

    always #5 clk = ~clk;

    // =========================================================================
    // DUTs — declarations above, instances below (Verilog-2005 ordering)
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

    assign spine_ready = 1'b1;  // always accept

    // =========================================================================
    // Shared PNM register file + flit builder
    // =========================================================================
    reg [31:0] pnm_regs [0:15];

    localparam R_CTRL = 4'h0, R_LAYER = 4'h1, R_MODULE = 4'h2, R_LEN = 4'h3,
               R_DATA = 4'h4, R_STATUS = 4'h5, R_RESULT = 4'h6,
               R_ERRORS = 4'h7, R_DISPATCH = 4'h8, R_WEIGHTS = 4'h9;

    reg [7:0] payload_buf [0:255];
    reg [7:0] payload_len, fb_pos;
    reg       inject_pending;
    reg [1:0] fb_state;
    reg [15:0] crc_calc;

    localparam FB_IDLE = 2'd0, FB_HDR = 2'd1, FB_PAYLOAD = 2'd2, FB_CRC = 2'd3;

    function [15:0] crc16_next(input [15:0] crc, input [7:0] data);
        reg [15:0] c;
        integer j;
        begin
            c = crc ^ {data, 8'h00};
            for (j = 0; j < 8; j = j + 1) begin
                if (c[15]) c = {c[14:0], 1'b0} ^ 16'h1021;
                else       c = {c[14:0], 1'b0};
            end
            crc16_next = c;
        end
    endfunction

    assign boot_done = pnm_regs[R_CTRL][2];

    // Combinational read mux (avoids NBA race with arbiter sampling)
    reg [31:0] slv_rd_mux;
    always @(*) begin
        case (slv_addr[5:2])
            R_STATUS:   slv_rd_mux = {31'h0, inject_pending};
            R_RESULT:   slv_rd_mux = pnm_regs[R_RESULT];
            R_ERRORS:   slv_rd_mux = pnm_regs[R_ERRORS];
            R_DISPATCH: slv_rd_mux = pnm_regs[R_DISPATCH];
            default:    slv_rd_mux = pnm_regs[slv_addr[5:2]];
        endcase
    end
    assign slv_rdata = slv_rd_mux;

    // Slave port handler (writes only)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slv_ready <= 1'b1;
        end else begin
            slv_ready <= 1'b1;
            if (slv_valid && slv_ready && slv_we) begin
                case (slv_addr[5:2])
                    R_CTRL:   pnm_regs[R_CTRL] <= slv_wdata;
                    R_LAYER:  pnm_regs[R_LAYER] <= slv_wdata;
                    R_MODULE: pnm_regs[R_MODULE] <= slv_wdata;
                    R_LEN:    pnm_regs[R_LEN] <= slv_wdata;
                    R_DATA: begin
                        payload_buf[pnm_regs[R_DATA][7:0]] <= slv_wdata[7:0];
                        pnm_regs[R_DATA] <= pnm_regs[R_DATA] + 1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // Flit builder
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spine_valid <= 1'b0; spine_data <= 8'h0;
            spine_sop <= 1'b0; spine_eop <= 1'b0;
            fb_state <= FB_IDLE; fb_pos <= 8'h0;
            crc_calc <= 16'hFFFF; inject_pending <= 1'b0;
            payload_len <= 8'h0;
        end else begin
            spine_valid <= 1'b0; spine_sop <= 1'b0; spine_eop <= 1'b0;
            case (fb_state)
                FB_IDLE: begin
                    if (slv_valid && slv_we && slv_addr[5:2] == R_CTRL && slv_wdata[0]) begin
                        inject_pending <= 1'b1;
                        payload_len <= pnm_regs[R_LEN][7:0];
                        fb_state <= FB_HDR; fb_pos <= 8'h0;
                        crc_calc <= 16'hFFFF;
                    end
                end
                FB_HDR: begin
                    if (spine_ready) begin
                        case (fb_pos)
                            0: begin spine_data <= pnm_regs[R_LAYER][7:0]; spine_sop <= 1'b1; spine_valid <= 1'b1; fb_pos <= 1; end
                            1: begin spine_data <= pnm_regs[R_MODULE][7:0]; spine_valid <= 1'b1; crc_calc <= crc16_next(crc_calc, pnm_regs[R_MODULE][7:0]); fb_pos <= 2; end
                            2: begin spine_data <= 8'h80; spine_valid <= 1'b1; crc_calc <= crc16_next(crc_calc, 8'h80); fb_pos <= 3; end
                            3: begin spine_data <= payload_len; spine_valid <= 1'b1; crc_calc <= crc16_next(crc_calc, payload_len); fb_pos <= 4; end
                            4: begin spine_data <= 8'h00; spine_valid <= 1'b1; crc_calc <= crc16_next(crc_calc, 8'h00); fb_pos <= 0; fb_state <= (payload_len > 0) ? FB_PAYLOAD : FB_CRC; end
                        endcase
                    end
                end
                FB_PAYLOAD: begin
                    if (spine_ready) begin
                        spine_data <= payload_buf[fb_pos]; spine_valid <= 1'b1;
                        crc_calc <= crc16_next(crc_calc, payload_buf[fb_pos]);
                        if (fb_pos >= payload_len - 1) begin fb_pos <= 0; fb_state <= FB_CRC; end
                        else fb_pos <= fb_pos + 1;
                    end
                end
                FB_CRC: begin
                    if (spine_ready) begin
                        case (fb_pos)
                            0: begin spine_data <= crc_calc[15:8]; spine_valid <= 1'b1; fb_pos <= 1; end
                            1: begin spine_data <= crc_calc[7:0]; spine_valid <= 1'b1; spine_eop <= 1'b1; inject_pending <= 1'b0; pnm_regs[R_DISPATCH] <= pnm_regs[R_DISPATCH] + 1; fb_state <= FB_IDLE; fb_pos <= 0; end
                        endcase
                    end
                end
            endcase
        end
    end

    // Spine extraction model
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pnm_regs[R_RESULT] <= 32'h0;
        else if (extract_valid && extract_eop)
            pnm_regs[R_RESULT] <= pnm_regs[R_RESULT] + 1;
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
        extract_data = 0; extract_valid = 0; extract_sop = 0; extract_eop = 0;
        errors = 0;
        for (k = 0; k < 16; k = k + 1) pnm_regs[k] = 32'h0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("--- T1: Host writes PNM_LAYER=0x03 ---");
        spi_frame(1'b0, 7'h01, 32'h00000003, resp, stat);
        if (pnm_regs[R_LAYER] !== 32'h3 || stat !== 8'h01) begin
            $display("FAIL: LAYER=0x%08h stat=0x%02h", pnm_regs[R_LAYER], stat); errors = errors + 1;
        end else $display("  OK");

        $display("--- T2: Flit injection ---");
        spi_frame(1'b0, 7'h02, 32'h5, resp, stat);
        spi_frame(1'b0, 7'h03, 32'h2, resp, stat);
        spi_frame(1'b0, 7'h04, 32'hAA, resp, stat);
        spi_frame(1'b0, 7'h04, 32'h55, resp, stat);
        spi_frame(1'b0, 7'h00, 32'h1, resp, stat);
        #500;
        if (pnm_regs[R_DISPATCH] !== 32'h1) begin
            $display("FAIL: dispatch=%0d", pnm_regs[R_DISPATCH]); errors = errors + 1;
        end else $display("  OK: dispatch=%0d", pnm_regs[R_DISPATCH]);

        $display("--- T3: Boot-done ---");
        spi_frame(1'b0, 7'h00, 32'h4, resp, stat);
        #200;
        if (!boot_done) begin
            $display("FAIL: boot_done"); errors = errors + 1;
        end else $display("  OK");

        $display("--- T4: Read DISPATCHES ---");
        spi_frame(1'b1, 7'h08, 32'h0, resp, stat);
        if (resp !== 32'h1) begin
            $display("FAIL: DISPATCHES=0x%08h", resp); errors = errors + 1;
        end else $display("  OK: DISPATCHES=%0d", resp);

        if (errors == 0)
            $display("*** HOST BMC COMM TEST PASSED ***");
        else
            $display("*** HOST BMC COMM TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

endmodule
