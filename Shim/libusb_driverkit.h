//
//  libusb_driverkit.h
//  RTL-SDR
//
//  Connects the libusb shim (libusb_driverkit.cpp) to the dext. The dext
//  attaches its matched USB interface before rtlsdr_open() and forwards the
//  completions of the asynchronous bulk transfers, whose OSActions have to
//  be created by the dext's own class.
//

#ifndef LIBUSB_DRIVERKIT_H
#define LIBUSB_DRIVERKIT_H

#include <stddef.h>
#include <stdint.h>

#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/OSAction.h>
#include <USBDriverKit/IOUSBHostInterface.h>

#include "include/libusb.h"

/* Creates the completion action of one asynchronous transfer, with
 * referenceSize bytes of reference memory. Its handler must run on the
 * event queue and pass the completion to libusb_driverkit_complete(). */
typedef kern_return_t (*libusb_driverkit_action_factory)(void *ctx,
                                                         size_t referenceSize,
                                                         OSAction **action);

/* Makes `interface` (already opened by the dext) the one libusb device.
 *
 * `eventQueue` must be created with kIODispatchQueueReentrant: the libusb
 * event handling sleeps on it while waiting for completions. Everything that
 * touches asynchronous transfers - libusb_alloc/submit/cancel/free_transfer
 * and libusb_handle_events*, i.e. rtlsdr_read_async() - has to run on it. */
kern_return_t libusb_driverkit_attach(IOUSBHostInterface *interface,
                                      IODispatchQueue *eventQueue,
                                      libusb_driverkit_action_factory createAction,
                                      void *ctx);

/* Aborts transfers still in flight, waits for their completions and releases
 * all USB resources. Call after rtlsdr_close(), not on the event queue. */
void libusb_driverkit_detach(void);

/* Hands the completion of a transfer's AsyncIO to libusb. Call from the
 * completion action's handler. */
void libusb_driverkit_complete(OSAction *action, IOReturn status,
                               uint32_t actualByteCount);

/* Number of asynchronous transfers in flight that have not been released
 * with libusb_free_transfer(). Safe to call from any queue. */
uint32_t libusb_driverkit_active_transfers(void);

#endif /* LIBUSB_DRIVERKIT_H */
