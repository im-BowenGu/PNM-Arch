module power_node #(
    parameter CORE_IDLE_PJ  = 3000,
    parameter MAC_PJ        = 87000,
    parameter IO_IDLE_PJ    = 500,
    parameter LINK_PJ       = 9500,
    parameter DRAM_BG_PJ    = 8000,
    parameter DRAM_RD_PJ    = 40000,
    parameter DRAM_WR_PJ    = 30000,

    parameter V_CORE_MV     = 800,
    parameter V_IO_MV       = 1200,
    parameter V_DRAM_MV     = 1100,

    parameter R_CORE_MOHM   = 4,
    parameter R_IO_MOHM     = 20,
    parameter R_DRAM_MOHM   = 5,

    parameter UVLO_CORE_MV  = 720,
    parameter UVLO_IO_MV    = 1080,
    parameter UVLO_DRAM_MV  = 990
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mac_en,
    input  wire        dram_rd,
    input  wire        dram_wr,
    input  wire        link_act,

    output reg  [31:0] p_core_mw,
    output reg  [31:0] p_io_mw,
    output reg  [31:0] p_dram_mw,
    output reg  [31:0] p_node_mw,

    output reg  [31:0] v_core_mv,
    output reg  [31:0] v_io_mv,
    output reg  [31:0] v_dram_mv,
    output reg         brownout,

    output reg  [63:0] e_total_pj
);

    reg [31:0] core_pj, io_pj, dram_pj;
    reg [63:0] e_core_pj, e_io_pj, e_dram_pj;
    reg [31:0] drop_uv;
    reg [31:0] droop_mv;
    reg [31:0] rail_lim, rail_nom;
    reg [31:0] i_core_ma, i_io_ma, i_dram_ma;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_pj      <= CORE_IDLE_PJ;
            io_pj        <= IO_IDLE_PJ;
            dram_pj      <= DRAM_BG_PJ;
            p_core_mw    <= 32'd0;
            p_io_mw      <= 32'd0;
            p_dram_mw    <= 32'd0;
            p_node_mw    <= 32'd0;
            v_core_mv    <= V_CORE_MV;
            v_io_mv      <= V_IO_MV;
            v_dram_mv    <= V_DRAM_MV;
            brownout     <= 1'b0;
            e_total_pj   <= 64'd0;
            e_core_pj    <= 64'd0;
            e_io_pj      <= 64'd0;
            e_dram_pj    <= 64'd0;
            drop_uv = 32'd0;
            droop_mv = 32'd0;
            rail_lim = 32'd0;
            rail_nom = 32'd0;
            i_core_ma    <= 32'd0;
            i_io_ma      <= 32'd0;
            i_dram_ma    <= 32'd0;
        end else begin
            core_pj <= CORE_IDLE_PJ + (mac_en ? MAC_PJ : 32'd0);
            io_pj   <= IO_IDLE_PJ   + (link_act ? LINK_PJ : 32'd0);
            dram_pj <= DRAM_BG_PJ
                     + (dram_rd ? DRAM_RD_PJ : 32'd0)
                     + (dram_wr ? DRAM_WR_PJ : 32'd0);

            p_core_mw <= core_pj / 32'd10;
            p_io_mw   <= io_pj   / 32'd10;
            p_dram_mw <= dram_pj / 32'd10;
            p_node_mw <= (core_pj + io_pj + dram_pj) / 32'd10;

            e_core_pj  <= e_core_pj  + {32'd0, core_pj};
            e_io_pj    <= e_io_pj    + {32'd0, io_pj};
            e_dram_pj  <= e_dram_pj  + {32'd0, dram_pj};
            e_total_pj <= e_total_pj + {32'd0, core_pj}
                                        + {32'd0, io_pj}
                                        + {32'd0, dram_pj};

            i_core_ma = (p_core_mw * 32'd1000) / V_CORE_MV;
            i_io_ma   = (p_io_mw   * 32'd1000) / V_IO_MV;
            i_dram_ma = (p_dram_mw * 32'd1000) / V_DRAM_MV;

            rail_lim = V_CORE_MV * 1000;
            rail_nom = V_CORE_MV;
            drop_uv = i_core_ma * R_CORE_MOHM;
            if (drop_uv >= rail_lim)
                v_core_mv <= 32'd0;
            else begin
                droop_mv  = (drop_uv + 500) / 1000;
                v_core_mv <= rail_nom - droop_mv;
            end

            rail_lim = V_IO_MV * 1000;
            rail_nom = V_IO_MV;
            drop_uv = i_io_ma * R_IO_MOHM;
            if (drop_uv >= rail_lim)
                v_io_mv <= 32'd0;
            else begin
                droop_mv = (drop_uv + 500) / 1000;
                v_io_mv  <= rail_nom - droop_mv;
            end

            rail_lim = V_DRAM_MV * 1000;
            rail_nom = V_DRAM_MV;
            drop_uv = i_dram_ma * R_DRAM_MOHM;
            if (drop_uv >= rail_lim)
                v_dram_mv <= 32'd0;
            else begin
                droop_mv  = (drop_uv + 500) / 1000;
                v_dram_mv <= rail_nom - droop_mv;
            end

            brownout <= (v_core_mv < UVLO_CORE_MV)
                     || (v_io_mv   < UVLO_IO_MV)
                     || (v_dram_mv < UVLO_DRAM_MV);
        end
    end

endmodule


module chassis_power #(
    parameter NUM_NODES   = 512,
    parameter SPINE_MW    = 72000,
    parameter ROUTER_MW   = 10000,
    parameter THERMAL_MW  = 600000,
    parameter ETA_PCT     = 92,
    parameter BUDGET_MW   = 10000000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mac_en,
    input  wire        dram_rd,
    input  wire        dram_wr,
    input  wire        link_act,

    output reg  [31:0] nodes_mw,
    output reg  [31:0] wall_mw,
    output reg         budget_exceeded,
    output reg  [63:0] e_nodes_pj
);

    wire [31:0] node_p [0:NUM_NODES-1];

    genvar g;
    generate
        for (g = 0; g < NUM_NODES; g = g + 1) begin : g_node
            power_node u_node (
                .clk(clk), .rst_n(rst_n),
                .mac_en(mac_en), .dram_rd(dram_rd),
                .dram_wr(dram_wr), .link_act(link_act),
                .p_core_mw(), .p_io_mw(), .p_dram_mw(),
                .p_node_mw(node_p[g]),
                .v_core_mv(), .v_io_mv(), .v_dram_mv(),
                .brownout(),
                .e_total_pj()
            );
        end
    endgenerate

    integer k;
    reg [63:0] sum_mw;
    reg [63:0] wall_q;
    localparam [63:0] BUDGET_Q = BUDGET_MW;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_mw          <= 64'd0;
            wall_q          <= 64'd0;
            nodes_mw        <= 32'd0;
            wall_mw         <= 32'd0;
            budget_exceeded <= 1'b0;
            e_nodes_pj      <= 64'd0;
        end else begin
            sum_mw = 64'd0;
            for (k = 0; k < NUM_NODES; k = k + 1)
                sum_mw = sum_mw + {32'd0, node_p[k]};

            nodes_mw <= sum_mw[31:0];
            wall_q   = (((sum_mw + SPINE_MW + ROUTER_MW) * 64'd100)
                        / ETA_PCT) + THERMAL_MW;
            wall_mw  <= wall_q[31:0];

            e_nodes_pj <= e_nodes_pj + sum_mw * 64'd10;

            budget_exceeded <= (wall_q > BUDGET_Q);
        end
    end

endmodule
