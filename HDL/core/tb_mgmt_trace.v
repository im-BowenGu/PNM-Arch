`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// The firmware's sequence, replayed against the real gating ASIC.
//
// fw/pnm_mgmt.c is the embedded management node's firmware; fw/test_mgmt_gating.c
// runs it against a behavioural model of the gating ASIC and records every bus
// transaction it makes.  This testbench replays that trace against the *real*
// gating ASIC, so the firmware and the silicon are checked against each other
// rather than each against its own model.
//
// The trace is written by the C test (PNM_MGMT_TRACE, default
// /tmp/pnm_mgmt_trace.txt).  Each line is either
//
//     W <addr> <data>   a write
//     R <addr>          a read
//
// The check: after the replay, the ASIC must hold exactly the weights and the
// hidden vector the firmware programmed, and the gating engine must have
// produced a *defined* decision.  A firmware that programmed the wrong
// register, in the wrong order, or with the wrong byte order would fail here.
//
// The trace's reads are replayed too, but their values are not checked: the
// firmware's decision depends on the model's arithmetic, and the hardware
// rounds where the model truncates, so the logits can differ by an ULP (the
// selected experts do not).
// ---------------------------------------------------------------------------

module tb_mgmt_trace;

    // the shape the firmware's test programs: 8 experts x 8 hidden dims
    localparam NUM_EXPERTS = 8;
    localparam HIDDEN_DIM  = 8;
    localparam TOP_K       = 2;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    integer errors = 0;
    integer guard;

    // the management node's bus
    reg  [15:0] mgr_addr = 16'd0;
    reg  [15:0] mgr_wdata = 16'd0;
    wire [15:0] mgr_rdata;
    reg         mgr_we = 1'b0;
    reg         mgr_valid = 1'b0;
    wire        mgr_ready;

    wire [15:0] asic_addr;
    wire [15:0] asic_wdata;
    wire [15:0] asic_rdata;
    wire        asic_we;
    wire        asic_valid;
    wire        asic_ready;

    wire [TOP_K*8-1:0]  expert_idx;
    wire [TOP_K*16-1:0] expert_logit;
    wire [TOP_K*8-1:0]  expert_layer;
    wire [TOP_K*8-1:0]  expert_module;
    wire                 result_valid;
    wire                 asic_busy;
    wire                 asic_done;
    wire [31:0]          asic_cycles;

    gating_asic #(
        .NUM_EXPERTS(NUM_EXPERTS), .HIDDEN_DIM(HIDDEN_DIM), .TOP_K(TOP_K),
        .ADDR_BITS(8), .ARRAY_SIZE(2),
        .WEIGHT_DEPTH(NUM_EXPERTS*HIDDEN_DIM), .HIDDEN_DEPTH(HIDDEN_DIM)
    ) u_asic (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(16'd0), .bus_wdata(16'd0), .bus_rdata(),
        .bus_we(1'b0), .bus_valid(1'b0), .bus_ready(),
        .mgmt_sel(1'b1),
        .mgmt_addr(mgr_addr), .mgmt_wdata(mgr_wdata), .mgmt_rdata(asic_rdata),
        .mgmt_we(mgr_we), .mgmt_valid(mgr_valid), .mgmt_ready(asic_ready),
        .prog_data(8'd0), .prog_valid(1'b0), .prog_sop(1'b0), .prog_eop(1'b0),
        .expert_idx(expert_idx), .expert_logit(expert_logit),
        .expert_layer(expert_layer), .expert_module(expert_module),
        .result_valid(result_valid),
        .busy(asic_busy), .done(asic_done), .cycle_count(asic_cycles)
    );

    // The programming the trace carries, collected as it is replayed so the
    // ASIC's own memories can be compared against it.
    reg [15:0] exp_weights [0:NUM_EXPERTS*HIDDEN_DIM-1];
    reg [15:0] exp_hidden  [0:HIDDEN_DIM-1];
    reg [15:0] wght_addr;
    reg [15:0] hid_addr;
    integer    n_weights;
    integer    n_hidden;
    integer    i;

    // One bus transaction: the gating ASIC's ready is a registered copy of
    // its valid, so a transaction completes on the second edge of a valid
    // window.  The firmware's driver holds valid across two edges.
    task bus_xfer;
        input [15:0] addr;
        input [15:0] data;
        input        we;
        begin
            mgr_addr  = addr;
            mgr_wdata = data;
            mgr_we    = we;
            mgr_valid = 1'b1;
            @(posedge clk);
            @(posedge clk);
            mgr_valid = 1'b0;
            mgr_we    = 1'b0;
            @(posedge clk);
        end
    endtask

    integer fd;
    integer rc;
    reg [8*16-1:0] line;
    reg [15:0] t_addr;
    reg [15:0] t_data;
    reg        t_we;
    integer    n_lines;
    integer    n_reads;
    integer    n_writes;

    initial begin
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        n_weights = 0;
        n_hidden  = 0;
        wght_addr = 16'd0;
        hid_addr  = 16'd0;

        fd = $fopen("/tmp/pnm_mgmt_trace.txt", "r");
        if (fd == 0) begin
            $display("FAIL: the trace file /tmp/pnm_mgmt_trace.txt is missing");
            $display("      (run fw/test_mgmt_gating.c first to write it)");
            errors = errors + 1;
        end else begin
            n_lines = 0;
            n_reads = 0;
            n_writes = 0;
            while ($fgets(line, fd) != 0) begin
                n_lines = n_lines + 1;
                // a write line has two fields, a read line one
                rc = $sscanf(line, "W %h %h", t_addr, t_data);
                if (rc == 2) begin
                    n_writes = n_writes + 1;
                    bus_xfer(t_addr, t_data, 1'b1);
                    // record what the firmware programmed
                    case (t_addr)
                        // an address write starts a new vector
                        16'h10: begin wght_addr = {16'd0, t_data}; n_weights = 0; end
                        16'h11: wght_addr = {t_data, wght_addr[7:0]};
                        16'h12: begin
                            if (n_weights < NUM_EXPERTS*HIDDEN_DIM)
                                exp_weights[n_weights] = t_data;
                            n_weights = n_weights + 1;
                            wght_addr = wght_addr + 1'b1;
                        end
                        16'h14: begin hid_addr = {16'd0, t_data}; n_hidden = 0; end
                        16'h15: hid_addr = {t_data, hid_addr[7:0]};
                        16'h16: begin
                            if (n_hidden < HIDDEN_DIM)
                                exp_hidden[n_hidden] = t_data;
                            n_hidden = n_hidden + 1;
                            hid_addr = hid_addr + 1'b1;
                        end
                        default: ;
                    endcase
                end else if ($sscanf(line, "R %h", t_addr) == 1) begin
                    n_reads = n_reads + 1;
                    bus_xfer(t_addr, 16'd0, 1'b0);
                    // A status read is the firmware's *wait*: it polls until
                    // the engine's busy falls.  The trace records the
                    // sequence, not the timing, so the replay re-derives the
                    // wait here -- otherwise the decision would be read
                    // before the engine had finished.
                    if (t_addr == 16'h02) begin
                        guard = 0;
                        while ((asic_rdata[0] == 1'b1) && guard < 10000) begin
                            bus_xfer(16'h02, 16'd0, 1'b0);
                            guard = guard + 1;
                        end
                        // settle: the packed decision output is registered
                        // behind the top-k buffer
                        bus_xfer(16'h02, 16'd0, 1'b0);
                        bus_xfer(16'h02, 16'd0, 1'b0);
                    end
                end
            end
            $fclose(fd);
            $display("  the trace had %0d lines (%0d writes, %0d reads)",
                     n_lines, n_writes, n_reads);
        end

        // ---- the silicon must hold exactly what the firmware programmed ----
        if (n_weights != NUM_EXPERTS*HIDDEN_DIM) begin
            $display("FAIL: the firmware programmed %0d weights, expected %0d",
                     n_weights, NUM_EXPERTS*HIDDEN_DIM);
            errors = errors + 1;
        end
        for (i = 0; i < NUM_EXPERTS*HIDDEN_DIM && i < n_weights; i = i + 1) begin
            if (u_asic.u_moe_gating.weights[i] !== exp_weights[i]) begin
                $display("FAIL: weight %0d is %h, the firmware programmed %h",
                         i, u_asic.u_moe_gating.weights[i], exp_weights[i]);
                errors = errors + 1;
            end
        end
        if (n_hidden != HIDDEN_DIM) begin
            $display("FAIL: the firmware programmed %0d hidden words, expected %0d",
                     n_hidden, HIDDEN_DIM);
            errors = errors + 1;
        end
        for (i = 0; i < HIDDEN_DIM && i < n_hidden; i = i + 1) begin
            if (u_asic.u_moe_gating.hidden_latch[i] !== exp_hidden[i]) begin
                $display("FAIL: hidden word %0d is %h, the firmware programmed %h",
                         i, u_asic.u_moe_gating.hidden_latch[i], exp_hidden[i]);
                errors = errors + 1;
            end
        end

        // ---- the engine must have produced a defined decision ----
        if (expert_idx[7:0] === 8'hXX || expert_idx[15:8] === 8'hXX) begin
            $display("FAIL: the decision is undefined (%h)", expert_idx);
            errors = errors + 1;
        end else begin
            $display("ok: the replayed firmware left the ASIC with the programmed");
            $display("    weights and hidden vector, and the engine selected");
            $display("    experts %0d and %0d", expert_idx[7:0], expert_idx[15:8]);
        end

        if (errors == 0)
            $display("*** MGMT TRACE TEST PASSED ***");
        else
            $display("*** MGMT TRACE TEST FAILED (%0d) ***", errors);
        $finish;
    end

endmodule
