//
//  unistd.h
//  RTL-SDR
//
//  usleep() for librtlsdr, implemented with IOSleep / IODelay in
//  ../libc_driverkit.cpp.
//

#ifndef RTLSDR_SHIM_UNISTD_H
#define RTLSDR_SHIM_UNISTD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned int useconds_t;

int usleep(useconds_t microseconds);

#ifdef __cplusplus
}
#endif

#endif /* RTLSDR_SHIM_UNISTD_H */
