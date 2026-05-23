//
//  RTL_SDR.cpp
//  RTL-SDR
//
//  Created by Arved Viehweger on 19.05.26.
//
//  DriverKit interface driver for the RTL2832U.
//
//  This file is the USBDriverKit transport layer underneath the ported
//  librtlsdr core. It provides:
//    * the C bridge declared in rtlsdr_usb.h (control transfers, bulk reads,
//      asynchronous IQ streaming, device reset),
//    * the DriverKit compatibility shims declared in rtlsdr_compat.h
//      (rtlsdr_log / rtlsdr_msleep / rtlsdr_mem_alloc / rtlsdr_mem_free),
//    * the device life cycle (Start / Stop),
//    * the IOUserClient factory (NewUserClient),
//    * the local entry points used by RTL_SDR_UserClient.
//
//  Threading model
//  ---------------
//  Everything that touches the device runs on RTL_SDR's *default* dispatch
//  queue (grabbed once via CopyDispatchQueue). Start/Stop/ReadComplete already
//  run there; HandleScalarCommand hops onto it with DispatchSync; softagc gain
//  changes are posted with DispatchAsync. A single serial queue means the
//  recursive I2C lock of the original librtlsdr code is no longer needed.
//
//  NOTE: a few USBDriverKit method signatures / constant names below are
//  marked "VERIFY" - please check them against the USBDriverKit SDK headers
//  in your Xcode version; they are the only spots likely to need a tweak.
//

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSAction.h>

#include <USBDriverKit/USBDriverKit.h>

#include "RTL_SDR.h"

#include "rtl-sdr.h"
#include "rtlsdr_usb.h"
#include "RTLSDRShared.h"

#define RTLSDR_MAX_XFER       32      /* hard cap on streaming buffers      */
#define RTLSDR_CTRL_BUF_SIZE  256     /* reusable control-transfer buffer   */

/* ===========================================================================
 * MARK: - Transport state
 *
 * The opaque rtlsdr_usb_t handle that librtlsdr.c passes around is a pointer
 * to this struct. It is allocated in Start() and freed in Stop().
 * ======================================================================== */
struct RTLSDRTransport {
    RTL_SDR                  *owner;        /* back-pointer to the dext object */
    IOUSBHostInterface       *interface;    /* matched USB interface (provider)*/
    IOUSBHostPipe            *pipeIn;       /* bulk-IN pipe, endpoint 0x81     */
    IODispatchQueue          *deviceQueue;  /* RTL_SDR default queue (retained)*/

    IOBufferMemoryDescriptor *ctrlBuffer;   /* reusable control buffer         */
    uint8_t                  *ctrlBytes;    /* mapped address of ctrlBuffer    */

    IOBufferMemoryDescriptor *iqRing;       /* shared IQ ring (app-mapped)     */
    RTLSDRRingBuffer         *iqRingAddr;   /* mapped address of iqRing        */

    rtlsdr_dev_t             *dev;          /* librtlsdr device                */

    /* asynchronous streaming */
    bool                      streaming;
    uint32_t                  streamBufNum;
    uint32_t                  streamBufLen;
    IOBufferMemoryDescriptor *streamBuf[RTLSDR_MAX_XFER];
    OSAction                 *streamAct[RTLSDR_MAX_XFER];
    uint8_t                  *streamAddr[RTLSDR_MAX_XFER];
    rtlsdr_usb_stream_cb_t    streamCb;
    void                     *streamCtx;
};

struct RTL_SDR_IVars {
    RTLSDRTransport *t;
};

static void RTLSDR_TeardownTransport(RTLSDRTransport *t);

/* ===========================================================================
 * MARK: - librtlsdr compatibility shims (rtlsdr_compat.h)
 * ======================================================================== */

/* ---- minimal printf-style formatter ------------------------------------
 * DriverKit does not export vsnprintf(), so rtlsdr_log() formats the
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

extern "C" void rtlsdr_log(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    rtlsdr__vformat(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "[rtlsdr] %{public}s", buf);
}

extern "C" void rtlsdr_msleep(uint32_t ms)
{
    IOSleep(ms);
}

extern "C" void *rtlsdr_mem_alloc(uint32_t size)
{
    return IOMallocZero(size);
}

extern "C" void rtlsdr_mem_free(void *ptr, uint32_t size)
{
    if (ptr)
        IOFree(ptr, size);
}

/* ===========================================================================
 * MARK: - IQ sink
 *
 * Installed as the librtlsdr async callback (dev->cb). Runs in the streaming
 * completion context and copies the IQ bytes into the shared ring buffer.
 * Single producer / single consumer; if the host app falls behind, the oldest
 * bytes are dropped and accounted in dropCount.
 * ======================================================================== */
static void RTLSDR_iqSink(unsigned char *buf, uint32_t len, void *ctx)
{
    RTLSDRTransport *t = (RTLSDRTransport *)ctx;
    if (!t || !t->iqRingAddr || len == 0)
        return;

    RTLSDRRingBuffer *ring = t->iqRingAddr;
    uint64_t w = ring->writeCount;
    uint64_t r = ring->readCount;
    uint64_t used = w - r;

    if (used + len > RTLSDR_RING_DATA_SIZE) {
        uint64_t drop = used + len - RTLSDR_RING_DATA_SIZE;
        ring->readCount  = r + drop;        /* best-effort: advance consumer  */
        ring->dropCount += drop;
    }

    uint32_t off   = (uint32_t)(w % RTLSDR_RING_DATA_SIZE);
    uint32_t first = RTLSDR_RING_DATA_SIZE - off;
    if (first > len)
        first = len;
    memcpy(ring->data + off, buf, first);
    if (len > first)
        memcpy(ring->data, buf + first, len - first);

    ring->writeCount = w + len;             /* publish last */
}

/* ===========================================================================
 * MARK: - USB C bridge (rtlsdr_usb.h)
 * ======================================================================== */

extern "C" int rtlsdr_usb_control_transfer(rtlsdr_usb_t usb,
                                           uint8_t  bmRequestType,
                                           uint8_t  bRequest,
                                           uint16_t wValue,
                                           uint16_t wIndex,
                                           uint8_t *data,
                                           uint16_t wLength,
                                           uint32_t timeout_ms)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t || !t->interface || !t->ctrlBuffer)
        return -1;

    const bool isIn = (bmRequestType & 0x80u) != 0;

    if (!isIn && wLength > 0 && data)
        memcpy(t->ctrlBytes, data, wLength);

    /* The descriptor must report exactly the transfer length. */
    t->ctrlBuffer->SetLength(wLength ? wLength : 1);

    uint16_t transferred = 0;
    /* IOUSBHostInterface::DeviceRequest - synchronous form: the five USB
     * setup-packet fields, then the data buffer, the byte count and a
     * completion timeout. */
    kern_return_t ret = t->interface->DeviceRequest(bmRequestType,
                                                    bRequest,
                                                    wValue,
                                                    wIndex,
                                                    wLength,
                                                    t->ctrlBuffer,
                                                    &transferred,
                                                    timeout_ms);
    if (ret != kIOReturnSuccess)
        return -1;

    if (isIn && data && transferred > 0) {
        uint16_t n = (transferred < wLength) ? transferred : wLength;
        memcpy(data, t->ctrlBytes, n);
    }
    return (int)transferred;
}

extern "C" int rtlsdr_usb_bulk_read(rtlsdr_usb_t usb,
                                    uint8_t *data,
                                    int      length,
                                    int     *transferred,
                                    uint32_t timeout_ms)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t || !t->pipeIn || !t->interface || length <= 0)
        return -1;

    IOBufferMemoryDescriptor *buf = nullptr;
    kern_return_t ret = t->interface->CreateIOBuffer(kIOMemoryDirectionIn,
                                                     (uint64_t)length, &buf);
    if (ret != kIOReturnSuccess || !buf)
        return -1;

    uint32_t got = 0;
    /* VERIFY: synchronous IOUSBHostPipe::IO(buffer, length, &count, timeout) */
    ret = t->pipeIn->IO(buf, (uint32_t)length, &got, timeout_ms);
    if (ret == kIOReturnSuccess) {
        IOAddressSegment seg;
        buf->GetAddressRange(&seg);
        memcpy(data, (void *)seg.address, got);
        if (transferred)
            *transferred = (int)got;
    }
    OSSafeReleaseNULL(buf);
    return (ret == kIOReturnSuccess) ? 0 : -1;
}

extern "C" int rtlsdr_usb_reset(rtlsdr_usb_t usb)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t || !t->interface)
        return -1;

    IOUSBHostDevice *dev = nullptr;
    /* VERIFY: IOUSBHostInterface::CopyDevice / IOUSBHostDevice::Reset */
    kern_return_t ret = t->interface->CopyDevice(&dev);
    if (ret == kIOReturnSuccess && dev) {
        ret = dev->Reset();
        OSSafeReleaseNULL(dev);
    }
    return (ret == kIOReturnSuccess) ? 0 : -1;
}

extern "C" int rtlsdr_usb_get_strings(rtlsdr_usb_t usb,
                                      char *manufact, char *product, char *serial)
{
    /* DriverKit port: string descriptors are only used by librtlsdr to
     * auto-detect the RTL-SDR Blog V4 crystal. Returning empty strings simply
     * makes that detection fall through, which is harmless for other dongles.
     * Implement with IOUSBHostDevice::CopyStringDescriptor() if you need it. */
    (void)usb;
    if (manufact) manufact[0] = '\0';
    if (product)  product[0]  = '\0';
    if (serial)   serial[0]   = '\0';
    return 0;
}

extern "C" int rtlsdr_usb_stream_start(rtlsdr_usb_t usb,
                                       uint32_t buf_num,
                                       uint32_t buf_len,
                                       rtlsdr_usb_stream_cb_t cb,
                                       void *ctx)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t || !t->pipeIn || !t->interface || !t->owner)
        return -1;
    if (t->streaming)
        return -2;
    if (buf_num == 0 || buf_num > RTLSDR_MAX_XFER)
        buf_num = RTLSDR_MAX_XFER;

    t->streamBufNum = buf_num;
    t->streamBufLen = buf_len;
    t->streamCb     = cb;
    t->streamCtx    = ctx;
    t->streaming    = true;

    /* allocate buffers and one completion action per buffer */
    for (uint32_t i = 0; i < buf_num; ++i) {
        kern_return_t ret = t->interface->CreateIOBuffer(kIOMemoryDirectionIn,
                                                         buf_len, &t->streamBuf[i]);
        if (ret != kIOReturnSuccess || !t->streamBuf[i]) {
            os_log(OS_LOG_DEFAULT, "[rtlsdr] stream buffer %u alloc failed: 0x%x", i, ret);
            t->streaming = false;
            return -1;
        }
        IOAddressSegment seg;
        t->streamBuf[i]->GetAddressRange(&seg);
        t->streamAddr[i] = (uint8_t *)seg.address;

        ret = t->owner->CreateActionReadComplete(sizeof(uint64_t), &t->streamAct[i]);
        if (ret != kIOReturnSuccess || !t->streamAct[i]) {
            os_log(OS_LOG_DEFAULT, "[rtlsdr] stream action %u alloc failed: 0x%x", i, ret);
            t->streaming = false;
            return -1;
        }
        /* stash the buffer index in the action's reference memory */
        *(uint64_t *)t->streamAct[i]->GetReference() = (uint64_t)i;
    }

    /* submit them all - completion timeout 0 == stream continuously */
    for (uint32_t i = 0; i < buf_num; ++i) {
        kern_return_t ret = t->pipeIn->AsyncIO(t->streamBuf[i], buf_len,
                                               t->streamAct[i], 0);
        if (ret != kIOReturnSuccess)
            os_log(OS_LOG_DEFAULT, "[rtlsdr] AsyncIO submit %u failed: 0x%x", i, ret);
    }
    os_log(OS_LOG_DEFAULT, "[rtlsdr] streaming started: %u x %u bytes", buf_num, buf_len);
    return 0;
}

extern "C" int rtlsdr_usb_stream_stop(rtlsdr_usb_t usb)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t)
        return -1;
    if (!t->streaming)
        return 0;

    t->streaming = false;

    /* VERIFY: IOUSBHostPipe::Abort(options, withError, forAction).
     * Use the synchronous option so that all in-flight transfers have
     * completed (and ReadComplete has run) by the time Abort returns. */
    if (t->pipeIn)
        t->pipeIn->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);

    for (uint32_t i = 0; i < t->streamBufNum; ++i) {
        OSSafeReleaseNULL(t->streamAct[i]);
        OSSafeReleaseNULL(t->streamBuf[i]);
        t->streamAddr[i] = nullptr;
    }
    t->streamBufNum = 0;
    t->streamCb     = nullptr;
    t->streamCtx    = nullptr;
    os_log(OS_LOG_DEFAULT, "[rtlsdr] streaming stopped");
    return 0;
}

extern "C" void rtlsdr_softagc_schedule(rtlsdr_usb_t usb)
{
    RTLSDRTransport *t = (RTLSDRTransport *)usb;
    if (!t || !t->deviceQueue || !t->dev)
        return;
    rtlsdr_dev_t *d = t->dev;
    /* Apply the gain change serialised on the device queue. */
    t->deviceQueue->DispatchAsync(^{
        rtlsdr_softagc_apply(d);
    });
}

/* ===========================================================================
 * MARK: - Transport teardown
 * ======================================================================== */
static void RTLSDR_TeardownTransport(RTLSDRTransport *t)
{
    if (!t)
        return;

    if (t->streaming)
        rtlsdr_usb_stream_stop(t);

    /* rtlsdr_close() issues USB control transfers (deinit_baseband); the
     * caller (Start failure path / Stop) already runs on the device queue. */
    if (t->dev) {
        rtlsdr_close(t->dev);
        t->dev = nullptr;
    }

    for (uint32_t i = 0; i < RTLSDR_MAX_XFER; ++i) {
        OSSafeReleaseNULL(t->streamAct[i]);
        OSSafeReleaseNULL(t->streamBuf[i]);
    }
    OSSafeReleaseNULL(t->ctrlBuffer);
    OSSafeReleaseNULL(t->iqRing);
    OSSafeReleaseNULL(t->pipeIn);

    if (t->interface) {
        t->interface->Close(t->owner, 0);
        t->interface = nullptr;
    }
    OSSafeReleaseNULL(t->deviceQueue);
}

/* ===========================================================================
 * MARK: - Device life cycle
 * ======================================================================== */

//  DriverKit does not allocate the ivars block by itself - init() must do it,
//  otherwise `ivars` is NULL for the whole object life time.
//  init() / free() are plain virtual methods of OSObject - implemented as
//  ordinary C++ overrides (no IMPL macro), the super call uses the base class
//  name directly.
bool
RTL_SDR::init()
{
    if (!IOService::init())
        return false;
    ivars = IONewZero(RTL_SDR_IVars, 1);
    return (ivars != nullptr);
}

void
RTL_SDR::free()
{
    IOSafeDeleteNULL(ivars, RTL_SDR_IVars, 1);
    IOService::free();
}

kern_return_t
IMPL(RTL_SDR, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR::Start super failed: 0x%x", ret);
        return ret;
    }
    os_log(OS_LOG_DEFAULT, "RTL_SDR::Start");

    RTLSDRTransport *t = (RTLSDRTransport *)IOMallocZero(sizeof(RTLSDRTransport));
    if (!t) {
        Stop(provider, SUPERDISPATCH);
        return kIOReturnNoMemory;
    }
    os_log(OS_LOG_DEFAULT, "RTL_SDR::Start ivars=%p t=%p", ivars, t);
    ivars->t  = t;
    t->owner  = this;

    t->interface = OSDynamicCast(IOUSBHostInterface, provider);
    if (!t->interface) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: provider is not an IOUSBHostInterface");
        ret = kIOReturnNoDevice;
        goto fail;
    }

    /* VERIFY: IOUSBHostInterface::Open(forClient, options, arg) */
    ret = t->interface->Open(this, 0, NULL);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: interface Open failed: 0x%x", ret);
        goto fail;
    }

    /* bulk-IN pipe carrying the IQ samples (endpoint address 0x81) */
    ret = t->interface->CopyPipe(0x81, &t->pipeIn);
    if (ret != kIOReturnSuccess || !t->pipeIn) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: CopyPipe(0x81) failed: 0x%x", ret);
        ret = kIOReturnNoDevice;
        goto fail;
    }

    /* Use this driver's own default dispatch queue for every device access:
     * Start / Stop / ReadComplete already run here, control commands hop on
     * with DispatchSync, softagc gain changes with DispatchAsync. */
    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &t->deviceQueue);
    if (ret != kIOReturnSuccess || !t->deviceQueue) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: CopyDispatchQueue failed: 0x%x", ret);
        goto fail;
    }

    /* reusable control-transfer buffer */
    ret = t->interface->CreateIOBuffer(kIOMemoryDirectionInOut,
                                       RTLSDR_CTRL_BUF_SIZE, &t->ctrlBuffer);
    if (ret != kIOReturnSuccess || !t->ctrlBuffer) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: ctrl buffer alloc failed: 0x%x", ret);
        goto fail;
    }
    {
        IOAddressSegment seg;
        t->ctrlBuffer->GetAddressRange(&seg);
        t->ctrlBytes = (uint8_t *)seg.address;
    }

    /* shared IQ ring buffer handed to the host app via the user client */
    ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut,
                                           sizeof(RTLSDRRingBuffer), 0,
                                           &t->iqRing);
    if (ret != kIOReturnSuccess || !t->iqRing) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: IQ ring alloc failed: 0x%x", ret);
        goto fail;
    }
    {
        IOAddressSegment seg;
        t->iqRing->GetAddressRange(&seg);
        t->iqRingAddr = (RTLSDRRingBuffer *)seg.address;
        memset(t->iqRingAddr, 0, sizeof(RTLSDRRingBuffer));
        t->iqRingAddr->dataSize = RTLSDR_RING_DATA_SIZE;
    }

    /* Open the librtlsdr device. We are already on the device queue, so this
     * (and all the control transfers it performs) runs serialised. */
    {
        int r = rtlsdr_open_usb(&t->dev, t);
        if (r != 0 || !t->dev) {
            os_log(OS_LOG_DEFAULT, "RTL_SDR: rtlsdr_open_usb failed: %d", r);
            ret = kIOReturnError;
            goto fail;
        }
    }

    RegisterService();
    os_log(OS_LOG_DEFAULT, "RTL_SDR: started, tuner type = %d",
           rtlsdr_get_tuner_type(t->dev));
    return kIOReturnSuccess;

fail:
    RTLSDR_TeardownTransport(t);
    IOFree(t, sizeof(RTLSDRTransport));
    ivars->t = nullptr;
    Stop(provider, SUPERDISPATCH);
    return ret;
}

kern_return_t
IMPL(RTL_SDR, Stop)
{
    os_log(OS_LOG_DEFAULT, "RTL_SDR::Stop");

    if (ivars && ivars->t) {
        RTLSDR_TeardownTransport(ivars->t);
        IOFree(ivars->t, sizeof(RTLSDRTransport));
        ivars->t = nullptr;
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(RTL_SDR, NewUserClient)
{
    os_log(OS_LOG_DEFAULT, "RTL_SDR::NewUserClient (type %u)", type);

    IOService *ucService = nullptr;
    /* Instantiates RTL_SDR_UserClient from the "UserClientProperties" dict
     * in Info.plist. */
    kern_return_t ret = Create(this, "UserClientProperties", &ucService);
    if (ret != kIOReturnSuccess || !ucService) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: user client Create failed: 0x%x", ret);
        return (ret != kIOReturnSuccess) ? ret : kIOReturnError;
    }

    *userClient = OSDynamicCast(IOUserClient, ucService);
    if (!*userClient) {
        ucService->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

/* ===========================================================================
 * MARK: - Bulk-IN completion
 *
 * Runs on the device queue, once per completed AsyncIO transfer. Forwards the
 * IQ samples to librtlsdr (softagc + dev->cb -> RTLSDR_iqSink) and resubmits
 * the same buffer.
 * ======================================================================== */
void
IMPL(RTL_SDR, ReadComplete)
{
    RTLSDRTransport *t = (ivars ? ivars->t : nullptr);
    if (!t)
        return;

    uint32_t idx = (uint32_t)(*(uint64_t *)action->GetReference());
    if (idx >= t->streamBufNum)
        return;

    if (t->streaming && status == kIOReturnSuccess && actualByteCount > 0) {
        if (t->streamCb)
            t->streamCb(t->streamAddr[idx], actualByteCount, t->streamCtx);
    }

    if (t->streaming &&
        status != kIOReturnAborted &&
        status != kIOReturnNotResponding &&
        status != kIOReturnNoDevice) {
        kern_return_t ret = t->pipeIn->AsyncIO(t->streamBuf[idx],
                                               t->streamBufLen, action, 0);
        if (ret != kIOReturnSuccess)
            os_log(OS_LOG_DEFAULT, "[rtlsdr] resubmit %u failed: 0x%x", idx, ret);
    }
}

/* ===========================================================================
 * MARK: - Local entry points for RTL_SDR_UserClient
 * ======================================================================== */

kern_return_t
RTL_SDR::HandleScalarCommand(uint32_t selector, uint64_t arg, uint64_t *result)
{
    RTLSDRTransport *t = (ivars ? ivars->t : nullptr);
    if (!t || !t->dev || !t->deviceQueue)
        return kIOReturnNotReady;

    __block int      r   = 0;
    __block uint64_t out = 0;

    /* Run the command serialised on the device queue. */
    t->deviceQueue->DispatchSync(^{
        rtlsdr_dev_t *d = t->dev;
        switch (selector) {
        case kRTLSDRMethodStartStream:
            r = rtlsdr_read_async(d, RTLSDR_iqSink, t, 0, 0);
            break;
        case kRTLSDRMethodStopStream:
            r = rtlsdr_cancel_async(d);
            break;
        case kRTLSDRMethodSetCenterFreq:
            r = rtlsdr_set_center_freq64(d, arg);
            break;
        case kRTLSDRMethodSetSampleRate:
            r = rtlsdr_set_sample_rate(d, (uint32_t)arg);
            break;
        case kRTLSDRMethodSetTunerGainMode:
            r = rtlsdr_set_tuner_gain_mode(d, (int)arg);
            break;
        case kRTLSDRMethodSetTunerGain:
            r = rtlsdr_set_tuner_gain(d, (int)(int32_t)arg);
            break;
        case kRTLSDRMethodSetAgcMode:
            r = rtlsdr_set_agc_mode(d, (int)arg);
            break;
        case kRTLSDRMethodSetFreqCorrection:
            r = rtlsdr_set_freq_correction(d, (int)(int32_t)arg);
            break;
        case kRTLSDRMethodSetTunerBandwidth:
            r = rtlsdr_set_tuner_bandwidth(d, (uint32_t)arg);
            break;
        case kRTLSDRMethodSetTestmode:
            r = rtlsdr_set_testmode(d, (int)arg);
            break;
        case kRTLSDRMethodSetDirectSampling:
            r = rtlsdr_set_direct_sampling(d, (int)arg);
            break;
        case kRTLSDRMethodSetBiasTee:
            r = rtlsdr_set_bias_tee(d, (int)arg);
            break;
        case kRTLSDRMethodResetBuffer:
            r = rtlsdr_reset_buffer(d);
            break;
        case kRTLSDRMethodSetGainByIndex: {
            int gains[128];
            int n = rtlsdr_get_tuner_gains(d, gains);
            if (n > 0 && (int)arg < n)
                r = rtlsdr_set_tuner_gain(d, gains[arg]);
            else
                r = -1;
            break;
        }
        case kRTLSDRMethodGetTunerType:
            out = (uint64_t)rtlsdr_get_tuner_type(d);
            break;
        default:
            r = -1;
            break;
        }
    });

    if (result)
        *result = out;
    return (r == 0) ? kIOReturnSuccess : kIOReturnError;
}

kern_return_t
RTL_SDR::CopyIQRing(IOMemoryDescriptor **ring)
{
    RTLSDRTransport *t = (ivars ? ivars->t : nullptr);
    if (!t || !t->iqRing || !ring)
        return kIOReturnNotReady;

    t->iqRing->retain();          /* balanced by the caller / the kernel */
    *ring = t->iqRing;
    return kIOReturnSuccess;
}

kern_return_t
RTL_SDR::FillDeviceInfo(void *infop)
{
    RTLSDRDeviceInfo *info = (RTLSDRDeviceInfo *)infop;
    if (!info)
        return kIOReturnBadArgument;
    memset(info, 0, sizeof(*info));

    RTLSDRTransport *t = (ivars ? ivars->t : nullptr);
    if (!t || !t->dev)
        return kIOReturnNotReady;

    info->valid      = 1;
    info->tunerType  = (uint32_t)rtlsdr_get_tuner_type(t->dev);
    info->sampleRate = rtlsdr_get_sample_rate(t->dev);
    info->streaming  = t->streaming ? 1u : 0u;
    return kIOReturnSuccess;
}
