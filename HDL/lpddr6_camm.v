`include "pnm_defs.vh"

// =============================================================================
// lpddr6_camm — Behavioral LPCAMM2 / LPDDR6 CAMM2 memory module model
//
// Models a JEDEC LPCAMM2 (JESD318) / LPDDR6 CAMM2 module as a banked
// behavioral array with configurable CAS latency and refresh overhead.
// Designed to sit on the motherboard next to a DUV MAC ASIC or orchestrator
// chip and respond to memory controller commands.
//
// Bus interface is compatible with the CPU bus used by bmc_orchestrator_top,
// orchestrator_sbc, and orchestrator_sbc_moe: address + write-data + byte-enable +
// valid/ready handshake.  The controller inside the orchestrator chip drives
// this interface; the model responds with read data after CAS latency.
//
// Handshake contract: bus_ready deasserts when a command is accepted;
// it reasserts when the operation fully completes (write committed or
// read data stable on bus_rdata).
//
// For simulation only — not synthesizable.
// =============================================================================

module lpddr6_camm #(
    parameter ADDR_WIDTH    = 32,
    parameter DATA_WIDTH    = 32,
    parameter MEM_DEPTH     = 4096,
    parameter CAS_LATENCY   = 4,
    parameter REFRESH_CYCLES= 1024,
    parameter REFRESH_BURST = 8,
    parameter MODULE_ID     = 8'h00
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [ADDR_WIDTH-1:0] bus_addr,
    input  wire [DATA_WIDTH-1:0] bus_wdata,
    output reg  [DATA_WIDTH-1:0] bus_rdata,
    input  wire                  bus_we,
    input  wire [DATA_WIDTH/8-1:0] bus_be,
    input  wire                  bus_valid,
    output reg                   bus_ready,
    output reg                   bus_rdv,
    output reg                   bus_resp,

    output wire                  dram_busy,
    output wire [31:0]           dram_read_count,
    output wire [31:0]           dram_write_count,
    output wire [31:0]           dram_refresh_count,

    input  wire                  doorbell_trig_in,
    output wire                  doorbell_ack_out,
    output wire                  node_err,
    output wire                  topology_rdy
);

    reg [31:0] mem [0:MEM_DEPTH-1];

    reg        cmd_pending;
    reg        cmd_we_r;
    reg        cmd_hit_r;
    reg [ADDR_WIDTH-1:0] cmd_addr_r;
    reg [DATA_WIDTH-1:0] cmd_wdata_r;
    reg [DATA_WIDTH/8-1:0] cmd_be_r;
    reg [7:0]  cmd_wait;

    wire [$clog2(MEM_DEPTH)-1:0] cmd_word_idx =
        cmd_addr_r[$clog2(MEM_DEPTH)-1+2:2];

    reg [31:0] refresh_cnt;
    reg        refresh_pending;
    reg [7:0]  refresh_burst_cnt;

    reg [31:0] rd_count, wr_count, ref_count;

    assign topology_rdy     = rst_n;
    assign doorbell_ack_out = doorbell_trig_in;
    assign node_err         = 1'b0;

    assign dram_busy = cmd_pending || refresh_pending;
    assign dram_read_count  = rd_count;
    assign dram_write_count = wr_count;
    assign dram_refresh_count = ref_count;

    // =========================================================================
    // Refresh scheduler
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt <= REFRESH_CYCLES;
            refresh_pending <= 1'b0;
            refresh_burst_cnt <= 8'h0;
            ref_count <= 32'h0;
        end else begin
            if (refresh_pending) begin
                if (refresh_burst_cnt > 0)
                    refresh_burst_cnt <= refresh_burst_cnt - 1;
                else begin
                    refresh_pending <= 1'b0;
                    refresh_cnt <= REFRESH_CYCLES;
                    ref_count <= ref_count + 1;
                end
            end else if (refresh_cnt > 0)
                refresh_cnt <= refresh_cnt - 1;
            else begin
                refresh_pending <= 1'b1;
                refresh_burst_cnt <= REFRESH_BURST[7:0];
            end
        end
    end

    // =========================================================================
    // Bus interface FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_ready     <= 1'b1;
            bus_rdv       <= 1'b0;
            bus_resp      <= 1'b0;
            bus_rdata     <= {DATA_WIDTH{1'b0}};
            cmd_pending   <= 1'b0;
            cmd_we_r      <= 1'b0;
            cmd_hit_r     <= 1'b0;
            cmd_addr_r    <= {ADDR_WIDTH{1'b0}};
            cmd_wdata_r   <= {DATA_WIDTH{1'b0}};
            cmd_wait      <= 8'h0;
            rd_count      <= 32'h0;
            wr_count      <= 32'h0;
        end else begin
            if (cmd_pending) begin
                if (cmd_wait > 0) begin
                    cmd_wait <= cmd_wait - 1;
                    if (!cmd_we_r && cmd_wait == 1 && cmd_hit_r) begin
                        // Load read data one cycle before ready asserts
                        bus_rdata <= mem[cmd_word_idx];
                    end
                end else begin
                    cmd_pending <= 1'b0;
                    bus_rdv     <= !cmd_we_r;
                    bus_resp    <= 1'b1;
                    bus_ready   <= 1'b1;
                    if (cmd_we_r) begin
                        wr_count <= wr_count + 1;
                    end else begin
                        rd_count <= rd_count + 1;
                    end
                end
            end else begin
                bus_rdv   <= 1'b0;
                bus_resp  <= 1'b0;
                if (bus_valid && bus_ready) begin
                    cmd_addr_r  <= bus_addr;
                    cmd_wdata_r <= bus_wdata;
                    cmd_be_r    <= (bus_we) ? bus_be : {DATA_WIDTH/8{1'b1}};
                    cmd_we_r    <= bus_we;
                    cmd_hit_r   <= ((bus_addr >> 2) < MEM_DEPTH);
                    cmd_pending <= 1'b1;
                    cmd_wait    <= (bus_we) ? 8'd1 : CAS_LATENCY[7:0];
                    bus_ready   <= 1'b0;
                end
            end
        end
    end

    // Write commit (separate block so memory write happens at completion).
    // Byte-enables from the accepted command mask the committed lanes; a
    // partial-word write leaves the remaining bytes untouched.
    integer be_i;
    always @(posedge clk) begin
        if (cmd_pending && cmd_we_r && cmd_wait == 0 && cmd_hit_r) begin
            for (be_i = 0; be_i < DATA_WIDTH/8; be_i = be_i + 1) begin
                if (cmd_be_r[be_i])
                    mem[cmd_word_idx][be_i*8 +: 8] <= cmd_wdata_r[be_i*8 +: 8];
            end
        end
    end

endmodule
