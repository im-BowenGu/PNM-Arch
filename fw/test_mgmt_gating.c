/**
 * test_mgmt_gating.c — the embedded management node's firmware.
 *
 * The management node is the mode-A manager of the gating ASIC: it programs
 * the router weights, gates each token, and emits the dispatch flits.  This
 * test drives the firmware against a behavioural model of the gating ASIC
 * (the same register semantics as HDL/core/gating_asic.v) and checks:
 *
 *   - the weight programming reaches the ASIC in the right order, with the
 *     coordinate latched first and the write pointer set once;
 *   - the hidden vector is written before the start, and as big-endian
 *     16-bit words;
 *   - the decision is read back through the rank window;
 *   - the dispatch flit is byte-exact: the header, the payload, and the
 *     CRC-16/CCITT-FALSE over the protected body, checked against an
 *     independently computed reference;
 *   - the CRC-16 helper agrees with the harness's Go implementation on a
 *     known vector.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "pnm_mgmt.h"
#include "pnm_crc16.h"

static int errors = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); \
        errors++; \
    } \
} while (0)

/* ------------------------------------------------------------------ */
/* A behavioural model of the gating ASIC                               */
/* ------------------------------------------------------------------ */

#define MODEL_MAX_WORDS 4096

typedef struct {
    /* the register file */
    uint16_t wght_addr;
    uint16_t hid_addr;
    uint16_t wght_data;
    uint16_t hid_data;
    uint8_t  coord_l, coord_m;
    uint8_t  started;
    uint8_t  busy;

    /* the memories */
    uint16_t weights[MODEL_MAX_WORDS];
    uint16_t hidden[MODEL_MAX_WORDS];
    int      nweights;
    int      nhidden;

    /* the decision the model returns (the real ASIC computes it) */
    uint16_t decision_idx[8];
    uint16_t decision_logit[8];

    /* the observation of what the firmware did */
    int      n_writes;
    int      n_reads;
    uint16_t last_addr;
    int      ctrl_written;      /* the step at which CTRL was written */
    int      hid_written;       /* the step at which the hidden vector ended */
    int      step;
} model_t;

static model_t g_model;

/* The trace of bus transactions, so the RTL can replay the firmware's exact
 * sequence and check that the silicon agrees with it.  Set PNM_MGMT_TRACE to
 * change where it goes. */
static FILE *g_trace = NULL;

static void model_write(void *ctx, uint16_t addr, uint16_t data)
{
    model_t *m = (model_t *)ctx;
    if (g_trace) fprintf(g_trace, "W %04X %04X\n", addr, data);
    m->n_writes++;
    m->last_addr = addr;
    m->step++;
    switch (addr) {
    case MGMT_REG_COORD_L:
        m->coord_l = (uint8_t)data;
        break;
    case MGMT_REG_COORD_M:
        m->coord_m = (uint8_t)data;
        break;
    case MGMT_REG_WGHT_ADDR_LO:
        m->wght_addr = data;
        break;
    case MGMT_REG_WGHT_ADDR_HI:
        m->wght_addr = (uint16_t)((m->wght_addr & 0x00FF) | (data << 8));
        break;
    case MGMT_REG_WGHT_DATA:
        if (m->nweights < MODEL_MAX_WORDS)
            m->weights[m->nweights++] = data;
        m->wght_addr++;
        break;
    case MGMT_REG_HID_ADDR_LO:
        m->hid_addr = data;
        break;
    case MGMT_REG_HID_ADDR_HI:
        m->hid_addr = (uint16_t)((m->hid_addr & 0x00FF) | (data << 8));
        break;
    case MGMT_REG_HID_DATA:
        if (m->nhidden < MODEL_MAX_WORDS)
            m->hidden[m->nhidden++] = data;
        m->hid_addr++;
        break;
    case MGMT_REG_CTRL:
        if (data & 0x0001u) {
            m->started = 1;
            m->busy = 1;
            m->ctrl_written = m->step;
        }
        break;
    default:
        break;
    }
}

static uint16_t model_read(void *ctx, uint16_t addr)
{
    model_t *m = (model_t *)ctx;
    if (g_trace) fprintf(g_trace, "R %04X\n", addr);
    m->n_reads++;
    switch (addr) {
    case MGMT_REG_STATUS:
        /* The engine finishes after one read of the status (the real ASIC
         * holds busy for the length of the computation). */
        if (m->busy) {
            m->busy = 0;
            return MGMT_STATUS_BUSY;
        }
        return 0;
    default:
        break;
    }
    if (addr >= MGMT_REG_RANK_IDX && addr < MGMT_REG_RANK_IDX + 16) {
        int k = (addr - MGMT_REG_RANK_IDX) / 2;
        if (k < 8) return m->decision_idx[k];
    }
    if (addr >= MGMT_REG_RANK_LOG && addr < MGMT_REG_RANK_LOG + 16) {
        int k = (addr - MGMT_REG_RANK_LOG) / 2;
        if (k < 8) return m->decision_logit[k];
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* An independent CRC reference                                         */
/* ------------------------------------------------------------------ */

static uint16_t ref_crc16(const uint8_t *d, int n)
{
    uint16_t crc = 0xFFFFu;
    int i, b;
    for (i = 0; i < n; i++) {
        crc ^= (uint16_t)((uint16_t)d[i] << 8);
        for (b = 0; b < 8; b++) {
            if (crc & 0x8000u) crc = (uint16_t)((crc << 1) ^ 0x1021u);
            else             crc = (uint16_t)(crc << 1);
        }
    }
    return crc;
}

int main(void)
{
    mgmt_t mg;
    mgmt_bus_t bus;
    static uint16_t weights[64];
    static uint8_t token[16];
    int i, step;
    bool done;
    int flits = 0;
    uint8_t first_flit[64];
    int first_flit_len = 0;

    /* the CRC helper against a known vector: the harness's Go
     * implementation (sim/internal/pnm/crc.go) produces 0x1021 for the
     * ASCII string "123456789" with the CCITT-FALSE parameters. */
    {
        const uint8_t check[] = "123456789";
        uint16_t crc = pnm_crc16(check, 9);
        CHECK(crc == 0x29B1u, "the CRC of \"123456789\" is %04X, expected 29B1", crc);
    }

    /* ---------------- the node's setup ---------------- */
    memset(&g_model, 0, sizeof(g_model));
    bus.write = model_write;
    bus.read = model_read;
    bus.ctx = &g_model;

    {
        const char *path = getenv("PNM_MGMT_TRACE");
        g_trace = fopen(path ? path : "/tmp/pnm_mgmt_trace.txt", "w");
        if (!g_trace) {
            printf("FAIL: cannot open the trace file\n");
            return 1;
        }
    }

    mgmt_init(&mg, &bus, 3, 0x25);
    mg.num_experts = 8;
    mg.top_k = 2;
    mg.hidden_dim = 8;

    /* the local expert map: this node's gating ASIC can select experts 0
     * and 2, which live on two other nodes */
    mg.experts[0].expert_idx = 0;
    mg.experts[0].target_layer = 3;
    mg.experts[0].target_x = 0;
    mg.experts[0].target_y = 1;
    mg.experts[1].expert_idx = 2;
    mg.experts[1].target_layer = 3;
    mg.experts[1].target_x = 1;
    mg.experts[1].target_y = 2;
    mg.num_mapped = 2;

    /* the router blob the host streamed to the node */
    for (i = 0; i < 64; i++)
        weights[i] = (uint16_t)(0x3C00u + i);   /* 1.0, 1.0078, ... */
    CHECK(mgmt_program_weights(&mg, weights, 64) == 0,
          "the weight programming failed");
    CHECK(g_model.nweights == 64, "the ASIC received %d weights, expected 64",
          g_model.nweights);
    CHECK(g_model.coord_l == 3 && g_model.coord_m == 0x25,
          "the coordinate was latched as (%d, %d)", g_model.coord_l, g_model.coord_m);
    for (i = 0; i < 64; i++)
        CHECK(g_model.weights[i] == weights[i],
              "weight %d is %04X, expected %04X", i, g_model.weights[i], weights[i]);

    /* ---------------- the host streams the router weights ---------------- */
    /* The host's weight-upload flits reach the board's receive path, which
     * hands the bytes to the management node; the node programs them into
     * the ASIC as they arrive, so it never holds the whole router. */
    {
        int w;
        mgmt_receive_begin(&mg, 64);
        CHECK(mg.state == MGMT_STATE_RECEIVE,
              "the receive did not start (state %d)", mg.state);
        for (w = 0; w < 64; w++) {
            mgmt_receive_byte(&mg, (uint8_t)(weights[w] >> 8));
            mgmt_receive_byte(&mg, (uint8_t)(weights[w] & 0xFF));
        }
        CHECK(mg.state == MGMT_STATE_IDLE,
              "the receive did not finish (state %d)", mg.state);
        CHECK(mg.rx_count == 64, "the node received %u words, expected 64",
              mg.rx_count);
        for (w = 0; w < 64; w++)
            CHECK(g_model.weights[w] == weights[w],
                  "the streamed weight %d is %04X, expected %04X", w,
                  g_model.weights[w], weights[w]);
        printf("ok: the node streamed %u router words into the ASIC\n",
               mg.rx_count);
    }

    /* ---------------- a token ---------------- */
    /* the payload carries the hidden state as big-endian 16-bit words */
    for (i = 0; i < 8; i++) {
        token[2 * i] = (uint8_t)(0x40u + i);
        token[2 * i + 1] = (uint8_t)(0x30u + i);
    }
    mgmt_push_token(&mg, token, 16);

    /* the model's decision: experts 0 and 2 (the two this node holds) */
    g_model.decision_idx[0] = 0;
    g_model.decision_logit[0] = 0xC130u;
    g_model.decision_idx[1] = 2;
    g_model.decision_logit[1] = 0xC158u;

    /* ---------------- run the state machine ---------------- */
    /* The state machine emits one flit per selected expert; the flit is
     * collected as it is produced, because mg->flit holds the *last* one
     * when the token's dispatch finishes. */
    done = false;
    for (step = 0; step < 1000; step++) {
        bool produced = mgmt_step(&mg);
        if (mg.have_flit) {
            if (flits == 0) {
                memcpy(first_flit, mg.flit.bytes, (size_t)mg.flit.nbytes);
                first_flit_len = mg.flit.nbytes;
            }
            flits++;
            mg.have_flit = false;
        }
        if (produced) { done = true; break; }
    }

    CHECK(done, "the state machine did not finish the token");
    CHECK(mg.tokens_gated == 1, "the token was gated %u times", mg.tokens_gated);
    CHECK(mg.num_selected == 2, "the decision had %d ranks, expected 2",
          mg.num_selected);
    CHECK(mg.selected[0] == 0 && mg.selected[1] == 2,
          "the decision was [%u, %u], expected [0, 2]",
          mg.selected[0], mg.selected[1]);
    CHECK(mg.selected_logit[0] == 0xC130u && mg.selected_logit[1] == 0xC158u,
          "the decision's logits are [%04X, %04X]", mg.selected_logit[0],
          mg.selected_logit[1]);

    /* the hidden vector must have been written before the start */
    CHECK(g_model.nhidden == 8, "the ASIC received %d hidden words, expected 8",
          g_model.nhidden);
    CHECK(g_model.hid_written == 0, "internal");
    for (i = 0; i < 8; i++) {
        uint16_t want = (uint16_t)(((uint16_t)token[2 * i] << 8) | token[2 * i + 1]);
        CHECK(g_model.hidden[i] == want,
              "hidden word %d is %04X, expected %04X", i, g_model.hidden[i], want);
    }

    /* the dispatch flit: byte-exact, with an independently computed CRC */
    CHECK(flits == 2, "the token produced %d dispatch flits, expected 2", flits);
    CHECK(first_flit_len == 5 + 16 + 2, "the flit is %d bytes, expected 23",
          first_flit_len);
    CHECK(first_flit[0] == 3, "the flit's LAYER is %u, expected 3", first_flit[0]);
    CHECK(first_flit[1] == 0x01, "the flit's MODULE is %02X, expected 01",
          first_flit[1]);
    CHECK(first_flit[2] == 0x80, "the flit's CTRL is %02X, expected 80",
          first_flit[2]);
    CHECK(first_flit[3] == 16 && first_flit[4] == 0,
          "the flit's LEN is %02X%02X, expected 0010", first_flit[4],
          first_flit[3]);
    for (i = 0; i < 16; i++)
        CHECK(first_flit[5 + i] == token[i],
              "the flit's payload byte %d is %02X, expected %02X", i,
              (unsigned)first_flit[5 + i], (unsigned)token[i]);
    {
        uint16_t crc = ref_crc16(&first_flit[1], 4 + 16);
        CHECK(first_flit[21] == (uint8_t)(crc >> 8) &&
              first_flit[22] == (uint8_t)(crc & 0xFF),
              "the flit's CRC is %02X%02X, expected %04X", first_flit[22],
              first_flit[21], crc);
    }

    /* ---------------- a second token, to prove the loop repeats ---------------- */
    g_model.decision_idx[0] = 2;
    g_model.decision_idx[1] = 0;
    mgmt_push_token(&mg, token, 16);
    flits = 0;
    done = false;
    for (step = 0; step < 1000; step++) {
        bool produced = mgmt_step(&mg);
        if (mg.have_flit) {
            if (flits == 0) {
                memcpy(first_flit, mg.flit.bytes, (size_t)mg.flit.nbytes);
                first_flit_len = mg.flit.nbytes;
            }
            flits++;
            mg.have_flit = false;
        }
        if (produced) { done = true; break; }
    }
    CHECK(done, "the second token did not finish");
    CHECK(mg.tokens_gated == 2, "two tokens should have been gated, got %u",
          mg.tokens_gated);
    CHECK(flits == 2, "the second token produced %d flits, expected 2", flits);
    /* the second token's decision is [2, 0], so its first dispatch is for
     * expert 2, which lives on node (1, 2) -> MODULE 0x12 */
    CHECK(first_flit[1] == 0x12, "the second token's MODULE is %02X, expected 12",
          first_flit[1]);

    /* ---------------- the CRC-16 helper against the fabric's own vector --- */
    {
        /* The Go twin (sim/internal/pnm/crc.go) over the byte string
         * {0x23, 0x80, 0x04, 0x00} gives 0xDFCC; the C helper must agree. */
        const uint8_t body[4] = { 0x23, 0x80, 0x04, 0x00 };
        uint16_t crc = pnm_crc16(body, 4);
        CHECK(crc == 0xDFCCu, "the CRC of the sample body is %04X, expected DFCC",
              crc);
    }

    if (g_trace) {
        fclose(g_trace);
        g_trace = NULL;
    }

    if (errors == 0)
        printf("*** MGMT GATING TEST PASSED ***\n");
    else
        printf("*** MGMT GATING TEST FAILED (%d) ***\n", errors);
    return errors ? 1 : 0;
}
