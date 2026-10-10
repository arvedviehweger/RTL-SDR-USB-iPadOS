//
//  libc_driverkit.cpp
//  RTL-SDR
//
//  C library functions librtlsdr uses that DriverKit does not provide
//  (declared in include/stdio.h, stdlib.h and unistd.h):
//    * malloc / calloc / free, and strdup on top of them, using IOMalloc,
//    * getenv - a dext has no environment,
//    * fprintf / printf (renamed, see include/stdio.h), formatted into os_log,
//    * usleep, using IOSleep / IODelay,
//    * isspace, which DriverKit's <ctype.h> declares but does not export.
//

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <os/log.h>

#include <DriverKit/IOLib.h>

/* ===========================================================================
 * MARK: - Heap
 *
 * IOFree() needs the size of the block, so it is kept in a header in front
 * of it. 16 bytes keep the returned pointer 16-byte aligned.
 * ======================================================================== */

struct rtlsdr_alloc_header {
    size_t size;                        /* including this header */
    size_t reserved;
};

extern "C" void *malloc(size_t size)
{
    if (size > SIZE_MAX - sizeof(rtlsdr_alloc_header))
        return nullptr;
    size_t total = size + sizeof(rtlsdr_alloc_header);
    rtlsdr_alloc_header *h = (rtlsdr_alloc_header *)IOMalloc(total);
    if (!h)
        return nullptr;
    h->size = total;
    return h + 1;
}

extern "C" void *calloc(size_t count, size_t size)
{
    if (size && count > (SIZE_MAX - sizeof(rtlsdr_alloc_header)) / size)
        return nullptr;
    size_t total = count * size + sizeof(rtlsdr_alloc_header);
    rtlsdr_alloc_header *h = (rtlsdr_alloc_header *)IOMallocZero(total);
    if (!h)
        return nullptr;
    h->size = total;
    return h + 1;
}

extern "C" void free(void *ptr)
{
    if (!ptr)
        return;
    rtlsdr_alloc_header *h = (rtlsdr_alloc_header *)ptr - 1;
    IOFree(h, h->size);
}

/* DriverKit's strdup() would allocate from a heap our free() cannot release. */
extern "C" char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *copy = (char *)malloc(n);
    if (copy)
        memcpy(copy, s, n);
    return copy;
}

extern "C" char *getenv(const char *name)
{
    (void)name;
    return nullptr;
}

extern "C" int isspace(int c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

/* ===========================================================================
 * MARK: - Sleeping
 * ======================================================================== */

extern "C" int usleep(unsigned int microseconds)
{
    if (microseconds >= 1000)
        IOSleep((microseconds + 999) / 1000);
    else if (microseconds > 0)
        IODelay(microseconds);
    return 0;
}

/* ===========================================================================
 * MARK: - Logging
 * ======================================================================== */

/* ---- minimal printf-style formatter ------------------------------------
 * DriverKit does not export vsnprintf(), so fprintf() formats the
 * conversion specifiers librtlsdr actually uses itself:
 *     d i u x X p c s f e g %%
 * with optional '0' flag, field width, '.'precision and the l / ll / h / z
 * length modifiers. va_arg() itself is a compiler builtin and needs no libc.
 * The output buffer is always NUL-terminated.
 */
static void rtlsdr__emit(char *out, size_t cap, size_t *pos, char c)
{
    if (*pos + 1 < cap)
        out[*pos] = c;
    (*pos)++;
}

static void rtlsdr__emit_str(char *out, size_t cap, size_t *pos,
                             const char *s, int width, int leftAlign)
{
    const char *p = s ? s : "(null)";
    int len = 0;
    while (p[len]) ++len;
    if (!leftAlign)
        for (int i = len; i < width; ++i) rtlsdr__emit(out, cap, pos, ' ');
    for (int i = 0; i < len; ++i) rtlsdr__emit(out, cap, pos, p[i]);
    if (leftAlign)
        for (int i = len; i < width; ++i) rtlsdr__emit(out, cap, pos, ' ');
}

static void rtlsdr__emit_num(char *out, size_t cap, size_t *pos,
                             unsigned long long v, int base, int upper,
                             int negative, int width, int prec, int zero)
{
    char digits[24];
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    if (!(v == 0 && prec == 0)) {
        do {
            digits[n++] = set[v % (unsigned)base];
            v /= (unsigned)base;
        } while (v && n < (int)sizeof(digits));
    }
    while (n < prec && n < (int)sizeof(digits))
        digits[n++] = '0';                    /* precision == minimum digits */

    int body = n + (negative ? 1 : 0);
    int pad  = (width > body) ? (width - body) : 0;

    if (zero && prec < 0) {
        if (negative) rtlsdr__emit(out, cap, pos, '-');
        for (int i = 0; i < pad; ++i) rtlsdr__emit(out, cap, pos, '0');
    } else {
        for (int i = 0; i < pad; ++i) rtlsdr__emit(out, cap, pos, ' ');
        if (negative) rtlsdr__emit(out, cap, pos, '-');
    }
    while (n > 0) rtlsdr__emit(out, cap, pos, digits[--n]);
}

static void rtlsdr__emit_double(char *out, size_t cap, size_t *pos,
                                double d, int prec)
{
    if (prec < 0) prec = 6;
    if (prec > 9) prec = 9;

    int neg = 0;
    if (d < 0.0) { neg = 1; d = -d; }
    if (neg)
        rtlsdr__emit(out, cap, pos, '-');
    if (d > 1.8e18) {                         /* outside 64-bit integer range */
        rtlsdr__emit_str(out, cap, pos, "ovf", 0, 0);
        return;
    }
    unsigned long long scale = 1;
    for (int i = 0; i < prec; ++i) scale *= 10ULL;
    unsigned long long scaled = (unsigned long long)(d * (double)scale + 0.5);
    rtlsdr__emit_num(out, cap, pos, scaled / scale, 10, 0, 0, 0, -1, 0);
    if (prec > 0) {
        rtlsdr__emit(out, cap, pos, '.');
        rtlsdr__emit_num(out, cap, pos, scaled % scale, 10, 0, 0, 0, prec, 0);
    }
}

static void rtlsdr__vformat(char *out, size_t cap, const char *fmt, va_list ap)
{
    size_t pos = 0;
    for (const char *p = fmt; p && *p; ++p) {
        if (*p != '%') { rtlsdr__emit(out, cap, &pos, *p); continue; }
        ++p;
        if (*p == '%') { rtlsdr__emit(out, cap, &pos, '%'); continue; }
        if (*p == '\0') break;

        int leftAlign = 0, zero = 0;
        for (;; ++p) {
            if (*p == '-')      leftAlign = 1;
            else if (*p == '0') zero = 1;
            else if (*p == '+' || *p == ' ' || *p == '#') { /* ignored */ }
            else break;
        }
        int width = 0;
        while (*p >= '0' && *p <= '9') { width = width * 10 + (*p - '0'); ++p; }
        int prec = -1;
        if (*p == '.') {
            ++p; prec = 0;
            while (*p >= '0' && *p <= '9') { prec = prec * 10 + (*p - '0'); ++p; }
        }
        int lng = 0;
        while (*p == 'l' || *p == 'h' || *p == 'z' || *p == 'j' || *p == 't') {
            if (*p == 'l') ++lng;
            ++p;
        }
        switch (*p) {
        case 'd': case 'i': {
            long long v = (lng >= 1) ? va_arg(ap, long long)
                                     : (long long)va_arg(ap, int);
            int neg = (v < 0);
            unsigned long long u = neg
                ? (unsigned long long)(-(v + 1)) + 1ULL
                : (unsigned long long)v;
            rtlsdr__emit_num(out, cap, &pos, u, 10, 0, neg, width, prec, zero);
            break;
        }
        case 'u': {
            unsigned long long v = (lng >= 1)
                ? va_arg(ap, unsigned long long)
                : (unsigned long long)va_arg(ap, unsigned int);
            rtlsdr__emit_num(out, cap, &pos, v, 10, 0, 0, width, prec, zero);
            break;
        }
        case 'x': case 'X': {
            unsigned long long v = (lng >= 1)
                ? va_arg(ap, unsigned long long)
                : (unsigned long long)va_arg(ap, unsigned int);
            rtlsdr__emit_num(out, cap, &pos, v, 16, (*p == 'X'),
                             0, width, prec, zero);
            break;
        }
        case 'p': {
            void *vp = va_arg(ap, void *);
            rtlsdr__emit(out, cap, &pos, '0');
            rtlsdr__emit(out, cap, &pos, 'x');
            rtlsdr__emit_num(out, cap, &pos,
                             (unsigned long long)(uintptr_t)vp,
                             16, 0, 0, 0, -1, 0);
            break;
        }
        case 'c':
            rtlsdr__emit(out, cap, &pos, (char)va_arg(ap, int));
            break;
        case 's':
            rtlsdr__emit_str(out, cap, &pos, va_arg(ap, const char *),
                             width, leftAlign);
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G':
            rtlsdr__emit_double(out, cap, &pos, va_arg(ap, double), prec);
            break;
        case '\0':
            out[(pos < cap) ? pos : (cap - 1)] = '\0';
            return;
        default:
            rtlsdr__emit(out, cap, &pos, '%');
            rtlsdr__emit(out, cap, &pos, *p);
            break;
        }
    }
    out[(pos < cap) ? pos : (cap - 1)] = '\0';
}

/* stderr and stdout only exist for librtlsdr to name; both go to os_log. */
extern "C" {
FILE *stderr;
FILE *stdout;
}

static void rtlsdr__log(const char *fmt, va_list ap)
{
    char buf[256];
    rtlsdr__vformat(buf, sizeof(buf), fmt, ap);

    /* librtlsdr ends its messages with a newline; os_log adds its own */
    size_t len = strlen(buf);
    while (len > 0 && buf[len - 1] == '\n')
        buf[--len] = '\0';
    os_log(OS_LOG_DEFAULT, "[rtlsdr] %{public}s", buf);
}

extern "C" int rtlsdr_shim_fprintf(FILE *stream, const char *fmt, ...)
{
    (void)stream;
    va_list ap;
    va_start(ap, fmt);
    rtlsdr__log(fmt, ap);
    va_end(ap);
    return 0;
}

extern "C" int rtlsdr_shim_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    rtlsdr__log(fmt, ap);
    va_end(ap);
    return 0;
}
