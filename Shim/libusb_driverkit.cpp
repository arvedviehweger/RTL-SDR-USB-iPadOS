//
//  libusb_driverkit.cpp
//  RTL-SDR
//
//  libusb-1.0 (the subset declared in include/libusb.h) on top of
//  USBDriverKit, so that librtlsdr runs unmodified inside the dext.
//
//  Device
//  ------
//  There is exactly one device: the IOUSBHostInterface the dext was matched
//  to, registered with libusb_driverkit_attach(). DriverKit runs one dext
//  process per matched interface, so the state below is a plain global.
//
//  Asynchronous transfers
//  ----------------------
//  libusb_submit_transfer() starts an IOUSBHostPipe::AsyncIO into a DMA
//  buffer owned by the transfer. The completion arrives in the dext's
//  ReadComplete on the event queue and is handed to libusb_driverkit_complete(),
//  which queues the transfer and wakes the event loop. libusb_handle_events*()
//  then copies the data into transfer->buffer and calls transfer->callback -
//  on the thread running the event loop, as in libusb.
//
//  While it waits, the event loop sleeps on the (reentrant) event queue, so
//  completions are delivered in between. Transfer state is only ever touched
//  on that queue and needs no lock.
//
//  libusb_free_transfer() on a transfer that is still in flight (librtlsdr
//  does that right after cancelling) only marks it. Its DMA buffer and
//  OSAction stay alive until the aborted completion has come back; the
//  OSAction must not be released before that.
//
//  USBDriverKit can only abort all I/O of a pipe at once, so cancelling one
//  transfer cancels every transfer on its endpoint. librtlsdr cancels all of
//  them anyway.
//

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSAction.h>

#include <USBDriverKit/USBDriverKit.h>

#include "libusb_driverkit.h"
#include "include/libusb.h"

#define DK_CTRL_BUF_SIZE   256                          /* reusable control buffer */
#define DK_MAX_PIPES       32                           /* 16 OUT + 16 IN endpoints */
#define DK_WAIT_SLICE_NS   (100ull * 1000 * 1000)       /* re-check while sleeping  */
#define DK_DETACH_WAIT_NS  (1000ull * 1000 * 1000)      /* aborted I/O at detach    */

struct libusb_context {
    int unused;
};

struct libusb_device {
    struct libusb_device_descriptor descriptor;
};

struct libusb_device_handle {
    libusb_device *dev;
};

struct dk_transfer {
    struct libusb_transfer       pub;       /* first: libusb_transfer * == dk_transfer * */
    dk_transfer                 *next;      /* all transfers                        */
    dk_transfer                 *nextDone;  /* completions awaiting dispatch        */
    IOBufferMemoryDescriptor    *dma;       /* AsyncIO target, copied to pub.buffer */
    uint8_t                     *dmaBytes;
    uint32_t                     dmaCapacity;
    OSAction                    *action;    /* reference memory holds this transfer */
    enum libusb_transfer_status  status;    /* of the last completion               */
    uint32_t                     actual;
    bool                         inFlight;
    bool                         cancelling;
    bool                         done;      /* on the done list                     */
    bool                         freed;     /* libusb_free_transfer() was called    */
};

static struct {
    bool                             attached;
    IOUSBHostInterface              *interface;
    IOUSBHostDevice                 *device;
    IODispatchQueue                 *queue;        /* event queue (reentrant)    */
    libusb_driverkit_action_factory  createAction;
    void                            *actionCtx;
    libusb_device                    dev;

    IOLock                          *ctrlLock;     /* guards ctrlBuffer          */
    IOBufferMemoryDescriptor        *ctrlBuffer;
    uint8_t                         *ctrlBytes;
    IOLock                          *pipeLock;     /* guards pipes[]             */
    IOUSBHostPipe                   *pipes[DK_MAX_PIPES];

    /* event queue only */
    dk_transfer                     *transfers;
    dk_transfer                     *doneHead;
    dk_transfer                     *doneTail;
    bool                             interrupted;
    bool                             queueWarned;
    bool                             sleepWarned;

    uint32_t                         active;       /* atomic                     */
} gDK;

/* ===========================================================================
 * MARK: - Helpers
 * ======================================================================== */

static uint64_t dk_now(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/* Transfer state belongs to the event queue; report a caller that is not on
 * it (once). */
static bool dk_on_queue(const char *func)
{
    if (gDK.queue && gDK.queue->OnQueue())
        return true;
    if (!gDK.queueWarned) {
        gDK.queueWarned = true;
        os_log(OS_LOG_DEFAULT, "[libusb] %{public}s called off the event queue", func);
    }
    return false;
}

static int dk_error(kern_return_t ret)
{
    switch (ret) {
    case kIOReturnSuccess:
        return LIBUSB_SUCCESS;
    case kIOReturnNoDevice:
    case kIOReturnNotAttached:
    case kIOReturnNotResponding:
    case kIOReturnOffline:
        return LIBUSB_ERROR_NO_DEVICE;
    case kIOReturnTimeout:
        return LIBUSB_ERROR_TIMEOUT;
    case kIOReturnOverrun:
        return LIBUSB_ERROR_OVERFLOW;
    case kIOReturnNoMemory:
    case kIOReturnNoResources:
        return LIBUSB_ERROR_NO_MEM;
    case kIOReturnBadArgument:
        return LIBUSB_ERROR_INVALID_PARAM;
    case kIOReturnBusy:
    case kIOReturnExclusiveAccess:
        return LIBUSB_ERROR_BUSY;
    case kIOReturnUnsupported:
        return LIBUSB_ERROR_NOT_SUPPORTED;
    case kIOReturnAborted:
        return LIBUSB_ERROR_INTERRUPTED;
    case kUSBHostReturnPipeStalled:
        return LIBUSB_ERROR_PIPE;
    default:
        return LIBUSB_ERROR_IO;
    }
}

static enum libusb_transfer_status dk_transfer_status(IOReturn status, bool cancelling)
{
    switch (status) {
    case kIOReturnSuccess:
    case kIOReturnUnderrun:                 /* short packet */
        return LIBUSB_TRANSFER_COMPLETED;
    case kIOReturnAborted:
        /* An abort nobody asked for: the device or interface went away. */
        return cancelling ? LIBUSB_TRANSFER_CANCELLED : LIBUSB_TRANSFER_NO_DEVICE;
    case kIOReturnNoDevice:
    case kIOReturnNotAttached:
    case kIOReturnNotResponding:
    case kIOReturnOffline:
        return LIBUSB_TRANSFER_NO_DEVICE;
    case kIOReturnTimeout:
        return LIBUSB_TRANSFER_TIMED_OUT;
    case kIOReturnOverrun:
        return LIBUSB_TRANSFER_OVERFLOW;
    case kUSBHostReturnPipeStalled:
        return LIBUSB_TRANSFER_STALL;
    default:
        return LIBUSB_TRANSFER_ERROR;
    }
}

/* Pipes are copied on first use and kept until detach. */
static IOUSBHostPipe *dk_pipe(uint8_t endpoint) DRIVERKIT_RETURNS_NOT_RETAINED;
static IOUSBHostPipe *dk_pipe(uint8_t endpoint)
{
    uint32_t idx = (endpoint & 0x0fu) | ((endpoint & LIBUSB_ENDPOINT_IN) ? 0x10u : 0u);

    IOLockLock(gDK.pipeLock);
    if (!gDK.pipes[idx] && gDK.interface) {
        IOUSBHostPipe *copied = nullptr;
        if (gDK.interface->CopyPipe(endpoint, &copied) == kIOReturnSuccess)
            gDK.pipes[idx] = copied;
    }
    IOUSBHostPipe *pipe = gDK.pipes[idx];
    IOLockUnlock(gDK.pipeLock);
    return pipe;
}

static void dk_destroy(dk_transfer *t)
{
    for (dk_transfer **p = &gDK.transfers; *p; p = &(*p)->next) {
        if (*p == t) {
            *p = t->next;
            break;
        }
    }
    OSSafeReleaseNULL(t->action);
    OSSafeReleaseNULL(t->dma);
    IOSafeDeleteNULL(t, dk_transfer, 1);
}

/* Releases transfers that were freed while in flight, once their completion
 * is in. Never runs inside a completion, so no OSAction is released from its
 * own handler. */
static void dk_reap(void)
{
    dk_transfer *t = gDK.transfers;
    while (t) {
        dk_transfer *next = t->next;
        if (t->freed && !t->inFlight && !t->done)
            dk_destroy(t);
        t = next;
    }
}

static bool dk_any_in_flight(void)
{
    for (dk_transfer *t = gDK.transfers; t; t = t->next)
        if (t->inFlight)
            return true;
    return false;
}

/* Delivers the queued completions in the order they arrived: copies the
 * data into transfer->buffer and calls transfer->callback. */
static void dk_dispatch(void)
{
    dk_transfer *t = gDK.doneHead;
    gDK.doneHead = nullptr;
    gDK.doneTail = nullptr;

    while (t) {
        dk_transfer *next = t->nextDone;
        t->nextDone = nullptr;
        t->done = false;

        if (!t->freed) {
            struct libusb_transfer *x = &t->pub;
            uint32_t n = t->actual;
            if (n > (uint32_t)x->length)
                n = (uint32_t)x->length;
            if (n && x->buffer)
                memcpy(x->buffer, t->dmaBytes, n);
            x->actual_length = (int)n;
            x->status = t->status;
            /* may resubmit or free this transfer */
            if (x->callback)
                x->callback(x);
        }
        t = next;
    }
}

static void dk_release_resources(void)
{
    for (uint32_t i = 0; i < DK_MAX_PIPES; ++i)
        OSSafeReleaseNULL(gDK.pipes[i]);
    OSSafeReleaseNULL(gDK.ctrlBuffer);
    gDK.ctrlBytes = nullptr;
    if (gDK.ctrlLock) {
        IOLockFree(gDK.ctrlLock);
        gDK.ctrlLock = nullptr;
    }
    if (gDK.pipeLock) {
        IOLockFree(gDK.pipeLock);
        gDK.pipeLock = nullptr;
    }
    OSSafeReleaseNULL(gDK.device);
    OSSafeReleaseNULL(gDK.queue);
    gDK.interface    = nullptr;
    gDK.createAction = nullptr;
    gDK.actionCtx    = nullptr;
    gDK.transfers    = nullptr;
    gDK.doneHead     = nullptr;
    gDK.doneTail     = nullptr;
    gDK.interrupted  = false;
    gDK.queueWarned  = false;
    gDK.sleepWarned  = false;
    __atomic_store_n(&gDK.active, 0u, __ATOMIC_RELAXED);
}

/* ===========================================================================
 * MARK: - Dext interface (libusb_driverkit.h)
 * ======================================================================== */

kern_return_t libusb_driverkit_attach(IOUSBHostInterface *interface,
                                      IODispatchQueue *eventQueue,
                                      libusb_driverkit_action_factory createAction,
                                      void *ctx)
{
    if (gDK.attached)
        return kIOReturnBusy;
    if (!interface || !eventQueue || !createAction)
        return kIOReturnBadArgument;

    kern_return_t ret = interface->CopyDevice(&gDK.device);
    if (ret != kIOReturnSuccess || !gDK.device) {
        gDK.device = nullptr;
        return (ret != kIOReturnSuccess) ? ret : kIOReturnNoDevice;
    }

    const IOUSBDeviceDescriptor *dd = gDK.device->CopyDeviceDescriptor();
    if (!dd) {
        dk_release_resources();
        return kIOReturnNoDevice;
    }
    struct libusb_device_descriptor *desc = &gDK.dev.descriptor;
    desc->bLength            = dd->bLength;
    desc->bDescriptorType    = dd->bDescriptorType;
    desc->bcdUSB             = dd->bcdUSB;
    desc->bDeviceClass       = dd->bDeviceClass;
    desc->bDeviceSubClass    = dd->bDeviceSubClass;
    desc->bDeviceProtocol    = dd->bDeviceProtocol;
    desc->bMaxPacketSize0    = dd->bMaxPacketSize0;
    desc->idVendor           = dd->idVendor;
    desc->idProduct          = dd->idProduct;
    desc->bcdDevice          = dd->bcdDevice;
    desc->iManufacturer      = dd->iManufacturer;
    desc->iProduct           = dd->iProduct;
    desc->iSerialNumber      = dd->iSerialNumber;
    desc->bNumConfigurations = dd->bNumConfigurations;
    IOUSBHostFreeDescriptor(dd);

    gDK.ctrlLock = IOLockAlloc();
    gDK.pipeLock = IOLockAlloc();
    if (!gDK.ctrlLock || !gDK.pipeLock) {
        dk_release_resources();
        return kIOReturnNoMemory;
    }

    ret = interface->CreateIOBuffer(kIOMemoryDirectionInOut, DK_CTRL_BUF_SIZE,
                                    &gDK.ctrlBuffer);
    if (ret != kIOReturnSuccess || !gDK.ctrlBuffer) {
        gDK.ctrlBuffer = nullptr;
        dk_release_resources();
        return (ret != kIOReturnSuccess) ? ret : kIOReturnNoMemory;
    }
    IOAddressSegment seg;
    gDK.ctrlBuffer->GetAddressRange(&seg);
    gDK.ctrlBytes = (uint8_t *)seg.address;

    eventQueue->retain();
    gDK.queue        = eventQueue;
    gDK.interface    = interface;
    gDK.createAction = createAction;
    gDK.actionCtx    = ctx;
    gDK.attached     = true;
    return kIOReturnSuccess;
}

void libusb_driverkit_detach(void)
{
    IODispatchQueue *queue = gDK.queue;
    if (queue && gDK.attached) {
        queue->DispatchSync(^{
            /* rtlsdr_read_async() has freed its transfers, but aborted ones
             * may still be on their way back. Abort whatever is in flight and
             * wait for it; the event queue keeps delivering while we sleep. */
            if (dk_any_in_flight()) {
                for (dk_transfer *t = gDK.transfers; t; t = t->next)
                    if (t->inFlight)
                        t->cancelling = true;
                IOLockLock(gDK.pipeLock);
                for (uint32_t i = 0; i < DK_MAX_PIPES; ++i)
                    if (gDK.pipes[i])
                        gDK.pipes[i]->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
                IOLockUnlock(gDK.pipeLock);
            }
            uint64_t deadline = dk_now() + DK_DETACH_WAIT_NS;
            while (dk_any_in_flight() && dk_now() < deadline)
                queue->SleepWithDeadline(&gDK, kIOTimerClockUptimeRaw, deadline);

            /* Release everything that has come back. A transfer still in
             * flight keeps its memory: its completion may yet arrive. */
            uint32_t leaked = 0;
            dk_transfer *t = gDK.transfers;
            while (t) {
                dk_transfer *next = t->next;
                if (t->inFlight)
                    ++leaked;
                else
                    dk_destroy(t);
                t = next;
            }
            if (leaked)
                os_log(OS_LOG_DEFAULT, "[libusb] detach: %u transfers never completed", leaked);
            gDK.attached = false;
        });
    }
    gDK.attached = false;
    dk_release_resources();
}

void libusb_driverkit_complete(OSAction *action, IOReturn status,
                               uint32_t actualByteCount)
{
    if (!gDK.attached || !action)
        return;
    dk_on_queue(__func__);

    dk_transfer *t = *(dk_transfer **)action->GetReference();
    if (!t || !t->inFlight)
        return;

    t->inFlight = false;
    t->status   = dk_transfer_status(status, t->cancelling);
    t->actual   = actualByteCount;

    /* A freed transfer is only waited for (dk_reap, detach). */
    if (!t->freed) {
        __atomic_fetch_sub(&gDK.active, 1u, __ATOMIC_RELAXED);
        t->done = true;
        if (gDK.doneTail)
            gDK.doneTail->nextDone = t;
        else
            gDK.doneHead = t;
        gDK.doneTail = t;
    }
    gDK.queue->Wakeup(&gDK);
}

uint32_t libusb_driverkit_active_transfers(void)
{
    return __atomic_load_n(&gDK.active, __ATOMIC_RELAXED);
}

/* ===========================================================================
 * MARK: - libusb: library and device handling
 * ======================================================================== */

int libusb_init(libusb_context **ctx)
{
    if (ctx) {
        *ctx = IONewZero(libusb_context, 1);
        if (!*ctx)
            return LIBUSB_ERROR_NO_MEM;
    }
    return LIBUSB_SUCCESS;
}

void libusb_exit(libusb_context *ctx)
{
    IOSafeDeleteNULL(ctx, libusb_context, 1);
}

ssize_t libusb_get_device_list(libusb_context *ctx, libusb_device ***list)
{
    (void)ctx;
    if (!list)
        return LIBUSB_ERROR_INVALID_PARAM;

    /* NULL-terminated, like libusb's */
    libusb_device **devices = IONewZero(libusb_device *, 2);
    if (!devices)
        return LIBUSB_ERROR_NO_MEM;

    ssize_t count = 0;
    if (gDK.attached)
        devices[count++] = &gDK.dev;
    *list = devices;
    return count;
}

void libusb_free_device_list(libusb_device **list, int unref_devices)
{
    (void)unref_devices;
    IOSafeDeleteNULL(list, libusb_device *, 2);
}

int libusb_get_device_descriptor(libusb_device *dev,
                                 struct libusb_device_descriptor *desc)
{
    if (!dev || !desc)
        return LIBUSB_ERROR_INVALID_PARAM;
    *desc = dev->descriptor;
    return LIBUSB_SUCCESS;
}

libusb_device *libusb_get_device(libusb_device_handle *dev_handle)
{
    return dev_handle ? dev_handle->dev : nullptr;
}

int libusb_open(libusb_device *dev, libusb_device_handle **dev_handle)
{
    if (!dev_handle)
        return LIBUSB_ERROR_INVALID_PARAM;
    *dev_handle = nullptr;
    if (!gDK.attached || dev != &gDK.dev)
        return LIBUSB_ERROR_NO_DEVICE;

    libusb_device_handle *handle = IONewZero(libusb_device_handle, 1);
    if (!handle)
        return LIBUSB_ERROR_NO_MEM;
    handle->dev = dev;
    *dev_handle = handle;
    return LIBUSB_SUCCESS;
}

void libusb_close(libusb_device_handle *dev_handle)
{
    IOSafeDeleteNULL(dev_handle, libusb_device_handle, 1);
}

int libusb_reset_device(libusb_device_handle *dev_handle)
{
    if (!dev_handle || !gDK.device)
        return LIBUSB_ERROR_NO_DEVICE;
    return dk_error(gDK.device->Reset());
}

/* The dext owns the interface: it is opened before librtlsdr runs and no
 * kernel driver competes for it. */
int libusb_kernel_driver_active(libusb_device_handle *dev_handle, int interface_number)
{
    (void)dev_handle;
    (void)interface_number;
    return 0;
}

int libusb_detach_kernel_driver(libusb_device_handle *dev_handle, int interface_number)
{
    (void)dev_handle;
    (void)interface_number;
    return LIBUSB_ERROR_NOT_SUPPORTED;
}

int libusb_attach_kernel_driver(libusb_device_handle *dev_handle, int interface_number)
{
    (void)dev_handle;
    (void)interface_number;
    return LIBUSB_ERROR_NOT_SUPPORTED;
}

int libusb_claim_interface(libusb_device_handle *dev_handle, int interface_number)
{
    (void)interface_number;
    return dev_handle ? LIBUSB_SUCCESS : LIBUSB_ERROR_INVALID_PARAM;
}

int libusb_release_interface(libusb_device_handle *dev_handle, int interface_number)
{
    (void)interface_number;
    return dev_handle ? LIBUSB_SUCCESS : LIBUSB_ERROR_INVALID_PARAM;
}

int libusb_get_string_descriptor_ascii(libusb_device_handle *dev_handle,
                                       uint8_t desc_index,
                                       unsigned char *data, int length)
{
    if (!dev_handle || !gDK.device)
        return LIBUSB_ERROR_NO_DEVICE;
    if (!desc_index || !data || length <= 0)
        return LIBUSB_ERROR_INVALID_PARAM;

    const IOUSBStringDescriptor *sd = gDK.device->CopyStringDescriptor(desc_index);
    if (!sd)
        return LIBUSB_ERROR_IO;

    /* bString is UTF-16LE after bLength / bDescriptorType; like libusb,
     * anything outside ASCII becomes '?'. */
    const uint8_t *raw = (const uint8_t *)sd;
    int n = 0;
    for (uint32_t i = 2; i + 1 < sd->bLength && n < length - 1; i += 2)
        data[n++] = ((raw[i] & 0x80) || raw[i + 1]) ? '?' : raw[i];
    data[n] = '\0';
    IOUSBHostFreeDescriptor(sd);
    return n;
}

/* ===========================================================================
 * MARK: - libusb: synchronous I/O
 * ======================================================================== */

int libusb_control_transfer(libusb_device_handle *dev_handle,
                            uint8_t request_type, uint8_t bRequest,
                            uint16_t wValue, uint16_t wIndex,
                            unsigned char *data, uint16_t wLength,
                            unsigned int timeout)
{
    if (!dev_handle || !gDK.attached)
        return LIBUSB_ERROR_NO_DEVICE;

    const bool isIn = (request_type & LIBUSB_ENDPOINT_IN) != 0;

    IOLockLock(gDK.ctrlLock);

    IOBufferMemoryDescriptor *buffer = gDK.ctrlBuffer;
    uint8_t *bytes = gDK.ctrlBytes;
    IOBufferMemoryDescriptor *large = nullptr;
    if (wLength > DK_CTRL_BUF_SIZE) {
        kern_return_t ret = gDK.interface->CreateIOBuffer(kIOMemoryDirectionInOut,
                                                          wLength, &large);
        if (ret != kIOReturnSuccess || !large) {
            IOLockUnlock(gDK.ctrlLock);
            return LIBUSB_ERROR_NO_MEM;
        }
        IOAddressSegment seg;
        large->GetAddressRange(&seg);
        buffer = large;
        bytes  = (uint8_t *)seg.address;
    }

    if (!isIn && wLength > 0 && data)
        memcpy(bytes, data, wLength);

    /* The descriptor must report exactly the transfer length. */
    buffer->SetLength(wLength ? wLength : 1);

    uint16_t transferred = 0;
    kern_return_t ret = gDK.interface->DeviceRequest(request_type, bRequest,
                                                     wValue, wIndex, wLength,
                                                     buffer, &transferred,
                                                     timeout);
    if (ret == kIOReturnSuccess && isIn && data && transferred > 0)
        memcpy(data, bytes, (transferred < wLength) ? transferred : wLength);

    IOLockUnlock(gDK.ctrlLock);
    OSSafeReleaseNULL(large);

    return (ret == kIOReturnSuccess) ? (int)transferred : dk_error(ret);
}

int libusb_bulk_transfer(libusb_device_handle *dev_handle,
                         unsigned char endpoint, unsigned char *data,
                         int length, int *actual_length, unsigned int timeout)
{
    if (actual_length)
        *actual_length = 0;
    if (!dev_handle || !gDK.attached)
        return LIBUSB_ERROR_NO_DEVICE;
    /* librtlsdr only reads */
    if (!(endpoint & LIBUSB_ENDPOINT_IN))
        return LIBUSB_ERROR_NOT_SUPPORTED;
    if (!data || length <= 0)
        return LIBUSB_ERROR_INVALID_PARAM;

    IOUSBHostPipe *pipe = dk_pipe(endpoint);
    if (!pipe)
        return LIBUSB_ERROR_NOT_FOUND;

    IOBufferMemoryDescriptor *buffer = nullptr;
    kern_return_t ret = gDK.interface->CreateIOBuffer(kIOMemoryDirectionIn,
                                                      (uint64_t)length, &buffer);
    if (ret != kIOReturnSuccess || !buffer)
        return LIBUSB_ERROR_NO_MEM;

    uint32_t got = 0;
    ret = pipe->IO(buffer, (uint32_t)length, &got, timeout);
    if (got > 0) {
        if (got > (uint32_t)length)
            got = (uint32_t)length;
        IOAddressSegment seg;
        buffer->GetAddressRange(&seg);
        memcpy(data, (const void *)seg.address, got);
        if (actual_length)
            *actual_length = (int)got;
    }
    OSSafeReleaseNULL(buffer);
    return dk_error(ret);
}

/* ===========================================================================
 * MARK: - libusb: asynchronous I/O
 * ======================================================================== */

struct libusb_transfer *libusb_alloc_transfer(int iso_packets)
{
    if (iso_packets > 0)
        return nullptr;                 /* no isochronous transfers */
    dk_on_queue(__func__);
    dk_reap();

    dk_transfer *t = IONewZero(dk_transfer, 1);
    if (!t)
        return nullptr;
    t->next = gDK.transfers;
    gDK.transfers = t;
    return &t->pub;
}

void libusb_free_transfer(struct libusb_transfer *transfer)
{
    if (!transfer)
        return;
    dk_on_queue(__func__);

    dk_transfer *t = (dk_transfer *)transfer;
    if (t->inFlight && !t->freed)
        __atomic_fetch_sub(&gDK.active, 1u, __ATOMIC_RELAXED);
    t->freed = true;
    if (!t->inFlight && !t->done)
        dk_destroy(t);
}

int libusb_submit_transfer(struct libusb_transfer *transfer)
{
    dk_transfer *t = (dk_transfer *)transfer;
    if (!t || t->freed)
        return LIBUSB_ERROR_INVALID_PARAM;
    if (!gDK.attached)
        return LIBUSB_ERROR_NO_DEVICE;
    dk_on_queue(__func__);
    if (t->inFlight || t->done)
        return LIBUSB_ERROR_BUSY;
    if (transfer->type != LIBUSB_TRANSFER_TYPE_BULK ||
        !(transfer->endpoint & LIBUSB_ENDPOINT_IN))
        return LIBUSB_ERROR_NOT_SUPPORTED;
    if (transfer->length <= 0)
        return LIBUSB_ERROR_INVALID_PARAM;

    IOUSBHostPipe *pipe = dk_pipe(transfer->endpoint);
    if (!pipe)
        return LIBUSB_ERROR_NOT_FOUND;

    kern_return_t ret;
    uint32_t length = (uint32_t)transfer->length;
    if (t->dmaCapacity < length) {
        OSSafeReleaseNULL(t->dma);
        t->dmaBytes = nullptr;
        t->dmaCapacity = 0;
        ret = gDK.interface->CreateIOBuffer(kIOMemoryDirectionIn, length, &t->dma);
        if (ret != kIOReturnSuccess || !t->dma) {
            t->dma = nullptr;
            return LIBUSB_ERROR_NO_MEM;
        }
        IOAddressSegment seg;
        t->dma->GetAddressRange(&seg);
        t->dmaBytes = (uint8_t *)seg.address;
        t->dmaCapacity = length;
    }
    if (!t->action) {
        ret = gDK.createAction(gDK.actionCtx, sizeof(dk_transfer *), &t->action);
        if (ret != kIOReturnSuccess || !t->action) {
            t->action = nullptr;
            return LIBUSB_ERROR_NO_MEM;
        }
        *(dk_transfer **)t->action->GetReference() = t;
    }

    ret = pipe->AsyncIO(t->dma, length, t->action, transfer->timeout);
    if (ret != kIOReturnSuccess)
        return dk_error(ret);

    t->inFlight   = true;
    t->cancelling = false;
    __atomic_fetch_add(&gDK.active, 1u, __ATOMIC_RELAXED);
    return LIBUSB_SUCCESS;
}

int libusb_cancel_transfer(struct libusb_transfer *transfer)
{
    dk_transfer *t = (dk_transfer *)transfer;
    if (!t || !t->inFlight || t->cancelling)
        return LIBUSB_ERROR_NOT_FOUND;
    dk_on_queue(__func__);

    IOUSBHostPipe *pipe = dk_pipe(transfer->endpoint);
    if (!pipe)
        return LIBUSB_ERROR_NOT_FOUND;

    /* The abort hits every transfer on the endpoint. */
    for (dk_transfer *u = gDK.transfers; u; u = u->next)
        if (u->inFlight && u->pub.endpoint == transfer->endpoint)
            u->cancelling = true;

    /* We are on the event queue, where the aborted completions are delivered:
     * they arrive once the event loop sleeps again. */
    kern_return_t ret = pipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ret != kIOReturnSuccess)
        os_log(OS_LOG_DEFAULT, "[libusb] pipe abort failed: 0x%x", ret);
    return LIBUSB_SUCCESS;
}

/* ===========================================================================
 * MARK: - libusb: event handling
 * ======================================================================== */

int libusb_handle_events_timeout_completed(libusb_context *ctx,
                                           struct timeval *tv,
                                           int *completed)
{
    (void)ctx;
    if (!gDK.attached)
        return LIBUSB_ERROR_NO_DEVICE;
    if (!dk_on_queue(__func__))
        return LIBUSB_ERROR_OTHER;      /* cannot sleep off the event queue */

    dk_reap();

    /* As in libusb: no event handling once *completed is set. */
    if (completed && *completed)
        return LIBUSB_SUCCESS;

    uint64_t timeout = 0;
    if (tv && tv->tv_sec >= 0 && tv->tv_usec >= 0)
        timeout = (uint64_t)tv->tv_sec * 1000000000ull + (uint64_t)tv->tv_usec * 1000ull;
    uint64_t deadline = dk_now() + timeout;

    /* Sleeping releases the event queue, so ReadComplete can deliver. */
    while (!gDK.doneHead && !gDK.interrupted && !(completed && *completed)) {
        uint64_t now = dk_now();
        if (now >= deadline)
            break;
        uint64_t wake = (deadline - now > DK_WAIT_SLICE_NS) ? now + DK_WAIT_SLICE_NS
                                                            : deadline;
        kern_return_t ret = gDK.queue->SleepWithDeadline(&gDK, kIOTimerClockUptimeRaw, wake);
        if (ret != kIOReturnSuccess && ret != kIOReturnTimeout) {
            if (!gDK.sleepWarned) {
                gDK.sleepWarned = true;
                os_log(OS_LOG_DEFAULT, "[libusb] event queue sleep failed: 0x%x", ret);
            }
            break;
        }
    }
    gDK.interrupted = false;

    dk_dispatch();
    return LIBUSB_SUCCESS;
}

int libusb_handle_events_timeout(libusb_context *ctx, struct timeval *tv)
{
    return libusb_handle_events_timeout_completed(ctx, tv, nullptr);
}

void libusb_interrupt_event_handler(libusb_context *ctx)
{
    (void)ctx;
    IODispatchQueue *queue = gDK.queue;
    if (!queue)
        return;
    /* Wakeup has to be called on the queue; this runs while the loop sleeps. */
    queue->DispatchAsync(^{
        gDK.interrupted = true;
        if (gDK.queue)
            gDK.queue->Wakeup(&gDK);
    });
}
