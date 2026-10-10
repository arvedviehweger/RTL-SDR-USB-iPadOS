//
//  libusb.h
//  RTL-SDR
//
//  The part of the libusb-1.0 API that librtlsdr uses, implemented on top of
//  USBDriverKit in ../libusb_driverkit.cpp. Names, types and signatures follow
//  libusb-1.0, so the unmodified librtlsdr sources compile against it.
//
//  Only one device exists: the IOUSBHostInterface the dext was matched to
//  (see libusb_driverkit_attach()). Asynchronous transfers support bulk IN,
//  which is all librtlsdr submits.
//

#ifndef RTLSDR_SHIM_LIBUSB_H
#define RTLSDR_SHIM_LIBUSB_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/_types/_ssize_t.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LIBUSB_CALL

/* DriverKit has no <sys/time.h> timeval; libusb takes its timeouts as one. */
#ifndef _STRUCT_TIMEVAL
#define _STRUCT_TIMEVAL struct timeval
struct timeval {
	long tv_sec;
	int  tv_usec;
};
#endif

enum libusb_error {
	LIBUSB_SUCCESS             = 0,
	LIBUSB_ERROR_IO            = -1,
	LIBUSB_ERROR_INVALID_PARAM = -2,
	LIBUSB_ERROR_ACCESS        = -3,
	LIBUSB_ERROR_NO_DEVICE     = -4,
	LIBUSB_ERROR_NOT_FOUND     = -5,
	LIBUSB_ERROR_BUSY          = -6,
	LIBUSB_ERROR_TIMEOUT       = -7,
	LIBUSB_ERROR_OVERFLOW      = -8,
	LIBUSB_ERROR_PIPE          = -9,
	LIBUSB_ERROR_INTERRUPTED   = -10,
	LIBUSB_ERROR_NO_MEM        = -11,
	LIBUSB_ERROR_NOT_SUPPORTED = -12,
	LIBUSB_ERROR_OTHER         = -99
};

enum libusb_endpoint_direction {
	LIBUSB_ENDPOINT_OUT = 0x00,
	LIBUSB_ENDPOINT_IN  = 0x80
};

enum libusb_request_type {
	LIBUSB_REQUEST_TYPE_STANDARD = (0x00 << 5),
	LIBUSB_REQUEST_TYPE_CLASS    = (0x01 << 5),
	LIBUSB_REQUEST_TYPE_VENDOR   = (0x02 << 5),
	LIBUSB_REQUEST_TYPE_RESERVED = (0x03 << 5)
};

enum libusb_transfer_type {
	LIBUSB_TRANSFER_TYPE_CONTROL     = 0,
	LIBUSB_TRANSFER_TYPE_ISOCHRONOUS = 1,
	LIBUSB_TRANSFER_TYPE_BULK        = 2,
	LIBUSB_TRANSFER_TYPE_INTERRUPT   = 3
};

enum libusb_transfer_status {
	LIBUSB_TRANSFER_COMPLETED,
	LIBUSB_TRANSFER_ERROR,
	LIBUSB_TRANSFER_TIMED_OUT,
	LIBUSB_TRANSFER_CANCELLED,
	LIBUSB_TRANSFER_STALL,
	LIBUSB_TRANSFER_NO_DEVICE,
	LIBUSB_TRANSFER_OVERFLOW
};

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

struct libusb_device_descriptor {
	uint8_t  bLength;
	uint8_t  bDescriptorType;
	uint16_t bcdUSB;
	uint8_t  bDeviceClass;
	uint8_t  bDeviceSubClass;
	uint8_t  bDeviceProtocol;
	uint8_t  bMaxPacketSize0;
	uint16_t idVendor;
	uint16_t idProduct;
	uint16_t bcdDevice;
	uint8_t  iManufacturer;
	uint8_t  iProduct;
	uint8_t  iSerialNumber;
	uint8_t  bNumConfigurations;
};

struct libusb_transfer;
typedef void (LIBUSB_CALL *libusb_transfer_cb_fn)(struct libusb_transfer *transfer);

struct libusb_transfer {
	libusb_device_handle *dev_handle;
	uint8_t flags;
	unsigned char endpoint;
	unsigned char type;
	unsigned int timeout;
	enum libusb_transfer_status status;
	int length;
	int actual_length;
	libusb_transfer_cb_fn callback;
	void *user_data;
	unsigned char *buffer;
	int num_iso_packets;
};

/* --- library / device handling ------------------------------------------- */

int  LIBUSB_CALL libusb_init(libusb_context **ctx);
void LIBUSB_CALL libusb_exit(libusb_context *ctx);

ssize_t LIBUSB_CALL libusb_get_device_list(libusb_context *ctx, libusb_device ***list);
void LIBUSB_CALL libusb_free_device_list(libusb_device **list, int unref_devices);
int  LIBUSB_CALL libusb_get_device_descriptor(libusb_device *dev,
	struct libusb_device_descriptor *desc);
libusb_device * LIBUSB_CALL libusb_get_device(libusb_device_handle *dev_handle);

int  LIBUSB_CALL libusb_open(libusb_device *dev, libusb_device_handle **dev_handle);
void LIBUSB_CALL libusb_close(libusb_device_handle *dev_handle);
int  LIBUSB_CALL libusb_reset_device(libusb_device_handle *dev_handle);

int  LIBUSB_CALL libusb_kernel_driver_active(libusb_device_handle *dev_handle, int interface_number);
int  LIBUSB_CALL libusb_detach_kernel_driver(libusb_device_handle *dev_handle, int interface_number);
int  LIBUSB_CALL libusb_attach_kernel_driver(libusb_device_handle *dev_handle, int interface_number);
int  LIBUSB_CALL libusb_claim_interface(libusb_device_handle *dev_handle, int interface_number);
int  LIBUSB_CALL libusb_release_interface(libusb_device_handle *dev_handle, int interface_number);

int  LIBUSB_CALL libusb_get_string_descriptor_ascii(libusb_device_handle *dev_handle,
	uint8_t desc_index, unsigned char *data, int length);

/* --- synchronous I/O ----------------------------------------------------- */

int  LIBUSB_CALL libusb_control_transfer(libusb_device_handle *dev_handle,
	uint8_t request_type, uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
	unsigned char *data, uint16_t wLength, unsigned int timeout);
int  LIBUSB_CALL libusb_bulk_transfer(libusb_device_handle *dev_handle,
	unsigned char endpoint, unsigned char *data, int length,
	int *actual_length, unsigned int timeout);

/* --- asynchronous I/O ---------------------------------------------------- */

struct libusb_transfer * LIBUSB_CALL libusb_alloc_transfer(int iso_packets);
void LIBUSB_CALL libusb_free_transfer(struct libusb_transfer *transfer);
int  LIBUSB_CALL libusb_submit_transfer(struct libusb_transfer *transfer);
int  LIBUSB_CALL libusb_cancel_transfer(struct libusb_transfer *transfer);

static inline void libusb_fill_bulk_transfer(struct libusb_transfer *transfer,
	libusb_device_handle *dev_handle, unsigned char endpoint,
	unsigned char *buffer, int length, libusb_transfer_cb_fn callback,
	void *user_data, unsigned int timeout)
{
	transfer->dev_handle = dev_handle;
	transfer->endpoint = endpoint;
	transfer->type = LIBUSB_TRANSFER_TYPE_BULK;
	transfer->timeout = timeout;
	transfer->buffer = buffer;
	transfer->length = length;
	transfer->user_data = user_data;
	transfer->callback = callback;
}

/* --- event handling ------------------------------------------------------ */

int  LIBUSB_CALL libusb_handle_events_timeout(libusb_context *ctx, struct timeval *tv);
int  LIBUSB_CALL libusb_handle_events_timeout_completed(libusb_context *ctx,
	struct timeval *tv, int *completed);
void LIBUSB_CALL libusb_interrupt_event_handler(libusb_context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* RTLSDR_SHIM_LIBUSB_H */
