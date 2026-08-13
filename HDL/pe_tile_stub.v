`include "pnm_defs.vh"

// =============================================================================
// pe_tile_stub — Processing Element (PE) tile placeholder for the MAC unit
//
// The hardware fabric decouples transport from computation: the deterministic
// repeater network connects to a modular PE interface via standard AXI-Stream /
// Ready-Valid handshaking, so the underlying execution block (systolic array,
// FP16 MAC array, or ALU) can be swapped independently of the routing fabric.
// This stub *is* that interface contract, in Verilog.
//
// It consumes one flit byte per clock on its slave port (s_axis_*), holds it
// in an elastic pipe for MULT_LATENCY clock cycles — the modelled
// multiply-accumulate latency — then re-presents it on the master port
// (m_axis_*).  It owns exactly two handshake flags: s_axis_tready (the pipe
// can accept a byte) and m_axis_tvalid (a result byte is present).  The node
// DMA / doorbell and the fabric see only the AXI-Stream interface; swapping
// the internals for a real systolic array or FP16 MAC array changes nothing
// outside this module.
//
// MULT_LATENCY: 1 or 2 clock cycles (the paper's approximate MAC latency,
// Section 2.9).  Default 2.
// =============================================================================
module pe_tile_stub #(
    parameter integer MULT_LATENCY = 2   // 1 or 2 cycles of multiply latency
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream slave — incoming flit from the node DMA port
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI-Stream master — the (delayed) result flit
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // -- elastic MAC-latency pipe -----------------------------------------
    // stage 1 feeds the master port and is always present; stage 0 adds the
    // second cycle when MULT_LATENCY >= 2.  Each stage is a classic
    // depth-1 elastic buffer (c.f. hfr.v): it accepts its upstream byte
    // whenever its downstream is ready or its own slot is empty, so the pipe
    // fills with the input stream and stalls in place under backpressure.
    reg [7:0] s0_data, s1_data;
    reg       s0_valid, s1_valid;
    reg       s0_last,  s1_last;

    wire s1_ready = m_axis_tready || !s1_valid;
    wire s0_ready = s1_ready || !s0_valid;

    assign s_axis_tready = (MULT_LATENCY >= 2) ? s0_ready : s1_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_data  <= 8'h00;  s1_valid <= 1'b0;  s1_last <= 1'b0;
            s0_data  <= 8'h00;  s0_valid <= 1'b0;  s0_last <= 1'b0;
        end else begin
            if (s1_ready) begin
                s1_data  <= (MULT_LATENCY >= 2) ? s0_data  : s_axis_tdata;
                s1_valid <= (MULT_LATENCY >= 2) ? s0_valid : s_axis_tvalid;
                s1_last  <= (MULT_LATENCY >= 2) ? s0_last  : s_axis_tlast;
            end
            if (MULT_LATENCY >= 2 && s0_ready) begin
                s0_data  <= s_axis_tdata;
                s0_valid <= s_axis_tvalid;
                s0_last  <= s_axis_tlast;
            end
        end
    end

    assign m_axis_tdata  = s1_data;
    assign m_axis_tvalid = s1_valid;
    assign m_axis_tlast  = s1_last;

endmodule
