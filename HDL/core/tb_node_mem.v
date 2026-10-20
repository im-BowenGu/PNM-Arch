`timescale 1ns/1ps

// tb_node_mem — standalone validation harness for the per-node multi-channel
// memory (node_mem.v).  Boots mem.hex (CHANNELS*DEPTH words), reads a burst
// request from req.hex (base, words), issues it, and emits each CHANNELS-wide
// beat as "B <hex>".  Compiled by node_mem_reference_test.py, run under vvp.

module tb_node_mem #(
    parameter CHANNELS = 4,
    parameter DEPTH    = 32,
    parameter WIDTH    = 16,
    parameter CAS      = 2,
    parameter ADDRW    = 16
)();

    localparam WORDS = CHANNELS * DEPTH;

    reg clk, rst_n;
    reg wr_en;
    reg [ADDRW-1:0] wr_addr;
    reg [WIDTH-1:0] wr_data;
    reg req_valid;
    reg [ADDRW-1:0] req_addr, req_words;
    wire req_ready, busy, rd_valid, rd_last;
    wire [CHANNELS*WIDTH-1:0] rd_data;
    wire [ADDRW-1:0] rd_beat, rd_beats;

    reg [WIDTH-1:0] minit [0:WORDS-1];
    reg [ADDRW-1:0] reqv [0:1];
    integer i, k, guard;

    node_mem #(
        .CHANNELS(CHANNELS), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .CAS(CAS), .ADDRW(ADDRW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .req_valid(req_valid), .req_addr(req_addr), .req_words(req_words),
        .req_ready(req_ready), .busy(busy),
        .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
        .rd_beat(rd_beat), .rd_beats(rd_beats)
    );

    always #1 clk = ~clk;

    initial begin
        $readmemh("mem.hex", minit);
        $readmemh("req.hex", reqv);
        clk = 0; rst_n = 0;
        wr_en = 0; wr_addr = 0; wr_data = 0;
        req_valid = 0; req_addr = 0; req_words = 0;
        #4 rst_n = 1;

        // ---- preload memory through the write port ----------------------
        for (i = 0; i < WORDS; i = i + 1) begin
            @(posedge clk);
            wr_en   <= 1'b1;
            wr_addr <= i[ADDRW-1:0];
            wr_data <= minit[i];
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // ---- issue the burst read --------------------------------------
        @(posedge clk);
        req_valid <= 1'b1;
        req_addr  <= reqv[0];
        req_words <= reqv[1];
        @(posedge clk);
        req_valid <= 1'b0;

        // ---- collect beats (negedge settles the combinational egress) ---
        k = 0; guard = 0;
        while ((k < (reqv[1] / CHANNELS)) && (guard < 100000)) begin
            @(negedge clk);
            if (rd_valid) begin
                $display("B %h", rd_data);
                k = k + 1;
            end
            guard = guard + 1;
        end
        $display("DONE %0d", k);
        $finish;
    end

endmodule
