`timescale 1ns/1ps

`include "dblock_addrs.vh"

module tb_gemma_decoder_block;

    localparam N = 16, NH = 2, HD = 8, FFD = 16, E = 4, EFF = 8, CACHE = 4;
    localparam KCW = CACHE * N;
    localparam ROPEW = (CACHE + 1) * NH * (HD / 2) * 2;
    localparam WMEMSZ = `WMEMSZ;

    reg clk = 0;
    reg rst_n = 0;

    reg  w_we, k_we, v_we, r_we, x_we;
    reg [15:0] w_addr;
    reg [15:0] w_data;
    reg [6:0]  k_addr, v_addr;
    reg [15:0] k_data, v_data;
    reg [8:0]  r_addr;
    reg [15:0] r_data;
    reg [3:0]  x_addr;
    reg [15:0] x_data;

    reg start;
    wire done;
    wire [15:0] o_data;
    reg [3:0] o_addr;

    gemma_decoder_block #(
        .N(N), .NH(NH), .HD(HD), .FFD(FFD), .E(E), .EFF(EFF), .CACHE(CACHE)
    ) uut (
        .clk(clk), .rst_n(rst_n),
        .w_we(w_we), .w_addr(w_addr), .w_data(w_data),
        .k_we(k_we), .k_addr(k_addr), .k_data(k_data),
        .v_we(v_we), .v_addr(v_addr), .v_data(v_data),
        .r_we(r_we), .r_addr(r_addr), .r_data(r_data),
        .x_we(x_we), .x_addr(x_addr), .x_data(x_data),
        .start(start), .done(done),
        .o_data(o_data), .o_addr(o_addr)
    );

    integer i;
    integer j;

    reg [15:0] tmp_x [0:N-1];
    reg [15:0] tmp_w [0:WMEMSZ-1];
    reg [15:0] tmp_k [0:KCW-1];
    reg [15:0] tmp_v [0:KCW-1];
    reg [15:0] tmp_r [0:ROPEW-1];

    initial begin
        w_we = 0; k_we = 0; v_we = 0; r_we = 0; x_we = 0;
        w_addr = 0; w_data = 0;
        k_addr = 0; k_data = 0;
        v_addr = 0; v_data = 0;
        r_addr = 0; r_data = 0;
        x_addr = 0; x_data = 0;
        start = 0;
        o_addr = 0;

        repeat (4) @(posedge clk);
        rst_n <= 1;

        // -- x words ---------------------------------------------------------
        $readmemh("dblock_x.hex", tmp_x);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            x_we <= 1;
            x_addr <= i;
            x_data <= tmp_x[i];
        end
        @(posedge clk);
        x_we <= 0;

        // -- weights ---------------------------------------------------------
        $readmemh("dblock_wmem.hex", tmp_w);
        for (i = 0; i < WMEMSZ; i = i + 1) begin
            @(posedge clk);
            w_we <= 1;
            w_addr <= i;
            w_data <= tmp_w[i];
        end
        @(posedge clk);
        w_we <= 0;

        // -- kcache ----------------------------------------------------------
        $readmemh("dblock_kc.hex", tmp_k);
        for (i = 0; i < KCW; i = i + 1) begin
            @(posedge clk);
            k_we <= 1;
            k_addr <= i;
            k_data <= tmp_k[i];
        end
        @(posedge clk);
        k_we <= 0;

        // -- vcache ----------------------------------------------------------
        $readmemh("dblock_vc.hex", tmp_v);
        for (i = 0; i < KCW; i = i + 1) begin
            @(posedge clk);
            v_we <= 1;
            v_addr <= i;
            v_data <= tmp_v[i];
        end
        @(posedge clk);
        v_we <= 0;

        // -- rope ------------------------------------------------------------
        $readmemh("dblock_rope.hex", tmp_r);
        for (i = 0; i < ROPEW; i = i + 1) begin
            @(posedge clk);
            r_we <= 1;
            r_addr <= i;
            r_data <= tmp_r[i];
        end
        @(posedge clk);
        r_we <= 0;

        // -- run -------------------------------------------------------------
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        while (!done) @(posedge clk);
        @(posedge clk);

        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            o_addr <= i;
            #1 $display("OUT %0d %04h", i, o_data);
        end

        $finish;
    end

    always #5 clk = ~clk;

endmodule