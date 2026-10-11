//
//  usb_driverkit.cpp
//  RTL-SDR
//
//  USB transport for the gnuradio4-blocks RTL2832 driver on top of
//  USBDriverKit (see usb_driverkit.h).
//
//  Control transfers go through IOUSBHostInterface::DeviceRequest into a
//  reusable DMA buffer, bulk reads through IOUSBHostPipe::IO. The IQ stream
//  does not use this file: the dext streams with its own AsyncIO transfers.
//

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>

#include <USBDriverKit/USBDriverKit.h>

#include "usb_driverkit.h"

#define DK_CTRL_BUF_SIZE   256                          /* reusable control buffer */
#define DK_MAX_PIPES       32                           /* 16 OUT + 16 IN endpoints */
#define DK_STRING_SIZE     256

static struct {
    bool                       attached;
    IOUSBHostInterface        *interface;
    IOUSBHostDevice           *device;
    uint16_t                   vendorId;
    uint16_t                   productId;
    char                       manufacturer[DK_STRING_SIZE];
    char                       product[DK_STRING_SIZE];

    IOLock                    *ctrlLock;     /* guards ctrlBuffer          */
    IOBufferMemoryDescriptor  *ctrlBuffer;
    uint8_t                   *ctrlBytes;
    IOLock                    *pipeLock;     /* guards pipes[]             */
    IOUSBHostPipe             *pipes[DK_MAX_PIPES];
} gUSB;

/* ===========================================================================
 * MARK: - Helpers
 * ======================================================================== */

/* Pipes are copied on first use and kept until detach. */
static IOUSBHostPipe *dk_pipe(uint8_t endpoint) DRIVERKIT_RETURNS_NOT_RETAINED;
static IOUSBHostPipe *dk_pipe(uint8_t endpoint)
{
    uint32_t idx = (endpoint & 0x0fu) | ((endpoint & 0x80u) ? 0x10u : 0u);

    IOLockLock(gUSB.pipeLock);
    if (!gUSB.pipes[idx] && gUSB.interface) {
        IOUSBHostPipe *copied = nullptr;
        if (gUSB.interface->CopyPipe(endpoint, &copied) == kIOReturnSuccess)
            gUSB.pipes[idx] = copied;
    }
    IOUSBHostPipe *pipe = gUSB.pipes[idx];
    IOLockUnlock(gUSB.pipeLock);
    return pipe;
}

/* String descriptor `index` as ASCII into `out` ("" if there is none). Like
 * libusb, anything outside ASCII becomes '?'. */
static void dk_read_string(uint8_t index, char *out, size_t size)
{
    out[0] = '\0';
    if (!index || !gUSB.device)
        return;

    const IOUSBStringDescriptor *sd = gUSB.device->CopyStringDescriptor(index);
    if (!sd)
        return;

    /* bString is UTF-16LE after bLength / bDescriptorType. */
    const uint8_t *raw = (const uint8_t *)sd;
    size_t n = 0;
    for (uint32_t i = 2; i + 1 < sd->bLength && n < size - 1; i += 2)
        out[n++] = ((raw[i] & 0x80) || raw[i + 1]) ? '?' : (char)raw[i];
    out[n] = '\0';
    IOUSBHostFreeDescriptor(sd);
}

static void dk_release_resources(void)
{
    for (uint32_t i = 0; i < DK_MAX_PIPES; ++i)
        OSSafeReleaseNULL(gUSB.pipes[i]);
    OSSafeReleaseNULL(gUSB.ctrlBuffer);
    gUSB.ctrlBytes = nullptr;
    if (gUSB.ctrlLock) {
        IOLockFree(gUSB.ctrlLock);
        gUSB.ctrlLock = nullptr;
    }
    if (gUSB.pipeLock) {
        IOLockFree(gUSB.pipeLock);
        gUSB.pipeLock = nullptr;
    }
    OSSafeReleaseNULL(gUSB.device);
    gUSB.interface       = nullptr;
    gUSB.vendorId        = 0;
    gUSB.productId       = 0;
    gUSB.manufacturer[0] = '\0';
    gUSB.product[0]      = '\0';
}

/* ===========================================================================
 * MARK: - Dext life cycle
 * ======================================================================== */

int32_t usb_driverkit_attach(IOUSBHostInterface *interface)
{
    if (gUSB.attached)
        return kIOReturnBusy;
    if (!interface)
        return kIOReturnBadArgument;

    kern_return_t ret = interface->CopyDevice(&gUSB.device);
    if (ret != kIOReturnSuccess || !gUSB.device) {
        gUSB.device = nullptr;
        return (ret != kIOReturnSuccess) ? ret : kIOReturnNoDevice;
    }

    const IOUSBDeviceDescriptor *dd = gUSB.device->CopyDeviceDescriptor();
    if (!dd) {
        dk_release_resources();
        return kIOReturnNoDevice;
    }
    gUSB.vendorId  = dd->idVendor;
    gUSB.productId = dd->idProduct;
    dk_read_string(dd->iManufacturer, gUSB.manufacturer, sizeof(gUSB.manufacturer));
    dk_read_string(dd->iProduct, gUSB.product, sizeof(gUSB.product));
    IOUSBHostFreeDescriptor(dd);

    gUSB.ctrlLock = IOLockAlloc();
    gUSB.pipeLock = IOLockAlloc();
    if (!gUSB.ctrlLock || !gUSB.pipeLock) {
        dk_release_resources();
        return kIOReturnNoMemory;
    }

    ret = interface->CreateIOBuffer(kIOMemoryDirectionInOut, DK_CTRL_BUF_SIZE,
                                    &gUSB.ctrlBuffer);
    if (ret != kIOReturnSuccess || !gUSB.ctrlBuffer) {
        gUSB.ctrlBuffer = nullptr;
        dk_release_resources();
        return (ret != kIOReturnSuccess) ? ret : kIOReturnNoMemory;
    }
    IOAddressSegment seg;
    gUSB.ctrlBuffer->GetAddressRange(&seg);
    gUSB.ctrlBytes = (uint8_t *)seg.address;

    gUSB.interface = interface;
    gUSB.attached  = true;
    return kIOReturnSuccess;
}

void usb_driverkit_detach(void)
{
    gUSB.attached = false;
    dk_release_resources();
}

/* ===========================================================================
 * MARK: - Device
 * ======================================================================== */

bool usb_driverkit_attached(void)
{
    return gUSB.attached;
}

void usb_driverkit_get_info(uint16_t *vendorId, uint16_t *productId,
                            const char **manufacturer, const char **product)
{
    if (vendorId)
        *vendorId = gUSB.vendorId;
    if (productId)
        *productId = gUSB.productId;
    if (manufacturer)
        *manufacturer = gUSB.manufacturer;
    if (product)
        *product = gUSB.product;
}

int32_t usb_driverkit_reset(void)
{
    if (!gUSB.attached || !gUSB.device)
        return kIOReturnNoDevice;
    return gUSB.device->Reset();
}

int32_t usb_driverkit_clear_halt(uint8_t endpoint)
{
    if (!gUSB.attached)
        return kIOReturnNoDevice;
    IOUSBHostPipe *pipe = dk_pipe(endpoint);
    if (!pipe)
        return kIOReturnNotFound;
    return pipe->ClearStall(true);
}

/* ===========================================================================
 * MARK: - Transfers
 * ======================================================================== */

int32_t usb_driverkit_control(uint8_t requestType, uint8_t request,
                              uint16_t value, uint16_t index,
                              void *data, uint16_t length,
                              uint32_t timeoutMs, uint16_t *transferred)
{
    if (transferred)
        *transferred = 0;
    if (!gUSB.attached)
        return kIOReturnNoDevice;

    const bool isIn = (requestType & 0x80u) != 0;

    IOLockLock(gUSB.ctrlLock);

    IOBufferMemoryDescriptor *buffer = gUSB.ctrlBuffer;
    uint8_t *bytes = gUSB.ctrlBytes;
    IOBufferMemoryDescriptor *large = nullptr;
    if (length > DK_CTRL_BUF_SIZE) {
        kern_return_t ret = gUSB.interface->CreateIOBuffer(kIOMemoryDirectionInOut,
                                                           length, &large);
        if (ret != kIOReturnSuccess || !large) {
            IOLockUnlock(gUSB.ctrlLock);
            return kIOReturnNoMemory;
        }
        IOAddressSegment seg;
        large->GetAddressRange(&seg);
        buffer = large;
        bytes  = (uint8_t *)seg.address;
    }

    if (!isIn && length > 0 && data)
        memcpy(bytes, data, length);

    /* The descriptor must report exactly the transfer length. */
    buffer->SetLength(length ? length : 1);

    uint16_t got = 0;
    kern_return_t ret = gUSB.interface->DeviceRequest(requestType, request,
                                                      value, index, length,
                                                      buffer, &got, timeoutMs);
    if (ret == kIOReturnSuccess && isIn && data && got > 0)
        memcpy(data, bytes, (got < length) ? got : length);

    IOLockUnlock(gUSB.ctrlLock);
    OSSafeReleaseNULL(large);

    if (ret == kIOReturnSuccess && transferred)
        *transferred = (got < length) ? got : length;
    return ret;
}

int32_t usb_driverkit_bulk_read(uint8_t endpoint, void *data, uint32_t length,
                                uint32_t timeoutMs, uint32_t *transferred)
{
    if (transferred)
        *transferred = 0;
    if (!gUSB.attached)
        return kIOReturnNoDevice;
    if (!(endpoint & 0x80u))
        return kIOReturnUnsupported;
    if (!data || length == 0)
        return kIOReturnBadArgument;

    IOUSBHostPipe *pipe = dk_pipe(endpoint);
    if (!pipe)
        return kIOReturnNotFound;

    IOBufferMemoryDescriptor *buffer = nullptr;
    kern_return_t ret = gUSB.interface->CreateIOBuffer(kIOMemoryDirectionIn,
                                                       length, &buffer);
    if (ret != kIOReturnSuccess || !buffer)
        return kIOReturnNoMemory;

    uint32_t got = 0;
    ret = pipe->IO(buffer, length, &got, timeoutMs);
    if (got > 0) {
        if (got > length)
            got = length;
        IOAddressSegment seg;
        buffer->GetAddressRange(&seg);
        memcpy(data, (const void *)seg.address, got);
        if (transferred)
            *transferred = got;
    }
    OSSafeReleaseNULL(buffer);
    return ret;
}
