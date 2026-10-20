`timescale 1ns/1ps

// =============================================================================
// node_mem — per-node multi-channel memory subsystem (paper §2.16 sub-channels)
//
// Each compute node (HDL/core/node.v) is paired with memory modules.  This
// module makes that memory MULTI-CHANNEL: the linear word space is interleaved
// across CHANNELS independent banks (word a lives on lane a mod CHANNELS), so a
// burst read presents CHANNELS words per clock after a fixed CAS_LATENCY.  That
// is the mechanism behind "per-node, hence per-request, bandwidth": aggregate
// node bandwidth scales with the channel count (CHANNELS x WIDTH bytes/cycle),
// while the per-channel latency is unchanged.
//
// The reference node pairs two 64 GB 192-bit LPCAMM2/LPDDR6 modules (128 GB,
// 384-bit, ~512 GB/s); node_mem is instantiated with CHANNELS=2 (one channel
// per 192-bit module) in the generated fabric topology and in the assembly
// board implementations/boards/node_dual_mem.json.
//
// It is the memory complement of node.v's MEM_CHAN ingest width: a request for
// `req_words` words comes back as `req_words/CHANNELS` in-order beats, each
// CHANNELS words wide, so the node consumes an N-word hidden/weight slice in
// N/CHANNELS cycles instead of N.
//
// Contract: req_addr is CHANNELS-aligned and req_words is a multiple of
// CHANNELS (the testbench and the node wrapper honour this).
// =============================================================================

module node_mem #(
    parameter CHANNELS = 4,     // memory channels (interleave factor)
    parameter DEPTH    = 1024,  // words per channel (capacity = CHANNELS*DEPTH)
    parameter WIDTH    = 16,    // word width in bits
    parameter CAS      = 2,     // per-channel read latency (cycles)
    parameter ADDRW    = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- write / preload port ------------------------------------------------
    input  wire                wr_en,
    input  wire [ADDRW-1:0]    wr_addr,
    input  wire [WIDTH-1:0]    wr_data,

    // -- burst read request --------------------------------------------------
    input  wire                req_valid,
    input  wire [ADDRW-1:0]    req_addr,   // CHANNELS-aligned linear word
    input  wire [ADDRW-1:0]    req_words,  // multiple of CHANNELS
    output wire                req_ready,  // accepts in IDLE
    output wire                busy,       // request in flight

    // -- CHANNELS-wide in-order egress --------------------------------------
    output wire [CHANNELS*WIDTH-1:0] rd_data,
    output wire                rd_valid,
    output wire                rd_last,
    output wire [ADDRW-1:0]    rd_beat,
    output wire [ADDRW-1:0]    rd_beats
);

    localparam WORDS = CHANNELS * DEPTH;
    reg [WIDTH-1:0] mem [0:WORDS-1];

    localparam S_IDLE   = 2'd0;
    localparam S_LAT    = 2'd1;
    localparam S_STREAM = 2'd2;
    localparam S_DONE   = 2'd3;

    reg [1:0]       st;
    reg [ADDRW-1:0] base;
    reg [ADDRW-1:0] beats;
    reg [ADDRW-1:0] beat;
    reg [7:0]       lat;

    assign req_ready = (st == S_IDLE);
    assign busy      = (st != S_IDLE);
    assign rd_beat   = beat;
    assign rd_beats  = beats;

    // combinational lane read: beat `beat` carries the CHANNELS words
    // [base + beat*CHANNELS + 0 .. +CHANNELS-1], one per channel.
    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : g_lane
            assign rd_data[c*WIDTH +: WIDTH] = mem[base + beat*CHANNELS + c];
        end
    endgenerate

    assign rd_valid = (st == S_STREAM);
    assign rd_last  = (st == S_STREAM) && (beat == beats - 1);

    integer w;
    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            base  <= {ADDRW{1'b0}};
            beats <= {ADDRW{1'b0}};
            beat  <= {ADDRW{1'b0}};
            lat   <= 8'd0;
        end else begin
            case (st)
                S_IDLE: if (req_valid) begin
                    base  <= req_addr;
                    beats <= req_words / CHANNELS;
                    beat  <= {ADDRW{1'b0}};
                    lat   <= CAS[7:0];
                    st    <= (req_words == 0) ? S_DONE : S_LAT;
                end

                S_LAT: begin
                    if (lat == 0) st <= S_STREAM;
                    else          lat <= lat - 8'd1;
                end

                S_STREAM: begin
                    if (beat == beats - 1)
                        st <= S_DONE;
                    beat <= beat + 1;
                end

                S_DONE: st <= S_IDLE;

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
