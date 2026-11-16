//
//  RTL-SDR-Host-Bridging-Header.h
//  RTL-SDR Host
//
//  Objective-C / C bridging header. Makes the C bridge, the shared
//  DEXT <-> app contract and the DAB decoders' C parts visible to Swift.
//
//  Xcode setup: set the target build setting
//      Swift Compiler - General > Objective-C Bridging Header
//  to  "RTL-SDR Host/RTL-SDR-Host-Bridging-Header.h"
//

#ifndef RTL_SDR_HOST_BRIDGING_HEADER_H
#define RTL_SDR_HOST_BRIDGING_HEADER_H

#include "RTLSDRShared.h"
#include "RTLSDRBridge.h"
#include "DAB/dab_fec.h"
#include "DAB/kjmp2.h"

#endif /* RTL_SDR_HOST_BRIDGING_HEADER_H */
