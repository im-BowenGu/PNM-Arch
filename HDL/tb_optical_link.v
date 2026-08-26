`timescale 1ns/1ps

module tb_optical_link;

    reg clk;
    reg clk_a;
    reg clk_b;
    reg rst_n;

    integer errors;

    localparam TOTAL_NS    = 1 + (2 * 49) / 10 + 1;
    localparam PROP_CYCLES = (TOTAL_NS + 9) / 10;
    localparam EXPECT_LAT  = PROP_CYCLES + 5;

    reg         s_txv;
    reg [31:0]  s_txd;
    reg         s_txs, s_txe;
    wire        s_txr;
    wire [31:0] s_rxd;
    wire        s_rxv, s_rxs, s_rxe;
    wire        s_ovf;
    wire [31:0] s_twc, s_rwc, s_tpc, s_rpc;

    optical_link #(
        .WIDTH(32), .FIBER_M(2), .E_O_NS(1), .O_E_NS(1),
        .FIFO_DEPTH(16), .NAME("sync")
    ) u_sync (
        .wr_clk(clk), .rd_clk(clk), .rst_n(rst_n),
        .tx_data(s_txd), .tx_valid(s_txv),
        .tx_sop(s_txs), .tx_eop(s_txe), .tx_ready(s_txr),
        .rx_data(s_rxd), .rx_valid(s_rxv),
        .rx_sop(s_rxs), .rx_eop(s_rxe),
        .overflow_err(s_ovf),
        .tx_word_count(s_twc), .rx_word_count(s_rwc),
        .tx_packet_count(s_tpc), .rx_packet_count(s_rpc)
    );

    reg [31:0] m_data [0:4095];
    reg        m_sop  [0:4095];
    reg        m_eop  [0:4095];
    integer    m_n;

    always @(posedge clk) begin
        if (rst_n && s_rxv) begin
            m_data[m_n] = s_rxd;
            m_sop[m_n]  = s_rxs;
            m_eop[m_n]  = s_rxe;
            m_n = m_n + 1;
        end
    end

    reg         a_txv;
    reg [31:0]  a_txd;
    reg         a_txs, a_txe;
    wire        a_txr;
    wire [31:0] a_rxd;
    wire        a_rxv;
    wire        a_ovf;
    wire [31:0] a_twc, a_rwc;

    optical_link #(
        .WIDTH(32), .FIBER_M(2), .E_O_NS(1), .O_E_NS(1),
        .FIFO_DEPTH(16), .NAME("async")
    ) u_async (
        .wr_clk(clk_a), .rd_clk(clk_b), .rst_n(rst_n),
        .tx_data(a_txd), .tx_valid(a_txv),
        .tx_sop(a_txs), .tx_eop(a_txe), .tx_ready(a_txr),
        .rx_data(a_rxd), .rx_valid(a_rxv),
        .rx_sop(), .rx_eop(),
        .overflow_err(a_ovf),
        .tx_word_count(a_twc), .rx_word_count(a_rwc),
        .tx_packet_count(), .rx_packet_count()
    );

    reg [31:0] am_data [0:1023];
    integer    am_n;

    always @(posedge clk_b) begin
        if (rst_n && a_rxv) begin
            am_data[am_n] = a_rxd;
            am_n = am_n + 1;
        end
    end

    reg         p_av, p_bv;
    reg [31:0]  p_ad, p_bd;
    reg         p_as, p_ae, p_bs, p_be;
    wire        p_ar, p_br;
    wire [31:0] p_ard, p_brd;
    wire        p_arxv, p_brxv;
    wire [31:0] p_total;

    optical_pair #(
        .WIDTH(32), .FIBER_M(2), .E_O_NS(1), .O_E_NS(1), .FIFO_DEPTH(16)
    ) u_pair (
        .clk_a(clk_a), .clk_b(clk_b), .rst_n(rst_n),
        .a_tx_data(p_ad), .a_tx_valid(p_av),
        .a_tx_sop(p_as), .a_tx_eop(p_ae), .a_tx_ready(p_ar),
        .a_rx_data(p_ard), .a_rx_valid(p_arxv),
        .a_rx_sop(), .a_rx_eop(),
        .b_tx_data(p_bd), .b_tx_valid(p_bv),
        .b_tx_sop(p_bs), .b_tx_eop(p_be), .b_tx_ready(p_br),
        .b_rx_data(p_brd), .b_rx_valid(p_brxv),
        .b_rx_sop(), .b_rx_eop(),
        .total_packets(p_total)
    );

    reg [31:0] pm_data [0:511];
    integer    pm_n;

    always @(posedge clk_b) begin
        if (rst_n && p_brxv) begin
            pm_data[pm_n] = p_brd;
            pm_n = pm_n + 1;
        end
    end

    always #5    clk   = ~clk;
    always #5    clk_a = ~clk_a;
    always #6.25 clk_b = ~clk_b;

    integer lat;
    integer i;
    integer pj;
    integer accepted;
    integer flood_base;
    integer sparse_base;
    integer seen_rdrop;

    task do_reset;
        begin
            rst_n = 1'b0;
            s_txv = 1'b0; s_txd = 32'h0; s_txs = 1'b0; s_txe = 1'b0;
            a_txv = 1'b0; a_txd = 32'h0; a_txs = 1'b0; a_txe = 1'b0;
            p_av  = 1'b0; p_ad  = 32'h0; p_as  = 1'b0; p_ae  = 1'b0;
            p_bv  = 1'b0; p_bd  = 32'h0; p_bs  = 1'b0; p_be  = 1'b0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task send_words;
        input integer nwords;
        input [31:0]  base;
        integer k;
        begin
            for (k = 0; k < nwords; k = k + 1) begin
                @(negedge clk);
                while (!s_txr)
                    @(negedge clk);
                s_txd = base + k;
                s_txs = (k == 0);
                s_txe = (k == nwords - 1);
                s_txv = 1'b1;
                @(posedge clk);
                s_txv <= 1'b0;
            end
        end
    endtask

    task wait_for_rx;
        input integer nexpect;
        integer guard;
        begin
            guard = 0;
            while (m_n < nexpect && guard < 50000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (m_n < nexpect) begin
                errors = errors + 1;
                $display("FAIL timeout waiting for %0d words (got %0d)",
                         nexpect, m_n);
            end
        end
    endtask

    task chk;
        input         cond;
        input [255:0] tag;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s", tag);
            end
        end
    endtask

    initial begin
        clk     = 1'b0;
        clk_a   = 1'b0;
        clk_b   = 1'b0;
        rst_n   = 1'b0;
        errors  = 0;
        m_n     = 0;
        am_n    = 0;
        pm_n    = 0;
        lat     = 0;
        accepted = 0;

        do_reset();

        // ------------------------------------------------------------------
        // T1: exact latency on an idle link (sync FIFO + prop pipe)
        // ------------------------------------------------------------------
        @(negedge clk);
        s_txd = 32'h0000_00C3; s_txs = 1'b1; s_txe = 1'b1; s_txv = 1'b1;
        @(posedge clk);
        s_txv <= 1'b0;
        lat = 0;
        while (!s_rxv && lat < 100) begin
            @(posedge clk);
            lat = lat + 1;
        end
        if (!s_rxv) begin
            errors = errors + 1;
            $display("FAIL t1.no_rx");
        end else if (lat !== EXPECT_LAT) begin
            errors = errors + 1;
            $display("FAIL t1.latency: got %0d expected %0d", lat, EXPECT_LAT);
        end else
            $display("T1 latency = %0d cycles (prop=%0d)", lat, PROP_CYCLES);

        // ------------------------------------------------------------------
        // T2: 200-word burst, byte-exact scoreboard with SOP/EOP alignment
        // ------------------------------------------------------------------
        repeat (4) @(posedge clk);
        i = m_n;
        send_words(200, 32'h1A00_0000);
        wait_for_rx(i + 200);
        begin : t2_check
            integer b;
            b = i;
            for (i = 0; i < 200; i = i + 1) begin
                if (m_data[b + i] !== 32'h1A00_0000 + i) begin
                    errors = errors + 1;
                    $display("FAIL t2.data[%0d]: got %08x expected %08x",
                             i, m_data[b + i], 32'h1A00_0000 + i);
                end
                if (i == 0 && !m_sop[b + i]) begin
                    errors = errors + 1;
                    $display("FAIL t2.sop missing at word 0");
                end
                if (i == 199 && !m_eop[b + i]) begin
                    errors = errors + 1;
                    $display("FAIL t2.eop missing at word 199");
                end
                if (i > 0 && i < 199 && (m_sop[b + i] || m_eop[b + i])) begin
                    errors = errors + 1;
                    $display("FAIL t2.spurious sop/eop at %0d", i);
                end
            end
        end
        repeat (4) @(posedge clk);

        // ------------------------------------------------------------------
        // T3: back-to-back flood, verify zero loss and no overflow flag.
        // Same-clock drain keeps occupancy under READY_LIMIT, so ready
        // stays asserted here; the async unit (T4) demonstrates deassertion.
        // ------------------------------------------------------------------
        flood_base = m_n;
        accepted = 0;
        i = 0;
        @(negedge clk);
        while (s_txr && i < 600) begin
            s_txd = 32'h2B00_0000 + i;
            s_txs = (i == 0);
            s_txe = (i == 599);
            s_txv = 1'b1;
            @(posedge clk);
            accepted = accepted + 1;
            i = i + 1;
            @(negedge clk);
        end
        chk(!s_ovf, "t3.overflow_flag_set");
        s_txv <= 1'b0;
        s_txe <= 1'b0;
        wait_for_rx(flood_base + accepted);
        chk(s_rwc == s_twc, "t3.word_counter_mismatch");
        chk(m_n == flood_base + accepted, "t3.loss_or_duplication");
        chk(m_data[flood_base] === 32'h2B00_0000, "t3.first_word");
        chk(m_data[m_n - 1] === 32'h2B00_0000 + accepted - 1, "t3.last_word");
        $display("T3 flood: accepted=%0d received=%0d, zero loss",
                 accepted, s_rwc);
        $display("T2 burst: 200 words verified");

        // ------------------------------------------------------------------
        // T5: sparse packets separated by long idle gaps
        // ------------------------------------------------------------------
        sparse_base = m_n;
        send_words(4, 32'h3C00_0000);
        repeat (300) @(posedge clk);
        send_words(4, 32'h3D00_0000);
        repeat (300) @(posedge clk);
        send_words(4, 32'h3E00_0000);
        wait_for_rx(sparse_base + 12);
        chk(m_data[sparse_base]      === 32'h3C00_0000, "t5.p1_first");
        chk(m_data[sparse_base + 4]  === 32'h3D00_0000, "t5.p2_first");
        chk(m_data[sparse_base + 8]  === 32'h3E00_0000, "t5.p3_first");
        $display("T5 sparse: 3 gapped packets verified in order");

        // ------------------------------------------------------------------
        // T4: async CDC, 100 MHz write domain / 80 MHz read domain.
        // Fill outpaces drain, so tx_ready must deassert at least once.
        // ------------------------------------------------------------------
        seen_rdrop = 0;
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk_a);
            while (!a_txr) begin
                seen_rdrop = 1;
                @(negedge clk_a);
            end
            a_txd = 32'h4D00_0000 + i;
            a_txs = (i == 0);
            a_txe = (i == 99);
            a_txv = 1'b1;
            @(posedge clk_a);
            a_txv <= 1'b0;
        end
        chk(seen_rdrop, "t4.ready_never_dropped");
        i = 0;
        while (am_n < 100 && i < 50000) begin
            @(posedge clk_b);
            i = i + 1;
        end
        chk(am_n == 100, "t4.timeout");
        for (i = 0; i < 100; i = i + 1) begin
            if (am_data[i] !== 32'h4D00_0000 + i) begin
                errors = errors + 1;
                $display("FAIL t4.data[%0d]: got %08x expected %08x",
                         i, am_data[i], 32'h4D00_0000 + i);
            end
        end
        chk(!a_ovf, "t4.overflow");
        chk(a_rwc == a_twc, "t4.counter_mismatch");
        $display("T4 async CDC: 100 words across 100->80 MHz domains verified");

        // ------------------------------------------------------------------
        // Pair: simultaneous bidirectional traffic, each side driven in its
        // own clock domain
        // ------------------------------------------------------------------
        fork
            begin : pair_a_side
                for (i = 0; i < 16; i = i + 1) begin
                    @(negedge clk_a);
                    while (!p_ar)
                        @(negedge clk_a);
                    p_ad = 32'h5E00_0000 + i;
                    p_as = (i == 0);
                    p_ae = (i == 15);
                    p_av = 1'b1;
                    @(posedge clk_a);
                    p_av <= 1'b0;
                end
            end
            begin : pair_b_side
                for (pj = 0; pj < 16; pj = pj + 1) begin
                    @(negedge clk_b);
                    while (!p_br)
                        @(negedge clk_b);
                    p_bd = 32'h6F00_0000 + pj;
                    p_bs = (pj == 0);
                    p_be = (pj == 15);
                    p_bv = 1'b1;
                    @(posedge clk_b);
                    p_bv <= 1'b0;
                end
            end
        join
        i = 0;
        while (pm_n < 16 && i < 50000) begin
            @(posedge clk_b);
            i = i + 1;
        end
        chk(pm_n == 16, "pair.timeout");
        for (i = 0; i < 16; i = i + 1) begin
            if (pm_data[i] !== 32'h5E00_0000 + i) begin
                errors = errors + 1;
                $display("FAIL pair.data[%0d]: got %08x expected %08x",
                         i, pm_data[i], 32'h5E00_0000 + i);
            end
        end
        chk(p_total >= 2, "pair.total_packets_too_low");
        $display("Pair bidirectional: A->B 16 words verified, total_packets=%0d",
                 p_total);

        // ------------------------------------------------------------------
        if (errors == 0)
            $display("*** OPTICAL LINK TEST PASSED ***");
        else
            $display("*** OPTICAL LINK TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin
        #100_000;
        $display("*** OPTICAL LINK TEST FAILED (timeout) ***");
        $finish;
    end

endmodule
