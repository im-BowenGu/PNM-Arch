`timescale 1ns/1ps

// =============================================================================
// gemma_decoder_block — integrated Gemma-4 decoder datapath (homunculus size).
//
// Mirrors HDL/core/real_decoder_block.py (the spec reference) op-for-op; every
// arithmetic step is a BF16 op from HDL/core/bf16_fp.vh.  The FSM is a
// straight-line program: one clock per stage, blocking assigns inside, so the
// result is bit-exact against the reference when both consume the same BF16
// words (weights, KV cache, rope tables, input).
//
// Configuration (parameterized; the emitters use N=16 NH=2 HD=8 FFD=16 E=4
// EFF=8 CACHE=4):
//   N   hidden size
//   NH  heads, HD head dim   (N == NH*HD)
//   FFD dense MLP width, E experts, EFF expert MLP width, CACHE keys
//
// Memories are preloaded over a small load port; `start` runs the block;
// `done` pulses; `x` holds the final hidden state (read via o_addr/o_data).
// =============================================================================
module gemma_decoder_block #(
    parameter N = 16, NH = 2, HD = 8, FFD = 16, E = 4, EFF = 8, CACHE = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // -- preload ports -------------------------------------------------------
    input  wire        w_we,  input wire [15:0] w_addr, input wire [15:0] w_data,
    input  wire        k_we,  input wire [6:0]  k_addr, input wire [15:0] k_data,
    input  wire        v_we,  input wire [6:0]  v_addr, input wire [15:0] v_data,
    input  wire        r_we,  input wire [8:0]  r_addr, input wire [15:0] r_data,
    input  wire        x_we,  input wire [3:0]  x_addr, input wire [15:0] x_data,

    // -- control / result ----------------------------------------------------
    input  wire        start,
    output reg         done,
    output reg  [15:0] o_data,
    input  wire [3:0]  o_addr
);

    `include "bf16_fp.vh"
    `include "dblock_addrs.vh"

    localparam POSQ = CACHE;
    localparam NP   = HD / 2;

    localparam CB_EPS     = `CC_EPS;
    localparam CB_INVN    = `CC_INVN;
    localparam CB_INVHD   = `CC_INVHD;
    localparam CB_INVSQRTN= `CC_INVSQRTN;
    localparam CB_GELUA   = `CC_GELUA;
    localparam CB_GELUB   = `CC_GELUB;
    localparam CB_LSCA    = `CC_LSCA;

    // -- memories ------------------------------------------------------------
    reg [15:0] wmem [0:`WMEMSZ-1];
    reg [15:0] kcache [0:CACHE*N-1];
    reg [15:0] vcache [0:CACHE*N-1];
    reg [15:0] roperam [0:(CACHE+1)*NH*NP*2-1];

    always @(posedge clk) begin
        if (w_we) wmem[w_addr] <= w_data;
        if (k_we) kcache[k_addr] <= k_data;
        if (v_we) vcache[v_addr] <= v_data;
        if (r_we) roperam[r_addr] <= r_data;
        if (x_we) x[x_addr] <= x_data;
    end

    // -- datapath registers --------------------------------------------------
    reg [15:0] x [0:N-1];
    reg [15:0] res [0:N-1];
    reg [15:0] tq [0:N-1];
    reg [15:0] qk [0:N-1];
    reg [15:0] kk [0:N-1];
    reg [15:0] vv [0:N-1];
    reg [15:0] qr [0:N-1];
    reg [15:0] score [0:NH*CACHE-1];
    reg [15:0] earr [0:NH*CACHE-1];
    reg [15:0] prob [0:NH*CACHE-1];
    reg [15:0] ctx [0:N-1];
    reg [15:0] ao [0:N-1];
    reg [15:0] u [0:N-1];
    reg [15:0] gate [0:FFD-1];
    reg [15:0] upi [0:FFD-1];
    reg [15:0] act [0:FFD-1];
    reg [15:0] dense [0:N-1];
    reg [15:0] h1 [0:N-1];
    reg [15:0] h2 [0:N-1];
    reg [15:0] moe [0:N-1];
    reg [15:0] dk [0:N-1];
    reg [15:0] rout [0:N-1];
    reg [15:0] pe [0:E-1];
    reg [15:0] pee [0:E-1];
    reg [15:0] x2 [0:N-1];
    reg [15:0] comb [0:N-1];

    reg [15:0] sacc;
    reg [15:0] vinv;
    reg [15:0] mx;
    reg [15:0] w0f, w1f, wsum;
    integer    t0, t1;

    integer i, j, o, h, c, d, p, k, r, e;
    reg [8:0] st;

    // -- FSM -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin : fsm
        if (!rst_n) begin
            st <= 0;
            done <= 0;
        end else if (start) begin
            st <= 1;
            done <= 0;
        end else begin
            case (st)
                // ---------- input_layernorm(x); save residual ----------
                1: begin
                    for (i = 0; i < N; i = i + 1) res[i] = x[i];
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(x[i], x[i]));
                end
                2: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                3: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        x[i] = bf16_mul(bf16_mul(x[i], vinv), wmem[`AW_N1 + i]);
                end
                // ---------- q/k/v projections -----------------------------
                4: begin
                    for (o = 0; o < N; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_Q + o*N + j], x[j]));
                        qk[o] = sacc;
                    end
                end
                5: begin
                    for (o = 0; o < N; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_K + o*N + j], x[j]));
                        kk[o] = sacc;
                    end
                end
                6: begin
                    for (o = 0; o < N; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_V + o*N + j], x[j]));
                        vv[o] = sacc;
                    end
                end
                // ---------- q_norm (per head) + rope @ POSQ ---------------
                7: begin
                    for (h = 0; h < NH; h = h + 1) begin
                        sacc = 16'h0000;
                        for (d = 0; d < HD; d = d + 1) begin
                            sacc = bf16_add(sacc, bf16_mul(qk[h*HD + d], qk[h*HD + d]));
                        end
                        vinv = bf16_rsqrt(bf16_add(bf16_mul(sacc, CB_INVHD), CB_EPS));
                        for (d = 0; d < HD; d = d + 1)
                            tq[h*HD + d] = bf16_mul(bf16_mul(qk[h*HD + d], vinv),
                                                    wmem[`AW_QN + h*HD + d]);
                        for (p = 0; p < NP; p = p + 1) begin
                            qr[h*HD + 2*p]   = bf16_sub(bf16_mul(tq[h*HD + 2*p],
                                        roperam[((POSQ*NH+h)*NP + p)*2 + 0]),
                                        bf16_mul(tq[h*HD + 2*p + 1],
                                        roperam[((POSQ*NH+h)*NP + p)*2 + 1]));
                            qr[h*HD + 2*p+1] = bf16_add(bf16_mul(tq[h*HD + 2*p],
                                        roperam[((POSQ*NH+h)*NP + p)*2 + 1]),
                                        bf16_mul(tq[h*HD + 2*p + 1],
                                        roperam[((POSQ*NH+h)*NP + p)*2 + 0]));
                        end
                    end
                end
                // ---------- attention scores over KV cache ------------------
                8: begin
                    for (h = 0; h < NH; h = h + 1)
                        for (c = 0; c < CACHE; c = c + 1) begin
                            sacc = 16'h0000;
                            for (d = 0; d < HD; d = d + 1)
                                sacc = bf16_add(sacc, bf16_mul(qr[h*HD + d],
                                        kcache[c*N + h*HD + d]));
                            score[h*CACHE + c] = sacc;
                        end
                end
                9: begin
                    for (h = 0; h < NH; h = h + 1) begin
                        mx = score[h*CACHE + 0];
                        for (c = 1; c < CACHE; c = c + 1)
                            if (bf16_gt(score[h*CACHE + c], mx)) mx = score[h*CACHE + c];
                        for (c = 0; c < CACHE; c = c + 1)
                            earr[h*CACHE + c] = bf16_exp(bf16_sub(score[h*CACHE + c], mx));
                        sacc = 16'h0000;
                        for (c = 0; c < CACHE; c = c + 1)
                            sacc = bf16_add(sacc, earr[h*CACHE + c]);
                        for (c = 0; c < CACHE; c = c + 1)
                            prob[h*CACHE + c] = bf16_div(earr[h*CACHE + c], sacc);
                    end
                end
                10: begin
                    for (h = 0; h < NH; h = h + 1)
                        for (d = 0; d < HD; d = d + 1) begin
                            sacc = 16'h0000;
                            for (c = 0; c < CACHE; c = c + 1)
                                sacc = bf16_add(sacc, bf16_mul(prob[h*CACHE + c],
                                        vcache[c*N + h*HD + d]));
                            ctx[h*HD + d] = sacc;
                        end
                end
                11: begin
                    for (o = 0; o < N; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_O + o*N + j], ctx[j]));
                        ao[o] = sacc;
                    end
                end
                // ---------- post_attention_layernorm(ao);  x = +res ---------
                12: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(ao[i], ao[i]));
                end
                13: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                14: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1) begin
                        tq[i] = bf16_mul(bf16_mul(ao[i], vinv), wmem[`AW_N2 + i]);
                        x[i]  = bf16_add(tq[i], res[i]);
                        res[i] = x[i];
                    end
                end
                // ---------- pre_feedforward_layernorm(x) -------------------
                15: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(x[i], x[i]));
                end
                16: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                17: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        u[i] = bf16_mul(bf16_mul(x[i], vinv), wmem[`AW_PRE1 + i]);
                end
                // ---------- dense MLP: gate / up / gelu / down -------------
                18: begin
                    for (o = 0; o < FFD; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_GATE + o*N + j], u[j]));
                        gate[o] = sacc;
                    end
                end
                19: begin
                    for (o = 0; o < FFD; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_UP + o*N + j], u[j]));
                        upi[o] = sacc;
                    end
                end
                20: begin
                    for (i = 0; i < FFD; i = i + 1)
                        act[i] = bf16_mul(bf16_gelu(gate[i], CB_GELUA, CB_GELUB), upi[i]);
                end
                21: begin
                    for (o = 0; o < N; o = o + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < FFD; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_DOWN + o*FFD + j], act[j]));
                        dense[o] = sacc;
                    end
                end
                // ---------- h1 = post_ff_1_norm(dense) ---------------------
                22: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(dense[i], dense[i]));
                end
                23: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                24: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        h1[i] = bf16_mul(bf16_mul(dense[i], vinv), wmem[`AW_PF1 + i]);
                end
                // ---------- router on plain residual ------------------------
                25: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(res[i], res[i]));
                end
                26: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                27: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        rout[i] = bf16_mul(bf16_mul(bf16_mul(res[i], vinv),
                                        wmem[`AW_RSCA + i]), CB_INVSQRTN);
                end
                28: begin
                    for (e = 0; e < E; e = e + 1) begin
                        sacc = 16'h0000;
                        for (j = 0; j < N; j = j + 1)
                            sacc = bf16_add(sacc, bf16_mul(wmem[`AW_RPROJ + e*N + j], rout[j]));
                        pe[e] = sacc;
                    end
                end
                // ---------- softmax over E experts --------------------------
                29: begin
                    mx = pe[0];
                    for (e = 1; e < E; e = e + 1)
                        if (bf16_gt(pe[e], mx)) mx = pe[e];
                    for (e = 0; e < E; e = e + 1)
                        pee[e] = bf16_exp(bf16_sub(pe[e], mx));
                    sacc = 16'h0000;
                    for (e = 0; e < E; e = e + 1)
                        sacc = bf16_add(sacc, pee[e]);
                    for (e = 0; e < E; e = e + 1)
                        pe[e] = bf16_div(pee[e], sacc);
                end
                // ---------- top-2 + normalize + per_expert_scale ------------
                30: begin
                    t0 = 0;
                    for (e = 1; e < E; e = e + 1)
                        if (bf16_gt(pe[e], pe[t0])) t0 = e;
                    t1 = (t0 == 0) ? 1 : 0;
                    for (e = 0; e < E; e = e + 1)
                        if (e != t0 && bf16_gt(pe[e], pe[t1])) t1 = e;
                    wsum = bf16_add(pe[t0], pe[t1]);
                    w0f = bf16_mul(bf16_div(pe[t0], wsum), wmem[`AW_PES + t0]);
                    w1f = bf16_mul(bf16_div(pe[t1], wsum), wmem[`AW_PES + t1]);
                end
                // ---------- x2 = pre_ff_2_norm(res) (expert input) ----------
                31: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(res[i], res[i]));
                end
                32: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                33: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        x2[i] = bf16_mul(bf16_mul(res[i], vinv), wmem[`AW_PRE2 + i]);
                end
                // ---------- expert pass (ascending expert index) ------------
                34: begin
                    for (i = 0; i < N; i = i + 1) moe[i] = 16'h0000;
                    // expert 0
                    if (0 == t0 || 0 == t1) begin
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (0*2*EFF + r)*N + j], x2[j]));
                            gate[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (0*2*EFF + EFF + r)*N + j], x2[j]));
                            upi[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1)
                            act[r] = bf16_mul(bf16_gelu(gate[r], CB_GELUA, CB_GELUB), upi[r]);
                        for (r = 0; r < N; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < EFF; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EDOW + (0*N + r)*EFF + j], act[j]));
                            dk[r] = sacc;
                        end
                        for (r = 0; r < N; r = r + 1)
                            moe[r] = bf16_add(moe[r], bf16_mul((0 == t0) ? w0f : w1f, dk[r]));
                    end
                end
                35: begin
                    // expert 1
                    if (1 == t0 || 1 == t1) begin
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (1*2*EFF + r)*N + j], x2[j]));
                            gate[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (1*2*EFF + EFF + r)*N + j], x2[j]));
                            upi[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1)
                            act[r] = bf16_mul(bf16_gelu(gate[r], CB_GELUA, CB_GELUB), upi[r]);
                        for (r = 0; r < N; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < EFF; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EDOW + (1*N + r)*EFF + j], act[j]));
                            dk[r] = sacc;
                        end
                        for (r = 0; r < N; r = r + 1)
                            moe[r] = bf16_add(moe[r], bf16_mul((1 == t0) ? w0f : w1f, dk[r]));
                    end
                end
                36: begin
                    // expert 2
                    if (2 == t0 || 2 == t1) begin
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (2*2*EFF + r)*N + j], x2[j]));
                            gate[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (2*2*EFF + EFF + r)*N + j], x2[j]));
                            upi[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1)
                            act[r] = bf16_mul(bf16_gelu(gate[r], CB_GELUA, CB_GELUB), upi[r]);
                        for (r = 0; r < N; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < EFF; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EDOW + (2*N + r)*EFF + j], act[j]));
                            dk[r] = sacc;
                        end
                        for (r = 0; r < N; r = r + 1)
                            moe[r] = bf16_add(moe[r], bf16_mul((2 == t0) ? w0f : w1f, dk[r]));
                    end
                end
                37: begin
                    // expert 3
                    if (3 == t0 || 3 == t1) begin
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (3*2*EFF + r)*N + j], x2[j]));
                            gate[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < N; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EGU + (3*2*EFF + EFF + r)*N + j], x2[j]));
                            upi[r] = sacc;
                        end
                        for (r = 0; r < EFF; r = r + 1)
                            act[r] = bf16_mul(bf16_gelu(gate[r], CB_GELUA, CB_GELUB), upi[r]);
                        for (r = 0; r < N; r = r + 1) begin
                            sacc = 16'h0000;
                            for (j = 0; j < EFF; j = j + 1)
                                sacc = bf16_add(sacc, bf16_mul(wmem[`AW_EDOW + (3*N + r)*EFF + j], act[j]));
                            dk[r] = sacc;
                        end
                        for (r = 0; r < N; r = r + 1)
                            moe[r] = bf16_add(moe[r], bf16_mul((3 == t0) ? w0f : w1f, dk[r]));
                    end
                end
                // ---------- h2 = post_ff_2_norm(moe) ------------------------
                38: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(moe[i], moe[i]));
                end
                39: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                40: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1)
                        h2[i] = bf16_mul(bf16_mul(moe[i], vinv), wmem[`AW_PF2 + i]);
                end
                // ---------- combine, post_ff_norm, residual, layer_scalar ---
                41: begin
                    for (i = 0; i < N; i = i + 1)
                        comb[i] = bf16_add(h1[i], h2[i]);
                end
                42: begin
                    sacc = 16'h0000;
                    for (i = 0; i < N; i = i + 1)
                        sacc = bf16_add(sacc, bf16_mul(comb[i], comb[i]));
                end
                43: begin
                    sacc = bf16_mul(sacc, CB_INVN);
                    sacc = bf16_add(sacc, CB_EPS);
                end
                44: begin
                    vinv = bf16_rsqrt(sacc);
                    for (i = 0; i < N; i = i + 1) begin
                        tq[i] = bf16_mul(bf16_mul(comb[i], vinv), wmem[`AW_PFF + i]);
                        x[i]  = bf16_mul(bf16_add(tq[i], res[i]), CB_LSCA);
                    end
                end
                45: begin
                    done <= 1;
                    st   <= 45;
                end
                default: ;
            endcase
            if (st >= 1 && st < 45) st <= st + 1;
        end
    end

    always @(*) begin
        o_data = x[o_addr];
    end

endmodule