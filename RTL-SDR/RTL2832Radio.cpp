//
//  RTL2832Radio.cpp
//  RTL-SDR
//
//  Device control of the dext on top of RTL2832Device from gnuradio4-blocks
//  (MIT, third_party/gnuradio4-blocks, compiled unmodified). RTL2832Device
//  programs the RTL2832U and the R820T/R828D/R860 or E4000 tuner; this file
//  maps the user client commands onto it with librtlsdr's semantics, so that
//  the app and rtl_tcp clients see the same behaviour as before.
//
//  Where the code comes from:
//    * RTL2832Device (gnuradio4-blocks, MIT): demodulator and tuner init,
//      tuning, gain, sample rate, sample clock correction, buffer reset.
//    * Values kept compatible with librtlsdr, marked "librtlsdr-compatible"
//      below: the gain step lists, the accepted sample rate ranges, the test
//      mode register values and the return codes. These are numbers and
//      behaviour clients rely on; no librtlsdr code is used.
//    * Everything else - the command mapping, frequency correction of the
//      tuner, the state handling - is written for this project.
//
//  Bias tee and direct sampling are not supported yet.
//

#include <stdint.h>
#include <stddef.h>
#include <new>
#include <os/log.h>

#include <gnuradio-4.0/sdr/RTL2832Device.hpp>

#include "RTL2832Radio.h"

using gr::blocks::sdr::RTL2832Device;
using gr::blocks::sdr::TunerType;

/* librtlsdr-compatible: -EINVAL for an unsupported sample rate. */
#define RTL2832RADIO_EINVAL        (-22)

/* Sample rate at open, until a client sets one. */
#define RTL2832RADIO_DEFAULT_RATE  2048000u

/* librtlsdr-compatible: the gain steps in tenths of a dB that librtlsdr
 * reports for these tuners. rtl_tcp clients have the same lists built in;
 * the dongle-info header announces their count and
 * kRTLSDRMethodSetGainByIndex picks one of them. */
static const int kR82xxGains[] = {
    0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254,
    280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496,
};
static const int kE4000Gains[] = {
    -10, 15, 40, 65, 90, 115, 140, 165, 190, 215, 240, 290, 340, 420,
};

struct RTL2832Radio {
    RTL2832Device dev;
    uint64_t      centerFreq      = 0;      /* last tuned frequency, 0: none */
    uint32_t      sampleRate      = 0;
    int           ppm             = 0;
    bool          manualGain      = false;
    int           gainTenthDb     = 0;
    bool          bandwidthWarned = false;
};

/* ===========================================================================
 * MARK: - Helpers
 * ======================================================================== */

static int RTL2832Radio_Fail(const char *what, const std::string &error)
{
    os_log(OS_LOG_DEFAULT, "[rtl2832] %{public}s: %{public}s", what, error.c_str());
    return -1;
}

static bool RTL2832Radio_IsR82xx(const RTL2832Radio *r)
{
    return r->dev._tunerType == TunerType::r820t || r->dev._tunerType == TunerType::r828d;
}

/* The tuner PLL and the demodulator's NCO run from one crystal, which is off
 * by r->ppm. RTL2832Device calculates with the nominal crystal, so it is
 * given the frequency that lands on `freq` with the actual one. */
static double RTL2832Radio_Corrected(const RTL2832Radio *r, uint64_t freq)
{
    return (double)freq * 1e6 / (1e6 + (double)r->ppm);
}

static int RTL2832Radio_ApplyGain(RTL2832Radio *r)
{
    if (r->manualGain) {
        if (auto res = r->dev.setTunerGain((float)r->gainTenthDb / 10.0f); !res)
            return RTL2832Radio_Fail("set tuner gain", res.error());
    } else {
        if (auto res = r->dev.setGainMode(true); !res)
            return RTL2832Radio_Fail("set auto gain", res.error());
    }
    return 0;
}

/* ===========================================================================
 * MARK: - Life cycle
 * ======================================================================== */

int RTL2832Radio_Open(RTL2832Radio **radio)
{
    *radio = nullptr;

    RTL2832Radio *r = new (std::nothrow) RTL2832Radio();
    if (!r)
        return -1;

    if (auto res = r->dev.open(0); !res) {
        RTL2832Radio_Fail("open", res.error());
        delete r;
        return -1;
    }

    if (RTL2832Radio_ApplyGain(r) != 0 ||
        RTL2832Radio_SetSampleRate(r, RTL2832RADIO_DEFAULT_RATE) != 0) {
        delete r;
        return -1;
    }
    *radio = r;
    return 0;
}

void RTL2832Radio_Close(RTL2832Radio *radio)
{
    delete radio;
}

/* ===========================================================================
 * MARK: - Commands
 * ======================================================================== */

int RTL2832Radio_SetCenterFreq(RTL2832Radio *r, uint64_t freq)
{
    if (auto res = r->dev.setCenterFrequency(RTL2832Radio_Corrected(r, freq)); !res)
        return RTL2832Radio_Fail("set center frequency", res.error());
    r->centerFreq = freq;
    return 0;
}

int RTL2832Radio_SetSampleRate(RTL2832Radio *r, uint32_t rate)
{
    /* librtlsdr-compatible: the ranges librtlsdr accepts. */
    if (!((rate > 225000 && rate <= 300000) || (rate > 900000 && rate <= 3200000)))
        return RTL2832RADIO_EINVAL;

    auto res = r->dev.setSampleRate((float)rate);
    if (!res)
        return RTL2832Radio_Fail("set sample rate", res.error());
    r->sampleRate = (uint32_t)*res;
    return 0;
}

int RTL2832Radio_SetTunerGainMode(RTL2832Radio *r, int manual)
{
    r->manualGain = (manual != 0);
    return RTL2832Radio_ApplyGain(r);
}

/* librtlsdr-compatible: setting a gain also selects manual gain. */
int RTL2832Radio_SetTunerGain(RTL2832Radio *r, int gainTenthDb)
{
    r->gainTenthDb = gainTenthDb;
    r->manualGain = true;
    return RTL2832Radio_ApplyGain(r);
}

int RTL2832Radio_SetGainByIndex(RTL2832Radio *r, uint32_t index)
{
    const int *gains = nullptr;
    uint32_t count = 0;
    if (RTL2832Radio_IsR82xx(r)) {
        gains = kR82xxGains;
        count = sizeof(kR82xxGains) / sizeof(kR82xxGains[0]);
    } else if (r->dev._tunerType == TunerType::e4000) {
        gains = kE4000Gains;
        count = sizeof(kE4000Gains) / sizeof(kE4000Gains[0]);
    }
    if (index >= count)
        return -1;
    return RTL2832Radio_SetTunerGain(r, gains[index]);
}

int RTL2832Radio_SetAgcMode(RTL2832Radio *r, int on)
{
    if (auto res = r->dev.setAgcMode(on != 0); !res)
        return RTL2832Radio_Fail("set AGC mode", res.error());
    return 0;
}

int RTL2832Radio_SetFreqCorrection(RTL2832Radio *r, int ppm)
{
    if (ppm == r->ppm)
        return -2;                      /* librtlsdr-compatible: unchanged */

    /* Sample clock: RTL2832Device programs the demodulator's correction. */
    if (auto res = r->dev.setFreqCorrection(ppm); !res)
        return RTL2832Radio_Fail("set frequency correction", res.error());
    r->ppm = ppm;

    /* Tuner: retune with the corrected frequency. */
    if (r->centerFreq)
        return RTL2832Radio_SetCenterFreq(r, r->centerFreq);
    return 0;
}

/* RTL2832Device keeps the tuner's IF filter at the width it sets up at open.
 * Accepted like librtlsdr does, so clients that send it keep working. */
int RTL2832Radio_SetTunerBandwidth(RTL2832Radio *r, uint32_t bandwidth)
{
    if (bandwidth != 0 && !r->bandwidthWarned) {
        r->bandwidthWarned = true;
        os_log(OS_LOG_DEFAULT, "[rtl2832] tuner bandwidth %u Hz requested, the IF filter stays at its default",
               bandwidth);
    }
    return 0;
}

/* Demodulator test mode: an 8-bit counter instead of samples.
 * librtlsdr-compatible: the register values librtlsdr writes. */
int RTL2832Radio_SetTestmode(RTL2832Radio *r, int on)
{
    if (auto res = r->dev.setDemodReg(0, 0x19, on ? 0x03 : 0x05, 1); !res)
        return RTL2832Radio_Fail("set test mode", res.error());
    return 0;
}

/* Not supported yet; off is what the dongle does anyway. */
int RTL2832Radio_SetDirectSampling(RTL2832Radio *r, int mode)
{
    (void)r;
    return (mode == 0) ? 0 : -1;
}

/* Not supported yet. */
int RTL2832Radio_SetBiasTee(RTL2832Radio *r, int on)
{
    (void)r;
    (void)on;
    return -1;
}

/* librtlsdr-compatible: librtlsdr does not support offset tuning on
 * R820T/R828D either and returns -2. */
int RTL2832Radio_SetOffsetTuning(RTL2832Radio *r, int on)
{
    (void)r;
    (void)on;
    return -2;
}

int RTL2832Radio_ResetBuffer(RTL2832Radio *r)
{
    if (auto res = r->dev.resetBuffer(); !res)
        return RTL2832Radio_Fail("reset buffer", res.error());
    return 0;
}

uint32_t RTL2832Radio_GetTunerType(const RTL2832Radio *r)
{
    switch (r->dev._tunerType) {
    case TunerType::e4000: return kRTL2832TunerE4000;
    case TunerType::r820t: return kRTL2832TunerR820T;
    case TunerType::r828d: return kRTL2832TunerR828D;
    default:               return kRTL2832TunerUnknown;
    }
}

uint32_t RTL2832Radio_GetSampleRate(const RTL2832Radio *r)
{
    return r->sampleRate;
}
