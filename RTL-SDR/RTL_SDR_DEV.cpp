//
//  RTL_SDR.cpp
//  RTL-SDR
//
//  Created by Arved Viehweger on 19.05.26.
//

#include <os/log.h>

#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOLib.h>

#include "RTL_SDR_DEV.h"

kern_return_t
IMPL(RTL_SDR_DEV, Start)
{
    os_log(OS_LOG_DEFAULT, "RTL_SDR_DEV::Start called");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "RTL_SDR_DEV::Start super failed: 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, "RTL_SDR_DEV driver started successfully");
    return kIOReturnSuccess;
}
