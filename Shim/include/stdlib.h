//
//  stdlib.h
//  RTL-SDR
//
//  DriverKit's <stdlib.h> has no heap allocation and no environment.
//  ../libc_driverkit.cpp implements both (IOMalloc, and an empty
//  environment), plus strdup() on top of that malloc().
//

#ifndef RTLSDR_SHIM_STDLIB_H
#define RTLSDR_SHIM_STDLIB_H

#include_next <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void  free(void *ptr);

char *getenv(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* RTLSDR_SHIM_STDLIB_H */
