`include "pnm_defs.vh"

// =============================================================================
// pcie_phy — PCIe Gen5 x16 PHY + controller (behavioral, Paper §2.7)
//
// Root-complex endpoint model for the SBC-class orchestrator chips. Provides the
// host connectivity path: bus-master DMA (MemWr/MemRd TLPs) toward host DRAM.
//
// Link parameters:
//   Width : x16 lanes (parameter LANES)
//   Speed : Gen5 = 32 GT/s per lane, 128b/130b encoding
//           => ~63 GB/s aggregate; modeled as PAYLOAD_BYTES_PER_CYCLE bytes
//              of TLP payload progress per clock (default LANES*4).
//
// LTSSM: DETECT -> POLLING -> CONFIG -> L0 on reset release; L0 is steady
// state. Completion-FIFO credit exhaustion enters RECOVERY (models Data Link
// flow-control credit starvation) and returns to L0 once drained below the
// low watermark.
//
// Register window (repo-standard two-phase valid/ready slave bus; reads are
// combinational, the ready pulse is registered):
//   0x00 ID          (RO)  {DID=0x5016, VID=0x10EE}
//   0x04 CMD         (RW)  bit0 mem-space en, bit1 bus-master en, bit2 intx en
//   0x08 STS         (RO)  [3:0] LTSSM state, [7:4] log2(link width),
//                          [11:8] gen, [15] link_up, [31:16] TLP count
//   0x0C DCAP        (RO)  [2:0] max payload enc, [5:3] max rd req enc,
//                          [23:16] payload bytes/cycle
//   0x10 DBELL       (WO)  bit0=start MemWr, bit1=start MemRd,
//                          bit4=W1C wr-done, bit5=W1C rd-done,
//                          bit6=flush CPL FIFO + clear errors
//   0x14 MWR_ADDR_LO (RW)  host destination addr [31:0]
//   0x18 MWR_ADDR_HI (RW)  host destination addr [63:32]
//   0x1C MWR_LEN     (RW)  MemWr length in bytes (streams multiple TLPs)
//   0x20 MRD_ADDR_LO (RW)  host source addr [31:0]
//   0x24 MRD_ADDR_HI (RW)  host source addr [63:32]
//   0x28 MRD_LEN     (RW)  MemRd length in bytes
//   0x2C CPL_DATA    (RO)  completion FIFO pop (32-bit words)
//   0x30 CPL_COUNT   (RO)  completion words available
//   0x34 INTR_EN     (RW)  bit0 wr-done irq, bit1 rd-done irq
//   0x38 INTR_STS    (RO)  bit0 wr-done, bit1 rd-done, bit2 err
//                          (W1C via DBELL bits 4/5/6)
//   0x3C LANE_STS    (RO)  per-lane active bitmap (16 bits)
//   0x40 WRDATA      (WO)  push one word into the outbound staging buffer
//   0x44 WR_COUNT    (RO)  staged words pending
//
// Loopback mode (parameter LOOPBACK=1): outgoing MemWr payloads are captured
// into a local store; MemRd completions are sourced from it, so a
// write-then-read sequence round-trips end-to-end without a host model.
//
// Error handling: a MemWr whose staging buffer holds fewer bytes than
// MWR_LEN clamps to the staged length and raises INTR_STS bit2 (err).
// =============================================================================

module pcie_phy #(
    parameter LANES                   = 16,
    parameter GEN                     = 5,
    parameter MAX_PAYLOAD_BYTES       = 512,
    parameter PAYLOAD_BYTES_PER_CYCLE = LANES * 4,
    parameter CPL_FIFO_WORDS          = 256,
    parameter STAGE_WORDS             = 128,   // outbound staging (words)
    parameter LB_WORDS                = 4096,  // loopback store (words)
    parameter LOOPBACK                = 1
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  ctl_addr,
    input  wire [31:0] ctl_wdata,
    input  wire        ctl_we,
    input  wire        ctl_valid,
    output reg         ctl_ready,
    output reg  [31:0] ctl_rdata,

    output wire        irq,
    output wire        link_up,
    output wire [3:0]  ltssm_state
);

    // =========================================================================
    // Register map
    // =========================================================================
    localparam REG_ID        = 8'h00;
    localparam REG_CMD       = 8'h04;
    localparam REG_STS       = 8'h08;
    localparam REG_DCAP      = 8'h0C;
    localparam REG_DBELL     = 8'h10;
    localparam REG_MWR_LO    = 8'h14;
    localparam REG_MWR_HI    = 8'h18;
    localparam REG_MWR_LEN   = 8'h1C;
    localparam REG_MRD_LO    = 8'h20;
    localparam REG_MRD_HI    = 8'h24;
    localparam REG_MRD_LEN   = 8'h28;
    localparam REG_CPL_DATA  = 8'h2C;
    localparam REG_CPL_COUNT = 8'h30;
    localparam REG_INTR_EN   = 8'h34;
    localparam REG_INTR_STS  = 8'h38;
    localparam REG_LANE_STS  = 8'h3C;
    localparam REG_WRDATA    = 8'h40;
    localparam REG_WR_COUNT  = 8'h44;

    localparam [31:0] VID_VAL  = 32'h5016_10EE;
    localparam [3:0]  GEN_ENC  = GEN[3:0];

    function [3:0] log2_lanes;
        input integer n;
        begin
            case (n)
                1:  log2_lanes = 4'd0;
                2:  log2_lanes = 4'd1;
                4:  log2_lanes = 4'd2;
                8:  log2_lanes = 4'd3;
                default: log2_lanes = 4'd4;
            endcase
        end
    endfunction

    function [2:0] mps_encode;
        input integer bytes;
        begin
            if      (bytes <= 128)  mps_encode = 3'd0;
            else if (bytes <= 256)  mps_encode = 3'd1;
            else if (bytes <= 512)  mps_encode = 3'd2;
            else if (bytes <= 1024) mps_encode = 3'd3;
            else if (bytes <= 2048) mps_encode = 3'd4;
            else                    mps_encode = 3'd5;
        end
    endfunction

    localparam [3:0] LANES_ENC = log2_lanes(LANES);
    localparam [2:0] MPS_ENC   = mps_encode(MAX_PAYLOAD_BYTES);
    localparam [7:0] PBC_ENC   = PAYLOAD_BYTES_PER_CYCLE[7:0];
    localparam integer WORDS_PER_CYC = PAYLOAD_BYTES_PER_CYCLE / 4;

    // =========================================================================
    // LTSSM
    // =========================================================================
    localparam LT_DETECT   = 4'd0;
    localparam LT_POLLING  = 4'd1;
    localparam LT_CONFIG   = 4'd2;
    localparam LT_L0       = 4'd3;
    localparam LT_RECOVERY = 4'd4;

    reg [3:0]  ltssm_q;
    reg [7:0]  ltssm_timer;
    assign ltssm_state = ltssm_q;
    assign link_up     = (ltssm_q == LT_L0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ltssm_q     <= LT_DETECT;
            ltssm_timer <= 8'h0;
        end else begin
            ltssm_timer <= ltssm_timer + 8'd1;
            case (ltssm_q)
                LT_DETECT: begin
                    if (&ltssm_timer[5:0]) begin
                        ltssm_q     <= LT_POLLING;
                        ltssm_timer <= 8'h0;
                    end
                end
                LT_POLLING: begin
                    if (&ltssm_timer[5:0]) begin
                        ltssm_q     <= LT_CONFIG;
                        ltssm_timer <= 8'h0;
                    end
                end
                LT_CONFIG: begin
                    if (&ltssm_timer[5:0]) begin
                        ltssm_q     <= LT_L0;
                        ltssm_timer <= 8'h0;
                    end
                end
                LT_L0: ;
                LT_RECOVERY: begin
                    if (&ltssm_timer[5:0]) begin
                        ltssm_q     <= LT_L0;
                        ltssm_timer <= 8'h0;
                    end
                end
                default: begin
                    ltssm_q     <= LT_DETECT;
                    ltssm_timer <= 8'h0;
                end
            endcase
        end
    end

    // =========================================================================
    // Command/status registers
    // =========================================================================
    reg        cmd_mse, cmd_bme, cmd_intx;
    reg [31:0] mwr_addr_lo, mwr_addr_hi, mwr_len;
    reg [31:0] mrd_addr_lo, mrd_addr_hi, mrd_len;
    reg        intr_en_wr, intr_en_rd;
    reg        sts_wr_done, sts_rd_done, sts_err;
    reg [15:0] tlp_count;

    assign irq = (intr_en_wr && sts_wr_done) ||
                 (intr_en_rd && sts_rd_done) ||
                 sts_err;

    wire [15:0] lane_sts_val = {LANES{1'b1}};

    // =========================================================================
    // Completion FIFO
    // =========================================================================
    reg [31:0] cpl_fifo [0:CPL_FIFO_WORDS-1];
    reg [$clog2(CPL_FIFO_WORDS)-1:0] cpl_wpos, cpl_rpos;
    reg [8:0]  cpl_used_r;
    reg        cpl_pop_d;          // deferred pop: set on read, executed next cycle
    wire       cpl_empty = (cpl_used_r == 0 && !cpl_pop_d);
    wire       cpl_full  = ({23'h0, cpl_used_r} >= CPL_FIFO_WORDS - WORDS_PER_CYC);
    wire [31:0] cpl_head = (cpl_used_r == 0) ? 32'h0 : cpl_fifo[cpl_rpos];

    // =========================================================================
    // Outbound staging buffer
    // =========================================================================
    reg [31:0] stage_mem [0:STAGE_WORDS-1];
    reg [$clog2(STAGE_WORDS)-1:0] stage_wpos, stage_rpos;
    reg [8:0]  stage_used_r;
    wire [31:0] staged_bytes = {stage_used_r} * 4;

    // =========================================================================
    // Loopback store
    // =========================================================================
    reg [31:0] lb_mem [0:LB_WORDS-1];

    // =========================================================================
    // DMA engine FSM
    // =========================================================================
    localparam DM_IDLE   = 3'd0;
    localparam DM_WR     = 3'd1;
    localparam DM_RD_REQ = 3'd2;
    localparam DM_RD_CPL = 3'd3;

    reg [2:0]  dm_state;
    reg [31:0] dm_base_word;
    reg [31:0] dm_total;        // total bytes for the operation
    reg [31:0] dm_done_bytes;   // bytes moved so far
    reg [31:0] dm_stage_base;   // staging read offset (word units)
    reg        rd_in_recovery;

    wire dma_busy = (dm_state == DM_WR) || (dm_state == DM_RD_CPL);

    // =========================================================================
    // Slave register bus
    // =========================================================================
    integer w;
    integer cpl_pushed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_mse      <= 1'b0;
            cmd_bme      <= 1'b0;
            cmd_intx     <= 1'b0;
            mwr_addr_lo  <= 32'h0;
            mwr_addr_hi  <= 32'h0;
            mwr_len      <= 32'h0;
            mrd_addr_lo  <= 32'h0;
            mrd_addr_hi  <= 32'h0;
            mrd_len      <= 32'h0;
            intr_en_wr   <= 1'b0;
            intr_en_rd   <= 1'b0;
            sts_wr_done  <= 1'b0;
            sts_rd_done  <= 1'b0;
            sts_err      <= 1'b0;
            tlp_count    <= 16'h0;
            cpl_wpos     <= 0;
            cpl_rpos     <= 0;
            cpl_used_r   <= 9'h0;
            cpl_pop_d    <= 1'b0;
            stage_wpos   <= 0;
            stage_rpos   <= 0;
            stage_used_r <= 9'h0;
            dm_state     <= DM_IDLE;
            dm_base_word <= 32'h0;
            dm_total     <= 32'h0;
            dm_done_bytes<= 32'h0;
            dm_stage_base<= 32'h0;
            rd_in_recovery <= 1'b0;
            ctl_ready    <= 1'b0;

        end else begin
            ctl_ready <= 1'b0;

            // ── Deferred CPL FIFO pop (executes one cycle after request) ──
            if (cpl_pop_d) begin
                cpl_rpos   <= ({24'h0, cpl_rpos} == CPL_FIFO_WORDS-1) ? 8'h0 : cpl_rpos + 8'd1;
                cpl_used_r <= cpl_used_r - 9'd1;
                cpl_pop_d  <= 1'b0;
            end

            // ── Completion FIFO pop on read (deferred) ──────────────────────
            if (ctl_valid && !ctl_we && (ctl_addr == REG_CPL_DATA) && !cpl_empty) begin
                cpl_pop_d <= 1'b1;
            end

            // ── DMA engine advance (only in L0 with bus master enabled) ──
            if (link_up && cmd_bme) begin
                case (dm_state)
                    DM_WR: begin
                        // Consume one beat from staging into loopback store.
                        if (LOOPBACK) begin
                            for (w = 0; w < WORDS_PER_CYC; w = w + 1) begin
                                if ((dm_done_bytes + w*4 < dm_total) &&
                                    ({stage_used_r} * 4 >= (w+1)*4)) begin
                                    lb_mem[(dm_base_word +
                                            ((dm_done_bytes >> 2) + w)) % LB_WORDS]
                                        <= stage_mem[(stage_rpos + w[6:0]) & 7'h7F];
                                end
                            end
                            if ({23'h0, stage_used_r} >= WORDS_PER_CYC) begin
                                stage_rpos <= stage_rpos + WORDS_PER_CYC[6:0];
                                stage_used_r <= stage_used_r - WORDS_PER_CYC[8:0];
                            end else if (stage_used_r != 0) begin
                                stage_rpos   <= 0;
                                stage_used_r <= 0;
                            end
                        end

                        if (dm_done_bytes + PAYLOAD_BYTES_PER_CYCLE >= dm_total) begin
                            // Final beat: count the trailing TLP
                            dm_done_bytes <= dm_total;
                            tlp_count     <= tlp_count + 16'd1;
                            dm_state      <= DM_IDLE;
                            sts_wr_done   <= 1'b1;
                        end else begin
                            dm_done_bytes <= dm_done_bytes + PAYLOAD_BYTES_PER_CYCLE;
                            if (((dm_done_bytes + PAYLOAD_BYTES_PER_CYCLE) %
                                 MAX_PAYLOAD_BYTES) == 0)
                                tlp_count <= tlp_count + 16'd1;
                        end
                    end

                    DM_RD_REQ: begin
                        // Single issue cycle; completions stream next states.
                        tlp_count <= tlp_count + 16'd1;
                        dm_state  <= DM_RD_CPL;
                    end

                    DM_RD_CPL: begin
                        if (!cpl_full) begin
                            // Push one beat worth of completion words.
                            cpl_pushed = 0;
                            for (w = 0; w < WORDS_PER_CYC; w = w + 1) begin
                                if (dm_done_bytes + w*4 < dm_total) begin
                                    cpl_fifo[(cpl_wpos + cpl_pushed[7:0]) & 8'hFF] <= LOOPBACK ?
                                        lb_mem[(dm_base_word +
                                                ((dm_done_bytes >> 2) + w)) % LB_WORDS] :
                                        ({16'h0, dm_base_word[15:0]} + w);
                                    cpl_pushed = cpl_pushed + 1;
                                end
                            end
                            cpl_wpos   <= cpl_wpos + cpl_pushed[7:0];
                            cpl_used_r <= cpl_used_r + cpl_pushed[8:0];
                            if (dm_done_bytes + PAYLOAD_BYTES_PER_CYCLE >= dm_total) begin
                                dm_done_bytes <= dm_total;
                                dm_state      <= DM_IDLE;
                                sts_rd_done   <= 1'b1;
                            end else begin
                                dm_done_bytes <= dm_done_bytes + PAYLOAD_BYTES_PER_CYCLE;
                            end
                        end else begin
                            // Credit starvation: enter RECOVERY until drained.
                            if (!rd_in_recovery) begin
                                rd_in_recovery <= 1'b1;
                                if (ltssm_q == LT_L0) ltssm_q <= LT_RECOVERY;
                            end
                        end
                        if (rd_in_recovery && (cpl_used_r < CPL_FIFO_WORDS/4)) begin
                            rd_in_recovery <= 1'b0;
                        end
                    end

                    default: ;
                endcase
            end else if (rd_in_recovery && (cpl_used_r < CPL_FIFO_WORDS/4)) begin
                rd_in_recovery <= 1'b0;
            end

            // ── Register writes ───────────────────────────────────────────
            if (ctl_valid && ctl_we) begin
                ctl_ready <= 1'b1;
                case (ctl_addr)
                    REG_CMD: begin
                        cmd_mse  <= ctl_wdata[0];
                        cmd_bme  <= ctl_wdata[1];
                        cmd_intx <= ctl_wdata[2];
                    end
                    REG_DBELL: begin
                        if (ctl_wdata[6]) begin
                            cpl_rpos    <= cpl_wpos;
                            cpl_used_r  <= 9'h0;
                            cpl_pop_d   <= 1'b0;
                            sts_wr_done <= 1'b0;
                            sts_rd_done <= 1'b0;
                            sts_err     <= 1'b0;
                        end
                        if (ctl_wdata[4]) sts_wr_done <= 1'b0;
                        if (ctl_wdata[5]) sts_rd_done <= 1'b0;
                        if (ctl_wdata[0] && link_up && cmd_mse && (dm_state == DM_IDLE)) begin
                            if (mwr_len > staged_bytes) sts_err <= 1'b1;
                            dm_total      <= (mwr_len > staged_bytes) ? staged_bytes : mwr_len;
                            dm_base_word  <= {2'h0, mwr_addr_lo[31:2]};
                            dm_done_bytes <= 32'h0;
                            dm_stage_base <= 32'h0;
                            dm_state      <= DM_WR;
                        end
                        if (ctl_wdata[1] && link_up && cmd_mse && (dm_state == DM_IDLE)) begin
                            dm_total      <= mrd_len;
                            dm_base_word  <= {2'h0, mrd_addr_lo[31:2]};
                            dm_done_bytes <= 32'h0;
                            dm_state      <= DM_RD_REQ;
                        end
                    end
                    REG_MWR_LO:  mwr_addr_lo <= ctl_wdata;
                    REG_MWR_HI:  mwr_addr_hi <= ctl_wdata;
                    REG_MWR_LEN: mwr_len     <= ctl_wdata;
                    REG_MRD_LO:  mrd_addr_lo <= ctl_wdata;
                    REG_MRD_HI:  mrd_addr_hi <= ctl_wdata;
                    REG_MRD_LEN: mrd_len     <= ctl_wdata;
                    REG_INTR_EN: begin
                        intr_en_wr <= ctl_wdata[0];
                        intr_en_rd <= ctl_wdata[1];
                    end
                    REG_WRDATA: begin
                        stage_mem[stage_wpos] <= ctl_wdata;
                        stage_wpos <= ({25'h0, stage_wpos} == STAGE_WORDS-1) ? 7'h0 : stage_wpos + 7'd1;
                        stage_used_r <= stage_used_r + 9'd1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Combinational read mux
    // =========================================================================
    always @(*) begin
        case (ctl_addr)
            REG_ID:        ctl_rdata = VID_VAL;
            REG_CMD:       ctl_rdata = {29'h0, cmd_intx, cmd_bme, cmd_mse};
            REG_STS:       ctl_rdata = {tlp_count, link_up, 3'b000,
                                        GEN_ENC, LANES_ENC, ltssm_q};
            REG_DCAP:      ctl_rdata = {8'h00, PBC_ENC, 10'h0, 3'b010, MPS_ENC};
            REG_MWR_LO:    ctl_rdata = mwr_addr_lo;
            REG_MWR_HI:    ctl_rdata = mwr_addr_hi;
            REG_MWR_LEN:   ctl_rdata = mwr_len;
            REG_MRD_LO:    ctl_rdata = mrd_addr_lo;
            REG_MRD_HI:    ctl_rdata = mrd_addr_hi;
            REG_MRD_LEN:   ctl_rdata = mrd_len;
            REG_CPL_DATA:  ctl_rdata = cpl_head;
            REG_CPL_COUNT: ctl_rdata = {23'h0, cpl_used_r};
            REG_INTR_EN:   ctl_rdata = {30'h0, intr_en_rd, intr_en_wr};
            REG_INTR_STS:  ctl_rdata = {29'h0, sts_err, sts_rd_done, sts_wr_done};
            REG_LANE_STS:  ctl_rdata = {16'h0, lane_sts_val};
            REG_WR_COUNT:  ctl_rdata = {23'h0, stage_used_r};
            default:       ctl_rdata = 32'h0;
        endcase
    end

endmodule
