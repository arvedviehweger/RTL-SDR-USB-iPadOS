//
//  RTL_SDR.cpp
//  RTL-SDR
//
//  Created by Arved Viehweger on 19.05.26.
//

#include <os/log.h>

#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOLib.h>

#include "RTL_SDR.h"

kern_return_t
IMPL(RTL_SDR, Start)
{
    kern_return_t ret;
    ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "Hello World");
    return ret;
}
