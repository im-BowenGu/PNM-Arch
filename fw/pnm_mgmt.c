/**
 * pnm_mgmt.c — the embedded management node's firmware.
 *
 * See pnm_mgmt.h for what this is.  The state machine is a single switch
 * with one step per call, so the caller controls the pacing: on a real board
 * that is the main loop (or a timer interrupt), and in a test it is a
 * simple loop until the node has produced its dispatch.
 *
 * The bus discipline matters and is easy to get wrong: the gating ASIC's
 * ready is a *registered copy* of valid, so a transaction completes on the
 * second edge of a valid window.  The board's write() and read() must hold
 * valid for that long; the mgmt_bus_t contract is that write()/read()
 * perform a complete transaction and return when it has.
 */

#include "pnm_mgmt.h"
#include "pnm_crc16.h"
#include <string.h>

void mgmt_init(mgmt_t *mg, const mgmt_bus_t *bus, uint8_t layer, uint8_t module)
{
    memset(mg, 0, sizeof(*mg));
    mg->bus = *bus;
    mg->layer = layer;
    mg->module = module;
    mg->state = MGMT_STATE_RESET;
}

/* ------------------------------------------------------------------ */
/* Weight programming                                                   */
/* ------------------------------------------------------------------ */

int mgmt_program_weights(mgmt_t *mg, const uint16_t *bf16_words, int nwords)
{
    int i;

    if (nwords <= 0 || bf16_words == NULL) {
        mg->errors++;
        return -1;
    }
    if (mg->num_experts > 0 && mg->hidden_dim > 0 &&
        nwords > (int)mg->num_experts * (int)mg->hidden_dim) {
        mg->errors++;
        return -1;
    }

    /* The coordinate is latched with the weights: the ASIC records which
     * (layer, module) the router belongs to. */
    mg->bus.write(mg->bus.ctx, MGMT_REG_COORD_L, mg->layer);
    mg->bus.write(mg->bus.ctx, MGMT_REG_COORD_M, mg->module);

    /* The weight RAM's write pointer is set once; each data write lands at
     * the current pointer and the ASIC increments it. */
    mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_ADDR_LO, 0);
    mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_ADDR_HI, 0);
    for (i = 0; i < nwords; i++)
        mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_DATA, bf16_words[i]);

    mg->state = MGMT_STATE_IDLE;
    return 0;
}

/* ------------------------------------------------------------------ */
/* The token                                                            */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* Receiving the router weights from the host                           */
/* ------------------------------------------------------------------ */

void mgmt_receive_begin(mgmt_t *mg, uint32_t nwords)
{
    if (nwords == 0) {
        mg->errors++;
        return;
    }
    /* The coordinate first, then the weight RAM's write pointer: the ASIC
     * latches the coordinate with the weights, and every data write lands
     * at the pointer and increments it. */
    mg->bus.write(mg->bus.ctx, MGMT_REG_COORD_L, mg->layer);
    mg->bus.write(mg->bus.ctx, MGMT_REG_COORD_M, mg->module);
    mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_ADDR_LO, 0);
    mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_ADDR_HI, 0);

    mg->rx_words  = nwords;
    mg->rx_count  = 0;
    mg->rx_word   = 0;
    mg->rx_byte   = 0;
    mg->rx_active = true;
    mg->state     = MGMT_STATE_RECEIVE;
}

void mgmt_receive_byte(mgmt_t *mg, uint8_t byte)
{
    if (!mg->rx_active) {
        mg->errors++;
        return;
    }
    /* The weights are BF16 words, most significant byte first. */
    if (mg->rx_byte == 0)
        mg->rx_word = (uint16_t)((uint16_t)byte << 8);
    else
        mg->rx_word = (uint16_t)(mg->rx_word | (uint16_t)byte);
    mg->rx_byte++;
    if (mg->rx_byte < 2)
        return;

    mg->rx_byte = 0;
    mg->bus.write(mg->bus.ctx, MGMT_REG_WGHT_DATA, mg->rx_word);
    mg->rx_count++;
    if (mg->rx_count >= mg->rx_words) {
        mg->rx_active = false;
        mg->state = MGMT_STATE_IDLE;
    }
}

void mgmt_push_token(mgmt_t *mg, const uint8_t *payload, int len)
{
    if (len < 0 || len > MGMT_MAX_TOKEN) {
        mg->errors++;
        return;
    }
    if (payload == NULL) {
        mg->errors++;
        return;
    }
    memcpy(mg->token, payload, (size_t)len);
    mg->token_len = len;
    mg->have_token = true;
}

/* ------------------------------------------------------------------ */
/* The flit builder                                                     */
/* ------------------------------------------------------------------ */

void mgmt_build_flit(mgmt_flit_t *f, uint8_t layer, uint8_t module,
                      const uint8_t *payload, int len)
{
    int i;
    uint16_t crc;

    memset(f, 0, sizeof(*f));
    f->layer = layer;
    f->module = module;
    f->len = (uint16_t)len;

    f->bytes[0] = layer;                       /* LAYER_ID  */
    f->bytes[1] = module;                      /* MODULE_ID */
    f->bytes[2] = MGMT_CTRL_COMPUTE;           /* CTRL      */
    f->bytes[3] = (uint8_t)(len & 0xFF);       /* LEN_LO    */
    f->bytes[4] = (uint8_t)(len >> 8);         /* LEN_HI    */
    for (i = 0; i < len && i < MGMT_MAX_TOKEN; i++) {
        f->payload[i] = payload[i];
        f->bytes[MGMT_FLEN_HDR + i] = payload[i];
    }

    /* The CRC covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload] -- the
     * LAYER_ID is stripped by the repeater and is outside the protected
     * body (HDL/pnm_defs.vh). */
    crc = pnm_crc16(&f->bytes[1], MGMT_FLEN_HDR - 1 + len);
    f->bytes[MGMT_FLEN_HDR + len] = (uint8_t)(crc >> 8);     /* CRC_HI */
    f->bytes[MGMT_FLEN_HDR + len + 1] = (uint8_t)(crc & 0xFF); /* CRC_LO */
    f->nbytes = MGMT_FLEN_HDR + len + MGMT_FLEN_CRC;
}

/* ------------------------------------------------------------------ */
/* The state machine                                                    */
/* ------------------------------------------------------------------ */

bool mgmt_step(mgmt_t *mg)
{
    int i;

    switch (mg->state) {
    case MGMT_STATE_RESET:
        /* Nothing to do until the host's router blob arrives and
         * mgmt_program_weights() or mgmt_receive_begin() runs. */
        return false;

    case MGMT_STATE_RECEIVE:
        /* The bytes arrive from the board's receive path, not from here:
         * mgmt_receive_byte() programs them into the ASIC as they come,
         * so the node never holds the whole router. */
        return false;

    case MGMT_STATE_IDLE:
        if (!mg->have_token)
            return false;
        mg->have_token = false;
        mg->num_selected = 0;
        mg->have_flit = false;
        mg->dispatch_index = 0;
        mg->state = MGMT_STATE_HIDDEN;
        return false;

    case MGMT_STATE_HIDDEN: {
        /* The hidden vector must be in the ASIC's hidden RAM *before* the
         * start: the engine latches it when the start bit raises.  The
         * token's payload carries the hidden state as big-endian 16-bit
         * words, and the ASIC wants BF16 words. */
        uint16_t word;
        int nwords = mg->token_len / 2;
        if (mg->hidden_dim > 0 && nwords > (int)mg->hidden_dim)
            nwords = mg->hidden_dim;
        mg->bus.write(mg->bus.ctx, MGMT_REG_HID_ADDR_LO, 0);
        mg->bus.write(mg->bus.ctx, MGMT_REG_HID_ADDR_HI, 0);
        for (i = 0; i < nwords; i++) {
            word = (uint16_t)(((uint16_t)mg->token[2 * i] << 8) |
                              (uint16_t)mg->token[2 * i + 1]);
            mg->bus.write(mg->bus.ctx, MGMT_REG_HID_DATA, word);
        }
        mg->state = MGMT_STATE_START;
        return false;
    }

    case MGMT_STATE_START:
        mg->bus.write(mg->bus.ctx, MGMT_REG_CTRL, 0x0001u);
        mg->state = MGMT_STATE_WAIT;
        return false;

    case MGMT_STATE_WAIT:
        /* The engine's done bit is a one-cycle pulse, so the handshake is
         * "wait for busy to go high, then wait for it to fall". */
        if (mg->bus.read(mg->bus.ctx, MGMT_REG_STATUS) & MGMT_STATUS_BUSY) {
            mg->busy_seen = true;
            return false;
        }
        if (!mg->busy_seen) {
            /* The engine has not started yet. */
            return false;
        }
        /* The engine has finished, but the ASIC's packed decision output
         * (the rank window's ids and logits) is registered one cycle behind
         * the top-k buffer, so a read taken in the same cycle would see the
         * previous token's -- or the reset sentinel's -- decision.  One more
         * transaction settles it. */
        mg->bus.read(mg->bus.ctx, MGMT_REG_STATUS);
        mg->tokens_gated++;
        mg->state = MGMT_STATE_RESULT;
        return false;

    case MGMT_STATE_RESULT:
        /* Read the decision back over the management bus: the rank window
         * exposes every top-k id and logit. */
        for (i = 0; i < mg->top_k && i < MGMT_MAX_TOPK; i++) {
            mg->selected[i] = (uint16_t)(mg->bus.read(mg->bus.ctx,
                                MGMT_REG_RANK_IDX + 2 * i) & 0xFF);
            mg->selected_logit[i] = mg->bus.read(mg->bus.ctx,
                                MGMT_REG_RANK_LOG + 2 * i);
        }
        mg->num_selected = (int)mg->top_k;
        mg->dispatch_index = 0;
        mg->state = MGMT_STATE_DISPATCH;
        return false;

    case MGMT_STATE_DISPATCH: {
        /* Map the selected expert to the node that holds it and build that
         * node's flit.  An expert this node does not hold is not ours to
         * dispatch -- another node's gating ASIC will select it. */
        int k = mg->dispatch_index;
        int found = -1;

        if (k >= mg->num_selected) {
            mg->state = MGMT_STATE_IDLE;
            return false;
        }
        for (i = 0; i < mg->num_mapped; i++) {
            if (mg->experts[i].expert_idx == mg->selected[k]) {
                found = i;
                break;
            }
        }
        if (found < 0) {
            mg->errors++;
        } else {
            mgmt_build_flit(&mg->flit, mg->experts[found].target_layer,
                            (uint8_t)((mg->experts[found].target_x << 4) |
                                      (mg->experts[found].target_y & 0x0F)),
                            mg->token, mg->token_len);
            mg->have_flit = true;
        }
        mg->tokens_dispatched++;
        mg->dispatch_index++;
        if (mg->dispatch_index >= mg->num_selected) {
            mg->state = MGMT_STATE_IDLE;
            return true;   /* the token's dispatch is complete */
        }
        return false;
    }

    case MGMT_STATE_ERROR:
    default:
        return false;
    }
}
