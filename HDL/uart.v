// =============================================================================
// uart — Simplified 16550-compatible UART
//
// Register map (relative to base):
//   0x00: THR / RDR    (Transmit Holding / Receive Data Register)
//   0x04: IER          (Interrupt Enable Register)
//   0x08: FCR / IIR    (FIFO Control / Interrupt Identification)
//   0x0C: LCR          (Line Control Register)
//   0x10: MCR          (Modem Control Register)
//   0x14: LSR          (Line Status Register)
//
// Features:
//   - 8N1 data format (8 data bits, no parity, 1 stop bit)
//   - Configurable baud rate via divisor latch
//   - TX/RX with 1-byte FIFO
//   - Interrupt output when RX data available or TX ready
// =============================================================================

module uart #(
    parameter CLK_FREQ = 100_000_000,  // 100 MHz
    parameter BAUD_RATE = 115200
)(
    input  wire        clk,
    input  wire        rst_n,

    // Bus slave interface
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        we,
    input  wire        valid,
    output wire        ready,

    // UART pins
    input  wire        uart_rx,
    output reg         uart_tx,

    // Interrupt
    output reg         irq
);

    assign ready = 1'b1;

    // Baud rate generator
    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam [15:0] BAUD_MAX = BAUD_DIV[15:0] - 16'd1;
    reg [15:0] baud_cnt;
    reg        baud_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_cnt  <= 16'h0;
            baud_tick <= 1'b0;
        end else begin
            if (baud_cnt >= BAUD_MAX) begin
                baud_cnt  <= 0;
                baud_tick <= 1'b1;
            end else begin
                baud_cnt  <= baud_cnt + 1;
                baud_tick <= 1'b0;
            end
        end
    end

    // Registers
    reg [7:0]  thr;          // transmit holding register
    reg [7:0]  rdr;          // receive data register
    reg [7:0]  ier;          // interrupt enable
    reg [7:0]  lcr;          // line control
    reg [7:0]  mcr;          // modem control
    reg [7:0]  lsr;          // line status
    reg [7:0]  fcr;          // fifo control

    reg        tx_busy;
    reg        thr_has_data;   // THR holds an unsent byte (set on write, cleared on send)
    reg [3:0]  tx_bit_cnt;
    reg [9:0]  tx_shift;     // start + 8 data + stop
    reg [3:0]  rx_bit_cnt;
    reg [7:0]  rx_shift;
    reg        rx_busy;
    reg [3:0]  rx_sync;      // synchronizer for uart_rx

    // TX state machine.
    // A byte is loaded from THR into the shift register only when THR actually
    // holds data (thr_has_data).  Using lsr[5] (THR-empty) as the start trigger
    // was a bug: it fired on reset (empty==1) transmitting stale data, and the
    // same-cycle THR write + stale capture dropped the first written byte.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy       <= 1'b0;
            thr_has_data  <= 1'b0;
            tx_bit_cnt    <= 4'h0;
            tx_shift      <= 10'h3FF;
            uart_tx       <= 1'b1;
            lsr[5]        <= 1'b1;  // THR empty
            lsr[6]        <= 1'b1;  // shift register empty
        end else if (!tx_busy && thr_has_data) begin
            // Start new transmission from the held byte
            tx_shift      <= {1'b1, thr, 1'b0};  // stop, 8 data, start
            tx_bit_cnt    <= 4'd0;
            tx_busy       <= 1'b1;
            thr_has_data  <= 1'b0;
            lsr[5]        <= 1'b1;  // THR becomes empty once loaded
            lsr[6]        <= 1'b0;
        end else if (tx_busy && baud_tick) begin
            uart_tx       <= tx_shift[tx_bit_cnt];
            tx_bit_cnt    <= tx_bit_cnt + 1;
            if (tx_bit_cnt == 4'd9) begin
                tx_busy    <= 1'b0;
                // NOTE: do not clear thr_has_data here; a byte written while
                // transmitting stays pending and is sent next.
                lsr[6]     <= 1'b1;  // shift register empty
            end
        end
    end

    // RX synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_sync <= 4'hF;
        else
            rx_sync <= {rx_sync[2:0], uart_rx};
    end

    wire rx_pin = rx_sync[3];  // metastable-resolved

    // RX state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_busy    <= 1'b0;
            rx_bit_cnt <= 4'h0;
            rx_shift   <= 8'h0;
            lsr[0]     <= 1'b0;  // data ready
        end else if (!rx_busy && !rx_pin) begin
            // Start bit detected
            rx_busy    <= 1'b1;
            rx_bit_cnt <= 4'd0;
        end else if (rx_busy && baud_tick) begin
            if (rx_bit_cnt >= 4'd1 && rx_bit_cnt <= 4'd8) begin
                // Sample data bits D0..D7 into rx_shift[0..7].
                // rx_bit_cnt is a 4-bit count, so rx_bit_cnt - 4'd1 is
                // plain 4-bit arithmetic (1..8 -> 0..7); a [2:0] part-select
                // would wrap 8 to 0 and index out of range.
                rx_shift[rx_bit_cnt - 4'd1] <= rx_pin;
            end else if (rx_bit_cnt == 4'd9) begin
                // Stop bit check
                if (rx_pin) begin
                    rdr       <= rx_shift;
                    lsr[0]    <= 1'b1;  // data ready
                end else begin
                    lsr[3]    <= 1'b1;  // framing error
                end
                rx_busy   <= 1'b0;
            end
            rx_bit_cnt <= rx_bit_cnt + 1;
        end
    end

    // Interrupt generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq <= 1'b0;
        else
            irq <= (ier[0] && lsr[0]) || (ier[1] && lsr[5]);
    end

    // Bus access
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata        <= 32'h0;
            thr          <= 8'h0;
            thr_has_data <= 1'b0;
            ier          <= 8'h0;
            fcr          <= 8'h0;
            lcr          <= 8'h0;
            mcr          <= 8'h0;
        end else begin
            rdata <= 32'h0;
            if (valid && !we) begin
                case (addr[4:0])
                    5'h00: rdata <= {24'h0, rdr};     // RDR read
                    5'h04: rdata <= {24'h0, ier};     // IER read
                    5'h08: rdata <= {24'h0, lsr[7:6], 2'b00, 3'b000, lsr[0]};  // IIR
                    5'h0C: rdata <= {24'h0, lcr};     // LCR read
                    5'h10: rdata <= {24'h0, mcr};    // MCR read
                    5'h14: rdata <= {24'h0, lsr};    // LSR read
                    default: rdata <= 32'h0;
                endcase
            end
            if (valid && we) begin
                case (addr[4:0])
                    5'h00: begin
                        thr          <= wdata[7:0];
                        thr_has_data <= 1'b1;
                        lsr[5]       <= 1'b0;  // THR not empty while writing
                    end
                    5'h04: ier <= wdata[7:0];
                    5'h08: fcr <= wdata[7:0];
                    5'h0C: lcr <= wdata[7:0];
                    5'h10: mcr <= wdata[7:0];
                    5'h14: ;  // LSR is read-only
                    default: ;
                endcase
            end
            // Clear data-ready when RDR is read
            if (valid && !we && addr[4:0] == 5'h00)
                lsr[0] <= 1'b0;
            // Clear framing error when LSR is read
            if (valid && !we && addr[4:0] == 5'h14)
                lsr[3] <= 1'b0;
        end
    end

endmodule
