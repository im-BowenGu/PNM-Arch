// =============================================================================
// clint — Core Local Interruptor (RISC-V Standard)
//
// Provides:
//   - Machine-mode timer (mtime / mtimecmp)
//   - Machine software interrupt (msip)
//   - Timer interrupt output (mtip)
//
// Register map (relative to base):
//   0x0000: msip         (32-bit, bit 0 = software interrupt pending)
//   0x0008: mtimecmp_lo  (low 32 bits of timer compare)
//   0x000C: mtimecmp_hi  (high 32 bits of timer compare)
//   0x0010: mtime_lo     (low 32 bits of free-running timer)
//   0x0014: mtime_hi     (high 32 bits of free-running timer)
// =============================================================================

module clint #(
    parameter CLK_FREQ = 100_000_000,  // 100 MHz
    parameter TIMER_PERIOD = CLK_FREQ / 10  // 100ms tick
)(
    input  wire        clk,
    input  wire        rst_n,

    // Bus slave interface
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire        valid,
    output wire        ready,

    // Interrupt outputs
    output reg         msip,    // machine software interrupt pending
    output reg         mtip     // machine timer interrupt pending
);

    assign ready = 1'b1;  // single-cycle access

    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg [31:0] msip_reg;

    wire [15:0] addr_offset = addr[15:0];

    // Timer prescaler
    reg [$clog2(TIMER_PERIOD)-1:0] tick_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime     <= 64'h0;
            mtimecmp  <= 64'hFFFF_FFFF_FFFF_FFFF;
            msip_reg  <= 32'h0;
            msip      <= 1'b0;
            mtip      <= 1'b0;
            tick_cnt  <= 0;
            rdata     <= 32'h0;
        end else begin
            // Timer tick
            if (tick_cnt >= TIMER_PERIOD[$clog2(TIMER_PERIOD)-1:0] - 1) begin
                tick_cnt <= 0;
                mtime    <= mtime + 64'd1;
            end else begin
                tick_cnt <= tick_cnt + 1;
            end

            // Compare
            mtip <= (mtime >= mtimecmp);
            msip <= msip_reg[0];

            // Bus access
            rdata <= 32'h0;
            if (valid) begin
                case (addr_offset)
                    // msip (0x0000)
                    16'h0000: begin
                        rdata <= msip_reg;
                        if (we) msip_reg <= wdata;
                    end
                    // mtimecmp low (0x0008)
                    16'h0008: begin
                        rdata <= mtimecmp[31:0];
                        if (we) mtimecmp[31:0] <= wdata;
                    end
                    // mtimecmp high (0x000C)
                    16'h000C: begin
                        rdata <= mtimecmp[63:32];
                        if (we) mtimecmp[63:32] <= wdata;
                    end
                    // mtime low (0x0010)
                    16'h0010: begin
                        rdata <= mtime[31:0];
                        if (we) mtime[31:0] <= wdata;
                    end
                    // mtime high (0x0014)
                    16'h0014: begin
                        rdata <= mtime[63:32];
                        if (we) mtime[63:32] <= wdata;
                    end
                    default: rdata <= 32'h0;
                endcase
            end
        end
    end

endmodule
