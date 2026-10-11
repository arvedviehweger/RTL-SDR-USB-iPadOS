//
//  RTL_SDR.cpp
//  RTL-SDR
//
//  Created by Arved Viehweger on 19.05.26.
//
//  DriverKit interface driver for the RTL2832U.
//
//  The dongle is programmed by RTL2832Device from gnuradio4-blocks
//  (third_party/gnuradio4-blocks), compiled unmodified. It reaches the device
//  through the USB transport in Shim/; RTL2832Radio.cpp maps the user client
//  commands onto it. This file provides:
//    * the device life cycle (Start / Stop), which attaches the matched USB
//      interface to the USB shim and opens the radio,
//    * the IQ stream, i.e. the bulk-IN transfers and their completions,
//    * the IOUserClient factory (NewUserClient),
//    * the local entry points used by RTL_SDR_UserClient.
//
//  Threading model
//  ---------------
//  Device control runs on RTL_SDR's *default* dispatch queue (grabbed once
//  via CopyDispatchQueue). Start/Stop already run there; HandleScalarCommand
//  hops onto it with DispatchSync.
//
//  IQ streaming runs on a second queue ("Stream"). ReadComplete
//  (QUEUENAME(Stream)) copies each completed transfer into the shared ring
//  and resubmits it, so IQ keeps flowing while control commands occupy the
//  default queue. Transfer state is only touched on the stream queue:
//  StartStream and StopStream reach it with DispatchSync.
//
//  The transfers - DMA buffer and OSAction each - live from Start to Stop.
//  An OSAction must not be released before its (aborted) completion has come
//  back, so teardown waits until no transfer is in flight.
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

#include "RTLSDRShared.h"
#include "RTL2832Radio.h"
#include "usb_driverkit.h"

/* Streaming geometry. 32 x 32 KiB delivers IQ to the ring every 8 ms at
 * 2.048 MS/s and still keeps ~256 ms queued on the USB pipe; fewer, larger
 * transfers reach rtl_tcp clients as bursts and gaps. */
#define RTLSDR_STREAM_BUF_NUM 32
#define RTLSDR_STREAM_BUF_LEN (32u * 1024u)

/* The RTL2832U's bulk-IN (IQ) endpoint. */
#define RTLSDR_IQ_ENDPOINT    0x81

/* How long StopStream waits for the aborted transfers. */
#define RTLSDR_STREAM_WAIT_MS 3000

/* "MARKETING_VERSION (CURRENT_PROJECT_VERSION)" of this build, passed in by
 * GCC_PREPROCESSOR_DEFINITIONS. Reported to the host app, which can tell from
 * it whether iPadOS still runs an older staged copy of the dext. */
#define RTLSDR_STRINGIFY(x)        #x
#define RTLSDR_XSTRINGIFY(x)       RTLSDR_STRINGIFY(x)
#define RTLSDR_DEXT_VERSION_STRING RTLSDR_XSTRINGIFY(RTLSDR_DEXT_VERSION) \
                                   " (" RTLSDR_XSTRINGIFY(RTLSDR_DEXT_BUILD) ")"

/* ===========================================================================
 * MARK: - Transport state
 *
 * Allocated in Start() and freed in Stop().
 * ======================================================================== */
struct RTLSDRTransport;

struct RTLSDRStreamTransfer {
    RTLSDRTransport          *t;
    IOBufferMemoryDescriptor *buffer;       /* AsyncIO target                  */
    const uint8_t            *bytes;        /* mapped address of buffer        */
    OSAction                 *action;       /* reference holds this transfer   */
    bool                      inFlight;     /* stream queue only               */
};

struct RTLSDRTransport {
    RTL_SDR                  *owner;        /* back-pointer to the dext object */
    IOUSBHostInterface       *interface;    /* matched USB interface (provider)*/
    IODispatchQueue          *deviceQueue;  /* RTL_SDR default queue (retained)*/
    IODispatchQueue          *streamQueue;  /* bulk-IN completions             */
    bool                      usbAttached;  /* interface handed to the shim    */

    IOBufferMemoryDescriptor *iqRing;       /* shared IQ ring (app-mapped)     */
    RTLSDRRingBuffer         *iqRingAddr;   /* mapped address of iqRing        */

    RTL2832Radio             *radio;        /* device control                  */
    char                      manufact[256]; /* USB strings, read in Start()  */
    char                      product[256];

    IOUSBHostPipe            *iqPipe;       /* bulk-IN endpoint 0x81           */
    RTLSDRStreamTransfer      transfers[RTLSDR_STREAM_BUF_NUM];

    /* set while the stream runs: completed transfers are resubmitted */
    bool                      streaming;    /* atomic                          */
    uint32_t                  inFlight;     /* atomic: submitted, not completed*/
};

struct RTL_SDR_IVars {
    RTLSDRTransport *t;
};

static void RTLSDR_CopyString(char *dst, size_t size, const char *src)
{
    size_t n = 0;
    while (src && src[n] && n < size - 1) {
        dst[n] = src[n];
        ++n;
    }
    dst[n] = '\0';
}

/* ===========================================================================
 * MARK: - IQ sink
 *
 * Runs on the stream queue for every completed transfer and copies the IQ
 * bytes into the shared ring buffer. Single producer / single consumer; if
 * the host app falls behind, the oldest bytes are dropped and accounted in
 * dropCount.
 * ======================================================================== */
static void RTLSDR_iqSink(RTLSDRTransport *t, const uint8_t *buf, uint32_t len)
{
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
 * ======================================================================== */

static bool RTLSDR_IsStreaming(RTLSDRTransport *t)
{
    return __atomic_load_n(&t->streaming, __ATOMIC_ACQUIRE);
}

static uint32_t RTLSDR_InFlight(RTLSDRTransport *t)
{
    return __atomic_load_n(&t->inFlight, __ATOMIC_ACQUIRE);
}

/* Stream queue only. */
static bool RTLSDR_Submit(RTLSDRStreamTransfer *x)
{
    kern_return_t ret = x->t->iqPipe->AsyncIO(x->buffer, RTLSDR_STREAM_BUF_LEN,
                                              x->action, 0);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "[rtlsdr] AsyncIO failed: 0x%x", ret);
        return false;
    }
    x->inFlight = true;
    return true;
}

/* Returns 0 once transfers are in flight, -2 while the stream (or the end of
 * the previous one) is still running. */
static int RTLSDR_StartStream(RTLSDRTransport *t)
{
    if (RTLSDR_IsStreaming(t) || RTLSDR_InFlight(t) > 0)
        return -2;

    __block uint32_t submitted = 0;
    t->streamQueue->DispatchSync(^{
        __atomic_store_n(&t->streaming, true, __ATOMIC_RELEASE);
        for (uint32_t i = 0; i < RTLSDR_STREAM_BUF_NUM; ++i) {
            if (RTLSDR_Submit(&t->transfers[i]))
                ++submitted;
        }
        __atomic_fetch_add(&t->inFlight, submitted, __ATOMIC_RELEASE);
        if (submitted == 0)
            __atomic_store_n(&t->streaming, false, __ATOMIC_RELEASE);
    });
    return submitted ? 0 : -1;
}

/* Aborts the transfers and waits until their completions are back. Returns
 * 0 if a stream was running, -2 if not, -1 if transfers are still in flight
 * after RTLSDR_STREAM_WAIT_MS. */
static int RTLSDR_StopStream(RTLSDRTransport *t)
{
    __block bool wasStreaming = false;
    t->streamQueue->DispatchSync(^{
        wasStreaming = __atomic_exchange_n(&t->streaming, false, __ATOMIC_ACQ_REL);
        /* No completion runs while we are on the stream queue, so none can
         * resubmit after this. The aborted ones arrive once we leave it. */
        if (RTLSDR_InFlight(t) > 0) {
            kern_return_t ret = t->iqPipe->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
            if (ret != kIOReturnSuccess)
                os_log(OS_LOG_DEFAULT, "[rtlsdr] pipe abort failed: 0x%x", ret);
        }
    });

    for (uint32_t ms = 0; RTLSDR_InFlight(t) > 0 && ms < RTLSDR_STREAM_WAIT_MS; ++ms)
        IOSleep(1);
    if (RTLSDR_InFlight(t) > 0) {
        os_log(OS_LOG_DEFAULT, "[rtlsdr] %u transfers still in flight after %u ms",
               RTLSDR_InFlight(t), RTLSDR_STREAM_WAIT_MS);
        return -1;
    }
    return wasStreaming ? 0 : -2;
}

/* ===========================================================================
 * MARK: - Transport teardown
 * ======================================================================== */

/* Returns false if `t` is still in use and must not be freed. */
static bool RTLSDR_TeardownTransport(RTLSDRTransport *t)
{
    if (!t)
        return true;

    if (t->streamQueue && t->iqPipe && (RTLSDR_IsStreaming(t) || RTLSDR_InFlight(t) > 0))
        RTLSDR_StopStream(t);
    if (RTLSDR_InFlight(t) > 0) {
        /* Their completions still reference the transfers and `t`. */
        os_log(OS_LOG_DEFAULT, "RTL_SDR: transfers did not complete, leaving the device open");
        return false;
    }

    if (t->radio) {
        RTL2832Radio_Close(t->radio);
        t->radio = nullptr;
    }
    for (uint32_t i = 0; i < RTLSDR_STREAM_BUF_NUM; ++i) {
        RTLSDRStreamTransfer *x = &t->transfers[i];
        OSSafeReleaseNULL(x->action);
        OSSafeReleaseNULL(x->buffer);
        x->bytes = nullptr;
    }
    OSSafeReleaseNULL(t->iqPipe);

    if (t->usbAttached) {
        usb_driverkit_detach();
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
    os_log(OS_LOG_DEFAULT, "RTL_SDR::Start (dext %{public}s)", RTLSDR_DEXT_VERSION_STRING);

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

    /* The bulk-IN completions (ReadComplete is declared QUEUENAME(Stream))
     * run on this queue. */
    ret = IODispatchQueue::Create("Stream", 0, 0, &t->streamQueue);
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

    /* The interface becomes the USB shim's one and only device. */
    ret = usb_driverkit_attach(t->interface);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: USB attach failed: 0x%x", ret);
        goto fail;
    }
    t->usbAttached = true;

    /* IQ stream: the pipe and the transfers, each with a DMA buffer and the
     * OSAction its completion arrives on. */
    ret = t->interface->CopyPipe(RTLSDR_IQ_ENDPOINT, &t->iqPipe);
    if (ret != kIOReturnSuccess || !t->iqPipe) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: CopyPipe(0x%x) failed: 0x%x", RTLSDR_IQ_ENDPOINT, ret);
        t->iqPipe = nullptr;
        if (ret == kIOReturnSuccess)
            ret = kIOReturnNotFound;
        goto fail;
    }
    for (uint32_t i = 0; i < RTLSDR_STREAM_BUF_NUM; ++i) {
        RTLSDRStreamTransfer *x = &t->transfers[i];
        x->t = t;
        ret = t->interface->CreateIOBuffer(kIOMemoryDirectionIn, RTLSDR_STREAM_BUF_LEN,
                                           &x->buffer);
        if (ret != kIOReturnSuccess || !x->buffer) {
            os_log(OS_LOG_DEFAULT, "RTL_SDR: stream buffer alloc failed: 0x%x", ret);
            x->buffer = nullptr;
            if (ret == kIOReturnSuccess)
                ret = kIOReturnNoMemory;
            goto fail;
        }
        IOAddressSegment seg;
        x->buffer->GetAddressRange(&seg);
        x->bytes = (const uint8_t *)seg.address;

        ret = CreateActionReadComplete(sizeof(RTLSDRStreamTransfer *), &x->action);
        if (ret != kIOReturnSuccess || !x->action) {
            os_log(OS_LOG_DEFAULT, "RTL_SDR: stream action create failed: 0x%x", ret);
            x->action = nullptr;
            if (ret == kIOReturnSuccess)
                ret = kIOReturnNoMemory;
            goto fail;
        }
        *(RTLSDRStreamTransfer **)x->action->GetReference() = x;
    }

    /* Initialise the dongle. We are on the device queue, so this (and all
     * the control transfers it performs) runs serialised with the commands. */
    if (RTL2832Radio_Open(&t->radio) != 0 || !t->radio) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR: radio open failed");
        t->radio = nullptr;
        ret = kIOReturnError;
        goto fail;
    }

    {
        const char *manufacturer = "";
        const char *product = "";
        usb_driverkit_get_info(nullptr, nullptr, &manufacturer, &product);
        RTLSDR_CopyString(t->manufact, sizeof(t->manufact), manufacturer);
        RTLSDR_CopyString(t->product, sizeof(t->product), product);
    }

    RegisterService();
    os_log(OS_LOG_DEFAULT, "RTL_SDR: started, tuner type = %u, device = %{public}s / %{public}s",
           RTL2832Radio_GetTunerType(t->radio), t->manufact, t->product);
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
 * Runs on the stream queue, once per completed transfer: hands the data to
 * the ring and resubmits the transfer while the stream runs.
 * ======================================================================== */
void
IMPL(RTL_SDR, ReadComplete)
{
    RTLSDRStreamTransfer *x = action ? *(RTLSDRStreamTransfer **)action->GetReference()
                                     : nullptr;
    if (!x || !x->inFlight)
        return;
    RTLSDRTransport *t = x->t;
    x->inFlight = false;

    bool ok = (status == kIOReturnSuccess || status == kIOReturnUnderrun);  /* short packet */
    if (ok && actualByteCount > 0) {
        uint32_t n = (actualByteCount < RTLSDR_STREAM_BUF_LEN) ? actualByteCount
                                                               : RTLSDR_STREAM_BUF_LEN;
        RTLSDR_iqSink(t, x->bytes, n);
    }
    if (ok && RTLSDR_IsStreaming(t) && RTLSDR_Submit(x))
        return;

    /* Not resubmitted: aborted by StopStream, or failed. When the last one
     * goes while the stream should run, the device stopped delivering. */
    uint32_t left = __atomic_sub_fetch(&t->inFlight, 1u, __ATOMIC_ACQ_REL);
    if (left == 0 && __atomic_exchange_n(&t->streaming, false, __ATOMIC_ACQ_REL))
        os_log(OS_LOG_DEFAULT, "[rtlsdr] IQ stream ended, last status 0x%x", status);
}

/* ===========================================================================
 * MARK: - Local entry points for RTL_SDR_UserClient
 * ======================================================================== */

kern_return_t
RTL_SDR::HandleScalarCommand(uint32_t selector, uint64_t arg, uint64_t *result)
{
    RTLSDRTransport *t = (ivars ? ivars->t : nullptr);
    if (!t || !t->radio || !t->deviceQueue)
        return kIOReturnNotReady;

    __block int      r   = 0;
    __block uint64_t out = 0;

    /* Run the command serialised on the device queue. */
    t->deviceQueue->DispatchSync(^{
        RTL2832Radio *d = t->radio;
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
            r = RTL2832Radio_SetCenterFreq(d, arg);
            break;
        case kRTLSDRMethodSetSampleRate:
            r = RTL2832Radio_SetSampleRate(d, (uint32_t)arg);
            break;
        case kRTLSDRMethodSetTunerGainMode:
            r = RTL2832Radio_SetTunerGainMode(d, (int)arg);
            break;
        case kRTLSDRMethodSetTunerGain:
            r = RTL2832Radio_SetTunerGain(d, (int)(int32_t)arg);
            break;
        case kRTLSDRMethodSetAgcMode:
            r = RTL2832Radio_SetAgcMode(d, (int)arg);
            break;
        case kRTLSDRMethodSetFreqCorrection:
            r = RTL2832Radio_SetFreqCorrection(d, (int)(int32_t)arg);
            break;
        case kRTLSDRMethodSetTunerBandwidth:
            r = RTL2832Radio_SetTunerBandwidth(d, (uint32_t)arg);
            break;
        case kRTLSDRMethodSetTestmode:
            r = RTL2832Radio_SetTestmode(d, (int)arg);
            break;
        case kRTLSDRMethodSetDirectSampling:
            r = RTL2832Radio_SetDirectSampling(d, (int)arg);
            break;
        case kRTLSDRMethodSetBiasTee:
            r = RTL2832Radio_SetBiasTee(d, (int)arg);
            break;
        case kRTLSDRMethodResetBuffer:
            r = RTL2832Radio_ResetBuffer(d);
            break;
        case kRTLSDRMethodSetGainByIndex:
            r = RTL2832Radio_SetGainByIndex(d, (arg > UINT32_MAX) ? UINT32_MAX : (uint32_t)arg);
            break;
        case kRTLSDRMethodGetTunerType:
            out = (uint64_t)RTL2832Radio_GetTunerType(d);
            break;
        case kRTLSDRMethodSetOffsetTuning:
            r = RTL2832Radio_SetOffsetTuning(d, (int)arg);
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
    if (!t || !t->radio)
        return kIOReturnNotReady;

    info->valid      = 1;
    info->tunerType  = RTL2832Radio_GetTunerType(t->radio);
    info->sampleRate = RTL2832Radio_GetSampleRate(t->radio);
    info->streaming  = RTLSDR_IsStreaming(t) ? 1u : 0u;
    /* both sides are NUL-terminated 256-byte buffers */
    memcpy(info->manufacturer, t->manufact, sizeof(info->manufacturer));
    memcpy(info->product, t->product, sizeof(info->product));
    static_assert(sizeof(RTLSDR_DEXT_VERSION_STRING) <= sizeof(info->dextVersion),
                  "dext version string too long");
    memcpy(info->dextVersion, RTLSDR_DEXT_VERSION_STRING, sizeof(RTLSDR_DEXT_VERSION_STRING));
    return kIOReturnSuccess;
}
