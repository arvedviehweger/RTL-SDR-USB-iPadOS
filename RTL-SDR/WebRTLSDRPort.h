//
//  WebRTLSDRPort.h
//  RTL-SDR
//
//  Functions ported from webrtlsdr, Apache License 2.0. See WebRTLSDRPort.cpp
//  for the copyright notice, the source of every function and what was
//  changed.
//
//  All functions return 0 on success or -1 after logging the error.
//

#ifndef WEBRTLSDR_PORT_H
#define WEBRTLSDR_PORT_H

#include <stddef.h>
#include <stdint.h>

namespace gr::blocks::sdr {
struct RTL2832Device;
}

/* One row of a webrtlsdr multiplexer table: [MHz, open drain, R26, R27]. */
struct WebRTLSDRMuxCfg {
    double  freqMhz;
    uint8_t openDrain;
    uint8_t rfMuxPoly;
    uint8_t tfC;
};

/* src/rtlsdr/rtlcom.ts */
int WebRTLSDR_GetSysReg(gr::blocks::sdr::RTL2832Device &dev, uint16_t address, uint8_t *value);
int WebRTLSDR_SetGpioOutput(gr::blocks::sdr::RTL2832Device &dev, int gpio);
int WebRTLSDR_SetGpioBit(gr::blocks::sdr::RTL2832Device &dev, int gpio, int val);

/* src/rtlsdr/rtl2832u.ts */
int WebRTLSDR_EnableBiasTee(gr::blocks::sdr::RTL2832Device &dev, bool enabled);
int WebRTLSDR_SetIfFrequency(gr::blocks::sdr::RTL2832Device &dev, double ifFreq);
int WebRTLSDR_EnterDirectSampling(gr::blocks::sdr::RTL2832Device &dev, int method, bool closeR8xxTuner);
int WebRTLSDR_LeaveDirectSampling(gr::blocks::sdr::RTL2832Device &dev);

/* src/rtlsdr/r8xx.ts */
int WebRTLSDR_R8xxClose(gr::blocks::sdr::RTL2832Device &dev);
int WebRTLSDR_R8xxSetMux(gr::blocks::sdr::RTL2832Device &dev, double freq,
                         const WebRTLSDRMuxCfg *muxCfgs, size_t count);

/* src/rtlsdr/r828d.ts */
extern const WebRTLSDRMuxCfg kWebRTLSDRMuxCfgsRtlSdrBlogV4[];
extern const size_t          kWebRTLSDRMuxCfgsRtlSdrBlogV4Count;

bool     WebRTLSDR_IsRtlSdrBlogV4(const char *manufacturer, const char *model);
uint64_t WebRTLSDR_R828DUpconvert(bool isRtlSdrBlogV4, uint64_t freq);
int      WebRTLSDR_R828DSelectInput(gr::blocks::sdr::RTL2832Device &dev, bool isRtlSdrBlogV4,
                                    uint64_t freq, int *input);

#endif /* WEBRTLSDR_PORT_H */
