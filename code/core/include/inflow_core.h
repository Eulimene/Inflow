#ifndef INFLOW_CORE_H
#define INFLOW_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version of the stable C ABI implemented by the linked Inflow core.
uint32_t inflow_core_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
