/* test_plan_wire.c — the dispatch plan is data.
 *
 * The host compiler (sim/internal/pnm/plan.go) encodes a dispatch plan to
 * bytes; the device firmware decodes it, validates it against its own
 * verifier, and re-encodes it.  This test requires the re-encoding to be
 * byte-identical to the received plan — if the two wire formats ever
 * diverged, this fails instead of the two sides silently disagreeing on
 * what a dispatch means.
 *
 * Usage: test_plan_wire <plan.bin> <reencoded.bin>
 */
#include <stdio.h>
#include <string.h>
#include "pnm_fw.h"
#include "plan.h"

int main(int argc, char **argv) {
    firmware_t fw;
    plan_header_t hdr;
    static dispatch_record_t recs[PNM_PLAN_MAX_RECORDS];
    static uint8_t buf[PNM_PLAN_MAX_BYTES];
    static uint8_t out[PNM_PLAN_MAX_BYTES];
    FILE *f;
    int len, nrec, nout, rc;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <plan.bin> <reencoded.bin>\n", argv[0]);
        return 2;
    }

    f = fopen(argv[1], "rb");
    if (!f) {
        printf("PLAN WIRE TEST FAILED: cannot open %s\n", argv[1]);
        return 1;
    }
    len = (int)fread(buf, 1, sizeof(buf), f);
    fclose(f);
    if (len <= 0) {
        printf("PLAN WIRE TEST FAILED: empty plan\n");
        return 1;
    }

    memset(&fw, 0, sizeof(fw));
    fw.state = FW_READY;
    fw.model_layers_per_physical = 1;

    rc = fw_plan_decode(buf, len, &hdr, recs,
                        (int)(sizeof(recs) / sizeof(recs[0])), &nrec);
    if (rc != 0) {
        printf("PLAN WIRE TEST FAILED: decode rc=%d\n", rc);
        return 1;
    }
    fw_plan_apply(&fw, &hdr);

    rc = fw_verify_dispatch(&fw, recs, nrec);
    if (rc != 0) {
        printf("PLAN WIRE TEST FAILED: verify rc=%d (%d records)\n", rc, nrec);
        return 1;
    }

    nout = fw_plan_encode(&hdr, recs, nrec, out, (int)sizeof(out));
    if (nout < 0) {
        printf("PLAN WIRE TEST FAILED: encode rc=%d\n", nout);
        return 1;
    }
    if (nout != len || memcmp(out, buf, (size_t)len) != 0) {
        printf("PLAN WIRE TEST FAILED: re-encoding differs (%d vs %d bytes)\n",
               nout, len);
        return 1;
    }

    f = fopen(argv[2], "wb");
    if (!f) {
        printf("PLAN WIRE TEST FAILED: cannot write %s\n", argv[2]);
        return 1;
    }
    fwrite(out, 1, (size_t)nout, f);
    fclose(f);

    printf("PLAN WIRE TEST PASSED (%d records, %d bytes, %d model layers)\n",
           nrec, len, fw.num_hidden_layers);
    return 0;
}
