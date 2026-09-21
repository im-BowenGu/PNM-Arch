/**
 * drv_pnm.c — PNM register window helpers for orchestrator_sbc bare-metal init.
 *
 * All access is inlined via drv_pnm.h; this translation unit exists so
 * the Makefile pattern rule (%.c → %) picks it up as a linkable object
 * if any non-inline helpers are added later.
 */

#include "drv_pnm.h"
