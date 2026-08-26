`timescale 1ns/1ps

module tb_pcb_si_link;

    reg clk, rst_n;

    reg  [7:0] sh_tx_data, xt_tx_data, lg_tx_data, ns_tx_data, mn_tx_data;
    reg  [7:0] xt_aggr, mn_aggr;
    reg        sh_v, xt_v, lg_v, ns_v, mn_v;
    reg        sh_sop, sh_eop, mn_sop, mn_eop;

    wire [7:0]  sh_rx, xt_rx, lg_rx, ns_rx, mn_rx;
    wire        sh_rv, xt_rv, lg_rv, ns_rv, mn_rv;
    wire        sh_rsop, sh_reop;
    wire [31:0] sh_loss, xt_loss, lg_loss, ns_loss, mn_loss;
    wire [31:0] mn_errs, xt_errs, ns_errs, lg_errs, sh_errs;
    wire [63:0] mn_chk, ns_chk;
    wire signed [31:0] mn_eye, xt_eye, lg_eye;
    wire [31:0] mn_marg, mn_jit, xt_marg;

    integer errors;
    integer wi, ri, rd;
    reg [7:0]  cur;
    reg [10:0] refq [0:19999];
    reg [10:0] got;

    wire mn_sop_got = u_main.rx_sop;
    wire mn_eop_got = u_main.rx_eop;

    initial begin : reader
        rd = 0;
        forever begin
            @(posedge clk); #1;
            if (mn_rv === 1'b1) begin
                got = {mn_sop_got, mn_eop_got, mn_rx};
                if (rd < 20000) begin
                    if (got !== refq[rd]) begin
                        errors = errors + 1;
                        $display("FAIL [stream wd %0d] got=%h exp=%h @%0t",
                                 rd, got, refq[rd], $time);
                    end
                end else begin
                    errors = errors + 1;
                    $display("FAIL [extra word] @%0t", $time);
                end
                rd = rd + 1;
            end
        end
    end

    pcb_si_link #(
        .WIDTH(8), .LENGTH_MM(50),
        .NOISE_MV(0), .DJ_MV(0), .COUPLE_PCT(0), .REFL_PCT(10),
        .JITTER_WIN(7'h00), .NAME("short")
    ) u_short (
        .clk(clk), .rst_n(rst_n),
        .tx_data(sh_tx_data), .tx_valid(sh_v),
        .tx_sop(sh_sop), .tx_eop(sh_eop), .tx_ready(),
        .aggr_data(8'h00),
        .rx_data(sh_rx), .rx_valid(sh_rv),
        .rx_sop(sh_rsop), .rx_eop(sh_reop),
        .loss_db(sh_loss), .ber_errors(sh_errs),
        .bits_checked(), .eye_min_uv(), .marginal_cnt(),
        .jitter_cnt(), .skew_ps()
    );

    pcb_si_link #(
        .WIDTH(8), .LENGTH_MM(40)
    ) u_main (
        .clk(clk), .rst_n(rst_n),
        .tx_data(mn_tx_data), .tx_valid(mn_v),
        .tx_sop(mn_sop), .tx_eop(mn_eop), .tx_ready(),
        .aggr_data(mn_aggr),
        .rx_data(mn_rx), .rx_valid(mn_rv),
        .rx_sop(), .rx_eop(),
        .loss_db(mn_loss), .ber_errors(mn_errs),
        .bits_checked(mn_chk), .eye_min_uv(mn_eye),
        .marginal_cnt(mn_marg), .jitter_cnt(mn_jit),
        .skew_ps()
    );

    pcb_si_link #(
        .WIDTH(8), .LENGTH_MM(10),
        .NOISE_MV(0), .DJ_MV(0), .COUPLE_PCT(8),
        .REFL_PCT(5), .EYE_MARGIN_UV(350000),
        .JITTER_WIN(7'h00), .NAME("xtalk")
    ) u_xtalk (
        .clk(clk), .rst_n(rst_n),
        .tx_data(xt_tx_data), .tx_valid(xt_v),
        .tx_sop(1'b0), .tx_eop(1'b0), .tx_ready(),
        .aggr_data(xt_aggr),
        .rx_data(xt_rx), .rx_valid(xt_rv),
        .rx_sop(), .rx_eop(),
        .loss_db(xt_loss), .ber_errors(xt_errs),
        .bits_checked(), .eye_min_uv(xt_eye),
        .marginal_cnt(xt_marg), .jitter_cnt(),
        .skew_ps()
    );

    pcb_si_link #(
        .WIDTH(8), .LENGTH_MM(40),
        .NOISE_MV(900), .NAME("noisy")
    ) u_noisy (
        .clk(clk), .rst_n(rst_n),
        .tx_data(ns_tx_data), .tx_valid(ns_v),
        .tx_sop(1'b0), .tx_eop(1'b0), .tx_ready(),
        .aggr_data(8'h00),
        .rx_data(ns_rx), .rx_valid(ns_rv),
        .rx_sop(), .rx_eop(),
        .loss_db(ns_loss), .ber_errors(ns_errs),
        .bits_checked(ns_chk), .eye_min_uv(),
        .marginal_cnt(), .jitter_cnt(), .skew_ps()
    );

    pcb_si_link #(
        .WIDTH(8), .LENGTH_MM(1000),
        .NOISE_MV(0), .DJ_MV(0), .COUPLE_PCT(0),
        .JITTER_WIN(7'h00), .NAME("long")
    ) u_long (
        .clk(clk), .rst_n(rst_n),
        .tx_data(lg_tx_data), .tx_valid(lg_v),
        .tx_sop(1'b0), .tx_eop(1'b0), .tx_ready(),
        .aggr_data(8'h00),
        .rx_data(lg_rx), .rx_valid(lg_rv),
        .rx_sop(), .rx_eop(),
        .loss_db(lg_loss), .ber_errors(lg_errs),
        .bits_checked(), .eye_min_uv(lg_eye),
        .marginal_cnt(), .jitter_cnt(), .skew_ps()
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
        rst_n = 1'b0;
        {sh_tx_data, sh_v, sh_sop, sh_eop} = 11'd0;
        {mn_tx_data, mn_v, mn_sop, mn_eop} = 12'd0;
        {xt_tx_data, xt_v} = 9'd0;
        {lg_tx_data, lg_v} = 9'd0;
        {ns_tx_data, ns_v} = 9'd0;
        mn_aggr = 8'h00;
        xt_aggr = 8'hFF;
        errors = 0;
        wi = 0; ri = 0; got = 11'd0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        settle(6);

        // ---- u_long / u_xtalk quiet carriers ----
        lg_tx_data = 8'hFF; lg_v = 1'b1;
        xt_tx_data = 8'hFF; xt_v = 1'b1;
        settle(4);

        chk(lg_loss === 32'd14, "loss long capped 14dB");
        chk(lg_eye < 32'sd120000, "long channel eye collapsed");
        chk(xt_loss === 32'd1, "loss xtalk 1dB");

        // ---- crosstalk: toggle aggressor, eye must degrade, no hard errors ----
        @(negedge clk); xt_aggr = 8'h00;
        settle(4);
        chk(xt_eye === 32'sd324325, "xtalk eye exact 324mV");
        chk(xt_errs === 32'd0, "xtalk no bit errors");
        chk(xt_marg > 32'd0, "xtalk margin violations counted");
        @(negedge clk); xt_aggr = 8'hFF;
        settle(4);

        // ---- short link: loss table + reflection step response ----
        chk(sh_loss === 32'd1, "loss short 1dB");
        settle(2);
        @(negedge clk);
        sh_tx_data = 8'hA5; sh_v = 1'b1; sh_sop = 1'b1; sh_eop = 1'b0;
        @(posedge clk); #1;
        chk(sh_rv === 1'b0, "latency cycle1 empty");
        @(posedge clk); #1;
        chk(sh_rv === 1'b1 && sh_rx === 8'hA5 && sh_rsop === 1'b1,
            "latency exactly 2 + sop");
        @(negedge clk);
        sh_tx_data = 8'h5A; sh_sop = 1'b0; sh_eop = 1'b1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        chk(sh_rx === 8'h5A && sh_reop === 1'b1, "eop passthrough");
        sh_v = 1'b0; sh_eop = 1'b0;

        // reflection step: quiet carrier back to 0, then step to FF
        settle(4);
        @(negedge clk);
        sh_tx_data = 8'hFF;
        @(posedge clk); #1;
        @(posedge clk); #1;
        chk(u_short.g_lane[0].u_lane.sample_uv === 32'sd320850,
            "reflection undershoot 320850uv");
        @(posedge clk); #1;
        chk(u_short.g_lane[0].u_lane.sample_uv === 32'sd392150,
            "settled 392150uv (A+echo)");
        chk(u_short.g_lane[0].u_lane.echo_last_uv === 32'sd35650,
            "echo tap 35650uv");
        sh_v = 1'b0;

        // ---- main link: 20000 random words, zero BER, live monitors ----
        mn_v = 1'b1;
        for (wi = 0; wi < 20000; wi = wi + 1) begin
            @(negedge clk);
            cur = $random;
            mn_tx_data <= cur;
            mn_sop <= (wi == 0);
            mn_eop <= ((wi % 64) == 63);
            refq[wi] = {(wi == 0), ((wi % 64) == 63), cur};
        end
        @(negedge clk);
        mn_v <= 1'b0; mn_sop <= 1'b0; mn_eop <= 1'b0;

        settle(4);
        chk(rd === 20000, "all 20000 words received");

        chk(mn_chk === 64'd160000, "main bits checked exact");
        chk(mn_errs === 32'd0, "main zero BER");
        chk(mn_jit > 32'd0, "main jitter events observed");
        chk(mn_marg === 32'd0, "main no margin violations");
        chk(mn_eye > 32'sd300000 && mn_eye < 32'sd374325,
            "main eye degraded but healthy");

        // ---- noisy link: detector must fire ----
        ns_v = 1'b1;
        for (wi = 0; wi < 3000; wi = wi + 1) begin
            @(negedge clk);
            ns_tx_data <= $random;
        end
        @(negedge clk);
        ns_v <= 1'b0;
        settle(4);
        chk(ns_chk === 64'd24000, "noisy bits checked exact");
        chk(ns_errs > 32'd0, "noisy link errors detected");

        if (errors == 0)
            $display("*** PCB SI LINK TEST PASSED ***");
        else
            $display("*** PCB SI LINK TEST FAILED (%0d errors) ***", errors);
        $finish;
    end

    initial begin
        #600000;
        $display("*** PCB SI LINK TEST FAILED (timeout) ***");
        $finish;
    end

endmodule
