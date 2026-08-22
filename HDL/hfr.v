`include "pnm_defs.vh"

// =============================================================================
// hfr — Hardware Flit Repeater
// Paper §1.4 (Unix philosophy) / §2.2 (NoB fabric)
//
// Does exactly one thing: forward a flit byte to the next hop, one clock later.
// No payload inspection, no routing state, no decisions — a pure pipe stage.
// Depth-1 elastic buffer also underpins the consumption guarantee (§4.3).
// Chain N instances for deeper elastic buffering.
//
// Carries a bit-mask comparator as a read-only monitor: it compares the
// packet head byte's low nibble against the LAYER field of the pre-loaded
// routing bitmap (paper §2.1).  On the spine it flags a flit for this board
// leaking past its xyz_repeater; on-board streams it is informational.  The
// comparator never affects the data path — the HFR stays a stateless pipe.
// =============================================================================
module hfr (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_sop,
    input  wire       in_eop,
    output wire       in_ready,
    // per-link VC sideband (paper §4.3): passed through unchanged — HFRs
    // carry no per-VC state and never decide a route
    input  wire [1:0] in_vc,
    output reg  [1:0] out_vc,

    output reg  [7:0] out_data,
    output reg        out_valid,
    output reg        out_sop,
    output reg        out_eop,
    input  wire       out_ready,

    // routing bitmap (routing-table entry):
    //   [10:7] LAYER : 4-bit layer ID, 1-based
    //   [6]    AXIS  : 0 = X, 1 = Y
    //   [5]    SIGN  : 0 = +, 1 = -
    //   [4:0]  DIST  : hop distance from the xyz_repeater
    input  wire [10:0] route_bitmap,
    // bit-mask comparator output (monitor only): asserts on the head byte
    // when (in_data[3:0] == route_bitmap[10:7])
    output wire        layer_match
);

    assign layer_match = in_valid && in_sop
        && ((in_data ^ {4'h0, route_bitmap[`RBM_LAYER_HI:`RBM_LAYER_LO]})
            & 8'h0F) == 8'h0;

    // Accept when the pipeline slot is free or the consumer is ready.
    assign in_ready = out_ready || !out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_sop   <= 1'b0;
            out_eop   <= 1'b0;
            out_data  <= 8'h00;
            out_vc    <= 2'b00;
        end else if (in_ready) begin
            out_valid <= in_valid;
            out_data  <= in_data;
            out_sop   <= in_sop;
            out_eop   <= in_eop;
            out_vc    <= in_vc;
        end
    end

endmodule
