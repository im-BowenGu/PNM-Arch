/**
 * pnm_mgmt.h — the embedded management node's firmware.
 *
 * The gating ASIC (HDL/core/gating_asic.v) is a per-node device: it holds
 * the router weights and produces the expert decision for every token that
 * lands on its node.  In the architecture's mode A, the manager of that
 * device is an **embedded management node** on the node board -- an MCU or a
 * Raspberry Pi Compute Module -- rather than the host.  This is the
 * firmware for that node.
 *
 * What it does:
 *
 *   1. At machine setup it takes the router weights the host streamed to
 *      it and programs them into the gating ASIC's weight RAM.
 *   2. Per token it takes the token the board's tap presented, writes the
 *      token's hidden state into the gating ASIC's hidden RAM, starts the
 *      gating engine, waits for it, and reads the decision back.
 *   3. It maps the selected expert ids to the nodes that hold them and
 *      emits the dispatch flits, with the fabric's CRC-16 over the
 *      protected body.
 *
 * Because the decision is taken on the board, it never crosses the fabric
 * (Section 2.17.1 of the paper): the host's role is to program the weights
 * once, and the per-token routing is local.
 *
 * The data the board's tap presents is the token's payload as it appears on
 * the fabric: bytes, with the hidden state packed as big-endian 16-bit
 * words (the same packing the host's driver uses).  The gating ASIC wants
 * BF16 words, so the firmware repacks on the way in.
 *
 * Constraints: no operating system, no dynamic allocation, no recursion.
 * Everything is static; the state machine is a single switch.
 */

#ifndef PNM_MGMT_H
#define PNM_MGMT_H

#include <stdint.h>
#include <stdbool.h>

#include "pnm_fw.h"

/* -- Limits ----------------------------------------------------------- */

#ifdef PNM_MCU
#define MGMT_MAX_EXPERTS   16
#define MGMT_MAX_TOPK      4
#define MGMT_MAX_TOKEN     64
#else
#define MGMT_MAX_EXPERTS   256
#define MGMT_MAX_TOPK      16
#define MGMT_MAX_TOKEN     256
#endif

/* -- The gating ASIC's register map (HDL/core/gating_asic.v) ----------- */

#define MGMT_REG_CTRL        0x00   /* [0] start                              */
#define MGMT_REG_STATUS      0x02   /* [0] busy, [1] done                     */
#define MGMT_REG_WGHT_ADDR_LO 0x10  /* the weight RAM's write pointer (low)   */
#define MGMT_REG_WGHT_ADDR_HI 0x11  /* the weight RAM's write pointer (high)  */
#define MGMT_REG_WGHT_DATA   0x12   /* a weight word; the pointer auto-increments */
#define MGMT_REG_HID_ADDR_LO 0x14   /* the hidden RAM's write pointer (low)   */
#define MGMT_REG_HID_ADDR_HI 0x15   /* the hidden RAM's write pointer (high)  */
#define MGMT_REG_HID_DATA    0x16   /* a hidden word; the pointer auto-increments */
#define MGMT_REG_COORD_L     0x18   /* the layer coordinate                  */
#define MGMT_REG_COORD_M     0x1A   /* the module coordinate                 */
#define MGMT_REG_RANK_IDX    0x200  /* + 2*k: expert k's id                   */
#define MGMT_REG_RANK_LOG    0x280  /* + 2*k: expert k's logit               */

#define MGMT_STATUS_BUSY     0x0001u

/* -- The wire format (HDL/pnm_defs.vh) -------------------------------- */

#define MGMT_CTRL_COMPUTE    0x80u  /* VC_SPINE | OP_COMPUTE                */
#define MGMT_FLEN_HDR        5       /* LAYER | MODULE | CTRL | LEN_LO | LEN_HI */
#define MGMT_FLEN_CRC        2       /* CRC_HI | CRC_LO                       */

/* -- The board port ---------------------------------------------------- */

/* How the management node reaches the gating ASIC.  A board implements
 * these two functions over whatever bus it has (SPI, a parallel GPIO port,
 * an AXI-Lite bridge); the firmware itself is bus-agnostic.  write() and
 * read() perform one complete transaction and return when it has: the
 * gating ASIC's ready is a registered copy of valid, so a transaction
 * completes on the second edge of a valid window, and the board's
 * implementation has to hold valid that long. */
typedef struct {
    void     (*write)(void *ctx, uint16_t addr, uint16_t data);
    uint16_t (*read)(void *ctx, uint16_t addr);
    void     (*ctx);
} mgmt_bus_t;

/* -- The local expert map ---------------------------------------------- */

/* One expert the node's gating ASIC can select, and the node that holds
 * it.  The host's MoE-map load provides this table. */
typedef struct {
    uint16_t expert_idx;
    uint8_t  target_layer;
    uint8_t  target_x;
    uint8_t  target_y;
} mgmt_expert_t;

/* -- The dispatch flit ------------------------------------------------- */

/* One flit the node emits towards the fabric. */
typedef struct {
    uint8_t  layer;
    uint8_t  module;
    uint16_t len;
    uint8_t  payload[MGMT_MAX_TOKEN];
    uint8_t  bytes[MGMT_FLEN_HDR + MGMT_MAX_TOKEN + MGMT_FLEN_CRC];
    int      nbytes;
} mgmt_flit_t;

/* -- The state machine -------------------------------------------------- */

typedef enum {
    MGMT_STATE_RESET = 0,     /* waiting for the weights                  */
    MGMT_STATE_RECEIVE,       /* receiving the router weights from the host */
    MGMT_STATE_IDLE,          /* programmed; waiting for a token          */
    MGMT_STATE_HIDDEN,        /* writing the hidden vector                 */
    MGMT_STATE_START,         /* starting the gating engine               */
    MGMT_STATE_WAIT,          /* waiting for the engine to finish         */
    MGMT_STATE_RESULT,        /* reading the decision back                */
    MGMT_STATE_DISPATCH,      /* emitting the dispatch flits              */
    MGMT_STATE_ERROR
} mgmt_state_t;

/* -- The node's context ------------------------------------------------- */

typedef struct {
    mgmt_bus_t   bus;
    mgmt_state_t state;

    /* the identity this node programs into the gating ASIC */
    uint8_t  layer;
    uint8_t  module;

    /* the gating ASIC's shape */
    uint16_t num_experts;
    uint16_t top_k;
    uint16_t hidden_dim;

    /* the local expert map (from the host's MoE-map load) */
    mgmt_expert_t experts[MGMT_MAX_EXPERTS];
    int      num_mapped;

    /* the token the board's tap presented */
    uint8_t  token[MGMT_MAX_TOKEN];
    int      token_len;
    bool     have_token;

    /* the decision the gating engine returned */
    uint16_t selected[MGMT_MAX_TOPK];
    uint16_t selected_logit[MGMT_MAX_TOPK];
    int      num_selected;

    /* the flit this node emitted for the current token */
    mgmt_flit_t flit;
    bool     have_flit;
    int      dispatch_index;

    /* the gating engine's busy line was seen high */
    bool     busy_seen;

    /* the receive path: the router weights the host streams to this node */
    uint32_t rx_words;      /* how many words the host is sending        */
    uint32_t rx_count;      /* how many have arrived                      */
    uint16_t rx_word;       /* the word being assembled                   */
    uint8_t  rx_byte;       /* the bytes of that word seen so far         */
    bool     rx_active;     /* a receive is in progress                   */

    /* counters */
    uint32_t tokens_gated;
    uint32_t tokens_dispatched;
    uint32_t errors;
} mgmt_t;

/* -- The API ------------------------------------------------------------ */

/* Initialize the node.  `layer` and `module` are the coordinates the
 * gating ASIC latches with the weights. */
void mgmt_init(mgmt_t *mg, const mgmt_bus_t *bus, uint8_t layer, uint8_t module);

/* Program the gating ASIC: the coordinate, then the router weights as BF16
 * words (the host's router blob).  `nwords` is the number of BF16 words
 * (num_experts * hidden_dim).  Returns 0 on success. */
int mgmt_program_weights(mgmt_t *mg, const uint16_t *bf16_words, int nwords);

/* The board's tap presents a token: the payload as it appears on the
 * fabric, with the hidden state packed as big-endian 16-bit words. */
void mgmt_push_token(mgmt_t *mg, const uint8_t *payload, int len);

/* Receive the router weights from the host.
 *
 * The host streams them to this board during machine programming, in
 * weight-upload flits; the board's receive path hands the bytes to the
 * management node, which programs them into the gating ASIC as they arrive
 * -- the node never holds the whole router, so a 4 KB MCU can program a
 * 700 KB router.
 *
 * mgmt_receive_begin() says how many BF16 words are coming; the board then
 * calls mgmt_receive_byte() once per byte, in order, most significant byte
 * first.  When the last word has been written the ASIC holds the router and
 * the node returns to its idle state. */
void mgmt_receive_begin(mgmt_t *mg, uint32_t nwords);
void mgmt_receive_byte(mgmt_t *mg, uint8_t byte);

/* Advance the state machine by one step.  Returns true when the node has
 * emitted a dispatch flit (the caller then reads mg->flit and clears
 * mg->have_flit). */
bool mgmt_step(mgmt_t *mg);

/* Build the fabric flit for one expert.  Exposed so the board's injector
 * can be tested against the fabric's own CRC. */
void mgmt_build_flit(mgmt_flit_t *f, uint8_t layer, uint8_t module,
                      const uint8_t *payload, int len);

#endif /* PNM_MGMT_H */
