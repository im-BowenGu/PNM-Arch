`timescale 1ns/1ps

module tb_power_rails;

    reg clk, rst_n;
    reg mac_en, dram_rd, dram_wr, link_act;

    wire [31:0] s_p_core, s_p_io, s_p_dram, s_p_node;
    wire [31:0] s_v_core, s_v_io, s_v_dram;
    wire        s_brownout;
    wire [63:0] s_e_total;

    wire [31:0] st_v_core, st_v_io, st_v_dram;
    wire        st_brownout;

    wire [31:0] c_nodes, c_wall;
    wire        c_budget;
    wire [63:0] c_e_nodes;

    wire [31:0] t_nodes, t_wall;
    wire        t_budget;
    wire [63:0] t_e_nodes;

    integer errors;
    reg [63:0] e0, e_delta;

    power_node u_single (
        .clk(clk), .rst_n(rst_n),
        .mac_en(mac_en), .dram_rd(dram_rd),
        .dram_wr(dram_wr), .link_act(link_act),
        .p_core_mw(s_p_core), .p_io_mw(s_p_io),
        .p_dram_mw(s_p_dram), .p_node_mw(s_p_node),
        .v_core_mv(s_v_core), .v_io_mv(s_v_io),
        .v_dram_mv(s_v_dram), .brownout(s_brownout),
        .e_total_pj(s_e_total)
    );

    power_node #(.R_CORE_MOHM(100)) u_stress (
        .clk(clk), .rst_n(rst_n),
        .mac_en(mac_en), .dram_rd(dram_rd),
        .dram_wr(dram_wr), .link_act(link_act),
        .p_core_mw(), .p_io_mw(), .p_dram_mw(), .p_node_mw(),
        .v_core_mv(st_v_core), .v_io_mv(st_v_io),
        .v_dram_mv(st_v_dram), .brownout(st_brownout),
        .e_total_pj()
    );

    chassis_power #(.NUM_NODES(512)) u_chassis (
        .clk(clk), .rst_n(rst_n),
        .mac_en(mac_en), .dram_rd(dram_rd),
        .dram_wr(dram_wr), .link_act(link_act),
        .nodes_mw(c_nodes), .wall_mw(c_wall),
        .budget_exceeded(c_budget), .e_nodes_pj(c_e_nodes)
    );

    chassis_power #(.NUM_NODES(512), .BUDGET_MW(5000000)) u_chassis_tight (
        .clk(clk), .rst_n(rst_n),
        .mac_en(mac_en), .dram_rd(dram_rd),
        .dram_wr(dram_wr), .link_act(link_act),
        .nodes_mw(t_nodes), .wall_mw(t_wall),
        .budget_exceeded(t_budget), .e_nodes_pj(t_e_nodes)
    );

    always #5 clk = ~clk;

    task chk;
        input cond;
        input [255:0] tag;
        begin
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL [%0s] @%0t", tag, $time);
            end
        end
    endtask

    task settle;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                #1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        mac_en = 1'b0; dram_rd = 1'b0; dram_wr = 1'b0; link_act = 1'b0;
        rst_n = 1'b0;
        errors = 0;
        e0 = 64'd0;
        e_delta = 64'd0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // T1: idle node
        settle(6);
        chk(s_p_core === 32'd300,  "T1 p_core idle");
        chk(s_p_io   === 32'd50,   "T1 p_io idle");
        chk(s_p_dram === 32'd800,  "T1 p_dram idle");
        chk(s_p_node === 32'd1150, "T1 p_node idle 1.15W");
        chk(s_v_core === 32'd798,  "T1 v_core idle droop");
        chk(s_v_io   === 32'd1199, "T1 v_io idle droop");
        chk(s_v_dram === 32'd1096, "T1 v_dram idle droop");
        chk(s_brownout === 1'b0,   "T1 no brownout idle");

        // T4: energy integral, 1000 idle cycles = 11,500,000 pJ
        e0 = s_e_total;
        repeat (1000) @(posedge clk);
        #1;
        e_delta = s_e_total - e0;
        chk(e_delta === 64'd11500000, "T4 energy integral idle");

        // T7: chassis roll-up idle
        chk(c_nodes === 32'd588800,  "T7 chassis nodes idle");
        chk(c_wall  === 32'd1329130, "T7 wall idle 1.33kW");
        chk(c_budget === 1'b0,       "T7 budget ok idle");

        // T2/T5/T6: full active (mac + dram_rd + link)
        @(negedge clk);
        mac_en = 1'b1; dram_rd = 1'b1; dram_wr = 1'b0; link_act = 1'b1;
        settle(6);
        chk(s_p_core === 32'd9000,  "T2 p_core active 9W");
        chk(s_p_io   === 32'd1000,  "T2 p_io active 1W");
        chk(s_p_dram === 32'd4800,  "T2 p_dram active 4.8W");
        chk(s_p_node === 32'd14800, "T2 p_node active 14.8W");
        chk(s_v_core === 32'd755,   "T2 v_core droop 755mV");
        chk(s_v_io   === 32'd1183,  "T2 v_io droop 1183mV");
        chk(s_v_dram === 32'd1078,  "T2 v_dram droop 1078mV");
        chk(s_brownout === 1'b0,    "T2 no brownout active");

        chk(st_v_core === 32'd0,     "T5 stress v_core clamped");
        chk(st_brownout === 1'b1,    "T5 stress brownout fires");

        chk(c_nodes === 32'd7577600,  "T6 chassis nodes active");
        chk(c_wall  === 32'd8925652,  "T6 wall active 8.93kW");
        chk(c_budget === 1'b0,        "T6 budget ok active");
        chk(t_budget === 1'b1,        "T6 tight budget flags");

        // T3: write-only DRAM traffic
        @(negedge clk);
        mac_en = 1'b0; dram_rd = 1'b0; dram_wr = 1'b1; link_act = 1'b0;
        settle(6);
        chk(s_p_dram === 32'd3800, "T3 p_dram wr-only 3.8W");
        chk(s_p_node === 32'd4150, "T3 p_node wr-only");

        if (errors == 0)
            $display("*** POWER RAILS TEST PASSED ***");
        else
            $display("*** POWER RAILS TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("*** POWER RAILS TEST FAILED (timeout) ***");
        $finish;
    end

endmodule
