//
//  rtl_app_ver.h
//  RTL-SDR
//
//  librtlsdr's CMake build generates this header from src/rtl_app_ver.h.in.
//  Keep the version in step with the third_party/librtlsdr checkout.
//

#ifndef __RTL_APP_VER_H
#define __RTL_APP_VER_H

#define APP_VER_MAJOR	0
#define APP_VER_MINOR	9
#define APP_VER_ID	"github.com/librtlsdr"

#define VER_TO_STRING(x)	#x
#define VAL_VER_TO_STR(x)	VER_TO_STRING(x)

#endif
