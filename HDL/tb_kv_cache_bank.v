`timescale 1ns/1ps
// Self-checking regression for kv_cache_bank.v (KV store/load + eviction).
//
// The bank is attached between the lxy_repeater NoB and the xy_turn: all
// KV commands ride the NoB as normal wormhole flits whose CTRL byte carries
// the opcode (OP_KV_STORE=0xA0, OP_KV_LOAD=0xB0 on vc class 2).
//
// Scenario A (eviction): fill bank 0 to full through the reclaim port, let
// the offload controller evict an entry (EVICTION_TARGET=0, discard), and
// require evict_done fires, occupancy decrements to DEPTH-1, and nothing is
// misrouted to the NoB.
//
// Scenario B (store+load round trip): CRC-valid KV_STORE of one 512-byte
// entry, then a CRC-valid KV_LOAD.  The response must be a complete compute
// flit  MODULE(echoed) | 0x80 | LEN_LO | LEN_HI | payload | CRC  whose CRC
// independently recomputes to the trailing CRC bytes, delivered byte-exact,
// with no spurious bytes before or after.
//
// Scenario C (corrupt store refused): a KV_STORE with a flipped payload byte
// (CRC mismatch) must be drained and discarded — occupancy unchanged, and
// the next load still serves the entry stored in scenario B.
//
// Scenario D (corrupt load refused): a KV_LOAD with a broken CRC must
// produce no response at all.
`timescale 1ns/1ps
module tb_kv_cache_bank;

    localparam DEPTH = 64;
    localparam ENTRY = 512;
    localparam ABITS = 6;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    integer errors = 0;

    // ---- kv_offload bank-0 (active) interface ----
    wire        kv_full_0;
    wire        kv_empty_0;
    wire [ABITS:0] kv_occ_0;
    wire [ABITS-1:0] kv_rp_0;
    wire        evict_req_0;
    wire [ABITS-1:0] evict_addr_0;
    wire        evict_done_0;
    wire [7:0]  evict_data_0;
    wire        evict_valid_0;
    wire        evict_ready_0;
    wire        reclaim_req_0;
    wire [7:0]  reclaim_data_0;
    wire        reclaim_valid_0;
    wire        reclaim_sop_0;
    wire        reclaim_eop_0;
    wire        reclaim_ready_0;

    // ---- unused banks 1..3 ----
    wire        evict_req_1, evict_req_2, evict_req_3;
    wire [ABITS-1:0] evict_addr_1, evict_addr_2, evict_addr_3;
    wire        evict_done_1, evict_done_2, evict_done_3;
    wire [7:0]  evict_data_1, evict_data_2, evict_data_3;
    wire        evict_valid_1, evict_valid_2, evict_valid_3;
    wire        evict_ready_1, evict_ready_2, evict_ready_3;
    wire        reclaim_req_1, reclaim_req_2, reclaim_req_3;
    wire [7:0]  reclaim_data_1, reclaim_data_2, reclaim_data_3;
    wire        reclaim_valid_1, reclaim_valid_2, reclaim_valid_3;
    wire        reclaim_sop_1, reclaim_sop_2, reclaim_sop_3;
    wire        reclaim_eop_1, reclaim_eop_2, reclaim_eop_3;
    wire        reclaim_ready_1, reclaim_ready_2, reclaim_ready_3;

    // ---- spine ----
    wire [7:0]  spine_out_data;
    wire        spine_out_valid, spine_out_sop, spine_out_eop;
    reg         spine_out_ready;
    reg  [7:0]  spine_in_data;
    reg         spine_in_valid, spine_in_sop, spine_in_eop;
    wire        spine_in_ready;
    wire [31:0] evictions, reloads, errs;

    kv_offload #(
        .NUM_LAYERS(1), .BANK_DEPTH(DEPTH), .ADDR_BITS(ABITS),
        .ENTRY_BYTES(ENTRY), .EVICTION_TARGET(0)
    ) u_offload (
        .clk(clk), .rst_n(rst_n),
        .kv_full_0(kv_full_0), .kv_empty_0(kv_empty_0),
        .kv_occupancy_0(kv_occ_0), .kv_read_ptr_0(kv_rp_0),
        .evict_req_0(evict_req_0), .evict_addr_0(evict_addr_0),
        .evict_done_0(evict_done_0), .evict_data_0(evict_data_0),
        .evict_valid_0(evict_valid_0), .evict_ready_0(evict_ready_0),
        .reclaim_req_0(reclaim_req_0), .reclaim_data_0(reclaim_data_0),
        .reclaim_valid_0(reclaim_valid_0), .reclaim_sop_0(reclaim_sop_0),
        .reclaim_eop_0(reclaim_eop_0), .reclaim_ready_0(reclaim_ready_0),
        .kv_full_1(1'b0), .kv_empty_1(1'b1), .kv_occupancy_1(0), .kv_read_ptr_1(0),
        .evict_req_1(evict_req_1), .evict_addr_1(evict_addr_1),
        .evict_done_1(evict_done_1), .evict_data_1(evict_data_1),
        .evict_valid_1(evict_valid_1), .evict_ready_1(evict_ready_1),
        .reclaim_req_1(reclaim_req_1), .reclaim_data_1(reclaim_data_1),
        .reclaim_valid_1(reclaim_valid_1), .reclaim_sop_1(reclaim_sop_1),
        .reclaim_eop_1(reclaim_eop_1), .reclaim_ready_1(reclaim_ready_1),
        .kv_full_2(1'b0), .kv_empty_2(1'b1), .kv_occupancy_2(0), .kv_read_ptr_2(0),
        .evict_req_2(evict_req_2), .evict_addr_2(evict_addr_2),
        .evict_done_2(evict_done_2), .evict_data_2(evict_data_2),
        .evict_valid_2(evict_valid_2), .evict_ready_2(evict_ready_2),
        .reclaim_req_2(reclaim_req_2), .reclaim_data_2(reclaim_data_2),
        .reclaim_valid_2(reclaim_valid_2), .reclaim_sop_2(reclaim_sop_2),
        .reclaim_eop_2(reclaim_eop_2), .reclaim_ready_2(reclaim_ready_2),
        .kv_full_3(1'b0), .kv_empty_3(1'b1), .kv_occupancy_3(0), .kv_read_ptr_3(0),
        .evict_req_3(evict_req_3), .evict_addr_3(evict_addr_3),
        .evict_done_3(evict_done_3), .evict_data_3(evict_data_3),
        .evict_valid_3(evict_valid_3), .evict_ready_3(evict_ready_3),
        .reclaim_req_3(reclaim_req_3), .reclaim_data_3(reclaim_data_3),
        .reclaim_valid_3(reclaim_valid_3), .reclaim_sop_3(reclaim_sop_3),
        .reclaim_eop_3(reclaim_eop_3), .reclaim_ready_3(reclaim_ready_3),
        .spine_out_data(spine_out_data), .spine_out_valid(spine_out_valid),
        .spine_out_sop(spine_out_sop), .spine_out_eop(spine_out_eop),
        .spine_out_ready(spine_out_ready), .spine_out_vc(),
        .spine_in_data(spine_in_data), .spine_in_valid(spine_in_valid),
        .spine_in_sop(spine_in_sop), .spine_in_eop(spine_in_eop),
        .spine_in_ready(spine_in_ready),
        .evictions(evictions), .reloads(reloads), .errors(errs)
    );

    // ---- kv_cache_bank (bank 0) ----
    reg  [7:0]  nob_in_data;
    reg         nob_in_valid, nob_in_sop, nob_in_eop;
    wire        nob_in_ready;
    reg  [1:0]  nob_in_vc;
    wire [7:0]  nob_out_data;
    wire        nob_out_valid, nob_out_sop, nob_out_eop;
    reg         nob_out_ready;
    wire [1:0]  nob_out_vc;
    wire [7:0]  kv_load_data;
    wire        kv_load_valid, kv_load_sop, kv_load_eop;
    reg         kv_load_ready;
    reg  [7:0]  reclaim_data;
    reg         reclaim_valid, reclaim_sop, reclaim_eop;
    reg         reclaim_req;
    wire        reclaim_ready;
    // manual eviction override (scenario E): the offload controller only
    // evicts at kv_full, so the bank's evict port is muxed with a manual
    // request/address/ready the testbench can drive directly.
    reg         evict_req_manual;
    reg  [ABITS-1:0] evict_addr_manual;
    reg         evict_ready_manual;
    wire        evict_req_b   = evict_req_manual ? 1'b1    : evict_req_0;
    wire [ABITS-1:0] evict_addr_b = evict_req_manual ? evict_addr_manual : evict_addr_0;
    wire        evict_ready_b = evict_req_manual ? evict_ready_manual : evict_ready_0;

    kv_cache_bank #(
        .BANK_DEPTH(DEPTH), .ENTRY_BYTES(ENTRY), .ADDR_BITS(ABITS)
    ) u_bank (
        .clk(clk), .rst_n(rst_n),
        .nob_in_data(nob_in_data), .nob_in_valid(nob_in_valid),
        .nob_in_sop(nob_in_sop), .nob_in_eop(nob_in_eop),
        .nob_in_ready(nob_in_ready), .nob_in_vc(nob_in_vc),
        .nob_out_data(nob_out_data), .nob_out_valid(nob_out_valid),
        .nob_out_sop(nob_out_sop), .nob_out_eop(nob_out_eop),
        .nob_out_ready(nob_out_ready), .nob_out_vc(nob_out_vc),
        .kv_store_data(8'h00), .kv_store_valid(1'b0), .kv_store_sop(1'b0),
        .kv_store_eop(1'b0), .kv_store_ready(),
        .kv_load_data(kv_load_data), .kv_load_valid(kv_load_valid),
        .kv_load_sop(kv_load_sop), .kv_load_eop(kv_load_eop), .kv_load_ready(kv_load_ready),
        .kv_full(kv_full_0), .kv_empty(kv_empty_0),
        .kv_occupancy(kv_occ_0), .kv_read_ptr(kv_rp_0),
        .evict_req(evict_req_b), .evict_addr(evict_addr_b),
        .evict_done(evict_done_0), .evict_data(evict_data_0),
        .evict_valid(evict_valid_0), .evict_ready(evict_ready_b),
        .reclaim_req(reclaim_req), .reclaim_data(reclaim_data),
        .reclaim_valid(reclaim_valid), .reclaim_sop(reclaim_sop),
        .reclaim_eop(reclaim_eop), .reclaim_ready(reclaim_ready)
    );

    integer i, j, k;
    integer ev_bytes, nob_bytes, resp_bytes;
    integer timeout_cnt;
    reg [7:0] tag;
    reg [7:0] entry_mem [0:ENTRY-1];
    reg [7:0] tx_mem    [0:4095];
    reg [7:0] tx_crc_hi, tx_crc_lo;
    reg [15:0] tx_idx;
    reg [15:0] crc_acc;
    reg        crc_bit;
    integer    tx_len;

    // ---- CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, MSB-first) ----
    function automatic [15:0] crc16;
        input [15:0] acc;
        input [7:0]  b;
        integer ii;
        reg [15:0] c;
        begin
            c = acc ^ (b << 8);
            for (ii = 0; ii < 8; ii = ii + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16 = c;
        end
    endfunction

    // ---- send tx_mem[0:n-1] byte-stream with valid/ready hold ----
    task send_stream(input integer n);
        integer kk;
        begin
            for (kk = 0; kk < n; ) begin
                @(negedge clk);
                nob_in_data = tx_mem[kk];
                nob_in_valid = 1;
                nob_in_sop = (kk == 0);
                nob_in_eop = (kk == n - 1);
                @(posedge clk);
                if (nob_in_ready) kk = kk + 1;
            end
            @(negedge clk);
            nob_in_valid = 0;
            nob_in_sop = 0;
            nob_in_eop = 0;
        end
    endtask

    // ---- build a KV_STORE command for one entry into tx_mem ----
    task build_store(input [7:0] mod);
        integer ii;
        begin
            tx_mem[0] = mod; tx_mem[1] = 8'hA0;
            tx_mem[2] = ENTRY[7:0]; tx_mem[3] = ENTRY[15:8];
            for (ii = 0; ii < ENTRY; ii = ii + 1)
                tx_mem[4 + ii] = entry_mem[ii];
            tx_len = 4 + ENTRY + 2;
            crc_acc = 16'hFFFF;
            for (ii = 0; ii < 4 + ENTRY; ii = ii + 1)
                crc_acc = crc16(crc_acc, tx_mem[ii]);
            tx_mem[4 + ENTRY]     = crc_acc[15:8];
            tx_mem[4 + ENTRY + 1] = crc_acc[7:0];
        end
    endtask

    // ---- build a KV_LOAD command (zero length) ----
    task build_load(input [7:0] mod, input corr);
        integer ii;
        begin
            tx_mem[0] = mod; tx_mem[1] = 8'hB0;
            tx_mem[2] = 8'h02; tx_mem[3] = 8'h00;      // LEN = 2 (index payload)
            tx_mem[4] = tx_idx[7:0]; tx_mem[5] = tx_idx[15:8];
            tx_len = 6 + 2;
            crc_acc = 16'hFFFF;
            for (ii = 0; ii < 6; ii = ii + 1)
                crc_acc = crc16(crc_acc, tx_mem[ii]);
            tx_mem[6] = crc_acc[15:8];
            tx_mem[7] = crc_acc[7:0];
            if (corr) tx_mem[6] = tx_mem[6] ^ 8'hFF;  // corrupt the request CRC
        end
    endtask

    // ---- collect one full response flit from nob_out and check it ----
    task check_response(input [7:0] exp_mod);
        integer got, idx;
        reg [7:0] g;
        reg [15:0] rcrc;
        reg got_ok;
        begin
            got = 0; got_ok = 1; rcrc = 16'hFFFF;
            // Sample-first: the response head (MODULE_ID) is already on the
            // wire the cycle the load request's EOP is accepted, so a wait
            // before the first sample would miss it.
            while (got < ENTRY + 4 + 2) begin
                if (nob_out_valid) begin
                    g = nob_out_data;
                    if (got == 0) begin
                        if (g !== exp_mod) begin
                            $display("FAIL: resp[0]=%02h expected MODULE %02h", g, exp_mod);
                            errors = errors + 1; got_ok = 0;
                        end
                        if (!nob_out_sop) begin
                            $display("FAIL: response missing SOP");
                            errors = errors + 1; got_ok = 0;
                        end
                        rcrc = crc16(rcrc, g);
                    end else if (got == 1) begin
                        if (g !== 8'h80) begin
                            $display("FAIL: resp[1]=%02h expected 80", g);
                            errors = errors + 1; got_ok = 0;
                        end
                        rcrc = crc16(rcrc, g);
                    end else if (got == 2) begin
                        if (g !== ENTRY[7:0]) begin
                            $display("FAIL: resp[2]=%02h expected LEN_LO %02h", g, ENTRY[7:0]);
                            errors = errors + 1; got_ok = 0;
                        end
                        rcrc = crc16(rcrc, g);
                    end else if (got == 3) begin
                        if (g !== ENTRY[15:8]) begin
                            $display("FAIL: resp[3]=%02h expected LEN_HI %02h", g, ENTRY[15:8]);
                            errors = errors + 1; got_ok = 0;
                        end
                        rcrc = crc16(rcrc, g);
                    end else if (got < ENTRY + 4) begin
                        idx = got - 4;
                        if (g !== entry_mem[idx]) begin
                            $display("FAIL: resp payload byte %0d = %02h, expected %02h",
                                     idx, g, entry_mem[idx]);
                            errors = errors + 1; got_ok = 0;
                        end
                        rcrc = crc16(rcrc, g);
                    end else if (got == ENTRY + 4) begin
                        if (g !== rcrc[15:8]) begin
                            $display("FAIL: resp CRC_HI = %02h, expected %02h", g, rcrc[15:8]);
                            errors = errors + 1; got_ok = 0;
                        end
                    end else begin
                        if (g !== rcrc[7:0]) begin
                            $display("FAIL: resp CRC_LO = %02h, expected %02h", g, rcrc[7:0]);
                            errors = errors + 1; got_ok = 0;
                        end
                        if (!nob_out_eop) begin
                            $display("FAIL: response missing EOP on last byte");
                            errors = errors + 1; got_ok = 0;
                        end
                    end
                    got = got + 1;
                end
                @(negedge clk);
            end
            // no spurious bytes after the stream ends
            timeout_cnt = 0;
            while (timeout_cnt < 600) begin
                @(negedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (nob_out_valid) begin
                    $display("FAIL: spurious NoB byte %02h after response end", nob_out_data);
                    errors = errors + 1;
                    timeout_cnt = 1000;
                end
            end
        end
    endtask

    // =========================================================================
    initial begin
        // ---- reset ----
        rst_n = 0;
        nob_in_valid = 0; nob_in_sop = 0; nob_in_eop = 0; nob_in_vc = 2'b11;
        nob_out_ready = 1;
        reclaim_req = 0; reclaim_valid = 0;
        evict_req_manual = 0; evict_ready_manual = 1; evict_addr_manual = 0;
        spine_out_ready = 1;
        spine_in_valid = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        // =====================================================================
        // Scenario A: fill to full via reclaim, evict one via kv_offload
        // =====================================================================
        $display("A: filling bank via reclaim...");
        for (i = 0; i < DEPTH; i = i + 1) begin
            tag = i[7:0];
            @(negedge clk);
            reclaim_req = 1;
            for (j = 0; j < ENTRY; j = j + 1) begin
                @(negedge clk);
                reclaim_valid = 1;
                reclaim_data  = tag + j[7:0];
                reclaim_sop   = (j == 0);
                reclaim_eop   = (j == ENTRY - 1);
            end
            @(negedge clk);
            reclaim_valid = 0;
            reclaim_req = 0;
            while (kv_occ_0 != i + 1) @(negedge clk);
        end
        $display("A: bank full, occupancy=%0d kv_full=%b", kv_occ_0, kv_full_0);
        if (kv_occ_0 != DEPTH || !kv_full_0) begin
            $display("FAIL: A occupancy=%0d expected %0d full=%b", kv_occ_0, DEPTH, kv_full_0);
            errors = errors + 1;
        end

        ev_bytes = 0; nob_bytes = 0;
        timeout_cnt = 0;
        while ((evictions == 0) && (timeout_cnt < 20000)) begin
            @(negedge clk);
            if (evict_valid_0) ev_bytes = ev_bytes + 1;
            if (nob_out_valid) nob_bytes = nob_bytes + 1;
            timeout_cnt = timeout_cnt + 1;
        end
        timeout_cnt = 0;
        while ((evict_valid_0 || evict_done_0) && (timeout_cnt < 20000)) begin
            @(negedge clk);
            if (evict_valid_0) ev_bytes = ev_bytes + 1;
            if (nob_out_valid) nob_bytes = nob_bytes + 1;
            timeout_cnt = timeout_cnt + 1;
        end
        $display("A: evict_bytes=%0d nob_bytes=%0d evictions=%0d occupancy=%0d",
                 ev_bytes, nob_bytes, evictions, kv_occ_0);
        if (ev_bytes != ENTRY) begin
            $display("FAIL: expected %0d evict bytes, saw %0d", ENTRY, ev_bytes);
            errors = errors + 1;
        end
        if (nob_bytes != 0) begin
            $display("FAIL: expected 0 NoB bytes during eviction, saw %0d", nob_bytes);
            errors = errors + 1;
        end
        if (evictions != 1) begin
            $display("FAIL: expected evictions=1, saw %0d", evictions);
            errors = errors + 1;
        end
        if (kv_occ_0 != DEPTH - 1) begin
            $display("FAIL: expected occupancy=%0d, saw %0d", DEPTH - 1, kv_occ_0);
            errors = errors + 1;
        end

        // =====================================================================
        // Scenario B: CRC-valid NoB store + load round trip
        // =====================================================================
        @(negedge clk);
        rst_n = 0;
        #10 rst_n = 1;
        nob_in_valid = 0; nob_in_sop = 0; nob_in_eop = 0;
        while (kv_occ_0 != 0) @(negedge clk);

        // entry: byte b = constant pattern (deterministic, verifiable)
        for (i = 0; i < ENTRY; i = i + 1) entry_mem[i] = i[7:0];
        tx_idx = 0;

        build_store(8'h3C);           // MODULE_ID 0x3C (arbitrary node id)
        $display("B: sending KV_STORE (mod=3C, %0d bytes)...", tx_len);
        send_stream(tx_len);
        while (kv_occ_0 != 1) @(negedge clk);
        $display("B: entry stored, occupancy=%0d", kv_occ_0);
        if (kv_occ_0 != 1) begin
            $display("FAIL: B store occupancy=%0d expected 1", kv_occ_0);
            errors = errors + 1;
        end

        build_load(8'h3C, 0);
        $display("B: sending KV_LOAD (mod=3C, %0d bytes, idx=%0d)...", tx_len, tx_idx);
        send_stream(tx_len);
        check_response(8'h3C);

        // =====================================================================
        // Scenario C: corrupt store refused (occupancy unchanged)
        // =====================================================================
        build_store(8'h4D);
        tx_mem[200] = tx_mem[200] ^ 8'hFF;   // corrupt a payload byte post-CRC
        $display("C: sending corrupt KV_STORE (mod=4D, CRC broken)...");
        send_stream(tx_len);
        repeat (20) @(negedge clk);
        if (kv_occ_0 != 1) begin
            $display("FAIL: C corrupt store changed occupancy to %0d (expected 1)", kv_occ_0);
            errors = errors + 1;
        end else begin
            $display("C: corrupt store refused, occupancy=%0d", kv_occ_0);
        end

        // the next good load must still serve scenario B's entry (FIFO order)
        build_load(8'h3C, 0);
        send_stream(tx_len);
        check_response(8'h3C);

        // =====================================================================
        // Scenario D: corrupt load request refused (no response)
        // =====================================================================
        resp_bytes = 0;
        build_load(8'h5E, 1);
        $display("D: sending corrupt KV_LOAD (CRC broken)...");
        send_stream(tx_len);
        timeout_cnt = 0;
        while (timeout_cnt < 600) begin
            @(negedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (nob_out_valid) begin
                resp_bytes = resp_bytes + 1;
                $display("FAIL: D spurious response byte %02h after corrupt load", nob_out_data);
                errors = errors + 1;
            end
        end
        if (resp_bytes == 0)
            $display("D: corrupt load refused (no response)");

        // =====================================================================
        // =====================================================================
        // Scenario E: second entry stored; loads are non-destructive reads
        // (read_ptr advances only on eviction), so two loads before any
        // eviction must both return entry 1, and a load after evicting the
        // oldest must return entry 2 (FIFO order preserved).
        // =====================================================================
        // entry 1 (stored in B) = i; entry 2 (stored now) = ~i
        for (i = 0; i < ENTRY; i = i + 1) entry_mem[i] = ~(i[7:0]);
        build_store(8'h6F);
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            $display("Es: in=%02h v=%b r=%b | ks=%0d lq=%0d ptv=%b p2v=%b", nob_in_data, nob_in_valid, nob_in_ready, u_bank.ks_state, u_bank.lq_state, u_bank.pt_valid, u_bank.pt2_valid);
        end
        send_stream(tx_len);
        while (kv_occ_0 != 2) @(negedge clk);
        // load 1 must serve entry 1 (byte = i)
        for (i = 0; i < ENTRY; i = i + 1) entry_mem[i] = i[7:0];
        build_load(8'h3C, 0);
        send_stream(tx_len);
        check_response(8'h3C);
        // load 2 still serves entry 1 (loads do not consume)
        build_load(8'h3C, 0);
        send_stream(tx_len);
        check_response(8'h3C);
        // evict the oldest (entry 1), then load 3 must serve entry 2 (~i)
        @(negedge clk);
        evict_req_manual = 1;
        evict_addr_manual = kv_rp_0;
        while (!evict_done_0) @(negedge clk);
        while (evict_done_0) @(negedge clk);
        evict_req_manual = 0;
        repeat (4) @(negedge clk);
        while (kv_occ_0 != 1) @(negedge clk);
        for (i = 0; i < ENTRY; i = i + 1) entry_mem[i] = ~(i[7:0]);
        tx_idx = 0;   // after evicting the oldest, entry 2 is at relative
                      // index 0 of the live window [read_ptr, read_ptr+occ)
        build_load(8'h6F, 0);
        send_stream(tx_len);
        check_response(8'h6F);

        if (errors == 0)
            $display("*** KV CACHE BANK TEST PASSED ***");
        else
            $display("*** KV CACHE BANK TEST FAILED (%0d errors) ***", errors);
        $finish;
    end


initial begin
        #40_000_000;
        $display("*** KV CACHE BANK TEST FAILED (timeout) ***");
        $finish;
    end
endmodule