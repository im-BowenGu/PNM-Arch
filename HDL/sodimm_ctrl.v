`include "pnm_defs.vh"

module sodimm_ctrl #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter MEM_DEPTH      = 4096,
    parameter NUM_BANKS      = 4,
    parameter COL_BITS       = 3,
    parameter CAS_LATENCY    = 15,
    parameter T_RCD          = 15,
    parameter T_RP           = 15,
    parameter T_RAS          = 38,
    parameter T_RFC          = 64,
    parameter REFRESH_CYCLES = 780,
    parameter REFRESH_BURST  = 8,
    parameter MODULE_ID      = 8'h00
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [ADDR_WIDTH-1:0]  bus_addr,
    input  wire [DATA_WIDTH-1:0]  bus_wdata,
    output reg  [DATA_WIDTH-1:0]  bus_rdata,
    input  wire                   bus_we,
    input  wire [DATA_WIDTH/8-1:0] bus_be,
    input  wire                   bus_valid,
    output reg                    bus_ready,
    output reg                    bus_rdv,
    output reg                    bus_resp,

    output wire                   dram_busy,
    output wire [31:0]            dram_read_count,
    output wire [31:0]            dram_write_count,
    output wire [31:0]            dram_refresh_count,

    input  wire                   doorbell_trig_in,
    output wire                   doorbell_ack_out,
    output wire                   node_err,
    output wire                   topology_rdy
);

    localparam WORD_BITS = $clog2(MEM_DEPTH);
    localparam BANK_BITS = $clog2(NUM_BANKS);
    localparam ROW_BITS  = WORD_BITS - COL_BITS - BANK_BITS;

    localparam ST_IDLE     = 3'd0,
               ST_WAIT_RAS = 3'd1,
               ST_PRE      = 3'd2,
               ST_RCD      = 3'd3,
               ST_CAS      = 3'd4;

    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    reg  [2:0]  st;
    reg  [7:0]  cnt;
    reg         cmd_we_r;
    reg         cmd_hit_r;
    reg  [ADDR_WIDTH-1:0]  cmd_addr_r;
    reg  [DATA_WIDTH-1:0]  cmd_wdata_r;
    reg  [DATA_WIDTH/8-1:0] cmd_be_r;
    reg  [BANK_BITS-1:0]   cmd_bank_r;

    reg [NUM_BANKS-1:0] bank_open;
    reg [ROW_BITS-1:0]  bank_row [0:NUM_BANKS-1];
    reg [7:0]           ras_cnt  [0:NUM_BANKS-1];

    reg [31:0] refresh_cnt;
    reg        refresh_pending;
    reg [7:0]  refresh_burst_cnt;

    reg [31:0] rd_count, wr_count, ref_count;

    wire [WORD_BITS-1:0] acc_word = bus_addr[WORD_BITS+1:2];
    wire [BANK_BITS-1:0] acc_bank = acc_word[COL_BITS+BANK_BITS-1:COL_BITS];
    wire [ROW_BITS-1:0]  acc_row  = acc_word[WORD_BITS-1:COL_BITS+BANK_BITS];

    wire [WORD_BITS-1:0] cmd_word = cmd_addr_r[WORD_BITS+1:2];
    wire [ROW_BITS-1:0]  cmd_row  = cmd_word[WORD_BITS-1:COL_BITS+BANK_BITS];

    wire ref_start_now = !refresh_pending && (refresh_cnt == 32'd0) &&
                         (st == ST_IDLE) && !(bus_valid && bus_ready);
    wire ref_block     = refresh_pending || ref_start_now;

    assign topology_rdy       = rst_n;
    assign doorbell_ack_out   = doorbell_trig_in;
    assign node_err           = 1'b0;
    assign dram_busy          = (st != ST_IDLE) || refresh_pending;
    assign dram_read_count    = rd_count;
    assign dram_write_count   = wr_count;
    assign dram_refresh_count = ref_count;

    integer bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (bi = 0; bi < NUM_BANKS; bi = bi + 1) begin
                bank_open[bi] <= 1'b0;
                bank_row[bi]  <= {ROW_BITS{1'b0}};
                ras_cnt[bi]   <= 8'h0;
            end
        end else begin
            for (bi = 0; bi < NUM_BANKS; bi = bi + 1)
                if (ras_cnt[bi] > 0)
                    ras_cnt[bi] <= ras_cnt[bi] - 8'd1;
            if (refresh_pending)
                for (bi = 0; bi < NUM_BANKS; bi = bi + 1)
                    bank_open[bi] <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st                <= ST_IDLE;
            cnt               <= 8'h0;
            cmd_we_r          <= 1'b0;
            cmd_hit_r         <= 1'b0;
            cmd_addr_r        <= {ADDR_WIDTH{1'b0}};
            cmd_wdata_r       <= {DATA_WIDTH{1'b0}};
            cmd_be_r          <= {(DATA_WIDTH/8){1'b0}};
            cmd_bank_r        <= {BANK_BITS{1'b0}};
            bus_ready         <= 1'b1;
            bus_rdv           <= 1'b0;
            bus_resp          <= 1'b0;
            bus_rdata         <= {DATA_WIDTH{1'b0}};
            refresh_cnt       <= REFRESH_CYCLES;
            refresh_pending   <= 1'b0;
            refresh_burst_cnt <= 8'h0;
            rd_count          <= 32'h0;
            wr_count          <= 32'h0;
            ref_count         <= 32'h0;
        end else begin
            bus_rdv  <= 1'b0;
            bus_resp <= 1'b0;

            if (refresh_pending) begin
                if (refresh_burst_cnt > 0)
                    refresh_burst_cnt <= refresh_burst_cnt - 8'd1;
                else begin
                    refresh_pending <= 1'b0;
                    refresh_cnt     <= REFRESH_CYCLES;
                    ref_count       <= ref_count + 32'd1;
                end
            end else if (refresh_cnt > 0)
                refresh_cnt <= refresh_cnt - 32'd1;
            else if (st == ST_IDLE && !(bus_valid && bus_ready)) begin
                refresh_pending   <= 1'b1;
                refresh_burst_cnt <= REFRESH_BURST[7:0];
            end

            case (st)
                ST_IDLE: begin
                    if (st == ST_IDLE)
                        bus_ready <= !ref_block;
                    if (bus_valid && bus_ready && !ref_block) begin
                        cmd_addr_r <= bus_addr;
                        cmd_wdata_r<= bus_wdata;
                        cmd_we_r   <= bus_we;
                        cmd_be_r   <= bus_be;
                        cmd_bank_r <= acc_bank;
                        cmd_hit_r  <= ((bus_addr >> 2) < MEM_DEPTH);
                        bus_ready  <= 1'b0;
                        if (!((bus_addr >> 2) < MEM_DEPTH)) begin
                            st  <= ST_CAS;
                            cnt <= 8'd1;
                        end else if (bank_open[acc_bank]) begin
                            if (bank_row[acc_bank] == acc_row) begin
                                st  <= ST_CAS;
                                cnt <= CAS_LATENCY[7:0];
                            end else if (ras_cnt[acc_bank] > 8'd0) begin
                                st  <= ST_WAIT_RAS;
                                cnt <= ras_cnt[acc_bank];
                            end else begin
                                st  <= ST_PRE;
                                cnt <= T_RP[7:0];
                            end
                        end else begin
                            st  <= ST_RCD;
                            cnt <= T_RCD[7:0];
                        end
                    end
                end

                ST_WAIT_RAS: begin
                    if (cnt > 8'd0)
                        cnt <= cnt - 8'd1;
                    else begin
                        st  <= ST_PRE;
                        cnt <= T_RP[7:0];
                    end
                end

                ST_PRE: begin
                    if (cnt > 8'd0)
                        cnt <= cnt - 8'd1;
                    else begin
                        st  <= ST_RCD;
                        cnt <= T_RCD[7:0];
                    end
                end

                ST_RCD: begin
                    if (cnt > 8'd0)
                        cnt <= cnt - 8'd1;
                    else begin
                        st  <= ST_CAS;
                        cnt <= CAS_LATENCY[7:0];
                        ras_cnt[cmd_bank_r] <= T_RAS[7:0];
                        if (cmd_hit_r) begin
                            bank_open[cmd_bank_r] <= 1'b1;
                            bank_row[cmd_bank_r]  <= cmd_row;
                        end
                    end
                end

                ST_CAS: begin
                    if (cnt > 8'd0) begin
                        cnt <= cnt - 8'd1;
                        if (!cmd_we_r && cnt == 8'd1 && cmd_hit_r)
                            bus_rdata <= mem[cmd_word];
                    end else begin
                        st        <= ST_IDLE;
                        bus_ready <= 1'b1;
                        bus_rdv   <= !cmd_we_r;
                        bus_resp  <= 1'b1;
                        if (cmd_we_r)
                            wr_count <= wr_count + 32'd1;
                        else
                            rd_count <= rd_count + 32'd1;
                    end
                end

                default: begin
                    st        <= ST_IDLE;
                    bus_ready <= 1'b1;
                end
            endcase
        end
    end

    integer lane;
    always @(posedge clk) begin
        if (st == ST_CAS && cnt == 8'd0 && cmd_we_r && cmd_hit_r)
            for (lane = 0; lane < DATA_WIDTH/8; lane = lane + 1)
                if (cmd_be_r[lane])
                    mem[cmd_word][lane*8 +: 8] <= cmd_wdata_r[lane*8 +: 8];
    end

endmodule
