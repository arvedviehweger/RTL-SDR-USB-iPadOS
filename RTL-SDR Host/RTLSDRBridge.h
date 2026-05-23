//
//  RTLSDRBridge.h
//  RTL-SDR Host
//
//  Thin C bridge over the IOKit user-client API. The IOKit functions are
//  awkward to call straight from Swift on iPadOS, so the connection handling
//  is wrapped here and exposed as a handful of plain C functions.
//
//  All of these talk to the RTL_SDR DriverKit extension's IOUserClient.
//

#ifndef RTLSDRBRIDGE_H
#define RTLSDRBRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Finds the RTL_SDR service and opens a user-client connection to it.
/// Returns a non-zero connection handle on success, 0 on failure.
uint32_t rtlsdrhost_open(void);

/// Closes a connection opened with rtlsdrhost_open().
void rtlsdrhost_close(uint32_t connection);

/// Invokes a scalar external method (one input value, one output value).
/// `selector` is one of the kRTLSDRMethod* constants. Returns the IOKit
/// kern_return_t (0 == KERN_SUCCESS). Any scalar result is stored in *out.
int rtlsdrhost_call(uint32_t connection, uint32_t selector,
                    uint64_t arg, uint64_t *out);

/// Invokes a structure-output external method (used for GetDeviceInfo).
/// `outStruct` receives up to *outSize bytes; *outSize is updated to the
/// number of bytes actually returned. Returns the IOKit kern_return_t.
int rtlsdrhost_get_struct(uint32_t connection, uint32_t selector,
                          void *outStruct, size_t *outSize);

/// Maps a shared memory region (memory type kRTLSDRMemoryType*) into this
/// process. Returns the mapped address, or NULL on failure; the byte size is
/// written to *outSize.
void *rtlsdrhost_map_memory(uint32_t connection, uint32_t memoryType,
                            uint64_t *outSize);

#ifdef __cplusplus
}
#endif

#endif /* RTLSDRBRIDGE_H */
