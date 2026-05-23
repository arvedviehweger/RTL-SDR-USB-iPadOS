//
//  rtlsdr_compat.h
//  RTL-SDR
//
//  DriverKit compatibility shims for librtlsdr.c.
//
//  A DriverKit extension has no <stdio.h>, no process environment and no
//  classic malloc/free. This header redirects the handful of libc facilities
//  librtlsdr relies on so that the body of librtlsdr.c can stay as close to
//  the upstream source as possible.
//
//  Include this *instead of* <stdio.h>/<stdlib.h>/<errno.h>/<ctype.h>.
//

#ifndef RTLSDR_COMPAT_H
#define RTLSDR_COMPAT_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* os_log-backed replacement for fprintf(stderr, ...) / printf(...).
 * Implemented in RTL_SDR.cpp. */
void  rtlsdr_log(const char *fmt, ...);

/* IOSleep-backed replacement for usleep(). Implemented in RTL_SDR.cpp. */
void  rtlsdr_msleep(uint32_t ms);

/* IOMalloc/IOFree-backed allocation. The caller tracks the size and passes it
 * back to rtlsdr_mem_free(). Implemented in RTL_SDR.cpp. */
void *rtlsdr_mem_alloc(uint32_t size);
void  rtlsdr_mem_free(void *ptr, uint32_t size);

#ifdef __cplusplus
}
#endif

/* Redirect the original stdio logging. Every fprintf() in librtlsdr.c targets
 * stderr; the stream argument is simply discarded by the macro. */
#define fprintf(stream, ...)  rtlsdr_log(__VA_ARGS__)
#define printf(...)           rtlsdr_log(__VA_ARGS__)

/* No POSIX sleep in DriverKit. */
#define usleep(us)            rtlsdr_msleep((uint32_t)((us) / 1000))

/* No process environment inside a dext. */
#define getenv(name)          ((char *)0)

/* errno / limits values used by librtlsdr (no <errno.h>/<limits.h> here). */
#ifndef EINVAL
#define EINVAL 22
#endif
#ifndef ENOMEM
#define ENOMEM 12
#endif
#ifndef INT_MAX
#define INT_MAX 2147483647
#endif

/* ---------------------------------------------------------------------------
 * Minimal libc helpers.
 *
 * librtlsdr's option-string parser (rtlsdr_set_opt_string / parseFreq) needs a
 * few <stdlib.h>/<ctype.h> functions. The dext drives the device through the
 * IOUserClient instead, so that code path is effectively unused - but it still
 * has to compile. If your DriverKit SDK already provides these symbols, define
 * RTLSDR_HAVE_LIBC_PARSE=1 (e.g. as a build setting) to drop the shims.
 * ------------------------------------------------------------------------- */
#ifndef RTLSDR_HAVE_LIBC_PARSE
#define RTLSDR_HAVE_LIBC_PARSE 0
#endif

#if !RTLSDR_HAVE_LIBC_PARSE

static inline int rtlsdr__isspace(int c) {
    return (c == ' ' || c == '\t' || c == '\n' ||
            c == '\v' || c == '\f' || c == '\r');
}
#define isspace(c) rtlsdr__isspace(c)

static inline int rtlsdr__atoi(const char *s) {
    int sgn = 1, v = 0;
    if (!s) return 0;
    while (*s == ' ' || *s == '\t') ++s;
    if (*s == '-') { sgn = -1; ++s; } else if (*s == '+') ++s;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); ++s; }
    return v * sgn;
}
#define atoi(s) rtlsdr__atoi(s)
#define atol(s) ((long)rtlsdr__atoi(s))

static inline double rtlsdr__atof(const char *s) {
    int sgn = 1;
    double v = 0.0, frac = 1.0;
    if (!s) return 0.0;
    while (*s == ' ' || *s == '\t') ++s;
    if (*s == '-') { sgn = -1; ++s; } else if (*s == '+') ++s;
    while (*s >= '0' && *s <= '9') { v = v * 10.0 + (*s - '0'); ++s; }
    if (*s == '.') {
        ++s;
        while (*s >= '0' && *s <= '9') { frac *= 0.1; v += (*s - '0') * frac; ++s; }
    }
    return v * sgn;
}
#define atof(s) rtlsdr__atof(s)

static inline char *rtlsdr__strtok(char *str, const char *delim) {
    static char *saved;
    char *tok;
    if (str) saved = str;
    if (!saved) return (char *)0;
    while (*saved && strchr(delim, *saved)) ++saved;
    if (!*saved) { saved = (char *)0; return (char *)0; }
    tok = saved;
    while (*saved && !strchr(delim, *saved)) ++saved;
    if (*saved) { *saved = '\0'; ++saved; } else saved = (char *)0;
    return tok;
}
#define strtok(s, d) rtlsdr__strtok((s), (d))

#endif /* !RTLSDR_HAVE_LIBC_PARSE */

#endif /* RTLSDR_COMPAT_H */
