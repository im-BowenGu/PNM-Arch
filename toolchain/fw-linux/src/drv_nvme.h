/**
 * drv_nvme.h — NVMe driver re-exports for fw-linux bare-metal init.
 *
 * The actual NVMe driver lives in fw/pnm_nvme.c and is compiled
 * and linked by the Makefile. This header provides a thin wrapper that
 * sets the register base to 0xD000_0000 (NVMe@0xD0000000 on the
 * orchestrator_sbc memory map) and hides the pnm_fw.h dependency from
 * other fw-linux sources.
 */

#ifndef DRV_NVME_H
#define DRV_NVME_H

#include "pnm_nvme.h"

#define NVME_BASE   0xD0000000u

#endif /* DRV_NVME_H */
