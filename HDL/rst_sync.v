`timescale 1ns/1ps

// Reset synchronizer — two-flop async assert, sync deassert.
// Used at every clock-domain boundary where a reset crosses from
// one domain to another.  The asynchronous assert path ensures the
// reset takes effect immediately regardless of clock state; the
// synchronizer chain on the deassert path prevents metastability
// when the upstream reset releases between two clock edges.

module rst_sync #(
    parameter STAGES = 2
)(
    input  wire clk,
    input  wire rst_n_async,
    output wire rst_n_sync
);

    reg [STAGES-1:0] sr;

    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async)
            sr <= {STAGES{1'b0}};
        else
            sr <= {sr[STAGES-2:0], 1'b1};
    end

    assign rst_n_sync = sr[STAGES-1];

endmodule
