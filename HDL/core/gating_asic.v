`timescale 1ns/1ps

module gating_asic #(
    parameter NUM_EXPERTS   = 128,
    parameter HIDDEN_DIM    = 64,
    parameter TOP_K         = 8,
    parameter ADDR_BITS     = 10,
    parameter ARRAY_SIZE    = 16,
    parameter PIPE_DEPTH    = 3,
    parameter WEIGHT_DEPTH  = 1024,
    parameter HIDDEN_DEPTH  = 256
)(
    input  wire        clk,
    input  wire        rst_n,

    // Register-mapped bus from the chip (active-high valid/ready)
    input  wire [15:0] bus_addr,
    input  wire [15:0] bus_wdata,
    output wire [15:0] bus_rdata,
    input  wire        bus_we,
    input  wire        bus_valid,
    output reg         bus_ready,

    // ---------------------------------------------------------------------
    // Management modes
    //
    // The gating ASIC is managed from one of two places:
    //
    //   mode A (mgmt_sel = 1) — the *embedded management node* on this node
    //     board (an MCU or a Raspberry Pi Compute Module) drives the register
    //     bus directly.  It also owns the node's memory, so it can stage the
    //     gating weights and read the token's hidden state locally: the
    //     per-token decision never leaves the board.
    //
    //   mode B (mgmt_sel = 0) — the *host* owns the machine.  The host's
    //     programming stream arrives over the fabric and is decoded by the
    //     fabric receiver below; the chip's local bus is idle.
    //
    // mgmt_sel is a strapping pin (the board's mode jumper), so the two modes
    // are the same silicon with a different manager.
    // ---------------------------------------------------------------------
    input  wire        mgmt_sel,        // 1 = the embedded management node
    input  wire [15:0] mgmt_addr,
    input  wire [15:0] mgmt_wdata,
    output wire [15:0] mgmt_rdata,
    input  wire        mgmt_we,
    input  wire        mgmt_valid,
    output reg         mgmt_ready,

    // Fabric-side programming stream (mode B): the host's bytes, addressed at
    // this node's coordinate, decoded into the same register map.
    input  wire [7:0]  prog_data,
    input  wire        prog_valid,
    input  wire        prog_sop,
    input  wire        prog_eop,

    // Top-K expert results (direct to orchestrator)
    output wire [TOP_K*8-1:0]  expert_idx,
    output wire [TOP_K*16-1:0] expert_logit,
    output wire [TOP_K*8-1:0]  expert_layer,
    output wire [TOP_K*8-1:0]  expert_module,
    output wire                 result_valid,

    // Status
    output wire        busy,
    output wire        done,
    output wire [31:0] cycle_count
);

    // ---------------------------------------------------------------
    // Register map (active-high active, byte offset from base)
    //   0x00  CTRL         [0]=start [1]=soft_reset
    //   0x02  STATUS       [0]=busy [1]=done [2]=fma_busy
    //   0x04  CYCLE_LO / 0x06 CYCLE_HI
    //   0x08  CFG_EXPERTS / 0x0A CFG_HIDDEN / 0x0C CFG_TOPK / 0x0E CFG_ARRAY
    //   0x10  WGHT_ADDR_LO (weight SRAM write address, low 16)
    //   0x11  WGHT_ADDR_HI (high 16)
    //   0x12  WGHT_DATA    (weight SRAM write data, BF16; asserting this
    //                       register performs the actual SRAM write)
    //   0x14  HIDDEN_ADDR_LO / 0x15 HIDDEN_ADDR_HI
    //   0x16  HIDDEN_DATA   (hidden SRAM write data, BF16)
    //   0x18  COORD_LAYER   (layer coordinate input, also latched to weights
    //                       being loaded)
    //   0x1A  COORD_MODULE
    //   0x20  RESULT_IDX0 / 0x22 RESULT_IDX1
    //   0x24  RESULT_LOGIT0 / 0x26 RESULT_LOGIT1
    //   0x30+ 2*e           LOGIT[e] (read-only, all NUM_EXPERTS logits)
    localparam [15:0] REG_CTRL      = 16'h0000;
    localparam [15:0] REG_STATUS    = 16'h0002;
    localparam [15:0] REG_CYCLE_LO  = 16'h0004;
    localparam [15:0] REG_CYCLE_HI  = 16'h0006;
    localparam [15:0] REG_CFG_EXP   = 16'h0008;
    localparam [15:0] REG_CFG_HID   = 16'h000A;
    localparam [15:0] REG_CFG_TOPK  = 16'h000C;
    localparam [15:0] REG_CFG_ARR   = 16'h000E;
    localparam [15:0] REG_WGHT_ADDR_LO = 16'h0010;
    localparam [15:0] REG_WGHT_ADDR_HI = 16'h0011;
    localparam [15:0] REG_WGHT_DATA    = 16'h0012;
    localparam [15:0] REG_HID_ADDR_LO  = 16'h0014;
    localparam [15:0] REG_HID_ADDR_HI  = 16'h0015;
    localparam [15:0] REG_HID_DATA     = 16'h0016;
    localparam [15:0] REG_COORD_L   = 16'h0018;
    localparam [15:0] REG_COORD_M   = 16'h001A;
    localparam [15:0] REG_RES_IDX0  = 16'h0020;
    localparam [15:0] REG_RES_IDX1  = 16'h0022;
    localparam [15:0] REG_RES_LOG0  = 16'h0024;
    localparam [15:0] REG_RES_LOG1  = 16'h0026;
    localparam [15:0] REG_LOGIT     = 16'h0030;

    // ---------------------------------------------------------------
    // Control / status registers
    // ---------------------------------------------------------------
    reg        ctrl_start;
    reg        ctrl_soft_reset;
    reg [31:0] cycle_counter;
    reg [7:0]  current_layer;
    reg [7:0]  current_module;

    // ---------------------------------------------------------------
    // Weight SRAM write port (bus -> moe_gating weight_load interface).
    // Addresses are assembled from two 16-bit bus writes into a 32-bit
    // word; moe_gating only sees ADDR_BITS of it.
    // ---------------------------------------------------------------
    reg  [15:0]          wght_waddr_lo;
    reg  [15:0]          wght_waddr_hi;
    reg  [15:0]          wght_wdata;
    reg                  wght_we;           // registered pulse on WGHT_DATA
    reg                  wght_incr;         // auto-increment request

    // ---------------------------------------------------------------
    // Hidden SRAM write port (written by orchestrator bus)
    // ---------------------------------------------------------------
    reg  [15:0]          hidden_waddr_lo;
    reg  [15:0]          hidden_waddr_hi;
    reg  [15:0]          hidden_wdata;
    reg                  hidden_we;
    reg                  hidden_incr;

    wire [31:0] wght_waddr = {wght_waddr_hi, wght_waddr_lo};
    wire [31:0] hidden_waddr = {hidden_waddr_hi, hidden_waddr_lo};

    // ---------------------------------------------------------------
    // Hidden state SRAM (orchestrator-written, read by gating unit)
    // ---------------------------------------------------------------
    reg [15:0] hidden_sram [0:HIDDEN_DEPTH-1];

    always @(posedge clk) begin
        if (hidden_we)
            hidden_sram[hidden_waddr[ADDR_BITS-1:0]] <= hidden_wdata;
    end

    // ---------------------------------------------------------------
    // MoE gating unit signals
    // ---------------------------------------------------------------
    wire mg_done;
    wire mg_fma_busy;
    wire [TOP_K*8-1:0]  mg_idx;
    wire [TOP_K*16-1:0] mg_logit;
    wire [TOP_K*8-1:0]  mg_layer_out;
    wire [TOP_K*8-1:0]  mg_module_out;
    wire [ADDR_BITS-1:0] mg_hidden_addr;

    wire [ADDR_BITS-1:0] hidden_raddr;
    wire [15:0]          hidden_rdata;
    assign hidden_raddr = mg_hidden_addr;
    assign hidden_rdata = hidden_sram[hidden_raddr];

    // Hidden-data handshake for the gating unit. hidden_valid is high while
    // gating is active (hidden_sram is a combinational read, so hidden_data
    // is valid the same cycle the address is presented).
    reg hidden_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            hidden_valid <= 1'b0;
        else if (ctrl_start)
            hidden_valid <= 1'b1;
        else if (mg_done)
            hidden_valid <= 1'b0;
    end

    assign busy = mg_fma_busy | ctrl_start;
    assign done = mg_done;
    assign expert_idx   = mg_idx;
    assign expert_logit = mg_logit;
    assign expert_layer = mg_layer_out;
    assign expert_module = mg_module_out;
    assign cycle_count  = cycle_counter;

    reg result_valid_r;
    assign result_valid = result_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            result_valid_r <= 1'b0;
        else if (mg_done)
            result_valid_r <= 1'b1;
        else if (ctrl_start)
            result_valid_r <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_counter <= 32'd0;
        else if (ctrl_start)
            cycle_counter <= 32'd0;
        else if (mg_fma_busy)
            cycle_counter <= cycle_counter + 1'b1;
    end

    // ---------------------------------------------------------------
    // Logit peek window: read logits[REG_LOGIT + 2*e]
    // ---------------------------------------------------------------
    wire [7:0]  logit_idx = (bus_addr >= REG_LOGIT) ?
                            (bus_addr - REG_LOGIT) >> 1 : 8'd0;
    wire [15:0] logit_val;

    // Read data is shared: whichever manager is active sees the same
    // register file (mode A reads it over mgmt_*, mode B over the fabric).
    reg [15:0] rd_data;
    assign bus_rdata  = rd_data;
    assign mgmt_rdata = rd_data;

    // ---------------------------------------------------------------
    // The effective register bus: the embedded management node in mode A,
    // the chip's local bus in mode B (the legacy/bring-up path).
    // ---------------------------------------------------------------
    wire [15:0] eff_addr  = mgmt_sel ? mgmt_addr  : bus_addr;
    wire [15:0] eff_wdata = mgmt_sel ? mgmt_wdata : bus_wdata;
    wire        eff_we    = mgmt_sel ? mgmt_we    : bus_we;
    wire        eff_valid = mgmt_sel ? mgmt_valid : bus_valid;
    wire        eff_ready = mgmt_sel ? mgmt_ready : bus_ready;


    // ---------------------------------------------------------------
    // Fabric programming receiver (mode B)
    //
    // The host's gating-weight programming arrives as a byte stream on the
    // fabric.  Bytes are assembled into 16-bit register writes on the same
    // map the bus uses (low byte first), so both managers program the ASIC
    // identically.
    // ---------------------------------------------------------------
    // A frame is three bytes: [reg_addr][data_lo][data_hi].  The address is
    // a byte offset, so the programming block (control, weights, hidden) is
    // reachable; the read-only logit window stays on the bus.
    reg [7:0]  prog_addr;
    reg [7:0]  prog_dlo;
    reg [1:0]  prog_phase;       // 0 = address, 1 = data low, 2 = data high
    reg        prog_wr_en;
    reg [15:0] prog_wr_addr;
    reg [15:0] prog_wr_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prog_addr      <= 8'd0;
            prog_dlo       <= 8'd0;
            prog_phase     <= 2'd0;
            prog_wr_en     <= 1'b0;
            prog_wr_addr   <= 16'd0;
            prog_wr_data   <= 16'd0;
        end else begin
            prog_wr_en <= 1'b0;
            if (prog_valid) begin
                if (prog_sop)
                    prog_phase <= 2'd0;
                case (prog_phase)
                    2'd0: begin
                        prog_addr  <= prog_data;
                        prog_phase <= 2'd1;
                    end
                    2'd1: begin
                        prog_dlo   <= prog_data;
                        prog_phase <= 2'd2;
                    end
                    default: begin
                        prog_wr_en   <= 1'b1;
                        prog_wr_addr <= {8'h00, prog_addr};
                        prog_wr_data <= {prog_data, prog_dlo};
                        prog_phase   <= 2'd0;
                    end
                endcase
            end
        end
    end

    // ---------------------------------------------------------------
    // Bus interface (registered, one-cycle latency). A WGHT_DATA write
    // latched here pulses moe_gating.weight_load on the following edge,
    // i.e. when wght_we/wght_waddr/wght_wdata are all stable.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_ready    <= 1'b0;
            mgmt_ready   <= 1'b0;
            rd_data      <= 16'd0;
            ctrl_start   <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            current_layer  <= 8'd0;
            current_module <= 8'd0;
            wght_waddr_lo <= 16'd0;
            wght_waddr_hi <= 16'd0;
            wght_wdata   <= 16'd0;
            wght_we      <= 1'b0;
            wght_incr    <= 1'b0;
            hidden_waddr_lo <= 16'd0;
            hidden_waddr_hi <= 16'd0;
            hidden_wdata <= 16'd0;
            hidden_we    <= 1'b0;
            hidden_incr  <= 1'b0;
        end else begin
            bus_ready <= bus_valid;
            mgmt_ready <= mgmt_valid;
            ctrl_start   <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            wght_we   <= 1'b0;
            hidden_we <= 1'b0;

            // Auto-increment fires the cycle AFTER a data write, so the data
            // write itself still targets the current pointer value. The hidden
            // write pointer wraps at HIDDEN_DIM and the weight pointer at
            // NUM_EXPERTS*HIDDEN_DIM, so streaming exactly one region's worth
            // of words (re)loads it back to the base without an address write.
            if (wght_incr) begin
                if (wght_waddr == NUM_EXPERTS*HIDDEN_DIM - 1)
                    wght_waddr_lo <= 16'd0;
                else
                    wght_waddr_lo <= wght_waddr_lo + 16'd1;
                if (wght_waddr_lo == 16'hFFFF)
                    wght_waddr_hi <= wght_waddr_hi + 16'd1;
            end
            if (hidden_incr) begin
                if (hidden_waddr_lo == (HIDDEN_DIM - 1))
                    hidden_waddr_lo <= 16'd0;
                else
                    hidden_waddr_lo <= hidden_waddr_lo + 16'd1;
                if (hidden_waddr_lo == 16'hFFFF)
                    hidden_waddr_hi <= hidden_waddr_hi + 16'd1;
            end
            wght_incr   <= 1'b0;
            hidden_incr <= 1'b0;

            // A fabric program write (mode B) takes precedence over the
            // local bus, which is idle in that mode.
            if (prog_wr_en) begin
                case (prog_wr_addr)
                    REG_CTRL: begin
                        ctrl_start    <= prog_wr_data[0];
                        ctrl_soft_reset <= prog_wr_data[1];
                    end
                    REG_WGHT_ADDR_LO: wght_waddr_lo <= prog_wr_data;
                    REG_WGHT_ADDR_HI: wght_waddr_hi <= prog_wr_data;
                    REG_WGHT_DATA: begin
                        wght_wdata <= prog_wr_data;
                        wght_we    <= 1'b1;
                        wght_incr  <= 1'b1;
                    end
                    REG_HID_ADDR_LO: hidden_waddr_lo <= prog_wr_data;
                    REG_HID_ADDR_HI: hidden_waddr_hi <= prog_wr_data;
                    REG_HID_DATA: begin
                        hidden_wdata <= prog_wr_data;
                        hidden_we    <= 1'b1;
                        hidden_incr  <= 1'b1;
                    end
                    REG_COORD_L: current_layer  <= prog_wr_data[7:0];
                    REG_COORD_M: current_module <= prog_wr_data[7:0];
                    default: ;
                endcase
            end else if (eff_valid && eff_ready) begin
                if (eff_we) begin
                    case (eff_addr)
                        REG_CTRL: begin
                            ctrl_start    <= eff_wdata[0];
                            ctrl_soft_reset <= eff_wdata[1];
                        end
                        REG_WGHT_ADDR_LO: wght_waddr_lo <= eff_wdata;
                        REG_WGHT_ADDR_HI: wght_waddr_hi <= eff_wdata;
                        REG_WGHT_DATA: begin
                            wght_wdata <= eff_wdata;
                            wght_we    <= 1'b1;
                            wght_incr  <= 1'b1;
                        end
                        REG_HID_ADDR_LO: hidden_waddr_lo <= eff_wdata;
                        REG_HID_ADDR_HI: hidden_waddr_hi <= eff_wdata;
                        REG_HID_DATA: begin
                            hidden_wdata <= eff_wdata;
                            hidden_we    <= 1'b1;
                            hidden_incr  <= 1'b1;
                        end
                        REG_COORD_L: current_layer  <= eff_wdata[7:0];
                        REG_COORD_M: current_module <= eff_wdata[7:0];
                        default: ;
                    endcase
                end else begin
                    case (eff_addr)
                        REG_STATUS:    rd_data   <= {13'd0, mg_fma_busy, mg_done, busy};
                        REG_CYCLE_LO:  rd_data   <= cycle_counter[15:0];
                        REG_CYCLE_HI:  rd_data   <= cycle_counter[31:16];
                        REG_CFG_EXP:   rd_data   <= NUM_EXPERTS[15:0];
                        REG_CFG_HID:   rd_data   <= HIDDEN_DIM[15:0];
                        REG_CFG_TOPK:  rd_data   <= TOP_K[15:0];
                        REG_CFG_ARR:   rd_data   <= ARRAY_SIZE[15:0];
                        REG_RES_IDX0:  rd_data   <= {8'd0, mg_idx[7:0]};
                        REG_RES_IDX1:  rd_data   <= {8'd0, mg_idx[15:8]};
                        REG_RES_LOG0:  rd_data   <= mg_logit[15:0];
                        REG_RES_LOG1:  rd_data   <= mg_logit[31:16];
                        default:
                            if (bus_addr >= REG_LOGIT)
                                rd_data   <= logit_val;
                            else
                                rd_data   <= 16'd0;
                    endcase
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // MoE gating unit. Its own on-chip weight SRAM is written over the
    // bus (WGHT_ADDR_LO/HI + WGHT_DATA pulses weight_load); hidden words
    // come from the hidden state SRAM.
    // ---------------------------------------------------------------
    moe_gating #(
        .NUM_EXPERTS(NUM_EXPERTS),
        .HIDDEN_DIM(HIDDEN_DIM),
        .TOP_K(TOP_K),
        .ADDR_BITS(ADDR_BITS)
    ) u_moe_gating (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (ctrl_start),
        .done             (mg_done),
        .hidden_addr      (mg_hidden_addr),
        .hidden_data      (hidden_rdata),
        .hidden_valid     (hidden_valid),
        .weight_load      (wght_we),
        .weight_addr      (wght_waddr[ADDR_BITS-1:0]),
        .weight_data      (wght_wdata),
        .current_layer    (current_layer),
        .moe_layer_in     (current_layer),
        .moe_module_in    (current_module),
        .expert_idx_packed   (mg_idx),
        .expert_logit_packed (mg_logit),
        .expert_layer_packed (mg_layer_out),
        .expert_module_packed(mg_module_out),
        .fma_busy         (mg_fma_busy),
        .logit_idx        (logit_idx),
        .logit_val        (logit_val)
    );

endmodule