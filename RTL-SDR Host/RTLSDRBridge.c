//
//  RTLSDRBridge.c
//  RTL-SDR Host
//
//  IOKit user-client glue. See RTLSDRBridge.h.
//

#include "RTLSDRBridge.h"

#include <Block.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>

//  The DriverKit service is registered under its IOUserClass name. The matching
//  is exact, so this does not also pick up "RTL_SDR_DEV" (the device-level
//  driver) - we want the interface driver that owns the user client.
static const char *kRTLSDRServiceName = "RTL_SDR";

int rtlsdrhost_service_present(void)
{
    io_service_t service = IOServiceGetMatchingService(
        0, IOServiceNameMatching(kRTLSDRServiceName));
    if (service == IO_OBJECT_NULL)
        return 0;
    IOObjectRelease(service);
    return 1;
}

//  Service notifications, delivered on the main queue.
static IONotificationPortRef gNotifyPort;
static io_iterator_t         gMatchedIterator;
static io_iterator_t         gTerminatedIterator;
static void                (^gServiceHandler)(void);

//  The iterators must be drained to re-arm the notification.
static void rtlsdrhost_service_changed(void *refcon, io_iterator_t iterator)
{
    (void)refcon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL)
        IOObjectRelease(service);
    if (gServiceHandler)
        gServiceHandler();
}

int rtlsdrhost_watch_service(void (^handler)(void))
{
    if (gNotifyPort)
        return 0;

    gNotifyPort = IONotificationPortCreate(0);
    if (!gNotifyPort)
        return -1;
    IONotificationPortSetDispatchQueue(gNotifyPort, dispatch_get_main_queue());
    gServiceHandler = Block_copy(handler);

    //  Each call consumes its matching dictionary.
    kern_return_t kr = IOServiceAddMatchingNotification(
        gNotifyPort, kIOMatchedNotification, IOServiceNameMatching(kRTLSDRServiceName),
        rtlsdrhost_service_changed, NULL, &gMatchedIterator);
    if (kr == KERN_SUCCESS)
        rtlsdrhost_service_changed(NULL, gMatchedIterator);

    kern_return_t kr2 = IOServiceAddMatchingNotification(
        gNotifyPort, kIOTerminatedNotification, IOServiceNameMatching(kRTLSDRServiceName),
        rtlsdrhost_service_changed, NULL, &gTerminatedIterator);
    if (kr2 == KERN_SUCCESS)
        rtlsdrhost_service_changed(NULL, gTerminatedIterator);

    return (kr == KERN_SUCCESS && kr2 == KERN_SUCCESS) ? 0 : -1;
}

uint32_t rtlsdrhost_open(void)
{
    //  Passing 0 as the main port selects the default IOKit main port; this
    //  avoids depending on kIOMainPortDefault vs kIOMasterPortDefault naming.
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(
        0, IOServiceNameMatching(kRTLSDRServiceName), &iterator);
    if (kr != KERN_SUCCESS)
        return 0;

    io_connect_t connection = IO_OBJECT_NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        kr = IOServiceOpen(service, mach_task_self_, 0, &connection);
        IOObjectRelease(service);
        if (kr == KERN_SUCCESS)
            break;
        connection = IO_OBJECT_NULL;
    }
    IOObjectRelease(iterator);

    return (uint32_t)connection;
}

void rtlsdrhost_close(uint32_t connection)
{
    if (connection != IO_OBJECT_NULL)
        IOServiceClose((io_connect_t)connection);
}

int rtlsdrhost_call(uint32_t connection, uint32_t selector,
                    uint64_t arg, uint64_t *out)
{
    uint64_t input[1]  = { arg };
    uint64_t output[1] = { 0 };
    uint32_t outputCount = 1;

    kern_return_t kr = IOConnectCallScalarMethod(
        (io_connect_t)connection, selector,
        input, 1, output, &outputCount);

    if (out != NULL)
        *out = (outputCount > 0) ? output[0] : 0;
    return (int)kr;
}

int rtlsdrhost_get_struct(uint32_t connection, uint32_t selector,
                          void *outStruct, size_t *outSize)
{
    kern_return_t kr = IOConnectCallStructMethod(
        (io_connect_t)connection, selector,
        NULL, 0, outStruct, outSize);
    return (int)kr;
}

void *rtlsdrhost_map_memory(uint32_t connection, uint32_t memoryType,
                            uint64_t *outSize)
{
    mach_vm_address_t address = 0;
    mach_vm_size_t    size    = 0;

    kern_return_t kr = IOConnectMapMemory64(
        (io_connect_t)connection, memoryType,
        mach_task_self_, &address, &size, kIOMapAnywhere);
    if (kr != KERN_SUCCESS)
        return NULL;

    if (outSize != NULL)
        *outSize = (uint64_t)size;
    return (void *)(uintptr_t)address;
}
