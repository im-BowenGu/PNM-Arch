/* Regression test for kv_load: non-destructive positional read.
 * Build: gcc -Wall -Wextra -std=c11 -o test_kv_load test_kv_load.c pnm_fw.c
 * Run:   ./test_kv_load   (expect "RESULT: ALL PASS"; exit 0)
 *
 * Banks use the RTL-fixed ENTRY_BYTES frame (PNM_KV_ENTRY_BYTES=512),
 * matching kv_cache_init. The test drives depth=2 with 2 banks.
 */
#include <stdio.h>
#include <string.h>
#include "pnm_fw.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
    else { printf("ok: %s\n", msg); } \
} while (0)

#define NENT 2                      /* two entries per bank */
#define EBYTES PNM_KV_ENTRY_BYTES   /* entry frame (RTL-fixed) */

int main(void) {
    kv_cache_t kv;
    kv_cache_init(&kv, 1, 16); /* entry_bytes = PNM_KV_ENTRY_BYTES */
    kv_layer_t *layer = &kv.layers[0];

    /* Backing store: PNM_KV_CACHE_BANKS x NENT entries x EBYTES bytes.
       Must match kv_cache_init's entry_bytes or kv_store overruns it. */
    uint8_t store[PNM_KV_CACHE_BANKS][NENT][EBYTES];
    for (int b = 0; b < PNM_KV_CACHE_BANKS; b++) {
        layer->banks[b].entries = store[b][0];
        layer->banks[b].depth = NENT;
        layer->banks[b].empty = true;
        layer->banks[b].full = false;
    }

    uint8_t entries[2 * PNM_KV_CACHE_BANKS][EBYTES];
    for (int i = 0; i < 2 * PNM_KV_CACHE_BANKS; i++) {
        memset(entries[i], (uint8_t)(0xA0 + i), sizeof(entries[i]));
        CHECK(kv_store(layer, i, entries[i], EBYTES), "kv_store(seq_pos) accepted");
    }
    CHECK(layer->banks[0].occupancy == 2, "bank0 occupancy == 2");
    CHECK(layer->banks[1].occupancy == 2, "bank1 occupancy == 2");

    /* Positional read: seq 5 lives in bank 1 at idx 1 */
    uint8_t buf[EBYTES];
    CHECK(kv_load(layer, 5, buf, EBYTES), "kv_load(5) succeeds");
    CHECK(buf[0] == 0xA5 && buf[17] == 0xA5, "kv_load(5) returns entry 5");

    /* Non-destructive: repeat load returns same data, occupancy unchanged */
    CHECK(kv_load(layer, 5, buf, EBYTES), "kv_load(5) repeat succeeds");
    CHECK(buf[0] == 0xA5, "repeat load returns same entry");
    CHECK(layer->banks[1].occupancy == 2, "occupancy unchanged after loads");
    CHECK(!layer->banks[1].empty, "bank not empty after loads");

    /* Correctness of addressing: load(1) != load(5) */
    CHECK(kv_load(layer, 1, buf, EBYTES), "kv_load(1) succeeds");
    CHECK(buf[0] == 0xA1, "kv_load(1) returns entry 1");
    CHECK(kv_load(layer, 5, buf, EBYTES), "kv_load(5) still succeeds");
    CHECK(buf[0] == 0xA5, "kv_load(5) still returns entry 5");

    /* Live-window: evict oldest, then the evicted position must fail */
    uint8_t ev[EBYTES];
    CHECK(kv_evict_oldest(layer, ev, EBYTES, KV_EVICT_NONE, NULL) > 0, "evict oldest");
    CHECK(ev[0] == 0xA0, "evicted entry is seq 0");
    CHECK(!kv_load(layer, 0, buf, EBYTES), "kv_load(0) fails after eviction (out of window)");

    /* Zero-pad: a short entry (much less than the frame) must read back as a
       zero-padded full frame, mirroring Go KVCacheBank.Store (twin parity).
       Without the C fix, the tail bytes retain stale prefill 0xAA. */
    {
        /* Reset bank 0 to a clean empty slot (write_ptr 0) so seq 0 maps
           deterministically to idx 0 and loads back cleanly. */
        kv_bank_t *b0 = &layer->banks[0];
        memset(store[0], 0xAA, sizeof(store[0]));  /* stale prefill */
        b0->write_ptr = 0;
        b0->read_ptr = 0;
        b0->occupancy = 0;
        b0->full = false;
        b0->empty = true;
        uint8_t short_entry[8];
        memset(short_entry, 0x77, sizeof(short_entry));
        if (!kv_store(layer, 0, short_entry, 8)) {
            printf("FAIL: short-entry kv_store rejected\n");
            failures++;
        } else {
            uint8_t fbuf[EBYTES];
            if (kv_load(layer, 0, fbuf, EBYTES)) {
                int bad = 0, i;
                for (i = 8; i < EBYTES; i++)
                    if (fbuf[i] != 0) { bad = 1; break; }
                CHECK(fbuf[0] == 0x77, "short entry prefix preserved");
                CHECK(!bad, "short entry tail zero-padded to frame");
            } else {
                printf("FAIL: short-entry kv_load(0) failed\n");
                failures++;
            }
        }
    }

    if (failures)
        printf("RESULT: %d FAILURES\n", failures);
    else
        printf("RESULT: ALL PASS\n");
    return failures ? 1 : 0;
}
