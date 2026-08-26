`timescale 1ns/1ps

// =============================================================================
// lpddr6_phy — LPDDR6 LPCAMM2 PHY controller
//
// Behavioral model of the LPDDR6 physical-layer interface for LPCAMM2
// modules. LPDDR6 is the newest DRAM generation with:
//   - Data rate: 12800 MT/s (DDR, 6400 MHz effective)
//   - CAS latency: 4 (significantly reduced from LPDDR5X's 14)
//   - Flat bank model (single-address space, no row/bank decomposition)
//   - Sub-ns refresh with fine-granularity scheduling
//
// This is the simplest of the three LPCAMM2 PHY models: LPDDR6's
// architecture eliminates the row/bank hierarchy in favor of a flat
// address space, reducing the FSM to CAS-wait + refresh scheduling.
//
// Bus interface follows the same valid/ready handshake as lpddr6_camm.v
// and sodimm_ctrl.v: bus_valid → accept → CAS wait → bus_rdv.
// =============================================================================

module lpddr6_phy #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter MEM_DEPTH      = 4096,
    parameter CAS_LATENCY    = 4,
    parameter REFRESH_CYCLES = 3900,
    parameter REFRESH_BURST  = 4,
    parameter MODULE_ID      = 8'h00
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // CPU bus (active-high valid/ready handshake)
    input  wire [ADDR_WIDTH-1:0]  bus_addr,
    input  wire [DATA_WIDTH-1:0]  bus_wdata,
    output reg  [DATA_WIDTH-1:0]  bus_rdata,
    input  wire                   bus_we,
    input  wire [DATA_WIDTH/8-1:0] bus_be,
    input  wire                   bus_valid,
    output reg                    bus_ready,
    output reg                    bus_rdv,
    output reg                    bus_resp,

    // DRAM telemetry
    output wire                   dram_busy,
    output wire [31:0]            dram_read_count,
    output wire [31:0]            dram_write_count,
    output wire [31:0]            dram_refresh_count,

    // Node/network sideband
    input  wire                   doorbell_trig_in,
    output wire                   doorbell_ack_out,
    output wire                   node_err,
    output wire                   topology_rdy
);

    // Telemetry counters
    reg [31:0] read_cnt;
    reg [31:0] write_cnt;
    reg [31:0] refresh_cnt;

    assign dram_read_count  = read_cnt;
    assign dram_write_count = write_cnt;
    assign dram_refresh_count = refresh_cnt;

    // FSM states (flat — no row/bank hierarchy)
    localparam ST_IDLE     = 2'd0;
    localparam ST_CAS      = 2'd1;
    localparam ST_REFRESH  = 2'd2;
    localparam ST_DONE     = 2'd3;

    reg [1:0]  state;
    reg [3:0]  cas_cnt;
    reg        active_we;
    reg [31:0] active_addr;
    reg [31:0] active_wdata;

    // Refresh
    reg [15:0] refresh_timer;
    reg        refresh_pending;
    reg [3:0]  refresh_burst_cnt;

    assign dram_busy = (state != ST_IDLE) || refresh_pending;
    assign topology_rdy    = rst_n;
    assign doorbell_ack_out = doorbell_trig_in;
    assign node_err        = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            bus_ready         <= 1'b1;
            bus_rdv           <= 1'b0;
            bus_resp          <= 1'b0;
            bus_rdata         <= 32'h0;
            cas_cnt           <= 4'h0;
            active_we         <= 1'b0;
            active_addr       <= 32'h0;
            active_wdata      <= 32'h0;
            read_cnt          <= 32'h0;
            write_cnt         <= 32'h0;
            refresh_cnt       <= 32'h0;
            refresh_timer     <= REFRESH_CYCLES[15:0];
            refresh_pending   <= 1'b0;
            refresh_burst_cnt <= 4'h0;
        end else begin
            // Refresh timer
            if (refresh_timer == 0) begin
                refresh_pending <= 1'b1;
                refresh_timer  <= REFRESH_CYCLES[15:0];
            end else if (!refresh_pending) begin
                refresh_timer <= refresh_timer - 1;
            end

            // Refresh burst
            if (refresh_pending && refresh_burst_cnt > 0) begin
                refresh_burst_cnt <= refresh_burst_cnt - 1;
                refresh_cnt       <= refresh_cnt + 1;
                if (refresh_burst_cnt == 1)
                    refresh_pending <= 1'b0;
            end else if (refresh_pending && refresh_burst_cnt == 0) begin
                refresh_burst_cnt <= REFRESH_BURST[3:0];
            end

            bus_rdv  <= 1'b0;
            bus_resp <= 1'b0;

            case (state)
                ST_IDLE: begin
                    bus_ready <= 1'b1;
                    if (bus_valid && !refresh_pending) begin
                        bus_ready  <= 1'b0;
                        active_we  <= bus_we;
                        active_addr<= bus_addr;
                        active_wdata<= bus_wdata;
                        state      <= ST_CAS;
                        cas_cnt    <= CAS_LATENCY[3:0];
                    end else if (refresh_pending) begin
                        bus_ready <= 1'b0;
                        state     <= ST_REFRESH;
                    end
                end

                ST_CAS: begin
                    if (cas_cnt > 0)
                        cas_cnt <= cas_cnt - 1;
                    else begin
                        if (!active_we) begin
                            bus_rdata <= mem_read(active_addr);
                            read_cnt  <= read_cnt + 1;
                        end else begin
                            mem_write(active_addr, active_wdata);
                            write_cnt <= write_cnt + 1;
                        end
                        bus_rdv  <= 1'b1;
                        bus_resp <= 1'b1;
                        state    <= ST_DONE;
                    end
                end

                ST_REFRESH: begin
                    if (refresh_burst_cnt == 0 && !refresh_pending) begin
                        state <= ST_IDLE;
                    end
                end

                ST_DONE: begin
                    bus_rdv  <= 1'b0;
                    bus_resp <= 1'b0;
                    bus_ready<= 1'b1;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // Behavioral memory array
    reg [31:0] mem [0:MEM_DEPTH-1];

    function [31:0] mem_read;
        input [31:0] addr;
        begin
            if ({20'b0, addr[$clog2(MEM_DEPTH)+1:2]} < MEM_DEPTH)
                mem_read = mem[addr[$clog2(MEM_DEPTH)+1:2]];
            else
                mem_read = 32'hDEAD_BEEF;
        end
    endfunction

    task mem_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            if ({20'b0, addr[$clog2(MEM_DEPTH)+1:2]} < MEM_DEPTH)
                mem[addr[$clog2(MEM_DEPTH)+1:2]] <= data;
        end
    endtask

endmodule
