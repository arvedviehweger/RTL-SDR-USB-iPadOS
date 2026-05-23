//
//  RTL_SDR_UserClient.cpp
//  RTL-SDR
//
//  IOUserClient implementation. Forwards control commands to the RTL_SDR dext
//  and exposes the shared IQ ring buffer to the host application.
//
//  This is the "unchecked" ExternalMethod style (the driver overrides
//  ExternalMethod directly instead of using an IOUserClientMethodDispatch
//  table). All arguments are validated defensively below.
//

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/OSData.h>

#include "RTL_SDR_UserClient.h"
#include "RTL_SDR.h"
#include "RTLSDRShared.h"

struct RTL_SDR_UserClient_IVars {
    RTL_SDR *owner;     /* the dext object that created this user client */
};

//  init() / free() are plain virtual methods - ordinary C++ overrides, no
//  IMPL macro, super call via the base class name.
bool
RTL_SDR_UserClient::init()
{
    if (!IOUserClient::init())
        return false;
    ivars = IONewZero(RTL_SDR_UserClient_IVars, 1);
    return (ivars != nullptr);
}

void
RTL_SDR_UserClient::free()
{
    IOSafeDeleteNULL(ivars, RTL_SDR_UserClient_IVars, 1);
    IOUserClient::free();
}

kern_return_t
IMPL(RTL_SDR_UserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess)
        return ret;

    ivars->owner = OSDynamicCast(RTL_SDR, provider);
    if (!ivars->owner) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR_UserClient: provider is not RTL_SDR");
        return kIOReturnBadArgument;
    }

    os_log(OS_LOG_DEFAULT, "RTL_SDR_UserClient::Start");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(RTL_SDR_UserClient, Stop)
{
    os_log(OS_LOG_DEFAULT, "RTL_SDR_UserClient::Stop");
    if (ivars)
        ivars->owner = nullptr;
    return Stop(provider, SUPERDISPATCH);
}

//  Hands the shared IQ ring buffer to the application. The app maps it with
//  IOConnectMapMemory64(connection, kRTLSDRMemoryTypeIQRing, ...).
kern_return_t
IMPL(RTL_SDR_UserClient, CopyClientMemoryForType)
{
    if (type == kRTLSDRMemoryTypeIQRing) {
        if (!ivars || !ivars->owner)
            return kIOReturnNotReady;

        IOMemoryDescriptor *ring = nullptr;
        kern_return_t ret = ivars->owner->CopyIQRing(&ring);
        if (ret != kIOReturnSuccess || !ring)
            return kIOReturnNoMemory;

        *memory = ring;     /* retained by CopyIQRing(); ownership passes on */
        return kIOReturnSuccess;
    }
    return CopyClientMemoryForType(type, options, memory, SUPERDISPATCH);
}

//  Dispatches control commands coming from IOConnectCall*Method().
//
//  ExternalMethod is a plain virtual method of IOUserClient (not a DriverKit
//  dispatched method), so it is implemented WITHOUT the IMPL() macro - there
//  is no RTL_SDR_UserClient_ExternalMethod_Args type.
kern_return_t
RTL_SDR_UserClient::ExternalMethod(uint64_t selector,
                                   IOUserClientMethodArguments *arguments,
                                   const IOUserClientMethodDispatch *dispatch,
                                   OSObject *target,
                                   void *reference)
{
    (void)dispatch;
    (void)target;
    (void)reference;

    if (!ivars || !ivars->owner)
        return kIOReturnNotReady;

    //  Structure-output command: device information.
    if (selector == kRTLSDRMethodGetDeviceInfo) {
        if (!arguments)
            return kIOReturnBadArgument;

        RTLSDRDeviceInfo info;
        kern_return_t ret = ivars->owner->FillDeviceInfo(&info);
        if (ret != kIOReturnSuccess)
            return ret;

        arguments->structureOutput = OSData::withBytes(&info, sizeof(info));
        return (arguments->structureOutput != nullptr)
                   ? kIOReturnSuccess : kIOReturnNoMemory;
    }

    //  Everything else is a scalar command (selectors 0 .. GetTunerType).
    if (selector >= kRTLSDRMethodCount)
        return kIOReturnBadArgument;

    uint64_t arg = 0;
    if (arguments && arguments->scalarInput && arguments->scalarInputCount > 0)
        arg = arguments->scalarInput[0];

    uint64_t result = 0;
    kern_return_t ret = ivars->owner->HandleScalarCommand((uint32_t)selector,
                                                          arg, &result);

    if (arguments && arguments->scalarOutput && arguments->scalarOutputCount > 0) {
        arguments->scalarOutput[0]   = result;
        arguments->scalarOutputCount = 1;
    }
    return ret;
}
