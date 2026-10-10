//
//  stdio.h
//  RTL-SDR
//
//  DriverKit's <stdio.h> only declares the snprintf family. librtlsdr logs
//  with fprintf(stderr, ...) / printf(...); ../libc_driverkit.cpp sends both
//  to os_log.
//
//  They are renamed so that the optimizer does not recognise them and turn
//  calls into fwrite() / puts(), which DriverKit lacks as well.
//

#ifndef RTLSDR_SHIM_STDIO_H
#define RTLSDR_SHIM_STDIO_H

#include_next <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

extern FILE *stderr;
extern FILE *stdout;

int rtlsdr_shim_fprintf(FILE *stream, const char *format, ...) __printflike(2, 3);
int rtlsdr_shim_printf(const char *format, ...) __printflike(1, 2);

#ifdef __cplusplus
}
#endif

#define fprintf rtlsdr_shim_fprintf
#define printf  rtlsdr_shim_printf

#endif /* RTLSDR_SHIM_STDIO_H */
