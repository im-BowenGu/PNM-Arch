// =============================================================================
// bf16_fp.vh — combinational BF16 arithmetic functions
//
// A compact, self-contained BF16 (bfloat16) soft-float library used by the
// integrated Gemma-4 decoder datapath (HDLF/core/gemma_decoder_block.v).  Every
// function takes and returns a 16-bit BF16 word:
//
//   bit 15    : sign
//   bits 14:7 : exponent, bias 127 (0 = zero/subnormal, 255 = inf/nan)
//   bits 6:0  : mantissa (7 bits)
//
// Semantics (deterministic; mirrored bit-for-bit by HDL/core/bf16_fp_ref.py):
//   bf16_mul/add/sub/div : round-to-nearest-even of the exact result.
//                          Subnormals are flushed to zero (FTZ), matching the
//                          bf16_fma hardware primitive used elsewhere.
//   bf16_exp/rsqrt/tanh  : fixed algorithms built only from the core ops plus
//                          integer range reduction, so RTL and the Python
//                          reference agree exactly.
//
// This file is a Verilog-2005 include (no module); instantiate the functions
// from any module.  Inf/NaN inputs are handled minimally (propagated); a
// decoder never produces them for the supported activation range.
// =============================================================================
`ifndef BF16_FP_VH
`define BF16_FP_VH

// -- constants ---------------------------------------------------------------
`define BF16_ONE   16'h3F80
`define BF16_TWO   16'h4000
`define BF16_HALF  16'h3F00
`define BF16_LOG2E 16'h3FB9   // 1.435546875 (nearest BF16 to log2 e)
`define BF16_LN2   16'h3F31   // 0.6923828125 (nearest BF16 to ln 2)
`define BF16_NAN   16'h7FC0
`define BF16_INF   16'h7F80

// -- classification: 0 = zero/subnormal(FTZ), 1 = normal, 2 = inf, 3 = nan ----
function [1:0] bf16_cls;
    input [15:0] x;
    begin
        if (x[14:7] == 8'hFF)
            bf16_cls = (x[6:0] == 7'd0) ? 2'd2 : 2'd3;
        else if (x[14:7] == 8'h00)
            bf16_cls = 2'd0;
        else
            bf16_cls = 2'd1;
    end
endfunction

function bf16_is_zero;
    input [15:0] x;
    begin bf16_is_zero = (bf16_cls(x) == 2'd0); end
endfunction

function [15:0] bf16_neg;
    input [15:0] x;
    begin bf16_neg = {~x[15], x[14:0]}; end
endfunction

function [15:0] bf16_abs;
    input [15:0] x;
    begin bf16_abs = {1'b0, x[14:0]}; end
endfunction

// -- pack sign s, unbiased exponent e, 8-bit significand m9 (128..255) --------
// Overflow -> inf, underflow -> signed zero (FTZ).
function [15:0] bf16_pack;
    input        s;
    input integer e;
    input [8:0]  m9;
    reg [8:0]    ee;
    begin
        ee = e + 127;
        if (ee >= 9'd255)      bf16_pack = {s, 8'hFF, 7'd0};
        else if (ee < 9'd1)    bf16_pack = {s, 15'd0};
        else                   bf16_pack = {s, ee[7:0], m9[6:0]};
    end
endfunction

// -- highest set bit index (0 if x == 0) -------------------------------------
function integer bf16_msb;
    input [31:0] x;
    integer i;
    begin
        bf16_msb = 0;
        for (i = 0; i < 32; i = i + 1)
            if (x[i]) bf16_msb = i;
    end
endfunction

// =============================================================================
// multiply : round-to-nearest-even (exact product)
// =============================================================================
function [15:0] bf16_mul;
    input [15:0] a, b;
    reg          s;
    reg [8:0]    ma, mb;
    reg [17:0]   prod;
    integer      L, e, sh;
    reg [8:0]    base, m9;
    reg          g, r, st, ru, ra, rb;
    begin
        s  = a[15] ^ b[15];
        ra = (bf16_cls(a) == 2'd0) || (bf16_cls(a) == 2'd3);
        rb = (bf16_cls(b) == 2'd0) || (bf16_cls(b) == 2'd3);
        if (bf16_cls(a) == 2'd3 || bf16_cls(b) == 2'd3)
            bf16_mul = `BF16_NAN;
        else if (bf16_cls(a) == 2'd0 || bf16_cls(b) == 2'd0)
            bf16_mul = {s, 15'd0};               // includes 0*inf -> 0 (rare)
        else if (bf16_cls(a) == 2'd2 || bf16_cls(b) == 2'd2)
            bf16_mul = {s, 8'hFF, 7'd0};
        else begin
            ma = {1'b1, a[6:0]};
            mb = {1'b1, b[6:0]};
            prod = ma * mb;                       // [2^14, 2^16)
            L    = bf16_msb({14'd0, prod});
            e    = (a[14:7] - 127) + (b[14:7] - 127) + (L - 14);
            sh   = L - 7;
            base = prod >> sh;
            g    = (sh >= 1) ? prod[sh-1] : 1'b0;
            r    = (sh >= 2) ? prod[sh-2] : 1'b0;
            st   = (sh >= 3) ? |(prod & ((1 << (sh-2)) - 1)) : 1'b0;
            ru   = g & (r | st | base[0]);
            m9   = base + ru;
            if (m9 == 9'd256) begin m9 = 9'd128; e = e + 1; end
            bf16_mul = bf16_pack(s, e, m9);
        end
    end
endfunction

// =============================================================================
// add : round-to-nearest-even (exact sum), sign-aware
// =============================================================================
function [15:0] bf16_add;
    input [15:0] a, b;
    reg          sA, sB, sres, sub_case, add_case;
    reg [8:0]    mA, mB;
    reg [31:0]   A, B, Bsh, S;
    integer      em, d, L, e, sh;
    reg [8:0]    base, m9;
    reg          g, r, st, ru, lost;
    reg [15:0]   vbig, vsmall;
    reg          sbig, ssmall;
    begin
        if (bf16_cls(a) == 2'd3 || bf16_cls(b) == 2'd3)
            bf16_add = `BF16_NAN;
        else if (bf16_cls(a) == 2'd0 && bf16_cls(b) == 2'd0)
            bf16_add = 16'h0000;
        else if (bf16_cls(a) == 2'd0)
            bf16_add = b;
        else if (bf16_cls(b) == 2'd0)
            bf16_add = a;
        else if (bf16_cls(a) == 2'd2 || bf16_cls(b) == 2'd2)
            bf16_add = `BF16_INF;               // inf + finite (opposite-inf rare)
        else begin
            if (a[14:7] >= b[14:7]) begin vbig = a; vsmall = b; end
            else                    begin vbig = b; vsmall = a; end
            sbig   = vbig[15];
            ssmall = vsmall[15];
            mA  = {1'b1, vbig[6:0]};
            mB  = {1'b1, vsmall[6:0]};
            em  = vbig[14:7];
            d   = vbig[14:7] - vsmall[14:7];
            A   = {23'd0, mA} << 14;            // exact, larger operand
            Bsh = {23'd0, mB} << 14;
            if (d == 0) begin
                B = Bsh; lost = 1'b0;
            end else if (d >= 22) begin
                B = 0; lost = (Bsh != 0);
            end else begin
                B = Bsh >> d;
                lost = |(Bsh & ((1 << d) - 1));
            end
            if (sbig == ssmall) begin
                S = A + B; sres = sbig; add_case = 1'b1;
            end else if (A >= B) begin
                S = A - B; sres = sbig; add_case = 1'b0;
            end else begin
                S = B - A; sres = ssmall; add_case = 1'b0;
            end
            // sub_case : the discarded bits belong to the smaller-magnitude
            // operand of an opposite-sign combine, i.e. they reduce |result|.
            sub_case = lost & ~add_case;
            if (S == 0) begin
                bf16_add = 16'h0000;               // exact zero is +0
            end else begin
                L  = bf16_msb(S);
                e  = L + (em - 134 - 14);
                sh = L - 7;
                if (sh >= 0) begin
                    base = S >> sh;
                    g    = S[sh-1];
                    r    = (sh >= 2) ? S[sh-2] : 1'b0;
                    st   = (sh >= 3) ? |(S & ((1 << (sh-2)) - 1)) : 1'b0;
                    // additive residual (same-sign) acts as extra sticky;
                    // subtractive residual at an exact half rounds down.
                    ru = g & (r | st | (lost & add_case) |
                              (base[0] & ~(sub_case & ~r & ~st)));
                end else begin
                    base = S << (-sh);
                    g = 1'b0; r = 1'b0; st = 1'b0;
                    ru = 1'b0;
                end
                m9 = base + ru;
                if (m9 == 9'd256) begin m9 = 9'd128; e = e + 1; end
                bf16_add = bf16_pack(sres, e, m9);
            end
        end
    end
endfunction

function [15:0] bf16_sub;
    input [15:0] a, b;
    begin bf16_sub = bf16_add(a, bf16_neg(b)); end
endfunction

// =============================================================================
// divide : round-to-nearest-even (exact quotient), unsigned magnitude
// =============================================================================
function [15:0] bf16_div;
    input [15:0] a, b;
    reg          s;
    reg [8:0]    ma, mb;
    reg [23:0]   num, Q;
    reg [23:0]   rem;
    integer      L, e, sh;
    reg [8:0]    base, m9;
    reg          g, r, st, ru;
    begin
        s = a[15] ^ b[15];
        if (bf16_cls(a) == 2'd3 || bf16_cls(b) == 2'd3)
            bf16_div = `BF16_NAN;
        else if (bf16_cls(a) == 2'd0 && bf16_cls(b) == 2'd0)
            bf16_div = `BF16_NAN;                // 0/0
        else if (bf16_cls(b) == 2'd0)
            bf16_div = (bf16_cls(a) == 2'd2) ? `BF16_NAN : {s, 8'hFF, 7'd0};
        else if (bf16_cls(a) == 2'd0)
            bf16_div = {s, 15'd0};
        else if (bf16_cls(a) == 2'd2 && bf16_cls(b) == 2'd2)
            bf16_div = `BF16_NAN;
        else if (bf16_cls(a) == 2'd2)
            bf16_div = {s, 8'hFF, 7'd0};
        else if (bf16_cls(b) == 2'd2)
            bf16_div = {s, 15'd0};
        else begin
            ma  = {1'b1, a[6:0]};
            mb  = {1'b1, b[6:0]};
            num = {15'd0, ma} << 14;             // ma * 2^14
            Q   = num / {15'd0, mb};
            rem = num % {15'd0, mb};
            L   = bf16_msb({8'd0, Q});
            e   = (a[14:7] - 127) - (b[14:7] - 127) + (L - 14);
            sh  = L - 7;
            base = Q >> sh;
            g    = Q[sh-1];
            r    = (sh >= 2) ? Q[sh-2] : 1'b0;
            st   = ((sh >= 3) ? |(Q & ((1 << (sh-2)) - 1)) : 1'b0) | (rem != 0);
            ru   = g & (r | st | base[0]);
            m9   = base + ru;
            if (m9 == 9'd256) begin m9 = 9'd128; e = e + 1; end
            bf16_div = bf16_pack(s, e, m9);
        end
    end
endfunction

// =============================================================================
// integer <-> BF16
// =============================================================================
function [15:0] bf16_int2bf;
    input integer iv;
    reg [31:0] mag;
    reg        s;
    integer    L, e;
    reg [8:0]  m9;
    begin
        s   = (iv < 0);
        mag = s ? -iv : iv;
        if (mag == 0) begin bf16_int2bf = 16'h0000; end
        else begin
            L  = bf16_msb(mag);
            e  = L;
            if (L >= 7) m9 = mag >> (L - 7);
            else        m9 = mag << (7 - L);
            bf16_int2bf = bf16_pack(s, e, m9);
        end
    end
endfunction

// floor(x) as a (signed) integer.  x normal only.
function integer bf16_floor;
    input [15:0] x;
    reg        s;
    reg [8:0]  sig;
    integer    e, sh, k;
    begin
        s   = x[15];
        sig = {1'b1, x[6:0]};
        e   = x[14:7] - 127;
        if (bf16_cls(x) == 2'd0) bf16_floor = 0;
        else if (e >= 7)         bf16_floor = s ? -(sig << (e-7)) : (sig << (e-7));
        else if (e >= 0) begin
            sh = 7 - e;
            k  = sig >> sh;
            if (s && ((sig & ((1 << sh) - 1)) != 0)) k = k + 1;
            bf16_floor = s ? -k : k;
        end else begin
            bf16_floor = s ? -1 : 0;             // |x| < 1
        end
    end
endfunction

// =============================================================================
// exponential : exp(x), fixed algorithm.
//   t = x * log2(e);  k = floor(t);  f = t - k in [0,1);
//   exp(x) = 2^k * 2^f, with 2^f from a 16-entry BF16 LUT (2^(i/16)).
// =============================================================================
function [15:0] bf16_exp2f;      // 2^f for f in [0,1)
    input [15:0] f;
    reg [3:0]    idx;
    begin
        idx = bf16_floor(bf16_mul(f, 16'h4180));   // round-ish f*16
        case (idx)
            4'd0:  bf16_exp2f = 16'h3F80; // 1.000
            4'd1:  bf16_exp2f = 16'h3FA9; // 1.0443
            4'd2:  bf16_exp2f = 16'h3FD2; // 1.0905
            4'd3:  bf16_exp2f = 16'h3FFD; // 1.1388
            4'd4:  bf16_exp2f = 16'h4027; // 1.1892
            4'd5:  bf16_exp2f = 16'h4052; // 1.2419
            4'd6:  bf16_exp2f = 16'h407E; // 1.2968
            4'd7:  bf16_exp2f = 16'h40AB; // 1.3543
            4'd8:  bf16_exp2f = 16'h40D9; // 1.4142
            4'd9:  bf16_exp2f = 16'h4109; // 1.4770
            4'd10: bf16_exp2f = 16'h413A; // 1.5422
            4'd11: bf16_exp2f = 16'h416C; // 1.6105
            4'd12: bf16_exp2f = 16'h41A0; // 1.6818
            4'd13: bf16_exp2f = 16'h41D5; // 1.7563
            4'd14: bf16_exp2f = 16'h420B; // 1.8340
            4'd15: bf16_exp2f = 16'h4243; // 1.9152
            default: bf16_exp2f = 16'h427C; // 2.0000 (idx 16)
        endcase
    end
endfunction

function [15:0] bf16_exp;
    input [15:0] x;
    reg [15:0]   t, f, p2k;
    integer      k;
    reg [8:0]    ee;
    begin
        if (bf16_cls(x) == 2'd0) bf16_exp = `BF16_ONE;
        // Large-magnitude guard:  bf16_floor returns a 32-bit integer, whose
        // `sig << (e-7)` overflows for |x| >= ~2^31 — far below the true exp
        // overflow bound (|x| ~ 88.7 => exp(x) ~ 2^128).  Clamp those extremes
        // first: |x| >= bf16(88.96)=0x42B2 saturates exp to INF/+0.
        else if (x[15] == 1'b0 && x >= 16'h42B2) bf16_exp = `BF16_INF;
        else if (x[15] == 1'b1 && x >= 16'hC2B2) bf16_exp = 16'h0000;
        else begin
            t = bf16_mul(x, `BF16_LOG2E);
            k = bf16_floor(t);
            f = bf16_sub(t, bf16_int2bf(k));       // in [0,1)
            if (k > 128)       bf16_exp = `BF16_INF;
            else if (k < -128) bf16_exp = 16'h0000;
            else begin
                ee  = k + 127;
                p2k = (k >= -126) ? {1'b0, ee[7:0], 7'd0} : `BF16_ONE; // FTZ tiny
                bf16_exp = bf16_mul(p2k, bf16_exp2f(f));
            end
        end
    end
endfunction

// =============================================================================
// reciprocal square root, Newton-Raphson from a bit-hack seed.
//   seed = 2^(-e/2) (exponent halve);  y <- y*(1.5 - 0.5*x*y*y), 4 iters.
// =============================================================================
function [15:0] bf16_rsqrt;
    input [15:0] x;
    integer      e, se;
    reg [15:0]   y;
    integer      i;
    begin
        if (bf16_cls(x) != 2'd1)
            bf16_rsqrt = 16'h0000;
        else begin
            e  = x[14:7] - 127;
            se = 127 - (e / 2);                    // floor division
            y  = (se >= 1) ? {1'b0, se[7:0], 7'd0} : `BF16_ONE;
            for (i = 0; i < 4; i = i + 1)
                y = bf16_mul(y, bf16_sub(16'h3FC0, bf16_mul(16'h3F00, bf16_mul(x, bf16_mul(y, y)))));
            bf16_rsqrt = y;
        end
    end
endfunction

// =============================================================================
// hyperbolic tangent : tanh(x) = 1 - 2/(exp(2x)+1)
// =============================================================================
function [15:0] bf16_tanh;
    input [15:0] x;
    reg [15:0]   e2, den, r;
    begin
        e2  = bf16_exp(bf16_mul(x, `BF16_TWO));
        den = bf16_add(e2, `BF16_ONE);
        r   = bf16_div(`BF16_TWO, den);
        bf16_tanh = bf16_sub(`BF16_ONE, r);
    end
endfunction

// =============================================================================
// numeric greater-than on BF16 words.  The 15-bit magnitude field [14:0] is
// monotonic in |x| (exponent then mantissa), so compares are bit math.
// Zeros/inf/nan are not exercised by the decoder path.
// =============================================================================
function bf16_gt;
    input [15:0] a, b;
    begin
        if (a[15] != b[15])
            bf16_gt = ~a[15] & ((a[14:7] != 0) | (b[14:7] != 0));
        else if (a[14:7] == 0)
            bf16_gt = 1'b0;
        else if (b[14:7] == 0)
            bf16_gt = ~a[15];
        else if (a[15])
            bf16_gt = (a[14:0] < b[14:0]);
        else
            bf16_gt = (a[14:0] > b[14:0]);
    end
endfunction

// =============================================================================
// GELU (tanh form) : 0.5*x*(1 + tanh(A*(x + B*x^3))), A/B from the emitter.
// =============================================================================
function [15:0] bf16_gelu;
    input [15:0] x;
    input [15:0] cA, cB;
    reg [15:0]   x3, inner, t, r, p;
    begin
        x3    = bf16_mul(bf16_mul(x, x), x);
        inner = bf16_add(x, bf16_mul(x3, cB));
        t     = bf16_mul(inner, cA);
        r     = bf16_div(`BF16_TWO, bf16_add(bf16_exp(bf16_mul(t, `BF16_TWO)), `BF16_ONE));
        p     = bf16_sub(`BF16_ONE, r);
        p     = bf16_add(`BF16_ONE, p);
        bf16_gelu = bf16_mul(bf16_mul(x, `BF16_HALF), p);
    end
endfunction

`endif
