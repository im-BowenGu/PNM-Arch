`include "pnm_defs.vh"

// =============================================================================
// pcb_link — Behavioral PCB interconnect model for PNM chassis
//
// Models a single unidirectional point-to-point link on the motherboard or
// spine, with configurable width, propagation delay, and optional signal
// integrity degradation.  Three parametric profiles cover the three PCB
// populations in the chassis (paper §2.4, Table 1):
//
//   Profile "spine"  — spine mezzanine connector (128-bit, ~5 mm mated)
//   Profile "board"  — motherboard point-to-point trace (128-bit, ~40 mm)
//   Profile "camm2"  — CAMM2 socket escape to MAC ASIC (192-bit, ~20 mm)
//
// The model is purely combinational delay.  It adds no protocol awareness:
// it is a wire with timing.
//
// For simulation only.
// =============================================================================

module pcb_link #(
    parameter WIDTH        = 128,          // Link width in bits
    parameter DELAY_NS     = 1,            // Propagation delay (ns)
    parameter DRIVE_MA     = 8,            // Drive strength (mA) — informational
    parameter IMPEDANCE_OH = 50,           // Trace impedance (ohms) — informational
    parameter NAME         = "pcb_link"    // Instance name for debug
)(
    input  wire              clk,          // Reference clock (for jitter model)
    input  wire              rst_n,

    // Source side
    input  wire [WIDTH-1:0]  tx_data,
    input  wire              tx_valid,
    input  wire              tx_sop,
    input  wire              tx_eop,
    output wire              tx_ready,

    // Sink side (delayed)
    output reg  [WIDTH-1:0]  rx_data,
    output reg               rx_valid,
    output reg               rx_sop,
    output reg               rx_eop
);

    // Delay in clock cycles (integer division, minimum 1)
    localparam DELAY_CYCLES = (DELAY_NS > 0) ? ((DELAY_NS + 9) / 10) : 1;

    // Shift-register delay line
    reg [WIDTH+2:0] delay_line [0:DELAY_CYCLES-1];
    integer i;

    assign tx_ready = 1'b1;  // always accepts (elastic buffer upstream)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= 0;
            rx_valid <= 1'b0;
            rx_sop   <= 1'b0;
            rx_eop   <= 1'b0;
            for (i = 0; i < DELAY_CYCLES; i = i + 1)
                delay_line[i] <= 0;
        end else begin
            // Shift data through delay line
            delay_line[0] <= {tx_sop, tx_eop, tx_valid, tx_data};
            for (i = 1; i < DELAY_CYCLES; i = i + 1)
                delay_line[i] <= delay_line[i-1];

            // Output from end of delay line
            rx_valid <= delay_line[DELAY_CYCLES-1][WIDTH];
            rx_sop   <= delay_line[DELAY_CYCLES-1][WIDTH+2];
            rx_eop   <= delay_line[DELAY_CYCLES-1][WIDTH+1];
            rx_data  <= delay_line[DELAY_CYCLES-1][WIDTH-1:0];
        end
    end

endmodule


// =============================================================================
// pcb_triple_link — 3 links sharing one clock domain (X, Y, spine egress)
//
// Common pattern: a node has X-out, Y-out, and spine-egress links that
// share physical layer resources on the motherboard.  This wrapper
// instantiates three pcb_link modules and counts total link activity.
// =============================================================================

module pcb_triple_link #(
    parameter WIDTH    = 128,
    parameter DELAY_NS = 1
)(
    input  wire              clk,
    input  wire              rst_n,

    // Link 0 (X-axis)
    input  wire [WIDTH-1:0]  tx0_data,
    input  wire              tx0_valid,
    input  wire              tx0_sop,
    input  wire              tx0_eop,
    output wire              tx0_ready,
    output wire [WIDTH-1:0]  rx0_data,
    output wire              rx0_valid,
    output wire              rx0_sop,
    output wire              rx0_eop,

    // Link 1 (Y-axis)
    input  wire [WIDTH-1:0]  tx1_data,
    input  wire              tx1_valid,
    input  wire              tx1_sop,
    input  wire              tx1_eop,
    output wire              tx1_ready,
    output wire [WIDTH-1:0]  rx1_data,
    output wire              rx1_valid,
    output wire              rx1_sop,
    output wire              rx1_eop,

    // Link 2 (spine egress)
    input  wire [WIDTH-1:0]  tx2_data,
    input  wire              tx2_valid,
    input  wire              tx2_sop,
    input  wire              tx2_eop,
    output wire              tx2_ready,
    output wire [WIDTH-1:0]  rx2_data,
    output wire              rx2_valid,
    output wire              rx2_sop,
    output wire              rx2_eop,

    // Aggregate status
    output wire [31:0]       total_flits
);

    reg [31:0] flit_cnt;

    assign total_flits = flit_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) flit_cnt <= 0;
        else if (rx0_valid && rx0_sop) flit_cnt <= flit_cnt + 1;
    end

    pcb_link #(.WIDTH(WIDTH), .DELAY_NS(DELAY_NS), .NAME("link_x"))
    u_x (.clk(clk), .rst_n(rst_n),
         .tx_data(tx0_data), .tx_valid(tx0_valid), .tx_sop(tx0_sop), .tx_eop(tx0_eop), .tx_ready(tx0_ready),
         .rx_data(rx0_data), .rx_valid(rx0_valid), .rx_sop(rx0_sop), .rx_eop(rx0_eop));

    pcb_link #(.WIDTH(WIDTH), .DELAY_NS(DELAY_NS), .NAME("link_y"))
    u_y (.clk(clk), .rst_n(rst_n),
         .tx_data(tx1_data), .tx_valid(tx1_valid), .tx_sop(tx1_sop), .tx_eop(tx1_eop), .tx_ready(tx1_ready),
         .rx_data(rx1_data), .rx_valid(rx1_valid), .rx_sop(rx1_sop), .rx_eop(rx1_eop));

    pcb_link #(.WIDTH(WIDTH), .DELAY_NS(DELAY_NS), .NAME("link_spine"))
    u_spine (.clk(clk), .rst_n(rst_n),
             .tx_data(tx2_data), .tx_valid(tx2_valid), .tx_sop(tx2_sop), .tx_eop(tx2_eop), .tx_ready(tx2_ready),
             .rx_data(rx2_data), .rx_valid(rx2_valid), .rx_sop(rx2_sop), .rx_eop(rx2_eop));

endmodule
