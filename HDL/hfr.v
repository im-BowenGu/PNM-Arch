`include "pnm_defs.vh"

// =============================================================================
// hfr — Hardware Flit Repeater
// Paper §1.4 (Unix philosophy) / §2.2 (NoB fabric)
//
// Does exactly one thing: forward a flit byte to the next hop, one clock later.
// No payload inspection, no routing state, no decisions — a pure pipe stage.
// Depth-1 elastic buffer also underpins the consumption guarantee (§4.3).
// Chain N instances for deeper elastic buffering.
// =============================================================================
module hfr (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_sop,
    input  wire       in_eop,
    output wire       in_ready,

    output reg  [7:0] out_data,
    output reg        out_valid,
    output reg        out_sop,
    output reg        out_eop,
    input  wire       out_ready
);

    // Accept when the pipeline slot is free or the consumer is ready.
    assign in_ready = out_ready || !out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_sop   <= 1'b0;
            out_eop   <= 1'b0;
            out_data  <= 8'h00;
        end else if (in_ready) begin
            out_valid <= in_valid;
            out_data  <= in_data;
            out_sop   <= in_sop;
            out_eop   <= in_eop;
        end
    end

endmodule
