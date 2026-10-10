//
//  RTL_SDR.cpp
//  RTL-SDR
//
//  Created by Arved Viehweger on 19.05.26.
//
//  DriverKit interface driver for the RTL2832U.
//
//  librtlsdr (third_party/librtlsdr) is compiled unmodified. It talks to the
//  device through the libusb, pthread and libc shims in Shim/ at the top of
//  the repository. This file
//  provides:
//    * the device life cycle (Start / Stop), which attaches the matched USB
//      interface to the libusb shim and opens it with rtlsdr_open(),
//    * the IQ stream, i.e. rtlsdr_read_async() and its callback,
//    * the IOUserClient factory (NewUserClient),
//    * the local entry points used by RTL_SDR_UserClient.
//
//  Threading model
//  ---------------
//  Device control runs on RTL_SDR's *default* dispatch queue (grabbed once
//  via CopyDispatchQueue). Start/Stop already run there; HandleScalarCommand
//  hops onto it with DispatchSync.
//
//  IQ streaming runs on a second, reentrant queue ("Stream"). StartStream
//  posts rtlsdr_read_async() there, where it runs librtlsdr's libusb event
//  loop until rtlsdr_cancel_async(). While the loop waits it sleeps on the
//  queue, which lets ReadComplete (QUEUENAME(Stream)) deliver the bulk-IN
//  completions to the libusb shim. This is upstream's own split - control
//  calls on one thread, the libusb event loop and IQ callbacks on another,
//  with librtlsdr's I2C mutex in between.
//

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSAction.h>

#include <USBDriverKit/USBDriverKit.h>

#include "RTL_SDR.h"

#include "rtl-sdr.h"
#include "RTLSDRShared.h"
#include "libusb_driverkit.h"

/* Streaming geometry passed to rtlsdr_read_async(). librtlsdr's default of
 * 15 x 256 KiB hands IQ to the ring only every 64 ms at 2.048 MS/s (128 ms
 * at 1.024 MS/s), which rtl_tcp clients see as bursts and gaps. 32 x 32 KiB
 * delivers every 8 ms and still keeps ~256 ms queued on the USB pipe. */
#define RTLSDR_STREAM_BUF_NUM 32
#define RTLSDR_STREAM_BUF_LEN (32u * 1024u)

/* How long StartStream / StopStream wait for the stream loop. */
#define RTLSDR_STREAM_WAIT_MS 3000

/* ===========================================================================
 * MARK: - Transport state
 *
 * Allocated in Start() and freed in Stop().
 * ======================================================================== */
struct RTLSDRTransport {
    RTL_SDR                  *owner;        /* back-pointer to the dext object */
    IOUSBHostInterface       *interface;    /* matched USB interface (provider)*/
    IODispatchQueue          *deviceQueue;  /* RTL_SDR default queue (retained)*/
    IODispatchQueue          *streamQueue;  /* runs the libusb event loop      */
    bool                      usbAttached;  /* interface handed to the shim    */

    IOBufferMemoryDescriptor *iqRing;       /* shared IQ ring (app-mapped)     */
    RTLSDRRingBuffer         *iqRingAddr;   /* mapped address of iqRing        */

    rtlsdr_dev_t             *dev;          /* librtlsdr device                */
    char                      manufact[256]; /* USB strings, read in Start()  */
    char                      product[256];

    /* set while rtlsdr_read_async() runs on the stream queue */
    bool                      streaming;    /* atomic                          */
    int                       streamResult; /* its return value                */
};

struct RTL_SDR_IVars {
    RTLSDRTransport *t;
};

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
 * MARK: - IQ stream
 *
 * rtlsdr_read_async() is librtlsdr's libusb event loop: it only returns
 * after rtlsdr_cancel_async(), so it gets the stream queue to itself.
 * ======================================================================== */

static bool RTLSDR_IsStreaming(RTLSDRTransport *t)
{
    return __atomic_load_n(&t->streaming, __ATOMIC_ACQUIRE);
}

/* Returns like a synchronous start: 0 once transfers are in flight, or the
 * result of rtlsdr_read_async() if it ended before that. */
static int RTLSDR_StartStream(RTLSDRTransport *t)
{
    if (RTLSDR_IsStreaming(t))
        return -2;

    t->streamResult = 0;
    __atomic_store_n(&t->streaming, true, __ATOMIC_RELEASE);
    t->streamQueue->DispatchAsync(^{
        int r = rtlsdr_read_async(t->dev, RTLSDR_iqSink, t,
                                  RTLSDR_STREAM_BUF_NUM, RTLSDR_STREAM_BUF_LEN);
        os_log(OS_LOG_DEFAULT, "[rtlsdr] rtlsdr_read_async returned %d", r);
        t->streamResult = r;
        __atomic_store_n(&t->streaming, false, __ATOMIC_RELEASE);
    });

    for (uint32_t ms = 0; ms < RTLSDR_STREAM_WAIT_MS; ++ms) {
        if (!RTLSDR_IsStreaming(t))
            return t->streamResult ? t->streamResult : -1;
        if (libusb_driverkit_active_transfers() > 0)
            return 0;
        IOSleep(1);
    }
    return 0;
}

/* rtlsdr_cancel_async() only flags the loop; wait until rtlsdr_read_async()
 * has returned, so that a following start or rtlsdr_close() finds librtlsdr
 * inactive. Returns the rtlsdr_cancel_async() result. */
static int RTLSDR_StopStream(RTLSDRTransport *t)
{
    int r = rtlsdr_cancel_async(t->dev);
    bool woken = false;

    for (uint32_t ms = 0; RTLSDR_IsStreaming(t) && ms < RTLSDR_STREAM_WAIT_MS; ++ms) {
        /* A loop posted just before may not be running yet. */
        if (r != 0)
            r = rtlsdr_cancel_async(t->dev);
        /* Don't wait for its next event or timeout. */
        if (r == 0 && !woken) {
            libusb_interrupt_event_handler(nullptr);
            woken = true;
        }
        IOSleep(1);
    }
    if (RTLSDR_IsStreaming(t))
        os_log(OS_LOG_DEFAULT, "[rtlsdr] stream loop still running after %u ms",
               RTLSDR_STREAM_WAIT_MS);
    return r;
}

/* ===========================================================================
 * MARK: - Transport teardown
 * ======================================================================== */

static kern_return_t RTLSDR_CreateReadAction(void *ctx, size_t referenceSize,
                                             OSAction **action)
{
    return ((RTL_SDR *)ctx)->CreateActionReadComplete(referenceSize, action);
}

/* Returns false if `t` is still in use and must not be freed. */
static bool RTLSDR_TeardownTransport(RTLSDRTransport *t)
{
    if (!t)
        return true;

    if (t->dev) {
        /* rtlsdr_close() waits until librtlsdr's async state is inactive. */
        if (RTLSDR_IsStreaming(t))
            RTLSDR_StopStream(t);
        if (RTLSDR_IsStreaming(t)) {
            /* The loop still uses the device, its transfers and `t`. */
            os_log(OS_LOG_DEFAULT, "RTL_SDR: stream loop did not stop, leaving the device open");
            return false;
        }
        /* rtlsdr_close() issues USB control transfers (deinit_baseband); the
         * caller (Start failure path / Stop) already runs on the device queue. */
        rtlsdr_close(t->dev);
        t->dev = nullptr;
    }

    if (t->usbAttached) {
        libusb_driverkit_detach();
        t->usbAttached = false;
    }
    OSSafeReleaseNULL(t->iqRing);

    if (t->interface) {
        t->interface->Close(t->owner, 0);
        t->interface = nullptr;
    }
    OSSafeReleaseNULL(t->streamQueue);
    OSSafeReleaseNULL(t->deviceQueue);
    return true;
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

    /* Use this driver's own default dispatch queue for device control:
     * Start / Stop already run here, control commands hop on with
     * DispatchSync. */
    ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &t->deviceQueue);
    if (ret != kIOReturnSuccess || !t->deviceQueue) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: CopyDispatchQueue failed: 0x%x", ret);
        goto fail;
    }

    /* The libusb event loop and the bulk-IN completions (ReadComplete is
     * declared QUEUENAME(Stream)) share this queue. It must be reentrant:
     * the event loop sleeps on it while waiting for completions. */
    ret = IODispatchQueue::Create("Stream", kIODispatchQueueReentrant, 0,
                                  &t->streamQueue);
    if (ret != kIOReturnSuccess || !t->streamQueue) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: stream queue create failed: 0x%x", ret);
        goto fail;
    }
    ret = SetDispatchQueue("Stream", t->streamQueue);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: SetDispatchQueue(Stream) failed: 0x%x", ret);
        goto fail;
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

    /* The interface becomes librtlsdr's one and only libusb device. */
    ret = libusb_driverkit_attach(t->interface, t->streamQueue,
                                  RTLSDR_CreateReadAction, this);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: libusb attach failed: 0x%x", ret);
        goto fail;
    }
    t->usbAttached = true;

    /* Open the librtlsdr device. We are on the device queue, so this (and all
     * the control transfers it performs) runs serialised with the commands. */
    {
        int r = rtlsdr_open(&t->dev, 0);
        if (r != 0 || !t->dev) {
            os_log(OS_LOG_DEFAULT, "RTL_SDR: rtlsdr_open failed: %d", r);
            t->dev = nullptr;
            ret = kIOReturnError;
            goto fail;
        }
    }

    rtlsdr_get_usb_strings(t->dev, t->manufact, t->product, nullptr);

    RegisterService();
    os_log(OS_LOG_DEFAULT, "RTL_SDR: started, tuner type = %d, device = %{public}s / %{public}s",
           rtlsdr_get_tuner_type(t->dev), t->manufact, t->product);
    return kIOReturnSuccess;

fail:
    ivars->t = nullptr;
    if (RTLSDR_TeardownTransport(t))
        IOFree(t, sizeof(RTLSDRTransport));
    Stop(provider, SUPERDISPATCH);
    return ret;
}

kern_return_t
IMPL(RTL_SDR, Stop)
{
    os_log(OS_LOG_DEFAULT, "RTL_SDR::Stop");

    if (ivars && ivars->t) {
        RTLSDRTransport *t = ivars->t;
        ivars->t = nullptr;
        if (RTLSDR_TeardownTransport(t))
            IOFree(t, sizeof(RTLSDRTransport));
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
 * Runs on the stream queue, once per completed libusb transfer. The libusb
 * shim queues it for the event loop in rtlsdr_read_async(), which calls
 * librtlsdr's transfer callback (softagc + dev->cb -> RTLSDR_iqSink).
 * ======================================================================== */
void
IMPL(RTL_SDR, ReadComplete)
{
    libusb_driverkit_complete(action, status, actualByteCount);
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
            r = RTLSDR_StartStream(t);
            os_log(OS_LOG_DEFAULT, "[rtlsdr] StartStream returned %d", r);
            break;
        case kRTLSDRMethodStopStream:
            r = RTLSDR_StopStream(t);
            os_log(OS_LOG_DEFAULT, "[rtlsdr] StopStream returned %d", r);
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
        case kRTLSDRMethodSetOffsetTuning:
            r = rtlsdr_set_offset_tuning(d, (int)arg);
            break;
        default:
            r = -1;
            break;
        }
    });

    if (result && selector != kRTLSDRMethodGetTunerType)
        out = (uint64_t)(int64_t)r;
    if (result)
        *result = out;
    if (selector == kRTLSDRMethodStartStream ||
        selector == kRTLSDRMethodStopStream)
        return kIOReturnSuccess;
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
    info->streaming  = RTLSDR_IsStreaming(t) ? 1u : 0u;
    /* both sides are NUL-terminated 256-byte buffers */
    memcpy(info->manufacturer, t->manufact, sizeof(info->manufacturer));
    memcpy(info->product, t->product, sizeof(info->product));
    return kIOReturnSuccess;
}
