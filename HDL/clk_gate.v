`timescale 1ns/1ps

// Clock gating cell — latch-based, safe for synthesis.
//
// The enable input is captured by a level-sensitive latch on the
// falling clock edge (when the clock is low), so the gated output
// never glitches.  A test-mode override (scan_en) bypasses the
// gate to allow DFT scan-chain operation.
//
// Usage:
//   wire gclk;
//   clk_gate u_cg (.clk(clk), .enable(en), .scan_en(scan), .gclk(gclk));

module clk_gate (
    input  wire clk,
    input  wire enable,
    input  wire scan_en,
    output wire gclk
);

    // verilator lint_off LATCH
    reg enable_latched;

    always @(*) begin
        if (!clk)
            enable_latched = enable | scan_en;
    end

    assign gclk = clk & enable_latched;

endmodule
