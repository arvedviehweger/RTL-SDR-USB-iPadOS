//
//  RTL2832Radio.h
//  RTL-SDR
//
//  Device control of the dext: the commands of the user client API
//  (kRTLSDRMethod* in RTLSDRShared.h) on top of the RTL2832Device driver from
//  gnuradio4-blocks. See RTL2832Radio.cpp.
//
//  All functions run on the dext's device queue. They return 0 on success or
//  a negative error in librtlsdr's conventions, which the user client hands
//  to the app unchanged.
//

#ifndef RTL2832_RADIO_H
#define RTL2832_RADIO_H

#include <stdint.h>

struct RTL2832Radio;

/* Tuner types as reported by kRTLSDRMethodGetTunerType (enum rtlsdr_tuner). */
enum {
    kRTL2832TunerUnknown = 0,
    kRTL2832TunerE4000   = 1,
    kRTL2832TunerR820T   = 5,
    kRTL2832TunerR828D   = 6,
};

/* Initialises the device attached with usb_driverkit_attach(). */
int  RTL2832Radio_Open(RTL2832Radio **radio);
void RTL2832Radio_Close(RTL2832Radio *radio);

int RTL2832Radio_SetCenterFreq(RTL2832Radio *radio, uint64_t freq);
int RTL2832Radio_SetSampleRate(RTL2832Radio *radio, uint32_t rate);
int RTL2832Radio_SetTunerGainMode(RTL2832Radio *radio, int manual);
int RTL2832Radio_SetTunerGain(RTL2832Radio *radio, int gainTenthDb);
int RTL2832Radio_SetGainByIndex(RTL2832Radio *radio, uint32_t index);
int RTL2832Radio_SetAgcMode(RTL2832Radio *radio, int on);
int RTL2832Radio_SetFreqCorrection(RTL2832Radio *radio, int ppm);
int RTL2832Radio_SetTunerBandwidth(RTL2832Radio *radio, uint32_t bandwidth);
int RTL2832Radio_SetTestmode(RTL2832Radio *radio, int on);
int RTL2832Radio_SetDirectSampling(RTL2832Radio *radio, int mode);
int RTL2832Radio_SetBiasTee(RTL2832Radio *radio, int on);
int RTL2832Radio_SetOffsetTuning(RTL2832Radio *radio, int on);
int RTL2832Radio_ResetBuffer(RTL2832Radio *radio);

uint32_t RTL2832Radio_GetTunerType(const RTL2832Radio *radio);
uint32_t RTL2832Radio_GetSampleRate(const RTL2832Radio *radio);

#endif /* RTL2832_RADIO_H */
