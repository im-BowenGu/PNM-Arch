// =============================================================================
// pnm_host_bridge — the PNM host bridge
//
// A CPU-less companion chip for the PNM chassis.  The host (a Raspberry Pi
// over the SPI bridge, or any third-party microcontroller) drives it; the
// chip injects the host's commands into the PNM fabric and returns results.
//
// It integrates:
//   - 64KB SRAM (data memory, host-addressable)
//   - PNM router engine (flit builder + spine injection/extraction)
//   - the host bus (the PNM register window, the SRAM and the router
//     registers), driven from outside through the SPI bridge / arbiter
//
// There is no CPU, no boot ROM, no timer and no console: the host owns the
// boot sequence (POST discovery, routing tables, weight upload, MoE gating
// weights) by writing the registers below.
//
// Memory map (host bus):
//   0x8000_0000 - 0x8000_FFFF  SRAM (64KB, read-write)
//   0xF000_0000 - 0xF000_003F  PNM router registers
//       0x00: ROUTE_CTRL      (write 1 to trigger flit injection)
//       0x04: ROUTE_LAYER     (layer ID for next flit)
//       0x08: ROUTE_MODULE    (module ID for next flit)
//       0x0C: ROUTE_LEN       (payload length in bytes)
//       0x10: ROUTE_DATA      (write payload bytes, auto-increment)
//       0x14: ROUTE_STATUS    (bit 0=busy, bit 1=done)
//       0x18: ROUTE_RESULT    (read result bytes from spine)
//       0x1C: ROUTE_ERRORS    (CRC/framing error count)
//       0x20: ROUTE_DISPATCH  (dispatch counter, read)
//       0x24: ROUTE_WEIGHTS   (weight flit counter, read)
//
// The host boot sequence:
//   1. POST discovery (poll topology_rdy)
//   2. Load routing tables
//   3. Upload weights
//   4. Load MoE gating weights
//   5. Signal boot_done
//   6. Begin inference dispatch loop
// =============================================================================

module pnm_host_bridge #(
    parameter CLK_FREQ    = 100_000_000,
    parameter BAUD_RATE   = 115200,
    parameter NUM_LAYERS  = 4,
    parameter BOARD_X     = 4,
    parameter BOARD_Y     = 4,
    parameter NUM_NODES   = NUM_LAYERS * BOARD_X * BOARD_Y,
    parameter MAX_EXPERTS = 128,
    parameter TOP_K       = 8,
    parameter HIDDEN_SIZE = 2816
)(
    input  wire        clk,
    input  wire        rst_n,

    // Host bus (the SPI bridge / arbiter drives this)
    input  wire [31:0] host_addr,
    input  wire [31:0] host_wdata,
    output reg  [31:0] host_rdata,
    input  wire        host_we,
    input  wire [3:0]  host_be,
    input  wire        host_valid,
    output wire        host_ready,

    // POST discovery sideband
    input  wire [NUM_NODES-1:0] topology_rdy,

    // Spine injection (to PNM fabric)
    output wire [7:0]  spine_inject_data,
    output wire        spine_inject_valid,
    output wire        spine_inject_sop,
    output wire        spine_inject_eop,
    input  wire        spine_inject_ready,
    output wire [1:0]  spine_inject_vc,

    // Spine extraction (from PNM fabric)
    input  wire [7:0]  spine_extract_data,
    input  wire        spine_extract_valid,
    input  wire        spine_extract_sop,
    input  wire        spine_extract_eop,
    input  wire [1:0]  spine_extract_vc,

    // Status
    output wire        boot_done
);

    // =========================================================================
    // Host bus interconnect
    // =========================================================================
    reg  [31:0] sram_rdata;
    reg  [31:0] pnm_rdata;

    // Slave selects (active-high, combinational from the host address)
    wire sel_sram = (host_addr[31:16] == 16'h8000);        // 0x8000_0000
    wire sel_pnm  = (host_addr[31:8]  == 24'hF000_00);     // 0xF000_0000

    // Mux read data based on slave select
    always @(*) begin
        host_rdata = 32'h0;
        if (sel_sram) host_rdata = sram_rdata;
        else if (sel_pnm)  host_rdata = pnm_rdata;
    end

    // =========================================================================
    // SRAM (64KB, word-addressable, byte-enable write)
    // Staging for the host's DMA path: the host pushes weights and stencil
    // domains here and the chip reads them from its own window.
    // =========================================================================
    reg [31:0] sram [0:16383];
    always @(*) begin
        if (sel_sram)
            sram_rdata = sram[host_addr[15:2]];
        else
            sram_rdata = 32'h0;
    end
    always @(posedge clk) begin
        if (sel_sram && host_valid && host_we) begin
            if (host_be[0]) sram[host_addr[15:2]][7:0]   <= host_wdata[7:0];
            if (host_be[1]) sram[host_addr[15:2]][15:8]  <= host_wdata[15:8];
            if (host_be[2]) sram[host_addr[15:2]][23:16] <= host_wdata[23:16];
            if (host_be[3]) sram[host_addr[15:2]][31:24] <= host_wdata[31:24];
        end
    end

    // The host bus acknowledges every access: an unmapped read returns zero
    // and an unmapped write is dropped.
    assign host_ready = 1'b1;

    // =========================================================================
    // Result FIFO
    //
    // The fabric returns a result as a byte stream, but the host reads the
    // register window far more slowly (a whole SPI frame per byte).  Without
    // a buffer the host would read the window long after the byte had gone.
    // The FIFO holds the returned bytes until the host collects them; a
    // read of ROUTE_RESULT pops one byte.
    // =========================================================================
    localparam RES_FIFO_BYTES = 256;
    reg [7:0] res_fifo [0:RES_FIFO_BYTES-1];
    reg [8:0] res_rd;
    reg [8:0] res_wr;
    reg [9:0] res_count;
    reg       res_pop;          // the host is reading the result this cycle

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_rd    <= 9'd0;
            res_wr    <= 9'd0;
            res_count <= 10'd0;
        end else begin
            // pop
            if (res_pop && (res_count != 0)) begin
                res_rd    <= res_rd + 1'b1;
                res_count <= res_count - 1'b1;
            end
            // push
            if (spine_extract_valid && (res_count < RES_FIFO_BYTES)) begin
                res_fifo[res_wr[7:0]] <= spine_extract_data;
                res_wr    <= res_wr + 1'b1;
                res_count <= res_count + 1'b1;
            end
        end
    end

    wire [7:0] res_head = res_fifo[res_rd[7:0]];

    // =========================================================================
    // PNM Router Engine (host-register-driven flit builder)
    // =========================================================================
    localparam CTRL_COMPUTE = 8'h80;  // VC_SPINE | OP_COMPUTE
    localparam CTRL_FORWARD = 8'h90;  // VC_SPINE | OP_FORWARD
    localparam REQ_MODULE   = 8'hEE;
    localparam VC_DESCENT   = 2'b10;

    // Router register file
    reg [7:0]  route_layer;
    reg [7:0]  route_module;
    reg [15:0] route_len;
    reg [7:0]  route_payload [0:255];
    reg [7:0]  route_wpos;
    reg [31:0] route_errors;
    reg [31:0] route_dispatches;
    reg [31:0] route_weight_flits;
    reg        boot_done_r;
    assign boot_done = boot_done_r;

    // Flit builder state
    localparam FB_IDLE    = 3'd0;
    localparam FB_HDR     = 3'd1;
    localparam FB_PAYLOAD = 3'd2;
    localparam FB_CRC     = 3'd3;

    reg [2:0]  fb_state;
    reg [7:0]  fb_layer_r;
    reg [7:0]  fb_module_r;
    reg [7:0]  fb_ctrl;
    reg [15:0] fb_len;
    reg [15:0] fb_pos;
    reg [15:0] fb_crc;
    reg        fb_active;
    reg [7:0]  fb_out_data_r;
    reg        fb_out_valid_r;
    reg        fb_out_sop_r;
    reg        fb_out_eop_r;

    wire       fb_out_ready = spine_inject_ready;
    wire       pnm_busy = fb_active;

    assign spine_inject_data  = fb_out_data_r;
    assign spine_inject_valid = fb_out_valid_r;
    assign spine_inject_sop   = fb_out_sop_r;
    assign spine_inject_eop   = fb_out_eop_r;
    assign spine_inject_vc    = VC_DESCENT;

    // CRC-16 (matches pnm_crc16 in crc.go / crc16.v)
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

    // PNM register access
    wire [7:0] pnm_addr = host_addr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            route_layer        <= 8'h0;
            route_module       <= 8'h0;
            route_len          <= 16'h0;
            route_wpos         <= 8'h0;
            route_errors       <= 32'h0;
            route_dispatches   <= 32'h0;
            route_weight_flits <= 32'h0;
            fb_state           <= FB_IDLE;
            fb_layer_r         <= 8'h0;
            fb_module_r        <= 8'h0;
            fb_ctrl            <= 8'h0;
            fb_len             <= 16'h0;
            fb_pos             <= 16'h0;
            fb_crc             <= 16'hFFFF;
            fb_active          <= 1'b0;
            fb_out_data_r      <= 8'h0;
            fb_out_valid_r     <= 1'b0;
            fb_out_sop_r       <= 1'b0;
            fb_out_eop_r       <= 1'b0;
            boot_done_r        <= 1'b0;
        end else begin
            fb_out_valid_r <= 1'b0;
            fb_out_sop_r   <= 1'b0;
            fb_out_eop_r   <= 1'b0;

            // CPU register writes
            if (sel_pnm && host_valid && host_we) begin
                case (pnm_addr)
                    8'h04: route_layer  <= host_wdata[7:0];
                    8'h08: route_module <= host_wdata[7:0];
                    8'h0C: route_len    <= host_wdata[15:0];
                    8'h10: begin  // ROUTE_DATA: write payload byte, auto-increment
                        if (!pnm_busy && route_wpos != 8'hFF) begin
                            route_payload[route_wpos] <= host_wdata[7:0];
                            route_wpos <= route_wpos + 1;
                        end
                    end
                    8'h00: begin  // ROUTE_CTRL: trigger injection or boot_done
                        if (host_wdata[2])
                            boot_done_r <= 1'b1;
                        if (!pnm_busy && host_wdata[0]) begin
                            fb_layer_r  <= route_layer;
                            fb_module_r <= route_module;
                            fb_ctrl     <= CTRL_COMPUTE;
                            fb_len      <= route_len;
                            fb_state    <= FB_HDR;
                            fb_pos      <= 16'h0;
                            fb_crc      <= 16'hFFFF;
                            fb_active   <= 1'b1;
                            route_wpos  <= 8'h0;
                        end
                    end
                    default: ;
                endcase
            end

            // Flit builder FSM
            case (fb_state)
                FB_IDLE: begin
                    fb_out_valid_r <= 1'b0;
                end

                FB_HDR: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        case (fb_pos)
                            0: begin fb_out_data_r <= fb_layer_r;  fb_out_sop_r <= 1; end
                            1: begin fb_out_data_r <= fb_module_r; end
                            2: begin fb_out_data_r <= fb_ctrl;    end
                            3: begin fb_out_data_r <= fb_len[7:0];  end
                            4: begin fb_out_data_r <= fb_len[15:8]; end
                        endcase
                        // CRC accumulation (MODULE_ID through LEN)
                        if (fb_pos >= 1 && fb_pos <= 4) begin
                            if (fb_pos == 1)
                                fb_crc <= crc16_next(16'hFFFF, fb_module_r);
                            else if (fb_pos == 2)
                                fb_crc <= crc16_next(fb_crc, fb_ctrl);
                            else if (fb_pos == 3)
                                fb_crc <= crc16_next(fb_crc, fb_len[7:0]);
                            else if (fb_pos == 4)
                                fb_crc <= crc16_next(fb_crc, fb_len[15:8]);
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
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        fb_out_sop_r   <= 0;
                        fb_out_data_r  <= route_payload[fb_pos[7:0]];
                        fb_crc         <= crc16_next(fb_crc, route_payload[fb_pos[7:0]]);
                        if (fb_pos == fb_len - 1) begin
                            fb_state <= FB_CRC;
                            fb_pos   <= 0;
                        end else
                            fb_pos <= fb_pos + 1;
                    end
                end

                FB_CRC: begin
                    if (fb_out_ready || !fb_out_valid_r) begin
                        fb_out_valid_r <= 1;
                        fb_out_sop_r   <= 0;
                        if (fb_pos == 0) begin
                            fb_out_data_r <= fb_crc[15:8];
                            fb_out_eop_r  <= 0;
                            fb_pos        <= 1;
                        end else begin
                            fb_out_data_r <= fb_crc[7:0];
                            fb_out_eop_r  <= 1;
                            fb_state      <= FB_IDLE;
                            fb_active     <= 0;
                            route_weight_flits <= route_weight_flits + 1;
                        end
                    end
                end

                default: fb_state <= FB_IDLE;
            endcase

            // Collect spine extraction results → to result buffer
            if (spine_extract_valid && spine_extract_eop)
                route_dispatches <= route_dispatches + 1;

        end
    end

    // -------------------------------------------------------------------------
    // PNM register reads
    //
    // These are combinational, like the SRAM read above.  A registered read
    // would be sampled by the arbiter one cycle too early: the arbiter takes
    // slv_rdata on the same edge it completes the transaction, so the value
    // it would see is the *previous* access's -- every register read would
    // return zero on the first access.  Combinational also matches how the
    // 16550 and the gating ASIC present their read data.
    // -------------------------------------------------------------------------
    // A read of ROUTE_RESULT pops one byte out of the result FIFO.  The pop
    // happens on the edge the read completes.
    always @(posedge clk) begin
        res_pop <= 1'b0;
        if (sel_pnm && host_valid && !host_we && (pnm_addr == 8'h18) &&
            (res_count != 0))
            res_pop <= 1'b1;
    end

    always @(*) begin
        pnm_rdata = 32'h0;
        case (pnm_addr)
            8'h00: pnm_rdata = {30'h0, 1'b0, pnm_busy};     // STATUS
            8'h04: pnm_rdata = {24'h0, route_layer};        // ROUTE_LAYER
            8'h08: pnm_rdata = {24'h0, route_module};       // ROUTE_MODULE
            8'h0C: pnm_rdata = {16'h0, route_len};          // ROUTE_LEN
            8'h10: pnm_rdata = {24'h0, route_payload[route_wpos]}; // ROUTE_DATA
            8'h14: pnm_rdata = {30'h0, 1'b0, pnm_busy};
            8'h18: pnm_rdata = {24'h0, res_head};         // ROUTE_RESULT (FIFO head)
            8'h1C: pnm_rdata = route_errors;                // ROUTE_ERRORS
            8'h20: pnm_rdata = route_dispatches;            // ROUTE_DISPATCH
            8'h24: pnm_rdata = route_weight_flits;          // ROUTE_WEIGHT_FLITS
            default: pnm_rdata = 32'h0;
        endcase
    end

endmodule
