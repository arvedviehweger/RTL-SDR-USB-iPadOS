//
//  usb_driverkit.h
//  RTL-SDR
//
//  USB transport for the gnuradio4-blocks RTL2832 driver on top of
//  USBDriverKit, implemented in usb_driverkit.cpp.
//
//  The dext registers the IOUSBHostInterface it was matched to with
//  usb_driverkit_attach(). The USBDevice stand-in in
//  include/gnuradio-4.0/common/USBDevice.hpp then reaches that device through
//  the transfer functions below. DriverKit runs one dext process per matched
//  interface, so there is exactly one device.
//
//  Return values are IOReturn codes. This header stays free of DriverKit
//  includes, because the USBDevice stand-in is compiled together with the
//  upstream code.
//

#ifndef RTLSDR_SHIM_USB_DRIVERKIT_H
#define RTLSDR_SHIM_USB_DRIVERKIT_H

#include <stdint.h>

class IOUSBHostInterface;

/* ---- dext life cycle --------------------------------------------------- */

/* Makes `interface` (opened by the caller) the one device. Reads the device
 * descriptor and the manufacturer / product strings. */
int32_t usb_driverkit_attach(IOUSBHostInterface *interface);

/* Releases everything usb_driverkit_attach() set up. */
void usb_driverkit_detach(void);

/* ---- device ------------------------------------------------------------ */

bool usb_driverkit_attached(void);

/* Device descriptor IDs and the USB strings ("" if the device has none).
 * The strings stay valid until usb_driverkit_detach(). */
void usb_driverkit_get_info(uint16_t *vendorId, uint16_t *productId,
                            const char **manufacturer, const char **product);

/* ---- transfers --------------------------------------------------------- */

/* Control transfer on the default pipe. `data` holds `length` bytes to send
 * (OUT) or receives up to `length` bytes (IN). */
int32_t usb_driverkit_control(uint8_t requestType, uint8_t request,
                              uint16_t value, uint16_t index,
                              void *data, uint16_t length,
                              uint32_t timeoutMs, uint16_t *transferred);

/* Synchronous bulk IN transfer. */
int32_t usb_driverkit_bulk_read(uint8_t endpoint, void *data, uint32_t length,
                                uint32_t timeoutMs, uint32_t *transferred);

int32_t usb_driverkit_reset(void);
int32_t usb_driverkit_clear_halt(uint8_t endpoint);

#endif /* RTLSDR_SHIM_USB_DRIVERKIT_H */
