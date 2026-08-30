`timescale 1ns/1ps
// Self-checking regression for the KV eviction path (kv_offload + kv_cache_bank)
//
// Scenario A (eviction): fill bank 0 to full through the reclaim port, let the
// offload controller evict an entry (EVICTION_TARGET=0, discard), and require
//   - evict_done fires, occupancy decrements to DEPTH-1, evictions == 1
//   - the payload is NOT misrouted to the NoB load port (nob_bytes == 0)
//   - after completion, NO second eviction re-triggers and no entry is
//     re-streamed on the NoB (regression for the pulse-vs-level protocol bug
//     and the KL_TAIL re-trigger window)
//
// Scenario B (load): store one entry via reclaim, issue a KV_LOAD command on
// the NoB (single op byte, vc=2'b11), and require the response
// [EE,80,lenL,lenH] followed by exactly ENTRY_BYTES payload bytes equal to the
// stored values, with no spurious trailing bytes (regression for the
// final-byte truncation where returning to KL_IDLE cut the muxed stream).
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
        .evict_req(evict_req_0), .evict_addr(evict_addr_0),
        .evict_done(evict_done_0), .evict_data(evict_data_0),
        .evict_valid(evict_valid_0), .evict_ready(evict_ready_0),
        .reclaim_req(reclaim_req), .reclaim_data(reclaim_data),
        .reclaim_valid(reclaim_valid), .reclaim_sop(reclaim_sop),
        .reclaim_eop(reclaim_eop), .reclaim_ready(reclaim_ready)
    );

    integer i, j;
    integer ev_bytes, nob_bytes;
    integer timeout_cnt;
    reg [7:0] tag;

    task fill_entry(input [7:0] tag);
    begin
        @(negedge clk);
        reclaim_req = 1;
        for (i = 0; i < ENTRY; i = i + 1) begin
            @(negedge clk);
            reclaim_valid = 1;
            reclaim_data  = tag ^ i[7:0];
            reclaim_sop   = (i == 0);
            reclaim_eop   = (i == ENTRY-1);
        end
        @(negedge clk);
        reclaim_valid = 0;
        reclaim_req = 0;
    end
    endtask

    initial begin
        // idle inputs
        nob_in_data = 0; nob_in_valid = 0; nob_in_sop = 0; nob_in_eop = 0; nob_in_vc = 0;
        nob_out_ready = 1;
        kv_load_ready = 0;
        reclaim_data = 0; reclaim_valid = 0; reclaim_sop = 0; reclaim_eop = 0; reclaim_req = 0;
        spine_out_ready = 1;
        spine_in_data = 0; spine_in_valid = 0; spine_in_sop = 0; spine_in_eop = 0;
        ev_bytes = 0; nob_bytes = 0; timeout_cnt = 0;

        #20 rst_n = 0;
        #10 rst_n = 1;

        // =================================================================
        // Scenario A: eviction path
        // =================================================================
        for (j = 0; j < DEPTH; j = j + 1) begin
            tag = j[7:0];
            fill_entry(tag);
        end
        while (kv_occ_0 != DEPTH) @(negedge clk);

        $display("A: bank full, occupancy=%0d kv_full=%b", kv_occ_0, kv_full_0);
        if (!kv_full_0) begin
            $display("FAIL: bank never reached full");
            errors = errors + 1;
        end

        // observe the eviction and keep watching for a duplicate re-trigger
        timeout_cnt = 0;
        while (timeout_cnt < 10000) begin
            @(negedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (evict_valid_0) ev_bytes = ev_bytes + 1;
            if (nob_out_valid) nob_bytes = nob_bytes + 1;
            if (evictions > 0 && timeout_cnt > 100) timeout_cnt = 10001;
        end
        while (timeout_cnt < 10600) begin
            @(negedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (evict_valid_0) ev_bytes = ev_bytes + 1;
            if (nob_out_valid) nob_bytes = nob_bytes + 1;
            if (evictions > 1) timeout_cnt = 11000;
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

        // =================================================================
        // Scenario B: KV_LOAD return path
        // =================================================================
        begin : scen_b
            reg [7:0] expect [0:ENTRY-1];
            integer got, idx;
            reg [7:0] gotdata;
            integer tc;

            // reset the bank between scenarios (A left it at DEPTH-1)
            @(negedge clk);
            rst_n = 0;
            #10 rst_n = 1;
            ev_bytes = 0; nob_bytes = 0;
            while (kv_occ_0 != 0) @(negedge clk);

            // store one entry: byte b = 8'(b)
            for (i = 0; i < ENTRY; i = i + 1) expect[i] = i[7:0];
            @(negedge clk);
            reclaim_req = 1;
            for (i = 0; i < ENTRY; i = i + 1) begin
                @(negedge clk);
                reclaim_valid = 1;
                reclaim_data  = i[7:0];
                reclaim_sop   = (i == 0);
                reclaim_eop   = (i == ENTRY-1);
            end
            @(negedge clk);
            reclaim_valid = 0;
            reclaim_req = 0;
            while (kv_occ_0 != 1) @(negedge clk);
            $display("B: entry stored, occupancy=%0d", kv_occ_0);

            // trigger KV_LOAD with a single op byte; the bank injects
            // [EE,80,lenL,lenH] on the NoB, with 0xEE in the trigger cycle
            got = 0; gotdata = 0; idx = 0;
            @(negedge clk);
            nob_in_valid = 1; nob_in_sop = 1; nob_in_data = 8'h03; nob_in_vc = 2'b11;
            @(negedge clk);
            nob_in_valid = 0; nob_in_sop = 0;
            if (!nob_out_valid || nob_out_data !== 8'hEE) begin
                $display("FAIL: B header[0]=%h expected EE (valid=%b)", nob_out_data, nob_out_valid);
                errors = errors + 1;
            end
            got = 1;

            while (got < ENTRY + 4) begin
                @(negedge clk);
                if (nob_out_valid) begin
                    gotdata = nob_out_data;
                    if (got >= 4) begin
                        idx = got - 4;
                        if (gotdata !== expect[idx]) begin
                            $display("FAIL: B payload byte %0d = %h, expected %h",
                                     idx, gotdata, expect[idx]);
                            errors = errors + 1;
                        end
                    end else begin
                        if (got == 1 && gotdata !== 8'h80) begin
                            $display("FAIL: B header[1]=%h expected 80", gotdata);
                            errors = errors + 1;
                        end
                        if (got == 2 && gotdata !== ENTRY[7:0]) begin
                            $display("FAIL: B header[2]=%h expected %h", gotdata, ENTRY[7:0]);
                            errors = errors + 1;
                        end
                        if (got == 3 && gotdata !== ENTRY[15:8]) begin
                            $display("FAIL: B header[3]=%h expected %h", gotdata, ENTRY[15:8]);
                            errors = errors + 1;
                        end
                    end
                    got = got + 1;
                end
            end

            // no spurious trailing bytes after the stream ends
            tc = 0;
            while (tc < 600) begin
                @(negedge clk);
                tc = tc + 1;
                if (nob_out_valid) begin
                    $display("FAIL: B spurious NoB byte %h after stream end", nob_out_data);
                    errors = errors + 1;
                    tc = 1000;
                end
            end
        end

        if (errors == 0)
            $display("*** KV CACHE BANK TEST PASSED ***");
        else
            $display("*** KV CACHE BANK TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("*** KV CACHE BANK TEST FAILED (timeout) ***");
        $finish;
    end

endmodule