`timescale 1ns/1ps

// =============================================================================
// ram_phy_stub — behavioral host-RAM PHY stub
//
// Models a chunk of host system RAM behind a simple read/write port with a
// fixed read latency (READ_LATENCY cycles from rd_req to rd_valid; the data
// line holds the last read until the next request).  tb_expert_loop.v uses it
// as the weight store for the gating network, the per-expert node weight
// matrices, the per-token hidden states, and the output buffer — i.e. the
// stub "pulls from RAM" for every data class the loop touches.
// =============================================================================

module ram_phy_stub #(
    parameter DEPTH        = 16384,
    parameter ADDR_W       = 14,
    parameter READ_LATENCY = 4
)(
    input  wire                clk,
    input  wire                rst_n,

    // read port
    input  wire [ADDR_W-1:0]   rd_addr,
    input  wire                rd_req,
    output wire [15:0]         rd_data,
    output wire                rd_valid,

    // write port
    input  wire [ADDR_W-1:0]   wr_addr,
    input  wire                wr_en,
    input  wire [15:0]         wr_data
);

    reg [15:0] mem [0:DEPTH-1];

    // read-latency pipeline: valid flags and latched addresses
    reg [READ_LATENCY-1:0]  vpipe;
    reg [ADDR_W-1:0]        lat_addr [0:READ_LATENCY-1];

    integer li;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vpipe <= {READ_LATENCY{1'b0}};
        else
            vpipe <= {vpipe[READ_LATENCY-2:0], rd_req};
    end

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        if (rd_req)
            lat_addr[0] <= rd_addr;
        for (li = 1; li < READ_LATENCY; li = li + 1)
            lat_addr[li] <= lat_addr[li-1];
    end

    assign rd_valid = vpipe[READ_LATENCY-1];
    assign rd_data  = mem[lat_addr[READ_LATENCY-1]];

endmodule