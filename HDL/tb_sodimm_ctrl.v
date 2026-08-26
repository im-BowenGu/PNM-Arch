`timescale 1ns/1ps

module tb_sodimm_ctrl;

    reg clk;
    reg rst_n;

    reg         tb_valid;
    reg         tb_we;
    reg [31:0]  tb_addr;
    reg [31:0]  tb_wdata;
    reg [3:0]   tb_be;

    integer     sel;

    wire [31:0] rdata0, rdata1, rdata2;
    wire        ready0, ready1, ready2;
    wire        rdv0, rdv1, rdv2;
    wire        resp0, resp1, resp2;
    wire [31:0] rd0, wr0, rf0;
    wire [31:0] rd1, wr1, rf1;
    wire [31:0] rd2, wr2, rf2;
    wire        busy0, busy1, busy2;

    wire cur_ready = (sel == 0) ? ready0 :
                     (sel == 1) ? ready1 : ready2;
    wire [31:0] cur_rdata = (sel == 0) ? rdata0 :
                            (sel == 1) ? rdata1 : rdata2;
    wire cur_resp = (sel == 0) ? resp0 :
                    (sel == 1) ? resp1 : resp2;

    reg rq_sh, rsp_sh;
    always @(negedge clk) begin
        rq_sh  = cur_ready;
        rsp_sh = cur_resp;
    end

    sodimm_ctrl #(
        .CAS_LATENCY(15), .T_RCD(15), .T_RP(15), .T_RAS(38),
        .T_RFC(64), .REFRESH_CYCLES(1024), .REFRESH_BURST(8)
    ) u_ddr4 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(tb_addr), .bus_wdata(tb_wdata), .bus_rdata(rdata0),
        .bus_we(tb_we), .bus_be(tb_be),
        .bus_valid(tb_valid && sel == 0),
        .bus_ready(ready0), .bus_rdv(rdv0), .bus_resp(resp0),
        .dram_busy(busy0),
        .dram_read_count(rd0), .dram_write_count(wr0), .dram_refresh_count(rf0),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(), .topology_rdy()
    );

    sodimm_ctrl #(
        .CAS_LATENCY(36), .T_RCD(36), .T_RP(36), .T_RAS(44),
        .T_RFC(96), .REFRESH_CYCLES(780), .REFRESH_BURST(8)
    ) u_ddr5 (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(tb_addr), .bus_wdata(tb_wdata), .bus_rdata(rdata1),
        .bus_we(tb_we), .bus_be(tb_be),
        .bus_valid(tb_valid && sel == 1),
        .bus_ready(ready1), .bus_rdv(rdv1), .bus_resp(resp1),
        .dram_busy(busy1),
        .dram_read_count(rd1), .dram_write_count(wr1), .dram_refresh_count(rf1),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(), .topology_rdy()
    );

    sodimm_ctrl #(
        .CAS_LATENCY(6), .T_RCD(6), .T_RP(6), .T_RAS(14),
        .T_RFC(16), .REFRESH_CYCLES(150), .REFRESH_BURST(25)
    ) u_ref (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(tb_addr), .bus_wdata(tb_wdata), .bus_rdata(rdata2),
        .bus_we(tb_we), .bus_be(tb_be),
        .bus_valid(tb_valid && sel == 2),
        .bus_ready(ready2), .bus_rdv(rdv2), .bus_resp(resp2),
        .dram_busy(busy2),
        .dram_read_count(rd2), .dram_write_count(wr2), .dram_refresh_count(rf2),
        .doorbell_trig_in(1'b0), .doorbell_ack_out(), .node_err(), .topology_rdy()
    );

    always #5 clk = ~clk;

    integer errors;
    integer lat;
    integer i;
    integer m_cold, m_hit, m_conf, m_immconf, m_ddr4, m_ddr5;
    integer stall_ref;
    reg     ref_pend_sh;

    always @(negedge clk) ref_pend_sh = u_ref.refresh_pending;
    always @(posedge clk)
        if (rst_n && ref_pend_sh)
            stall_ref = stall_ref + 1;

    task do_reset;
        begin
            rst_n    = 1'b0;
            tb_valid = 1'b0;
            tb_we    = 1'b0;
            tb_be    = 4'h0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task nopspin;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    task bus_op;
        input         wb;
        input  [31:0] a;
        input  [31:0] d;
        input  [3:0]  bm;
        integer n;
        reg     acc;
        begin
            begin : op_loop
                @(negedge clk);
                tb_addr  = a;
                tb_wdata = d;
                tb_we    = wb;
                tb_be    = bm;
                tb_valid = 1'b1;
                acc = 1'b0;
                n = 0;
                @(posedge clk);
                if (rq_sh) begin
                    acc = 1'b1;
                    tb_valid = 1'b0;
                end
                forever begin
                    @(posedge clk);
                    if (!acc) begin
                        if (rq_sh) begin
                            acc = 1'b1;
                            n   = 0;
                            tb_valid = 1'b0;
                        end
                    end else begin
                        if (rsp_sh)
                            disable op_loop;
                        n = n + 1;
                    end
                end
            end
            lat = n;
            @(negedge clk);
        end
    endtask

    task bus_wr;
        input [31:0] a;
        input [31:0] d;
        begin
            bus_op(1'b1, a, d, 4'hF);
        end
    endtask

    task bus_rd;
        input [31:0] a;
        begin
            bus_op(1'b0, a, 32'h0, 4'hF);
        end
    endtask

    task chk32;
        input [31:0] got;
        input [31:0] exp;
        input [127:0] tag;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got %08x expected %08x", tag, got, exp);
            end
        end
    endtask

    task chk_lat;
        input integer got;
        input integer exp;
        input [127:0] tag;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: lat %0d expected %0d", tag, got, exp);
            end
        end
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        sel       = 0;
        errors    = 0;
        stall_ref = 0;
        lat       = 0;

        do_reset();

        // ------------------------------------------------------------------
        // T1: row miss / row hit / row conflict latency on the DDR4-like unit
        // ------------------------------------------------------------------
        sel = 0;
        bus_rd(32'h0000_0000);                       // cold: closed bank -> RCD+CL
        m_cold = lat;
        chk_lat(m_cold, 32, "t1.cold");
        bus_rd(32'h0000_0000);                       // open-page hit -> CL only
        m_hit = lat;
        chk_lat(m_hit, 16, "t1.hit");
        chk_lat(m_cold - m_hit, 16, "t1.delta_rcd");
        nopspin(60);
        bus_rd(32'h0000_0400);                       // same bank, different row
        m_conf = lat;
        chk_lat(m_conf, 48, "t1.conflict");          // RP+RCD+CL+pipe
        bus_rd(32'h0000_0800);                       // conflict with tRAS still counting
        m_immconf = lat;
        i = m_immconf - 48;
        if (i < 2 || i > 37) begin
            errors = errors + 1;
            $display("FAIL t1.ras_wait out of range: %0d (imm=%0d)", i, m_immconf);
        end else
            $display("t1 ras_wait = %0d cycles (immconf %0d)", i, m_immconf);
        bus_rd(32'h0000_0800);                       // newly opened row hits
        chk_lat(lat, 16, "t1.hit2");
        $display("T1 latencies: cold=%0d hit=%0d conflict=%0d", m_cold, m_hit, m_conf);

        // ------------------------------------------------------------------
        // T2: write/readback integrity + partial byte-enable on DDR4-like unit
        // ------------------------------------------------------------------
        for (i = 0; i < 64; i = i + 1)
            bus_wr(32'h0000_1000 + 4*i, i * 32'h9E3779B9 + 32'h51ED270B);
        for (i = 0; i < 64; i = i + 1) begin
            bus_rd(32'h0000_1000 + 4*i);
            chk32(cur_rdata, i * 32'h9E3779B9 + 32'h51ED270B, "t2.roundtrip");
        end
        bus_wr(32'h0000_1400, 32'hDEADBEEF);
        bus_op(1'b1, 32'h0000_1400, 32'h11111111, 4'b0101);
        bus_rd(32'h0000_1400);
        chk32(cur_rdata, 32'hDE11BE11, "t2.byte_enable");

        // ------------------------------------------------------------------
        // T3: refresh storm on the short-interval unit: no corruption,
        //     refresh counter advances, stall cycles observed
        // ------------------------------------------------------------------
        sel = 2;
        do_reset();
        nopspin(220);
        for (i = 0; i < 40; i = i + 1)
            bus_wr(32'h0000_2000 + 4*i, 32'hA5000000 + 3*i + 7);
        for (i = 0; i < 40; i = i + 1) begin
            bus_rd(32'h0000_2000 + 4*i);
            chk32(cur_rdata, 32'hA5000000 + 3*i + 7, "t3.refresh_data");
        end
        if (rf2 < 4) begin
            errors = errors + 1;
            $display("FAIL t3.refresh_count too low: %0d (t=%0t rcnt=%0d pend=%b)",
                     rf2, $time, u_ref.refresh_cnt, u_ref.refresh_pending);
        end
        if (stall_ref == 0) begin
            errors = errors + 1;
            $display("FAIL t3.no refresh stalls observed");
        end
        $display("T3 refreshes=%0d stall_cycles=%0d", rf2, stall_ref);

        // ------------------------------------------------------------------
        // T4: identical traffic through DDR4-like vs DDR5-like units
        // ------------------------------------------------------------------
        sel = 0;
        bus_rd(32'h0000_3000);
        m_ddr4 = lat;
        for (i = 0; i < 16; i = i + 1)
            bus_wr(32'h0000_3100 + 4*i, 32'h0BADF00D + i);
        for (i = 0; i < 16; i = i + 1) begin
            bus_rd(32'h0000_3100 + 4*i);
            chk32(cur_rdata, 32'h0BADF00D + i, "t4.ddr4_data");
        end
        sel = 1;
        bus_rd(32'h0000_3000);
        m_ddr5 = lat;
        for (i = 0; i < 16; i = i + 1)
            bus_wr(32'h0000_3100 + 4*i, 32'h0BADF00D + i);
        for (i = 0; i < 16; i = i + 1) begin
            bus_rd(32'h0000_3100 + 4*i);
            chk32(cur_rdata, 32'h0BADF00D + i, "t4.ddr5_data");
        end
        chk_lat(m_ddr4, 32, "t4.ddr4_cold");
        chk_lat(m_ddr5, 74, "t4.ddr5_cold");
        $display("T4 cold-miss latency: ddr4=%0d ddr5=%0d", m_ddr4, m_ddr5);

        // ------------------------------------------------------------------
        $display("ddr4 counts: rd=%0d wr=%0d ref=%0d", rd0, wr0, rf0);
        $display("ddr5 counts: rd=%0d wr=%0d ref=%0d", rd1, wr1, rf1);
        if (errors == 0)
            $display("*** SODIMM CTRL TEST PASSED ***");
        else
            $display("*** SODIMM CTRL TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin
        #6_000_000;
        $display("*** SODIMM CTRL TEST FAILED (timeout) ***");
        $finish;
    end

endmodule
