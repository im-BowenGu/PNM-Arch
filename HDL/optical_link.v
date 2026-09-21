`include "pnm_defs.vh"

module optical_link #(
    parameter WIDTH        = 128,
    parameter FIBER_M      = 2,
    parameter E_O_NS       = 1,
    parameter O_E_NS       = 1,
    parameter FIFO_DEPTH   = 16,
    parameter NAME         = "optical_link"
)(
    input  wire              wr_clk,
    input  wire              rd_clk,
    input  wire              rst_n,

    input  wire [WIDTH-1:0]  tx_data,
    input  wire              tx_valid,
    input  wire              tx_sop,
    input  wire              tx_eop,
    output wire              tx_ready,

    output reg  [WIDTH-1:0]  rx_data,
    output reg               rx_valid,
    output reg               rx_sop,
    output reg               rx_eop,

    output reg               overflow_err,
    output reg  [31:0]       tx_word_count,
    output reg  [31:0]       rx_word_count,
    output reg  [31:0]       tx_packet_count,
    output reg  [31:0]       rx_packet_count
);

    localparam NS_PER_CYCLE = 10;
    localparam TOTAL_NS     = E_O_NS + (FIBER_M * 49) / 10 + O_E_NS;
    localparam PROP_CYCLES  = (TOTAL_NS + NS_PER_CYCLE - 1) / NS_PER_CYCLE;
    localparam AW           = $clog2(FIFO_DEPTH);
    localparam PTRW         = AW + 1;
    localparam EW           = WIDTH + 2;
    localparam READY_LIMIT  = (FIFO_DEPTH > PROP_CYCLES + 2) ?
                              (FIFO_DEPTH - PROP_CYCLES - 2) : 1;

    function [PTRW-1:0] bin2gray;
        input [PTRW-1:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [PTRW-1:0] gray2bin;
        input [PTRW-1:0] g;
        integer j;
        begin
            gray2bin[PTRW-1] = g[PTRW-1];
            for (j = PTRW-2; j >= 0; j = j - 1)
                gray2bin[j] = gray2bin[j+1] ^ g[j];
        end
    endfunction

    reg [EW-1:0] fifo_mem [0:FIFO_DEPTH-1];

    reg [PTRW-1:0] wbin, wgray;
    reg [PTRW-1:0] rbin, rgray;
    reg [PTRW-1:0] wgray_s1, wgray_s2;
    reg [PTRW-1:0] rgray_s1, rgray_s2;
    reg [PTRW-1:0] rgray_ws1, rgray_ws2;

    wire [PTRW-1:0] wbin_rd  = gray2bin(wgray_s2);
    wire            not_empty = (wbin_rd != rbin);
    wire [EW-1:0]   head_word = fifo_mem[rbin[AW-1:0]];
    wire            pop       = not_empty;

    wire [PTRW-1:0] rbin_wr   = gray2bin(rgray_ws2);
    wire [PTRW-1:0] occup     = wbin - rbin_wr;
    wire [PTRW-1:0] ready_lim = READY_LIMIT[PTRW-1:0];
    wire            incan     = (occup >= ready_lim);
    assign          tx_ready  = !incan;

    reg [EW-1:0] pipe [0:PROP_CYCLES];
    reg          pipe_v [0:PROP_CYCLES];

    integer i;

    initial begin
        wbin = 0; wgray = 0; rbin = 0; rgray = 0;
        wgray_s1 = 0; wgray_s2 = 0; rgray_s1 = 0; rgray_s2 = 0;
    end

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wbin            <= {PTRW{1'b0}};
            wgray           <= {PTRW{1'b0}};
            tx_word_count   <= 32'h0;
            tx_packet_count <= 32'h0;
            overflow_err    <= 1'b0;
        end else begin
            if (tx_valid && tx_ready) begin
                fifo_mem[wbin[AW-1:0]] <= {tx_sop, tx_eop, tx_data};
                wbin            <= wbin + {{(PTRW-1){1'b0}}, 1'b1};
                wgray           <= bin2gray(wbin + {{(PTRW-1){1'b0}}, 1'b1});
                tx_word_count   <= tx_word_count + 32'd1;
                if (tx_sop)
                    tx_packet_count <= tx_packet_count + 32'd1;
            end else if (tx_valid && !tx_ready) begin
                overflow_err <= 1'b1;
            end
        end
    end

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rbin            <= {PTRW{1'b0}};
            rgray           <= {PTRW{1'b0}};
            wgray_s1        <= {PTRW{1'b0}};
            wgray_s2        <= {PTRW{1'b0}};
            rgray_s1        <= {PTRW{1'b0}};
            rgray_s2        <= {PTRW{1'b0}};
            rx_valid        <= 1'b0;
            rx_sop          <= 1'b0;
            rx_eop          <= 1'b0;
            rx_data         <= {WIDTH{1'b0}};
            rx_word_count   <= 32'h0;
            rx_packet_count <= 32'h0;
            for (i = 0; i <= PROP_CYCLES; i = i + 1) begin
                pipe[i]   <= {EW{1'b0}};
                pipe_v[i] <= 1'b0;
            end
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;

            if (pop) begin
                rbin            <= rbin + {{(PTRW-1){1'b0}}, 1'b1};
                rgray           <= bin2gray(rbin + {{(PTRW-1){1'b0}}, 1'b1});
                rx_word_count   <= rx_word_count + 32'd1;
                if (head_word[EW-1])
                    rx_packet_count <= rx_packet_count + 32'd1;
            end

            pipe[0]   <= head_word;
            pipe_v[0] <= pop;
            for (i = 1; i <= PROP_CYCLES; i = i + 1) begin
                pipe[i]   <= pipe[i-1];
                pipe_v[i] <= pipe_v[i-1];
            end

            rx_valid <= pipe_v[PROP_CYCLES];
            if (pipe_v[PROP_CYCLES]) begin
                rx_data <= pipe[PROP_CYCLES][WIDTH-1:0];
                rx_sop  <= pipe[PROP_CYCLES][WIDTH+1];
                rx_eop  <= pipe[PROP_CYCLES][WIDTH];
            end
        end
    end

    // Write-side CDC: synchronize rgray (rd_clk domain) to wr_clk
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            rgray_ws1 <= {PTRW{1'b0}};
            rgray_ws2 <= {PTRW{1'b0}};
        end else begin
            rgray_ws1 <= rgray;
            rgray_ws2 <= rgray_ws1;
        end
    end

endmodule


module optical_pair #(
    parameter WIDTH      = 128,
    parameter FIBER_M    = 2,
    parameter E_O_NS     = 1,
    parameter O_E_NS     = 1,
    parameter FIFO_DEPTH = 16
)(
    input  wire              clk_a,
    input  wire              clk_b,
    input  wire              rst_n,

    input  wire [WIDTH-1:0]  a_tx_data,
    input  wire              a_tx_valid,
    input  wire              a_tx_sop,
    input  wire              a_tx_eop,
    output wire              a_tx_ready,
    output wire [WIDTH-1:0]  a_rx_data,
    output wire              a_rx_valid,
    output wire              a_rx_sop,
    output wire              a_rx_eop,

    input  wire [WIDTH-1:0]  b_tx_data,
    input  wire              b_tx_valid,
    input  wire              b_tx_sop,
    input  wire              b_tx_eop,
    output wire              b_tx_ready,
    output wire [WIDTH-1:0]  b_rx_data,
    output wire              b_rx_valid,
    output wire              b_rx_sop,
    output wire              b_rx_eop,

    output wire [31:0]       total_packets
);

    wire [31:0] pk_a, pk_b;
    wire        ovf_a, ovf_b;

    assign total_packets = pk_a + pk_b;

    optical_link #(
        .WIDTH(WIDTH), .FIBER_M(FIBER_M),
        .E_O_NS(E_O_NS), .O_E_NS(O_E_NS), .FIFO_DEPTH(FIFO_DEPTH),
        .NAME("pair_ab")
    ) u_ab (
        .wr_clk(clk_a), .rd_clk(clk_b), .rst_n(rst_n),
        .tx_data(a_tx_data), .tx_valid(a_tx_valid),
        .tx_sop(a_tx_sop), .tx_eop(a_tx_eop), .tx_ready(a_tx_ready),
        .rx_data(b_rx_data), .rx_valid(b_rx_valid),
        .rx_sop(b_rx_sop), .rx_eop(b_rx_eop),
        .overflow_err(ovf_a),
        .tx_word_count(), .rx_word_count(),
        .tx_packet_count(pk_a), .rx_packet_count()
    );

    optical_link #(
        .WIDTH(WIDTH), .FIBER_M(FIBER_M),
        .E_O_NS(E_O_NS), .O_E_NS(O_E_NS), .FIFO_DEPTH(FIFO_DEPTH),
        .NAME("pair_ba")
    ) u_ba (
        .wr_clk(clk_b), .rd_clk(clk_a), .rst_n(rst_n),
        .tx_data(b_tx_data), .tx_valid(b_tx_valid),
        .tx_sop(b_tx_sop), .tx_eop(b_tx_eop), .tx_ready(b_tx_ready),
        .rx_data(a_rx_data), .rx_valid(a_rx_valid),
        .rx_sop(a_rx_sop), .rx_eop(a_rx_eop),
        .overflow_err(ovf_b),
        .tx_word_count(), .rx_word_count(),
        .tx_packet_count(pk_b), .rx_packet_count()
    );

endmodule
