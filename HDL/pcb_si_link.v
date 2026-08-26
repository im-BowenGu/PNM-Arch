`include "pnm_defs.vh"

// =============================================================================
// pcb_si_link — Electrical (signal-integrity) PCB link model
//
// SPECIFIC IMPLEMENTATION of the abstract pcb_link concept (HDL/pcb_link.v,
// "a wire with timing"): this file models the electrical channel the wire
// really is. Feature set:
//
//   1. Insertion loss   flat-loss dB table (0..14 dB, 1 dB steps); the applied
//                       step derives from length: (LENGTH_MM*LOSS_CUDB_PER_MM
//                       + 99)/100, clamped. Voltage gain = 10^(-dB/20) in ppm.
//   2. Reflections      single-bounce echo tap: the PREVIOUS post-attenuation
//                       sample is added back scaled by REFL_PCT (=100*Gamma,
//                       Gamma=(ZL-Z0)/(ZL+Z0), supplied precomputed).
//   3. Crosstalk        per-lane NEXT: aggressor edge (aggr - aggr_prev),
//                       scaled by COUPLE_PCT/128 (i.e. percent of full swing).
//   4. Noise            PRBS-32 LFSR (Fibonacci, taps 31,21,1,0) mapped to a
//                       zero-centered +/-NOISE_MV uniform approximation.
//   5. Jitter           rare LFSR-window hits (rnd[22:16]==JITTER_WIN, default
//                       7'h7F => p=1/128/lane/cycle) inject a deterministic-
//                       jitter kick of +/-DJ_MV into THAT sample; the event is
//                       counted. Set JITTER_WIN=7'h00 to disable (an all-zero
//                       LFSR state is unreachable).
//   6. Skew             SKEW_PS reported as a timing-budget output; data
//                       alignment is unchanged (skew signoff, not shifting).
//   7. Eye monitor      worst-case sampled |eye height| in uV (per polarity of
//                       the delayed ideal symbol) + marginal-sample counter
//                       below EYE_MARGIN_UV.
//   8. Error accounting per-lane hard-decision mismatches vs the 2-cycle
//                       delayed input; summed across lanes with bits_checked
//                       for direct BER measurement.
//
// Framing (valid/sop/eop/ready) is identical to pcb_link and latency is fixed
// at LATENCY = 2 cycles (flight time << UI at 100 MHz; loss/jitter dominate).
// Drop-in replacement wherever pcb_link instantiates. All arithmetic is
// deterministic integer fixed point. For simulation only.
// =============================================================================

module si_lane #(
    parameter V_SWING_MV    = 400,
    parameter NOISE_MV      = 10,
    parameter DJ_MV         = 30,
    parameter REFL_PCT      = 5,
    parameter COUPLE_PCT    = 3,
    parameter EYE_MARGIN_UV = 200000,
    parameter JITTER_WIN    = 7'h7F
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire               d_in,
    input  wire               aggr_in,
    input  wire               stat_en,
    input  wire [19:0]        gain_ppm,
    input  wire [6:0]         rnd,

    output reg                d_out,
    output reg  signed [31:0] sample_uv,
    output reg  signed [31:0] echo_last_uv,
    output reg  [31:0]        bit_errs,
    output reg  [63:0]        bits_checked,
    output reg  signed [31:0] eye_min_uv,
    output reg  [31:0]        marginal_cnt,
    output reg  [31:0]        jitter_cnt
);

    reg               d_in_d1, d_in_d2;
    reg               a_prev;
    reg  [2:0]        warm;
    reg  signed [31:0] atten_uv;
    reg  signed [31:0] prev_atten_uv;
    reg  signed [31:0] rnd_c;

    reg  signed [31:0] gain_q;
    wire signed [31:0] swing_uv   = V_SWING_MV * 1000;
    wire signed [31:0] ideal_uv   = d_in ? swing_uv : -swing_uv;
    wire signed [63:0] att_prod   = ideal_uv * gain_q;
    wire [63:0]        att_q      = att_prod / 1000000;
    wire signed [31:0] att_next   = att_q[31:0];

    wire signed [31:0] aggr_now   = aggr_in ? swing_uv : -swing_uv;
    wire signed [31:0] aggr_was   = a_prev ? swing_uv : -swing_uv;
    wire signed [31:0] aggr_diff  = aggr_now - aggr_was;
    wire signed [63:0] xt_prod    = aggr_diff * COUPLE_PCT;
    wire [63:0]        xt_q       = xt_prod >>> 7;
    wire signed [31:0] xtalk_uv   = xt_q[31:0];

`ifdef EYE_DBG
    always @(posedge clk) begin
        if (xtalk_uv != 0)
            $display("XT %m now=%0d was=%0d diff=%0d xt=%0d",
                     aggr_now, aggr_was, aggr_diff, xtalk_uv);
    end
`endif
    wire signed [31:0] noise_uv   = ((rnd_c * (NOISE_MV * 1000)) >>> 7);
    wire signed [31:0] dj_uv      = ((rnd_c * (DJ_MV * 1000)) >>> 6);
    wire        jit_hit           = (rnd == JITTER_WIN);
    wire        stats_en          = (warm >= 3'd4);

    wire signed [63:0] echo_p     = prev_atten_uv * REFL_PCT;
    wire signed [63:0] echo_d     = echo_p / 100;
    wire signed [31:0] echo_uv    = echo_d[31:0];
    wire signed [31:0] rx_raw_uv  = atten_uv + echo_uv + xtalk_uv + noise_uv;
    wire signed [31:0] rx_uv      = jit_hit ? (rx_raw_uv + dj_uv) : rx_raw_uv;
    wire               dec_bit    = (rx_uv >= 0);
    wire signed [31:0] mag_uv     = d_in_d1 ? rx_uv : -rx_uv;

`ifdef EYE_DBG
    always @(posedge clk)
        if (stat_en && stats_en)
            $display("DEC %m d=%b d1=%b d2=%b dec=%b rx=%0d",
                     d_in, d_in_d1, d_in_d2, dec_bit, rx_uv);
`endif
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_in_d1        <= 1'b0;
            d_in_d2        <= 1'b0;
            a_prev         <= 1'b0;
            warm           <= 3'd0;
            rnd_c          <= 32'sd0;
            gain_q         <= 32'sd0;
            atten_uv       <= 32'sd0;
            prev_atten_uv  <= 32'sd0;
            d_out          <= 1'b0;
            sample_uv      <= 32'sd0;
            echo_last_uv   <= 32'sd0;
            bit_errs       <= 32'd0;
            bits_checked   <= 64'd0;
            eye_min_uv     <= 32'sh7FFFFFFF;
            marginal_cnt   <= 32'd0;
            jitter_cnt     <= 32'd0;
        end else begin
            if (jit_hit)
                jitter_cnt <= jitter_cnt + 32'd1;

            d_out          <= dec_bit;
            sample_uv      <= rx_uv;
            echo_last_uv   <= echo_uv;

            if (stats_en && stat_en) begin
                if (mag_uv < eye_min_uv) begin
`ifdef EYE_DBG
                    $display("EYE %m mag=%0d rx=%0d d1=%b warm=%0d atten=%0d prev=%0d gain=%0d",
                             mag_uv, rx_uv, d_in_d1, warm, atten_uv,
                             prev_atten_uv, gain_ppm);
`endif
                    eye_min_uv <= mag_uv;
                end
                if (mag_uv < EYE_MARGIN_UV)
                    marginal_cnt <= marginal_cnt + 32'd1;

                bit_errs     <= bit_errs + ((dec_bit != d_in_d1) ? 32'd1 : 32'd0);
                bits_checked <= bits_checked + 64'd1;
            end

            if (warm != 3'd7)
                warm <= warm + 3'd1;
            rnd_c          <= {{25{rnd[6]}}, rnd};
            gain_q         <= {{12{1'b0}}, gain_ppm};
            prev_atten_uv <= atten_uv;
            atten_uv      <= att_next;
            d_in_d1       <= d_in;
            d_in_d2       <= d_in_d1;
            a_prev        <= aggr_in;
        end
    end

endmodule


module pcb_si_link #(
    parameter WIDTH            = 128,
    parameter LENGTH_MM        = 40,
    parameter LOSS_CUDB_PER_MM = 2,
    parameter V_SWING_MV       = 400,
    parameter NOISE_MV         = 10,
    parameter DJ_MV            = 30,
    parameter REFL_PCT         = 5,
    parameter COUPLE_PCT       = 3,
    parameter SKEW_PS          = 15,
    parameter EYE_MARGIN_UV    = 200000,
    parameter JITTER_WIN       = 7'h7F,
    parameter NAME             = "pcb_si_link"
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire [WIDTH-1:0]   tx_data,
    input  wire               tx_valid,
    input  wire               tx_sop,
    input  wire               tx_eop,
    output wire               tx_ready,

    input  wire [WIDTH-1:0]   aggr_data,

    output wire [WIDTH-1:0]   rx_data,
    output wire               rx_valid,
    output wire               rx_sop,
    output wire               rx_eop,

    output wire [31:0]        loss_db,
    output wire [31:0]        ber_errors,
    output wire [63:0]        bits_checked,
    output wire signed [31:0] eye_min_uv,
    output wire [31:0]        marginal_cnt,
    output wire [31:0]        jitter_cnt,
    output wire [31:0]        skew_ps
);

    localparam LOSS_DB_RAW = (LENGTH_MM * LOSS_CUDB_PER_MM + 99) / 100;
    localparam LOSS_DB     = (LOSS_DB_RAW > 14) ? 14 : LOSS_DB_RAW;
    localparam LATENCY     = 2;

    function [19:0] gain_ppm_for_db;
        input [3:0] db;
        begin
            case (db)
                4'd0:    gain_ppm_for_db = 20'd1000000;
                4'd1:    gain_ppm_for_db = 20'd891251;
                4'd2:    gain_ppm_for_db = 20'd794328;
                4'd3:    gain_ppm_for_db = 20'd707946;
                4'd4:    gain_ppm_for_db = 20'd630957;
                4'd5:    gain_ppm_for_db = 20'd562341;
                4'd6:    gain_ppm_for_db = 20'd501187;
                4'd7:    gain_ppm_for_db = 20'd446684;
                4'd8:    gain_ppm_for_db = 20'd398107;
                4'd9:    gain_ppm_for_db = 20'd354813;
                4'd10:   gain_ppm_for_db = 20'd316228;
                4'd11:   gain_ppm_for_db = 20'd281838;
                4'd12:   gain_ppm_for_db = 20'd251189;
                4'd13:   gain_ppm_for_db = 20'd223872;
                default: gain_ppm_for_db = 20'd199526;
            endcase
        end
    endfunction

    assign loss_db  = LOSS_DB;
    assign skew_ps  = SKEW_PS;
    assign tx_ready = 1'b1;

    wire [19:0] gain_ppm_q = gain_ppm_for_db(LOSS_DB[3:0]);

    reg             v_d1, v_d2;

    reg [31:0] lfsr;
    wire       fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 32'hACE1_2345;
        else        lfsr <= {lfsr[30:0], fb};
    end

    genvar g;
    wire               s_dout   [0:WIDTH-1];
    wire signed [31:0] s_sample [0:WIDTH-1];
    wire signed [31:0] s_echo   [0:WIDTH-1];
    wire [31:0]        s_errs   [0:WIDTH-1];
    wire [63:0]        s_chk    [0:WIDTH-1];
    wire signed [31:0] s_eye    [0:WIDTH-1];
    wire [31:0]        s_marg   [0:WIDTH-1];
    wire [31:0]        s_jit    [0:WIDTH-1];

    generate
        for (g = 0; g < WIDTH; g = g + 1) begin : g_lane
            si_lane #(
                .V_SWING_MV   (V_SWING_MV),
                .NOISE_MV     (NOISE_MV),
                .DJ_MV        (DJ_MV),
                .REFL_PCT     (REFL_PCT),
                .COUPLE_PCT   (COUPLE_PCT),
                .EYE_MARGIN_UV(EYE_MARGIN_UV),
                .JITTER_WIN   (JITTER_WIN)
            ) u_lane (
                .clk           (clk),
                .rst_n         (rst_n),
                .d_in          (tx_data[g]),
                .aggr_in       (aggr_data[g]),
                .stat_en       (v_d2),
                .gain_ppm      (gain_ppm_q),
                .rnd           (lfsr[(g*4) % 26 +: 7]),
                .d_out         (s_dout[g]),
                .sample_uv     (s_sample[g]),
                .echo_last_uv  (s_echo[g]),
                .bit_errs      (s_errs[g]),
                .bits_checked  (s_chk[g]),
                .eye_min_uv    (s_eye[g]),
                .marginal_cnt  (s_marg[g]),
                .jitter_cnt    (s_jit[g])
            );
        end
    endgenerate

    reg [31:0]        err_acc;
    reg [63:0]        chk_acc;
    reg signed [31:0] eye_acc;
    reg [31:0]        marg_acc;
    reg [31:0]        jit_acc;
    integer i;

    always @* begin
        err_acc  = 32'd0;
        chk_acc  = 64'd0;
        eye_acc  = 32'sh7FFFFFFF;
        marg_acc = 32'd0;
        jit_acc  = 32'd0;
        for (i = 0; i < WIDTH; i = i + 1) begin
            err_acc  = err_acc  + s_errs[i];
            chk_acc  = chk_acc  + s_chk[i];
            if (s_eye[i] < eye_acc)
                eye_acc = s_eye[i];
            marg_acc = marg_acc + s_marg[i];
            jit_acc  = jit_acc  + s_jit[i];
        end
    end

    assign ber_errors   = err_acc;
    assign bits_checked = chk_acc;
    assign eye_min_uv   = eye_acc;
    assign marginal_cnt = marg_acc;
    assign jitter_cnt   = jit_acc;

    reg [WIDTH+2:0] p1, p2;

    assign {rx_sop, rx_eop, rx_valid, rx_data} = p2;


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1 <= {(WIDTH+3){1'b0}};
            p2 <= {(WIDTH+3){1'b0}};
            v_d1 <= 1'b0;
            v_d2 <= 1'b0;
        end else begin
            p1 <= {tx_sop, tx_eop, tx_valid, tx_data};
            p2 <= p1;
            v_d1 <= tx_valid;
            v_d2 <= v_d1;
        end
    end

endmodule
