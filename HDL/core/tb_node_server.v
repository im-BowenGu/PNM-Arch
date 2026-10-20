`timescale 1ns/1ps

// =============================================================================
// tb_node_server — persistent compute-node server for the pnmgate/harness
// composition (node.v made request-serverable over files, mirroring
// tb_gating_server.v).
//
//   The harness (pnmgate / the Go composition test) boots one process per
//   (layer, expert) slice:
//   1. BOOT  : the real expert's gate_up slice (wu.hex, GU_ROWS x N words) and
//              down slice (wd.hex, N x EFF words) are loaded into node.v's
//              weight SRAMs.  Status is signalled via "status.txt".
//   2. SERVE : loop over requests n = 0,1,2,...
//       * wait for file "req_<n>.go"
//       * $readmemh("x_<n>.hex") -> N hidden words
//       * pulse start, stream the N hidden words (node.v's capture FSM is
//         self-resetting per start), wait done
//       * read the N-wide expert output via the out_addr/out_val window and
//         write "res_<n>.txt" (one hex word per line), then "res_<n>.done".
//   MAXREQ=0 means serve forever (the harness kills the process when done).
//
//   Weights persist across requests (node.v only overwrites on weight_load),
//   so a persistent server serves many hidden vectors for one expert.
// =============================================================================

module tb_node_server #(
    parameter N           = 16,
    parameter EFF         = 8,
    parameter CU_TYPE     = 0,
    parameter WIDTH       = 16,
    parameter GU_ROWS     = 16,   // wu.hex rows = 2*EFF (BF16) or EFF (gate-only units)
    parameter [3:0] MXFP4_SHIFT = 4'd0,
    parameter MAXREQ      = 0,
    parameter CLK_PERIOD  = 10
)();

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n = 0;

    reg        start;
    reg        hidden_valid;
    reg [WIDTH-1:0] hidden_data;
    reg        weight_load;
    reg        weight_sel;
    reg [15:0] weight_addr;
    reg [WIDTH-1:0] weight_data;
    reg [7:0]  out_addr;
    reg [7:0]  dbg_addr;
    wire [WIDTH-1:0] out_val, gate_val, up_val, act_val;
    wire done;

    node #(.N(N), .EFF(EFF), .CU_TYPE(CU_TYPE), .WIDTH(WIDTH),
           .MXFP4_SHIFT(MXFP4_SHIFT)) u_node (
        .clk(clk), .rst_n(rst_n),
        .start(start), .done(done),
        .hidden_valid(hidden_valid), .hidden_data(hidden_data),
        .weight_load(weight_load), .weight_sel(weight_sel),
        .weight_addr(weight_addr), .weight_data(weight_data),
        .out_addr(out_addr), .out_val(out_val),
        .dbg_addr(dbg_addr), .gate_val(gate_val), .up_val(up_val), .act_val(act_val)
    );

    reg [WIDTH-1:0] wu [0:GU_ROWS*N-1];
    reg [WIDTH-1:0] wd [0:N*EFF-1];
    reg [WIDTH-1:0] xv [0:N-1];
    reg [255:0] fname_hex;
    reg [255:0] fname_go;
    reg [255:0] fname_res;
    reg [255:0] fname_done;
    integer n, fd, i;

    initial begin
        n = 0;
        start = 0; hidden_valid = 0; hidden_data = 0;
        weight_load = 0; weight_sel = 0; weight_addr = 0; weight_data = 0;
        out_addr = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- BOOT: stream gate/up then down weight slices ----
        $readmemh("wu.hex", wu);
        $readmemh("wd.hex", wd);
        for (i = 0; i < GU_ROWS*N; i = i + 1) begin
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

        fd = $fopen("status.txt", "w");
        $fwrite(fd, "ready N=%0d EFF=%0d CU=%0d W=%0d\n", N, EFF, CU_TYPE, WIDTH);
        $fclose(fd);

        // ---- SERVE --------------------------------------------------------
        forever begin
            $swrite(fname_go,  "req_%0d.go",   n);
            $swrite(fname_hex, "x_%0d.hex",   n);
            $swrite(fname_res, "res_%0d.txt", n);
            $swrite(fname_done,"res_%0d.done",n);

            fd = $fopen(fname_go, "r");
            while (fd == 0) begin
                #(CLK_PERIOD*8);
                fd = $fopen(fname_go, "r");
            end
            $fclose(fd);

            $readmemh(fname_hex, xv);

            // Settle off the clock grid: the fopen poll advances in whole-period
            // delays, so a request that arrives after boot resumes exactly at a
            // posedge instant, and `@(posedge clk)` after `start <= 1` can return
            // in the *same* timestep, collapsing the start pulse to zero cycles
            // (node.v never leaves X_IDLE).  The gating server sidesteps this by
            // holding bus_valid across three edges; here one `#1` off-grid does the
            // same, making the pulse span a full clock period deterministically.
            #1;

            start <= 1;
            @(posedge clk);
            start <= 0;
            for (i = 0; i < N; i = i + 1) begin
                hidden_data <= xv[i]; hidden_valid <= 1;
                @(posedge clk);
            end
            hidden_valid <= 0;

            while (!done) @(posedge clk);
            @(posedge clk);

            fd = $fopen(fname_res, "w");
            for (i = 0; i < N; i = i + 1) begin
                out_addr <= i;
                #1 $fwrite(fd, "%0h\n", out_val);
            end
            $fclose(fd);

            fd = $fopen(fname_done, "w");
            $fwrite(fd, "done %0d\n", n);
            $fclose(fd);

            $display("NODE-RES %0d done", n);
            n = n + 1;
            if (MAXREQ > 0 && n >= MAXREQ) begin
                $display("NODE-QUIT served=%0d", MAXREQ);
                $finish;
            end
        end
    end

endmodule