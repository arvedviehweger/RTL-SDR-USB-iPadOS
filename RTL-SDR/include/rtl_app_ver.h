//
//  rtl_app_ver.h
//  RTL-SDR
//
//  The librtlsdr fork this project is based on normally generates this header
//  from its CMake build. The DriverKit (Xcode) build does not run CMake, so a
//  static version definition is provided here. It only feeds rtlsdr_get_ver_id()
//  and rtlsdr_get_version(); adjust the values freely.
//

#ifndef RTL_APP_VER_H
#define RTL_APP_VER_H

#define APP_VER_ID     "rtl-sdr (USBDriverKit port)"
#define APP_VER_MAJOR  0
#define APP_VER_MINOR  1

#endif /* RTL_APP_VER_H */
