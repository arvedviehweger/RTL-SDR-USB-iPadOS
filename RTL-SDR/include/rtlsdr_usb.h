//
//  rtlsdr_usb.h
//  RTL-SDR
//
//  C bridge between librtlsdr.c and the USBDriverKit transport implemented in
//  RTL_SDR.cpp. librtlsdr.c is compiled as plain C and must not see any
//  DriverKit C++ headers; every USB operation it needs is funnelled through
//  the extern "C" functions declared here.
//
//  The argument order of the transfer functions deliberately mirrors the
//  libusb calls they replace, so the call sites in librtlsdr.c change as
//  little as possible.
//

#ifndef RTLSDR_USB_H
#define RTLSDR_USB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to the USBDriverKit transport. Concretely this is the RTL_SDR
 * DriverKit object, but librtlsdr.c only ever treats it as a void pointer. */
typedef void * rtlsdr_usb_t;

/* USB bmRequestType bits. librtlsdr builds its CTRL_IN / CTRL_OUT request
 * types from these; they used to come from <libusb.h>. The values are the
 * standard USB ones, so they stay numerically identical. */
#ifndef LIBUSB_ENDPOINT_IN
#define LIBUSB_ENDPOINT_IN          0x80
#endif
#ifndef LIBUSB_ENDPOINT_OUT
#define LIBUSB_ENDPOINT_OUT         0x00
#endif
#ifndef LIBUSB_REQUEST_TYPE_VENDOR
#define LIBUSB_REQUEST_TYPE_VENDOR  0x40
#endif

/* --- synchronous transfers ------------------------------------------------ */

/* Control transfer on endpoint 0.
 * Returns the number of bytes transferred, or a negative value on error
 * (same convention as libusb_control_transfer). */
int  rtlsdr_usb_control_transfer(rtlsdr_usb_t usb,
                                 uint8_t  bmRequestType,
                                 uint8_t  bRequest,
                                 uint16_t wValue,
                                 uint16_t wIndex,
                                 uint8_t *data,
                                 uint16_t wLength,
                                 uint32_t timeout_ms);

/* Synchronous bulk read from the IQ endpoint (0x81).
 * Returns 0 on success and stores the byte count in *transferred. */
int  rtlsdr_usb_bulk_read(rtlsdr_usb_t usb,
                          uint8_t *data,
                          int      length,
                          int     *transferred,
                          uint32_t timeout_ms);

/* USB device reset. Returns 0 on success. */
int  rtlsdr_usb_reset(rtlsdr_usb_t usb);

/* Manufacturer / product / serial strings. Each buffer must be >= 256 bytes
 * or NULL. Returns 0 on success. */
int  rtlsdr_usb_get_strings(rtlsdr_usb_t usb,
                            char *manufact, char *product, char *serial);

/* --- asynchronous IQ streaming -------------------------------------------- */

/* Invoked once per completed bulk transfer, on the dext streaming queue. */
typedef void (*rtlsdr_usb_stream_cb_t)(unsigned char *buf,
                                       uint32_t       len,
                                       void          *ctx);

/* Allocates buf_num buffers of buf_len bytes, submits them all on the bulk
 * pipe and returns immediately. The bridge owns resubmission. Returns 0 on
 * success. */
int  rtlsdr_usb_stream_start(rtlsdr_usb_t usb,
                             uint32_t buf_num,
                             uint32_t buf_len,
                             rtlsdr_usb_stream_cb_t cb,
                             void *ctx);

/* Aborts streaming, waits for in-flight transfers to complete and frees the
 * buffers. Returns 0 on success. */
int  rtlsdr_usb_stream_stop(rtlsdr_usb_t usb);

/* --- softagc scheduling --------------------------------------------------- */

/* Schedules rtlsdr_softagc_apply() on the device dispatch queue. Replaces the
 * pthread condition-variable signalling of the original librtlsdr code.
 * The argument is the rtlsdr_usb_t transport handle (librtlsdr passes
 * dev->usb). */
void rtlsdr_softagc_schedule(rtlsdr_usb_t usb);

/* --- librtlsdr entry points used by the dext ------------------------------ */

struct rtlsdr_dev;

/* DriverKit replacement for rtlsdr_open(): opens the device on an already
 * matched USB transport instead of enumerating the USB bus. */
int  rtlsdr_open_usb(struct rtlsdr_dev **out_dev, rtlsdr_usb_t usb);

/* Defined in librtlsdr.c, invoked by the bridge on the device queue. */
void rtlsdr_softagc_apply(struct rtlsdr_dev *dev);

#ifdef __cplusplus
}
#endif

#endif /* RTLSDR_USB_H */
