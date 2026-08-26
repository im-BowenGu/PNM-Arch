`timescale 1ns/1ps

// =============================================================================
// lpddr5x_phy — LPDDR5X LPCAMM2 PHY controller
//
// Behavioral model of the LPDDR5X physical-layer interface for LPCAMM2
// modules. LPDDR5X improves on LPDDR5 with:
//   - Higher data rate: 8533 MT/s (vs 6400 MT/s)
//   - Reduced CAS latency: 14 (vs 16)
//   - Tighter timing parameters (T_RCD, T_RP, T_RAS reduced)
//   - Same 4-bank architecture
//
// Bus interface follows the same valid/ready handshake as lpddr6_camm.v
// and sodimm_ctrl.v: bus_valid → accept → CAS wait → bus_rdv.
// =============================================================================

module lpddr5x_phy #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter MEM_DEPTH      = 4096,
    parameter CAS_LATENCY    = 14,
    parameter REFRESH_CYCLES = 3500,
    parameter REFRESH_BURST  = 8,
    parameter NUM_BANKS      = 4,
    parameter T_RCD          = 3,
    parameter T_RP           = 2,
    parameter T_RAS          = 7,
    parameter T_RFC          = 10,
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

    // Bank state
    reg        bank_row_open [0:NUM_BANKS-1];
    reg [31:0] bank_row      [0:NUM_BANKS-1];
    reg [3:0]  ras_countdown [0:NUM_BANKS-1];
    reg [3:0]  rp_timer      [0:NUM_BANKS-1];

    // FSM states
    localparam ST_IDLE     = 3'd0;
    localparam ST_WAIT_RAS = 3'd1;
    localparam ST_RCD      = 3'd2;
    localparam ST_CAS      = 3'd3;
    localparam ST_DONE     = 3'd4;

    reg [2:0]  state;
    reg [3:0]  cas_cnt;
    reg [3:0]  ras_cnt;
    reg [1:0]  active_bank;
    reg [31:0] active_row;
    reg        active_we;
    reg [31:0] active_addr;
    reg [31:0] active_wdata;

    // Refresh
    reg [15:0] refresh_timer;
    reg        refresh_pending;
    reg [3:0]  refresh_burst_cnt;

    wire [1:0] bank_idx = bus_addr[13:12];

    assign dram_busy = (state != ST_IDLE) || refresh_pending;
    assign topology_rdy    = rst_n;
    assign doorbell_ack_out = doorbell_trig_in;
    assign node_err        = 1'b0;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            bus_ready         <= 1'b1;
            bus_rdv           <= 1'b0;
            bus_resp          <= 1'b0;
            bus_rdata         <= 32'h0;
            cas_cnt           <= 4'h0;
            ras_cnt           <= 4'h0;
            active_bank       <= 2'h0;
            active_row        <= 32'h0;
            active_we         <= 1'b0;
            active_addr       <= 32'h0;
            active_wdata      <= 32'h0;
            read_cnt          <= 32'h0;
            write_cnt         <= 32'h0;
            refresh_cnt       <= 32'h0;
            refresh_timer     <= REFRESH_CYCLES[15:0];
            refresh_pending   <= 1'b0;
            refresh_burst_cnt <= 4'h0;
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                bank_row_open[i] <= 1'b0;
                bank_row[i]      <= 32'h0;
                ras_countdown[i] <= 4'h0;
                rp_timer[i]      <= 4'h0;
            end
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

            // Bank timers
            for (i = 0; i < NUM_BANKS; i = i + 1) begin
                if (ras_countdown[i] > 0)
                    ras_countdown[i] <= ras_countdown[i] - 1;
                if (rp_timer[i] > 0)
                    rp_timer[i] <= rp_timer[i] - 1;
            end

            bus_rdv  <= 1'b0;
            bus_resp <= 1'b0;

            case (state)
                ST_IDLE: begin
                    bus_ready <= 1'b1;
                    if (bus_valid && !refresh_pending) begin
                        bus_ready <= 1'b0;
                        active_bank  <= bank_idx;
                        active_row   <= {18'h0, bus_addr[13:0]};
                        active_we    <= bus_we;
                        active_addr  <= bus_addr;
                        active_wdata <= bus_wdata;

                        if (!bank_row_open[bank_idx] ||
                            bank_row[bank_idx] != {18'h0, bus_addr[13:0]}) begin
                            state  <= ST_WAIT_RAS;
                            ras_cnt <= T_RCD[3:0];
                        end else begin
                            state   <= ST_CAS;
                            cas_cnt <= CAS_LATENCY[3:0];
                        end
                    end
                end

                ST_WAIT_RAS: begin
                    if (ras_cnt > 0)
                        ras_cnt <= ras_cnt - 1;
                    else begin
                        bank_row_open[active_bank] <= 1'b1;
                        bank_row[active_bank]      <= active_row;
                        ras_countdown[active_bank]  <= T_RAS[3:0];
                        state  <= ST_RCD;
                        ras_cnt <= T_RCD[3:0];
                    end
                end

                ST_RCD: begin
                    if (ras_cnt > 0)
                        ras_cnt <= ras_cnt - 1;
                    else begin
                        bank_row_open[active_bank] <= 1'b1;
                        bank_row[active_bank]      <= active_row;
                        ras_countdown[active_bank]  <= T_RAS[3:0];
                        state   <= ST_CAS;
                        cas_cnt <= CAS_LATENCY[3:0];
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
