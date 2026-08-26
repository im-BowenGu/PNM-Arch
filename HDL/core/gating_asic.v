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

    // Register-mapped bus from orchestrator (active-high valid/ready)
    input  wire [15:0] bus_addr,
    input  wire [15:0] bus_wdata,
    output reg  [15:0] bus_rdata,
    input  wire        bus_we,
    input  wire        bus_valid,
    output reg         bus_ready,

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
    //   0x04  CYCLE_LO
    //   0x06  CYCLE_HI
    //   0x08  CFG_EXPERTS   (read-only, NUM_EXPERTS)
    //   0x0A  CFG_HIDDEN    (read-only, HIDDEN_DIM)
    //   0x0C  CFG_TOPK      (read-only, TOP_K)
    //   0x0E  CFG_ARRAY     (read-only, ARRAY_SIZE)
    //   0x10  WGHT_ADDR     (weight SRAM write address)
    //   0x12  WGHT_DATA     (weight SRAM write data, BF16)
    //   0x14  HIDDEN_ADDR   (hidden SRAM write address)
    //   0x16  HIDDEN_DATA   (hidden SRAM write data, BF16)
    //   0x18  COORD_LAYER   (layer coordinate input)
    //   0x1A  COORD_MODULE  (module coordinate input)
    //   0x20  RESULT_IDX0   (expert_idx[0], read-only)
    //   0x22  RESULT_IDX1   (expert_idx[1], read-only)
    //   0x24  RESULT_LOGIT0 (expert_logit[0:1], read-only)
    //   0x26  RESULT_LOGIT1 (expert_logit[2:3], read-only)
    localparam [15:0] REG_CTRL      = 16'h0000;
    localparam [15:0] REG_STATUS    = 16'h0002;
    localparam [15:0] REG_CYCLE_LO  = 16'h0004;
    localparam [15:0] REG_CYCLE_HI  = 16'h0006;
    localparam [15:0] REG_CFG_EXP   = 16'h0008;
    localparam [15:0] REG_CFG_HID   = 16'h000A;
    localparam [15:0] REG_CFG_TOPK  = 16'h000C;
    localparam [15:0] REG_CFG_ARR   = 16'h000E;
    localparam [15:0] REG_WGHT_ADDR = 16'h0010;
    localparam [15:0] REG_WGHT_DATA = 16'h0012;
    localparam [15:0] REG_HID_ADDR  = 16'h0014;
    localparam [15:0] REG_HID_DATA  = 16'h0016;
    localparam [15:0] REG_COORD_L   = 16'h0018;
    localparam [15:0] REG_COORD_M   = 16'h001A;
    localparam [15:0] REG_RES_IDX0  = 16'h0020;
    localparam [15:0] REG_RES_IDX1  = 16'h0022;
    localparam [15:0] REG_RES_LOG0  = 16'h0024;
    localparam [15:0] REG_RES_LOG1  = 16'h0026;

    // ---------------------------------------------------------------
    // Control / status registers
    // ---------------------------------------------------------------
    reg        ctrl_start;
    reg        ctrl_soft_reset;
    reg [31:0] cycle_counter;
    reg [7:0]  current_layer;
    reg [7:0]  current_module;

    // ---------------------------------------------------------------
    // Weight SRAM write port (written by orchestrator bus)
    // ---------------------------------------------------------------
    reg                  wght_we;
    reg  [ADDR_BITS-1:0] wght_waddr;
    reg  [15:0]          wght_wdata;

    // ---------------------------------------------------------------
    // Hidden SRAM write port (written by orchestrator bus)
    // ---------------------------------------------------------------
    reg                  hidden_we;
    reg  [ADDR_BITS-1:0] hidden_waddr;
    reg  [15:0]          hidden_wdata;

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

    assign busy = mg_fma_busy | ctrl_start;
    assign done = mg_done;
    assign expert_idx   = mg_idx;
    assign expert_logit = mg_logit;
    assign expert_layer = mg_layer_out;
    assign expert_module = mg_module_out;
    assign cycle_count  = cycle_counter;

    // Result valid: latched when gating unit asserts done
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

    // Cycle counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_counter <= 32'd0;
        else if (ctrl_start)
            cycle_counter <= 32'd0;
        else if (mg_fma_busy)
            cycle_counter <= cycle_counter + 1'b1;
    end

    // ---------------------------------------------------------------
    // Bus interface (registered, one-cycle latency)
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_ready    <= 1'b0;
            bus_rdata    <= 16'd0;
            ctrl_start   <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            current_layer  <= 8'd0;
            current_module <= 8'd0;
            wght_we    <= 1'b0;
            wght_waddr <= {ADDR_BITS{1'b0}};
            wght_wdata <= 16'd0;
            hidden_we    <= 1'b0;
            hidden_waddr <= {ADDR_BITS{1'b0}};
            hidden_wdata <= 16'd0;
        end else begin
            bus_ready <= bus_valid;
            ctrl_start   <= 1'b0;
            ctrl_soft_reset <= 1'b0;

            if (bus_valid && bus_ready) begin
                if (bus_we) begin
                    case (bus_addr)
                        REG_CTRL: begin
                            ctrl_start    <= bus_wdata[0];
                            ctrl_soft_reset <= bus_wdata[1];
                        end
                        REG_WGHT_ADDR: wght_waddr <= bus_wdata[ADDR_BITS-1:0];
                        REG_WGHT_DATA: begin
                            wght_wdata <= bus_wdata;
                            wght_we    <= 1'b1;
                        end
                        REG_HID_ADDR: hidden_waddr <= bus_wdata[ADDR_BITS-1:0];
                        REG_HID_DATA: begin
                            hidden_wdata <= bus_wdata;
                            hidden_we    <= 1'b1;
                        end
                        REG_COORD_L: current_layer  <= bus_wdata[7:0];
                        REG_COORD_M: current_module <= bus_wdata[7:0];
                        default: ;
                    endcase
                end else begin
                    wght_we   <= 1'b0;
                    hidden_we <= 1'b0;
                    case (bus_addr)
                        REG_STATUS:    bus_rdata <= {13'd0, mg_fma_busy, mg_done, busy};
                        REG_CYCLE_LO:  bus_rdata <= cycle_counter[15:0];
                        REG_CYCLE_HI:  bus_rdata <= cycle_counter[31:16];
                        REG_CFG_EXP:   bus_rdata <= NUM_EXPERTS[15:0];
                        REG_CFG_HID:   bus_rdata <= HIDDEN_DIM[15:0];
                        REG_CFG_TOPK:  bus_rdata <= TOP_K[15:0];
                        REG_CFG_ARR:   bus_rdata <= ARRAY_SIZE[15:0];
                        REG_RES_IDX0:  bus_rdata <= {8'd0, mg_idx[7:0]};
                        REG_RES_IDX1:  bus_rdata <= {8'd0, mg_idx[15:8]};
                        REG_RES_LOG0:  bus_rdata <= mg_logit[15:0];
                        REG_RES_LOG1:  bus_rdata <= mg_logit[31:16];
                        default:       bus_rdata <= 16'd0;
                    endcase
                end
            end else begin
                wght_we   <= 1'b0;
                hidden_we <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------
    // Weight SRAM (written by orchestrator, read by gating unit)
    // ---------------------------------------------------------------
    wire [ADDR_BITS-1:0] wght_raddr;
    wire [15:0]          wght_rdata;

    reg [15:0] wght_sram [0:WEIGHT_DEPTH-1];

    always @(posedge clk) begin
        if (wght_we)
            wght_sram[wght_waddr] <= wght_wdata;
    end

    assign wght_rdata = wght_sram[wght_raddr];

    // ---------------------------------------------------------------
    // Hidden state SRAM (written by orchestrator, read by gating unit)
    // ---------------------------------------------------------------
    wire [ADDR_BITS-1:0] hidden_raddr;
    wire [15:0]          hidden_rdata;

    reg [15:0] hidden_sram [0:HIDDEN_DEPTH-1];

    always @(posedge clk) begin
        if (hidden_we)
            hidden_sram[hidden_waddr] <= hidden_wdata;
    end

    assign hidden_rdata = hidden_sram[hidden_raddr];

    // ---------------------------------------------------------------
    // MoE gating unit
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
        .weight_load      (1'b0),
        .weight_addr      ({ADDR_BITS{1'b0}}),
        .weight_data      (16'h0000),
        .current_layer    (current_layer),
        .moe_layer_in     (8'd0),
        .moe_module_in    (8'd0),
        .expert_idx_packed   (mg_idx),
        .expert_logit_packed (mg_logit),
        .expert_layer_packed (mg_layer_out),
        .expert_module_packed(mg_module_out),
        .fma_busy         (mg_fma_busy)
    );

endmodule
