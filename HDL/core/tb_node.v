`timescale 1ns/1ps

// tb_node — standalone validation harness for the compute node (node.v).
// Boots wu.hex (2*EFF x N gate/up), wd.hex (N x EFF down), streams
// x.hex (N hidden words), then emits result words as "R <i> <hex>".
// CU_TYPE / WIDTH select the embedded numeric ASIC. Compiled by
// node_reference_test.py and run under vvp.

module tb_node #(
    parameter N        = 16,
    parameter EFF      = 8,
    parameter CU_TYPE  = 0,
    parameter WIDTH    = 16,
    parameter MEM_CHAN = 1,
    parameter [3:0] MXFP4_SHIFT = 4'd0
)();

    reg clk, rst_n, start, hidden_valid, weight_load, weight_sel;
    reg [MEM_CHAN*WIDTH-1:0] hidden_data;
    reg [WIDTH-1:0] weight_data;
    reg [15:0] weight_addr;
    reg [7:0]  out_addr, dbg_addr;
    wire [WIDTH-1:0] out_val, gate_val, up_val, act_val;
    wire done;
    integer i, c;

    reg [WIDTH-1:0] wu [0:2*EFF*N-1];
    reg [WIDTH-1:0] wd [0:N*EFF-1];
    reg [WIDTH-1:0] xv [0:N-1];

    node #(.N(N), .EFF(EFF), .CU_TYPE(CU_TYPE), .WIDTH(WIDTH),
           .MEM_CHAN(MEM_CHAN), .MXFP4_SHIFT(MXFP4_SHIFT)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .done         (done),
        .hidden_valid (hidden_valid),
        .hidden_data  (hidden_data),
        .weight_load  (weight_load),
        .weight_sel   (weight_sel),
        .weight_addr  (weight_addr),
        .weight_data  (weight_data),
        .out_addr     (out_addr),
        .out_val      (out_val),
        .dbg_addr     (dbg_addr),
        .gate_val     (gate_val),
        .up_val       (up_val),
        .act_val      (act_val)
    );

    always #1 clk = ~clk;

    initial begin
        $readmemh("wu.hex", wu);
        $readmemh("wd.hex", wd);
        $readmemh("x.hex",  xv);
        clk = 0; rst_n = 0; start = 0; hidden_valid = 0; hidden_data = 0;
        weight_load = 0; weight_sel = 0; weight_addr = 0; weight_data = 0;
        out_addr = 0;
        #4 rst_n = 1;

        // ---- boot: stream gate/up then down weights ---------------------
        for (i = 0; i < 2*EFF*N; i = i + 1) begin
            @(posedge clk);
            weight_addr <= i; weight_data <= wu[i]; weight_sel <= 0; weight_load <= 1;
        end
        for (i = 0; i < N*EFF; i = i + 1) begin
            @(posedge clk);
            weight_addr <= i; weight_data <= wd[i]; weight_sel <= 1; weight_load <= 1;
        end
        @(posedge clk);
        weight_load <= 0;
        @(posedge clk);

        // ---- request -----------------------------------------------------
        start <= 1;
        @(posedge clk);
        start <= 0;

        // ---- stream the N-word hidden vector, MEM_CHAN words per beat ----
        for (i = 0; i < N / MEM_CHAN; i = i + 1) begin
            for (c = 0; c < MEM_CHAN; c = c + 1)
                hidden_data[c*WIDTH +: WIDTH] <= xv[i*MEM_CHAN + c];
            hidden_valid <= 1;
            @(posedge clk);
        end
        hidden_valid <= 0;

        wait (done);

        // ---- dump the N-wide expert output -------------------------------
        for (i = 0; i < N; i = i + 1) begin
            out_addr <= i;
            #1 $display("R %0d %0h", i, out_val);
        end
        for (i = 0; i < EFF; i = i + 1) begin
            dbg_addr <= i;
            #1 $display("G %0d %0h", i, gate_val);
            dbg_addr <= i;
            #1 $display("U %0d %0h", i, up_val);
            dbg_addr <= i;
            #1 $display("A %0d %0h", i, act_val);
        end
        $finish;
    end
endmodule
