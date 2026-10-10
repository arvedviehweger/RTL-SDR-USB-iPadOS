//
//  errno.h
//  RTL-SDR
//
//  DriverKit has no <errno.h>. librtlsdr and its tuner drivers only use the
//  error constants (as negative return values); the pthread shim returns
//  them as POSIX does.
//

#ifndef RTLSDR_SHIM_ERRNO_H
#define RTLSDR_SHIM_ERRNO_H

#define ENOMEM  12
#define EINVAL  22
#define EAGAIN  35

#endif /* RTLSDR_SHIM_ERRNO_H */
