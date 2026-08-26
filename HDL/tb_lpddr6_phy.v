`timescale 1ns/1ps

// =============================================================================
// tb_lpddr6_phy — Self-checking testbench for LPDDR6 PHY controller
// =============================================================================

module tb_lpddr6_phy;

    reg         clk;
    reg         rst_n;
    reg  [31:0] bus_addr;
    reg  [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    reg         bus_we;
    reg  [3:0]  bus_be;
    reg         bus_valid;
    wire        bus_ready;
    wire        bus_rdv;
    wire        bus_resp;
    wire        dram_busy;
    wire [31:0] dram_read_count;
    wire [31:0] dram_write_count;
    wire [31:0] dram_refresh_count;
    reg         doorbell_trig;
    wire        doorbell_ack;
    wire        node_err;
    wire        topology_rdy;

    lpddr6_phy #(
        .MEM_DEPTH(256),
        .CAS_LATENCY(2),
        .REFRESH_CYCLES(100)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_we(bus_we), .bus_be(bus_be), .bus_valid(bus_valid),
        .bus_ready(bus_ready), .bus_rdv(bus_rdv), .bus_resp(bus_resp),
        .dram_busy(dram_busy),
        .dram_read_count(dram_read_count),
        .dram_write_count(dram_write_count),
        .dram_refresh_count(dram_refresh_count),
        .doorbell_trig_in(doorbell_trig),
        .doorbell_ack_out(doorbell_ack),
        .node_err(node_err), .topology_rdy(topology_rdy)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors;
    task automatic wait_ready;
        begin
            repeat(50) @(posedge clk);
            if (!bus_ready) repeat(50) @(posedge clk);
        end
    endtask

    task automatic write_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            bus_addr  <= addr; bus_wdata <= data;
            bus_we <= 1'b1; bus_be <= 4'hF; bus_valid <= 1'b1;
            @(posedge clk);
            while (!bus_ready) @(posedge clk);
            bus_valid <= 1'b0;
            wait_ready;
        end
    endtask

    task automatic read_word;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            bus_addr <= addr; bus_we <= 1'b0; bus_be <= 4'hF; bus_valid <= 1'b1;
            @(posedge clk);
            while (!bus_ready) @(posedge clk);
            bus_valid <= 1'b0;
            @(posedge clk);
            while (!bus_rdv) @(posedge clk);
            data = bus_rdata;
            wait_ready;
        end
    endtask

    reg [31:0] rdata;
    initial begin
        $dumpfile("lpddr6_phy.vcd");
        $dumpvars(0, tb_lpddr6_phy);
        errors = 0;
        rst_n = 0;
        bus_addr = 0; bus_wdata = 0; bus_we = 0;
        bus_be = 0; bus_valid = 0; doorbell_trig = 0;
        repeat(5) @(posedge clk);
        rst_n = 1; repeat(5) @(posedge clk);

        // Test 1: Write/read basic (flat address, CL4)
        $display("Test 1: Write/read basic");
        write_word(32'h00000000, 32'hFEED_FACE);
        read_word(32'h00000000, rdata);
        if (rdata !== 32'hFEED_FACE) begin
            $display("  FAIL: got %h", rdata); errors = errors + 1;
        end else $display("  OK: %h", rdata);

        // Test 2: Multiple addresses
        $display("Test 2: Multi-address");
        write_word(32'h00000010, 32'hAABB_CCDD);
        write_word(32'h00000020, 32'h1122_3344);
        read_word(32'h00000010, rdata);
        if (rdata !== 32'hAABB_CCDD) begin
            $display("  FAIL addr 0x10: got %h", rdata); errors = errors + 1;
        end else $display("  OK: %h", rdata);
        read_word(32'h00000020, rdata);
        if (rdata !== 32'h1122_3344) begin
            $display("  FAIL addr 0x20: got %h", rdata); errors = errors + 1;
        end else $display("  OK: %h", rdata);

        // Test 3: Telemetry
        $display("Test 3: Telemetry");
        if (dram_read_count < 2 || dram_write_count < 2) begin
            $display("  FAIL: reads=%0d writes=%0d", dram_read_count, dram_write_count);
            errors = errors + 1;
        end else $display("  OK: reads=%0d writes=%0d", dram_read_count, dram_write_count);

        if (errors == 0)
            $display("*** LPDDR6 PHY TEST PASSED ***");
        else begin
            $display("*** LPDDR6 PHY TEST FAILED (%0d errors) ***", errors);
            $finish(1);
        end
        $finish;
    end

endmodule
