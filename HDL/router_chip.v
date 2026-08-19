`include "pnm_defs.vh"

// =============================================================================
// router_chip — Central Router Chip (Paper §2.1, §2.5, §2.8)
//
// The only stateful silicon in the PNM chassis.  Sits at the spine root and
// handles:
//
//   1. POST Discovery (§2.5): pings the fabric, collects TOPOLOGY_RDY,
//      computes routing bitmaps for every node pair.
//
//   2. Weight Upload DMA (§2.5): receives weight blobs from the host via
//      PCIe, wraps each in a wormhole flit header [LAYER_ID | MODULE_ID |
//      CTRL | LEN], computes CRC-16, and injects into the spine.
//
//   3. MoE Routing (§2.8): evaluates the gating network (router.proj.weight
//      stored in on-chip SRAM), selects top-k experts, maps each expert
//      index to a (layer, module_id) coordinate via the AOT-computed table,
//      and dispatches the token payload to the selected nodes.
//
//   4. Result Collection (§2.9): receives result echoes from the spine
//      (tail_up, class 1 ascent), routes them back to the host via PCIe.
//
// Interface:
//   - PCIe ingress/egress: byte stream from/to host CPU (8-bit data + sop/eop)
//   - Spine injection: connects to pnm_top inject_data/valid/sop/eop/ready
//   - Spine extraction: receives from pnm_top tail_up_data/valid/sop/eop
//   - POST sideband: topology_rdy per node (active-high pulse)
//   - Configuration: routing_bitmap load port (active at boot)
//
// All internal state is SRAM-backed; the chip is programmed by the host
// driver at boot (firmware phase 2, see firmware.go).
// =============================================================================
module router_chip #(
    parameter NUM_LAYERS   = 4,
    parameter BOARD_X      = 4,
    parameter BOARD_Y      = 4,
    parameter NUM_NODES    = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter MAX_EXPERTS  = 128,
    parameter TOP_K        = 8,
    parameter HIDDEN_SIZE  = 2816,
    parameter VENDOR_ID    = 16'h4D50   // "MP" for Memory-Processor
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- PCIe ingress (host → router) ------------------------------------
    input  wire [7:0]  pcie_in_data,
    input  wire        pcie_in_valid,
    input  wire        pcie_in_sop,
    input  wire        pcie_in_eop,
    output wire        pcie_in_ready,

    // -- PCIe egress (router → host) -------------------------------------
    output reg  [7:0]  pcie_out_data,
    output reg         pcie_out_valid,
    output reg         pcie_out_sop,
    output reg         pcie_out_eop,
    input  wire        pcie_out_ready,

    // -- Spine injection port (connects to pnm_top inject_data) ----------
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    input  wire        spine_inject_ready,
    output wire [1:0]  spine_inject_vc,

    // -- Spine extraction port (receives from pnm_top tail_up) -----------
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // -- POST discovery sideband -----------------------------------------
    input  wire [NUM_NODES-1:0] topology_rdy,  // one bit per node

    // -- Status ----------------------------------------------------------
    output reg         boot_done,       // POST + weight load complete
    output reg  [31:0] dispatches,      // total MoE dispatches
    output reg  [31:0] weight_flits,    // weight flits injected
    output reg  [31:0] errors           // CRC / framing errors
);

    // =========================================================================
    // Internal constants
    // =========================================================================
    localparam CTRL_WEIGHT_UPLOAD = 8'h80;  // vc_class=2 | OP_COMPUTE
    localparam CTRL_COMPUTE       = 8'h80;  // vc_class=2 | OP_COMPUTE
    localparam CTRL_FORWARD       = 8'h90;  // vc_class=2 | OP_FORWARD
    localparam REQ_MODULE         = 8'hEE;  // AOT-fixed requester (spine root)
    localparam VC_DESCENT         = 2'b10;  // class 2: spine descent
    localparam VC_EGRESS          = 2'b00;  // class 0: board egress
    localparam MAX_PKT_BYTES      = 65535;  // max payload per flit

    // =========================================================================
    // Boot FSM states
    // =========================================================================
    localparam BOOT_RESET     = 3'd0;
    localparam BOOT_POST_PING = 3'd1;
    localparam BOOT_POST_WAIT = 3'd2;
    localparam BOOT_LOAD_RT   = 3'd3;  // load routing tables into repeaters
    localparam BOOT_LOAD_WT   = 3'd4;  // receive weight blobs from host
    localparam BOOT_LOAD_MOE  = 3'd5;  // load MoE gating weights into SRAM
    localparam BOOT_READY     = 3'd6;

    reg [2:0]  boot_state;
    reg [7:0]  boot_phase;     // sub-step counter within each boot phase
    reg [15:0] post_ping_resp; // count of TOPOLOGY_RDY responses received

    // =========================================================================
    // Routing table: per-node bitmap (11 bits each)
    // Stored in SRAM, indexed by (layer * BOARD_X * BOARD_Y + x * BOARD_Y + y)
    // =========================================================================
    reg [10:0] route_table [0:NUM_NODES-1];

    // =========================================================================
    // MoE expert map: expert_index → (physical_layer, module_id)
    // Stored in SRAM, indexed by (model_layer * MAX_EXPERTS + expert_idx)
    // =========================================================================
    reg [7:0]  moe_layer  [0:NUM_LAYERS*MAX_EXPERTS-1];
    reg [7:0]  moe_module [0:NUM_LAYERS*MAX_EXPERTS-1];

    // =========================================================================
    // MoE gating weights: router.proj.weight[layer][expert][hidden]
    // On-chip SRAM (21.6 MB for Gemma-4: 30 layers × 128 experts × 2816 × BF16)
    // =========================================================================
    reg [7:0]  moe_weights [0:NUM_LAYERS*MAX_EXPERTS*HIDDEN_SIZE-1];

    // =========================================================================
    // Forward declarations (Verilog-2005: must declare before use)
    // =========================================================================
    localparam ADDR_BITS = 20;  // must hold NUM_EXPERTS*HIDDEN_DIM (e.g. 128*2816=360448 for Gemma-4)

    reg [2:0]  pie_state;
    reg [3:0]  pie_pos;
    reg [7:0]  pie_buf [0:5];
    reg [7:0]  fb_layer;

    // =========================================================================
    // MoE gating unit: systolic-array gated matrix-vector multiply + top-K
    // =========================================================================
    wire        gate_start;
    wire        gate_done;
    wire [TOP_K*8-1:0]  gate_expert_idx_packed;
    wire [TOP_K*16-1:0] gate_expert_logit_packed;
    wire [ADDR_BITS-1:0] gate_hidden_addr;
    wire        gate_fma_busy;
    reg  [15:0] gate_hidden_data;

    moe_gating #(
        .NUM_EXPERTS(MAX_EXPERTS),
        .HIDDEN_DIM(HIDDEN_SIZE),
        .TOP_K(TOP_K),
        .ADDR_BITS(ADDR_BITS)
    ) u_gating (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (gate_start),
        .done          (gate_done),
        .current_layer (fb_layer),
        .hidden_addr   (gate_hidden_addr),
        .hidden_data   (gate_hidden_data),
        .weight_load   (pie_state == PIE_MOE_H && pie_pos == 3),
        .weight_addr   (pie_buf[0] * NUM_EXPERTS * HIDDEN_SIZE + pie_buf[1] * HIDDEN_SIZE),
        .weight_data   ({pie_buf[2], pcie_in_data}),
        .moe_layer_in  (moe_layer[pie_buf[0] * MAX_EXPERTS + pie_buf[1]]),
        .moe_module_in (moe_module[pie_buf[0] * MAX_EXPERTS + pie_buf[1]]),
        .expert_idx_packed   (gate_expert_idx_packed),
        .expert_logit_packed (gate_expert_logit_packed),
        .fma_busy      (gate_fma_busy)
    );

    // =========================================================================
    // POST discovery counter
    // =========================================================================
    reg [15:0] node_count;  // total nodes discovered

    // =========================================================================
    // Flit builder state machine
    // =========================================================================
    localparam FB_IDLE    = 3'd0;
    localparam FB_HDR     = 3'd1;  // accept LAYER_ID, MODULE_ID, CTRL, LEN
    localparam FB_PAYLOAD = 3'd2;  // accept payload bytes
    localparam FB_CRC     = 3'd3;  // compute and append CRC

    reg [2:0]  fb_state;
    reg [7:0]  fb_module;
    reg [7:0]  fb_ctrl;
    reg [15:0] fb_len;
    reg [15:0] fb_pos;      // byte position within payload (flit builder only)
    reg [15:0] fb_crc;      // running CRC-16/CCITT
    reg        fb_active;   // flit builder is processing a message

    reg [15:0] pie_fwd_cnt; // payload bytes forwarded to flit builder

    // =========================================================================
    // PCIe ingress parser state machine
    // =========================================================================
    localparam PIE_IDLE      = 3'd0;
    localparam PIE_CMD       = 3'd1;  // command byte
    localparam PIE_WEIGHT_H  = 3'd2;  // weight upload header
    localparam PIE_WEIGHT_P  = 3'd3;  // weight upload payload
    localparam PIE_RT_NODE   = 3'd4;  // routing table entry
    localparam PIE_MOE_H     = 3'd5;  // MoE map entry
    localparam PIE_INF_TOKEN = 3'd6;  // inference token header
    localparam PIE_INF_TOKEN_P = 3'd7; // inference token payload

    reg [7:0]  pie_cmd;
    reg [15:0] pie_len;

    // =========================================================================
    // Result collection: accumulates tail_up bytes into PCIe egress flits
    // =========================================================================
    localparam RC_IDLE = 2'd0;
    localparam RC_SEND = 2'd1;

    reg [1:0]  rc_state;
    reg [7:0]  rc_buf [0:9]; // result header + up to 4 payload bytes
    reg [3:0]  rc_pos;
    reg [3:0]  rc_len;

    // =========================================================================
    // CRC-16 computation (inline, matches crc16.v / crc.go)
    // =========================================================================
    function [15:0] crc16_next;
        input [15:0] crc_in;
        input [7:0]  data_in;
        reg [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data_in, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_next = crc;
        end
    endfunction

    // =========================================================================
    // Flit builder: accepts raw bytes from the PCIe parser and constructs
    // wormhole flits for spine injection
    // =========================================================================

    // Flit builder output registers
    reg [7:0]  fb_out_data;
    reg        fb_out_valid;
    reg        fb_out_sop;
    reg        fb_out_eop;
    wire       fb_out_ready = spine_inject_ready;

    assign spine_inject_data  = fb_out_data;
    assign spine_inject_valid = fb_out_valid;
    assign spine_inject_sop   = fb_out_sop;
    assign spine_inject_eop   = fb_out_eop;
    assign spine_inject_vc    = VC_DESCENT;

    // Flit builder input ready (accepts from PCIe parser)
    reg        fb_in_ready_r;
    wire       fb_in_ready = fb_in_ready_r;

    assign pcie_in_ready = (pie_state == PIE_WEIGHT_P || pie_state == PIE_INF_TOKEN_P) ? (fb_in_ready && fb_state == 3'd2) : 1'b1;

    // =========================================================================
    // Main control FSM
    // =========================================================================

    // Boot completion
    wire [15:0] total_nodes = NUM_LAYERS[15:0] * BOARD_X[15:0] * BOARD_Y[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_state    <= BOOT_RESET;
            boot_phase    <= 0;
            post_ping_resp <= 0;
            node_count    <= 0;
            boot_done     <= 0;
            dispatches    <= 0;
            weight_flits  <= 0;
            errors        <= 0;

            fb_state      <= FB_IDLE;
            fb_layer      <= 0;
            fb_module     <= 0;
            fb_ctrl       <= 0;
            fb_len        <= 0;
            fb_pos        <= 0;
            fb_crc        <= 16'hFFFF;
            fb_active     <= 0;
            fb_out_data   <= 0;
            fb_out_valid  <= 0;
            fb_out_sop    <= 0;
            fb_out_eop    <= 0;
            fb_in_ready_r <= 0;

            pie_state     <= PIE_IDLE;
            pie_cmd       <= 0;
            pie_pos       <= 0;
            pie_len       <= 0;
            pie_fwd_cnt   <= 0;

            rc_state      <= RC_IDLE;
            rc_pos        <= 0;
            rc_len        <= 0;
        end else begin
            // Defaults
            fb_out_valid <= 1'b0;
            fb_out_sop   <= 1'b0;
            fb_out_eop   <= 1'b0;

            // =================================================================
            // Boot FSM
            // =================================================================
            case (boot_state)
                BOOT_RESET: begin
                    boot_phase <= 0;
                    boot_state <= BOOT_POST_PING;
                end

                BOOT_POST_PING: begin
                    // Count TOPOLOGY_RDY responses
                    post_ping_resp <= 0;
                    node_count     <= 0;
                    boot_state     <= BOOT_POST_WAIT;
                    boot_phase     <= 0;
                end

                BOOT_POST_WAIT: begin
                    // Latch topology_rdy bits over 256 cycles for metastability
                    if (boot_phase < 255)
                        boot_phase <= boot_phase + 1;
                    else begin
                        // Count set bits (popcount)
                        node_count <= 0;
                        begin : popcount
                            integer i;
                            for (i = 0; i < NUM_NODES; i = i + 1) begin
                                if (topology_rdy[i])
                                    node_count <= node_count + 1;
                            end
                        end
                        boot_state <= BOOT_LOAD_RT;
                        boot_phase <= 0;
                    end
                end

                BOOT_LOAD_RT: begin
                    // Routing tables loaded by host driver via PCIe commands
                    if (pie_state == PIE_IDLE && pie_cmd == 8'hFF) begin
                        pie_cmd <= 0;  // clear to prevent multi-phase skip
                        boot_state <= BOOT_LOAD_WT;
                        boot_phase <= 0;
                    end
                end

                BOOT_LOAD_WT: begin
                    // Weight blobs loaded by host driver via PCIe commands.
                    if (pie_state == PIE_IDLE && pie_cmd == 8'hFF) begin
                        pie_cmd <= 0;
                        boot_state <= BOOT_LOAD_MOE;
                        boot_phase <= 0;
                    end
                end

                BOOT_LOAD_MOE: begin
                    // MoE gating weights + expert map loaded by host.
                    if (pie_state == PIE_IDLE && pie_cmd == 8'hFF) begin
                        pie_cmd <= 0;
                        boot_state  <= BOOT_READY;
                        boot_done   <= 1'b1;
                    end
                end

                BOOT_READY: begin
                    // Normal operation: dispatch tokens, collect results.
                end

                default: boot_state <= BOOT_RESET;
            endcase

            // =================================================================
            // PCIe ingress parser
            // =================================================================
            if (pcie_in_valid && pcie_in_ready) begin
                case (pie_state)
                    PIE_IDLE: begin
                        pie_cmd <= pcie_in_data;
                        case (pcie_in_data)
                            8'h01: pie_state <= PIE_WEIGHT_H;  // weight upload
                            8'h02: pie_state <= PIE_RT_NODE;   // routing table
                            8'h03: pie_state <= PIE_MOE_H;     // MoE map
                            8'h04: pie_state <= PIE_INF_TOKEN; // inference token
                            8'hFF: ; // boot phase advance (no-op, handled above)
                            default: errors <= errors + 1;
                        endcase
                        pie_pos <= 0;
                    end

                    PIE_WEIGHT_H: begin
                        // Collect: layer(1) + module(1) + len_hi(1) + len_lo(1)
                        pie_buf[pie_pos[2:0]] <= pcie_in_data;
                        if (pie_pos == 3) begin
                            fb_layer  <= pie_buf[0];
                            fb_module <= pie_buf[1];
                            fb_len    <= {pie_buf[2], pcie_in_data};
                            fb_ctrl   <= CTRL_WEIGHT_UPLOAD;
                            fb_state  <= FB_HDR;
                            fb_pos    <= 0;
                            fb_crc    <= 16'hFFFF;
                            fb_active <= 1;
                            pie_state <= PIE_WEIGHT_P;
                            pie_fwd_cnt <= 0;
                            fb_in_ready_r <= 1;
                        end else
                            pie_pos <= pie_pos + 1;
                    end

                    PIE_WEIGHT_P: begin
                        // Wait for flit builder to finish emitting the flit
                        // (FB_CRC = 3'd3, then back to FB_IDLE = 3'd0)
                        if (fb_state == 3'd0 && !fb_active) begin
                            pie_state <= PIE_IDLE;
                            fb_in_ready_r <= 0;
                        end
                    end

                    PIE_RT_NODE: begin
                        // Collect: node_id(1) + bitmap_hi(1) + bitmap_lo(1)
                        pie_buf[pie_pos[2:0]] <= pcie_in_data;
                        if (pie_pos == 2) begin
                            begin : rt_load
                                integer idx;
                                idx = pie_buf[0];  // node_id
                                if (idx < NUM_NODES)
                                    route_table[idx] <= {pie_buf[1], pcie_in_data};
                            end
                            pie_state <= PIE_IDLE;
                        end else
                            pie_pos <= pie_pos + 1;
                    end

                    PIE_MOE_H: begin
                        // Collect: layer(1) + expert(1) + target_layer(1) + target_module(1)
                        pie_buf[pie_pos[2:0]] <= pcie_in_data;
                        if (pie_pos == 3) begin
                            begin : moe_load
                                integer idx;
                                idx = pie_buf[0] * MAX_EXPERTS + pie_buf[1];
                                if (idx < NUM_LAYERS * MAX_EXPERTS) begin
                                    moe_layer[idx]  <= pcie_in_data;
                                    moe_module[idx] <= pie_buf[2];
                                end
                            end
                            pie_state <= PIE_IDLE;
                        end else
                            pie_pos <= pie_pos + 1;
                    end

                    PIE_INF_TOKEN: begin
                        // Inference: collect len_hi(1) + len_lo(1), then payload
                        pie_buf[pie_pos[2:0]] <= pcie_in_data;
                        if (pie_pos == 0) begin
                            // First byte after CMD is LEN_HI
                            pie_pos <= 1;
                        end else if (pie_pos == 1) begin
                            // Second byte is LEN_LO
                            fb_layer  <= 8'd1;  // LAYER_ID = 1 (1-based, layer 0)
                            fb_module <= 8'h00; // MODULE_ID = node (0,0)
                            fb_ctrl   <= CTRL_COMPUTE;
                            fb_len    <= {pie_buf[0], pcie_in_data};
                            fb_state  <= FB_HDR;
                            fb_pos    <= 0;
                            fb_crc    <= 16'hFFFF;
                            fb_active <= 1;
                            pie_state <= PIE_INF_TOKEN_P;
                            pie_fwd_cnt <= 0;
                            fb_in_ready_r <= 1;
                            dispatches <= dispatches + 1;
                        end
                    end

                    PIE_INF_TOKEN_P: begin
                        // Wait for flit builder to finish emitting the flit
                        if (fb_state == 3'd0 && !fb_active) begin
                            pie_state <= PIE_IDLE;
                            fb_in_ready_r <= 0;
                        end
                    end
                    default: pie_state <= PIE_IDLE;
                endcase
            end

            // =================================================================
            // Flit-builder-done check (runs even when pcie_in_valid is deasserted)
            // =================================================================
            if ((pie_state == PIE_WEIGHT_P || pie_state == PIE_INF_TOKEN_P)
                && fb_state == 3'd0 && !fb_active) begin
                pie_state <= PIE_IDLE;
                fb_in_ready_r <= 0;
            end

            // =================================================================
            // Flit builder: constructs wormhole flits for spine injection
            // =================================================================
            case (fb_state)
                FB_IDLE: begin
                    fb_out_valid <= 1'b0;
                end

                FB_HDR: begin
                    if (fb_out_ready || !fb_out_valid) begin
                        // Emit: LAYER_ID | MODULE_ID | CTRL | LEN_LO | LEN_HI
                        case (fb_pos)
                            0: begin fb_out_data <= fb_layer;  fb_out_sop <= 1; fb_out_valid <= 1; end
                            1: begin fb_out_data <= fb_module; fb_out_sop <= 0; end
                            2: begin fb_out_data <= fb_ctrl;   end
                            3: begin fb_out_data <= fb_len[7:0];  end  // LEN_LO
                            4: begin fb_out_data <= fb_len[15:8]; end  // LEN_HI
                        endcase
                        // Update CRC over header bytes (CRC covers MODULE_ID, CTRL, LEN, payload)
                        if (fb_pos >= 1 && fb_pos <= 4) begin
                            if (fb_pos == 1)
                                fb_crc <= crc16_next(16'hFFFF, fb_module);
                            else if (fb_pos == 2)
                                fb_crc <= crc16_next(fb_crc, fb_ctrl);
                            else if (fb_pos == 3)
                                fb_crc <= crc16_next(fb_crc, fb_len[7:0]);   // LEN_LO
                            else if (fb_pos == 4)
                                fb_crc <= crc16_next(fb_crc, fb_len[15:8]);  // LEN_HI
                        end
                        if (fb_pos == 4) begin
                            if (fb_len == 0) begin
                                fb_state <= FB_CRC;
                                fb_pos   <= 0;
                            end else begin
                                fb_state <= FB_PAYLOAD;
                                fb_pos   <= 0;
                            end
                        end else
                            fb_pos <= fb_pos + 1;
                    end
                end

                FB_PAYLOAD: begin
                    // Forward payload bytes from PCIe parser, respecting backpressure
                    if (fb_out_ready || !fb_out_valid) begin
                        if (fb_in_ready && pcie_in_valid) begin
                            fb_out_data  <= pcie_in_data;
                            fb_out_valid <= 1;
                            fb_out_sop   <= 0;
                            fb_crc       <= crc16_next(fb_crc, pcie_in_data);
                            if (fb_pos == fb_len - 1) begin
                                fb_state <= FB_CRC;
                                fb_pos   <= 0;
                            end else
                                fb_pos <= fb_pos + 1;
                        end
                    end
                end

                FB_CRC: begin
                    if (fb_out_ready || !fb_out_valid) begin
                        fb_out_valid <= 1;
                        fb_out_sop   <= 0;
                        if (fb_pos == 0) begin
                            fb_out_data <= fb_crc[15:8]; // CRC_HI
                            fb_out_eop  <= 0;
                            fb_pos      <= 1;
                        end else begin
                            fb_out_data <= fb_crc[7:0];  // CRC_LO
                            fb_out_eop  <= 1;
                            fb_state    <= FB_IDLE;
                            fb_active   <= 0;
                            weight_flits <= weight_flits + 1;
                        end
                    end
                end

                default: fb_state <= FB_IDLE;
            endcase

            // =================================================================
            // Result collection: tail_up → PCIe egress
            // Forwards result echoes from the spine back to the host via PCIe.
            // =================================================================
            if (spine_extract_valid && boot_done && pcie_out_ready) begin
                pcie_out_data  <= spine_extract_data;
                pcie_out_valid <= 1;
                pcie_out_sop   <= spine_extract_sop;
                pcie_out_eop   <= spine_extract_eop;
            end else begin
                pcie_out_valid <= 0;
            end

            // =================================================================
            // Reset on boot_phase commands
            // =================================================================
            if (pcie_in_valid && pcie_in_data == 8'hFF && pie_state == PIE_IDLE) begin
                pie_cmd <= 8'hFF; // signal boot phase advance
            end
        end
    end

endmodule
