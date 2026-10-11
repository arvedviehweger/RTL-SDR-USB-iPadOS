//
//  WebRTLSDRPort.cpp
//  RTL-SDR
//
//  Functions ported from webrtlsdr (https://github.com/jtarrio/webrtlsdr),
//  commit 5699cec220cb0349e8f9144b7b71d3d03b5d9dbf:
//
//      Copyright 2024 Jacobo Tarrio Barreiro. All rights reserved.
//      Copyright 2013 Google Inc. All rights reserved.
//
//      Licensed under the Apache License, Version 2.0 (the "License");
//      you may not use this file except in compliance with the License.
//      You may obtain a copy of the License at
//
//          http://www.apache.org/licenses/LICENSE-2.0
//
//      Unless required by applicable law or agreed to in writing, software
//      distributed under the License is distributed on an "AS IS" BASIS,
//      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
//      implied. See the License for the specific language governing
//      permissions and limitations under the License.
//
//  A copy of the license is in third_party/LICENSE.webrtlsdr.
//
//  Modified by Arved Viehweger, 2026: translated from TypeScript to C++ and
//  rewritten on top of RTL2832Device from gnuradio4-blocks, which does the
//  USB and I2C access. Every function below names the webrtlsdr function it
//  was ported from, with a link to the exact lines, and lists what differs.
//  This file holds all code taken from webrtlsdr; nothing else in the
//  project is.
//

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <os/log.h>

#include <gnuradio-4.0/sdr/RTL2832Device.hpp>

#include "WebRTLSDRPort.h"

using gr::blocks::sdr::RTL2832Device;
using gr::blocks::sdr::TunerType;

/* ===========================================================================
 * MARK: - Helpers (not from webrtlsdr)
 * ======================================================================== */

static int WebRTLSDR_Fail(const char *what, const std::string &error)
{
    os_log(OS_LOG_DEFAULT, "[rtl2832] %{public}s: %{public}s", what, error.c_str());
    return -1;
}

/* RtlCom.setSysReg() */
static int WebRTLSDR_SetSysReg(RTL2832Device &dev, uint16_t address, uint8_t value)
{
    if (auto r = dev.setSysReg(address, value); !r)
        return WebRTLSDR_Fail("setSysReg", r.error());
    return 0;
}

/* RtlCom.setDemodReg() with a 1-byte value */
static int WebRTLSDR_SetDemodReg(RTL2832Device &dev, uint8_t page, uint8_t addr, uint8_t value)
{
    if (auto r = dev.setDemodReg(page, addr, value, 1); !r)
        return WebRTLSDR_Fail("setDemodReg", r.error());
    return 0;
}

/* R8xx._writeRegMask(); the I2C repeater must be open */
static int WebRTLSDR_WriteRegMask(RTL2832Device &dev, uint8_t addr, uint8_t value, uint8_t mask)
{
    if (auto r = dev.writeTunerRegMask(addr, value, mask); !r)
        return WebRTLSDR_Fail("writeRegMask", r.error());
    return 0;
}

/* ===========================================================================
 * MARK: - src/rtlsdr/rtlcom.ts
 * ======================================================================== */

/* RtlCom.getSysReg()
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtlcom.ts#L79-L81
 * Changes: reads through RTL2832Device::ctrlTransferIn(). */
int WebRTLSDR_GetSysReg(RTL2832Device &dev, uint16_t address, uint8_t *value)
{
    auto r = dev.ctrlTransferIn(address, 0x200, 1);
    if (!r)
        return WebRTLSDR_Fail("getSysReg", r.error());
    if (r->empty())
        return WebRTLSDR_Fail("getSysReg", "no data");
    *value = (*r)[0];
    return 0;
}

/* RtlCom.setGpioOutput()
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtlcom.ts#L142-L148
 * Changes: none besides the translation. */
int WebRTLSDR_SetGpioOutput(RTL2832Device &dev, int gpio)
{
    uint8_t bit = (uint8_t)(1u << gpio);
    uint8_t r = 0;
    if (WebRTLSDR_GetSysReg(dev, 0x3004, &r) != 0 ||
        WebRTLSDR_SetSysReg(dev, 0x3004, (uint8_t)(r & ~bit)) != 0 ||
        WebRTLSDR_GetSysReg(dev, 0x3003, &r) != 0 ||
        WebRTLSDR_SetSysReg(dev, 0x3003, (uint8_t)(r | bit)) != 0)
        return -1;
    return 0;
}

/* RtlCom.setGpioBit()
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtlcom.ts#L150-L155
 * Changes: none besides the translation. */
int WebRTLSDR_SetGpioBit(RTL2832Device &dev, int gpio, int val)
{
    uint8_t bit = (uint8_t)(1u << gpio);
    uint8_t r = 0;
    if (WebRTLSDR_GetSysReg(dev, 0x3001, &r) != 0)
        return -1;
    r = val ? (uint8_t)(r | bit) : (uint8_t)(r & ~bit);
    return WebRTLSDR_SetSysReg(dev, 0x3001, r);
}

/* ===========================================================================
 * MARK: - src/rtlsdr/rtl2832u.ts
 * ======================================================================== */

/* RTL2832U.enableBiasTee()
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtl2832u.ts#L265-L269
 * Changes: does not keep the state (biasTeeEnabled). */
int WebRTLSDR_EnableBiasTee(RTL2832Device &dev, bool enabled)
{
    if (WebRTLSDR_SetGpioOutput(dev, 0) != 0 ||
        WebRTLSDR_SetGpioBit(dev, 0, enabled ? 1 : 0) != 0)
        return -1;
    return 0;
}

/* RTL2832U._setIfFrequency()
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtl2832u.ts#L234-L242
 * Changes: calculates with the nominal crystal frequency instead of the
 * ppm-corrected one; the caller passes a frequency that is already corrected
 * (RTL2832Radio_Corrected()). Does not return the resulting frequency. */
int WebRTLSDR_SetIfFrequency(RTL2832Device &dev, double ifFreq)
{
    double xtalFrequency = (double)gr::blocks::sdr::kXtalFreq;
    /* Math.floor(); the quotient is not negative */
    int32_t multiplier = -1 * (int32_t)((ifFreq * (1 << 22)) / xtalFrequency);
    // [21:0] set IF frequency
    if (WebRTLSDR_SetDemodReg(dev, 1, 0x19, (uint8_t)((multiplier >> 16) & 0x3f)) != 0 ||
        WebRTLSDR_SetDemodReg(dev, 1, 0x1a, (uint8_t)((multiplier >> 8) & 0xff)) != 0 ||
        WebRTLSDR_SetDemodReg(dev, 1, 0x1b, (uint8_t)(multiplier & 0xff)) != 0)
        return -1;
    return 0;
}

/* RTL2832U._maybeSetDirectSampling(), branch that turns direct sampling on
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtl2832u.ts#L333-L346
 * `method`: 1 = I, 2 = Q (webrtlsdr's DirectSampling.I / .Q).
 * Changes:
 *   - The caller switches direct sampling on explicitly, as in librtlsdr,
 *     instead of it following the tuning frequency (L327-L332).
 *   - The caller decides whether an R820T/R828D tuner is to be put into
 *     standby (tunerWasOn, and webrtlsdr only knows R8xx tuners).
 *   - Does not switch the RTL2832's AGC on (L346); it stays as the client
 *     set it, as in librtlsdr. */
int WebRTLSDR_EnterDirectSampling(RTL2832Device &dev, int method, bool closeR8xxTuner)
{
    if (closeR8xxTuner && WebRTLSDR_R8xxClose(dev) != 0)
        return -1;
    // [0] disable zero-IF input
    if (WebRTLSDR_SetDemodReg(dev, 1, 0xb1, 0b00011010) != 0)
        return -1;
    // [0] non-inverted spectrum
    if (WebRTLSDR_SetDemodReg(dev, 1, 0x15, 0b00000000) != 0)
        return -1;
    // [5:4] exchange ADC_I, ADC_Q datapath if Q channel is selected
    uint8_t regValue = (method == 1) ? 0b10000000 : 0b10010000;
    return WebRTLSDR_SetDemodReg(dev, 0, 0x06, regValue);
}

/* RTL2832U._maybeSetDirectSampling(), branch that turns direct sampling off
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/rtl2832u.ts#L347-L360
 * Changes:
 *   - tuner.open() (L348-L350) is replaced by RTL2832Device's tuner init and
 *     the demodulator settings RTL2832Device::detectTuner() applies for the
 *     R820T/R828D.
 *   - E4000: not in webrtlsdr, which has no E4000 support. Uses
 *     RTL2832Device's E4000 init and the zero-IF settings of
 *     RTL2832Device::initDemod().
 *   - The IF frequency (L351-L354) is set by the next tune, in
 *     RTL2832Device::setCenterFrequency().
 *   - Does not touch the RTL2832's AGC (L359), see above.
 *   - The caller re-applies the gain (L360). */
int WebRTLSDR_LeaveDirectSampling(RTL2832Device &dev)
{
    if (dev._tunerType == TunerType::r820t || dev._tunerType == TunerType::r828d) {
        if (auto r = dev.initTuner(); !r)
            return WebRTLSDR_Fail("tuner init", r.error());
        if (WebRTLSDR_SetDemodReg(dev, 1, 0xb1, 0x1a) != 0 ||     /* RTL2832Device: low-IF */
            WebRTLSDR_SetDemodReg(dev, 0, 0x08, 0x4d) != 0)       /* RTL2832Device: one ADC */
            return -1;
        // [0] inverted spectrum
        if (WebRTLSDR_SetDemodReg(dev, 1, 0x15, 0b00000001) != 0)
            return -1;
    } else if (dev._tunerType == TunerType::e4000) {
        if (auto r = dev.initE4kTuner(); !r)
            return WebRTLSDR_Fail("tuner init", r.error());
        if (WebRTLSDR_SetDemodReg(dev, 1, 0xb1, 0x1b) != 0 ||     /* RTL2832Device: zero-IF */
            WebRTLSDR_SetDemodReg(dev, 1, 0x15, 0x00) != 0)       /* RTL2832Device: not inverted */
            return -1;
    }
    // [5:4] default ADC_I, ADC_Q datapath
    return WebRTLSDR_SetDemodReg(dev, 0, 0x06, 0b10000000);
}

/* ===========================================================================
 * MARK: - src/rtlsdr/r8xx.ts
 * ======================================================================== */

/* R8xx.close(): R820T/R828D into standby
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r8xx.ts#L189-L212
 * Changes: opens the I2C repeater itself (the webrtlsdr caller does). */
int WebRTLSDR_R8xxClose(RTL2832Device &dev)
{
    auto gate = dev.i2cGate();
    if (!gate)
        return WebRTLSDR_Fail("openI2C", gate.error());
    // [7] power detector 1 off [6] power detector 3 off [5] filter gain [2:0] LNA power 1
    if (WebRTLSDR_WriteRegMask(dev, 0x06, 0b10110001, 0xff) != 0) return -1;
    // [7] loop through off [5] lna 1 power off [4] LNA gain manual [3:0] LNA gain 3
    if (WebRTLSDR_WriteRegMask(dev, 0x05, 0b10110011, 0xff) != 0) return -1;
    // [6] mixer power off [5] mixer normal current [4] mixer gain auto [3:0] mixer gain 10
    if (WebRTLSDR_WriteRegMask(dev, 0x07, 0b00111010, 0xff) != 0) return -1;
    // [7] mixer buffer power off [6] mixer buffer low current [5:0] image gain 0
    if (WebRTLSDR_WriteRegMask(dev, 0x08, 0b01000000, 0xff) != 0) return -1;
    // [7] IF filter off [6] IF filter low current [5:0] image phase 0
    if (WebRTLSDR_WriteRegMask(dev, 0x09, 0b11000000, 0xff) != 0) return -1;
    // [7] channel filter off [6:5] filter power 1 [3:0] filter bandwidth 6
    if (WebRTLSDR_WriteRegMask(dev, 0x0a, 0b00111010, 0xff) != 0) return -1;
    // [6] vga power off [4] vga controlled by pin [3:0] vga gain 5
    if (WebRTLSDR_WriteRegMask(dev, 0x0c, 0b00110101, 0xff) != 0) return -1;
    // [4] clock output on [1] internal agc clock on
    if (WebRTLSDR_WriteRegMask(dev, 0x0f, 0b01101000, 0xff) != 0) return -1;
    // [7:6] pll analog regulator off
    if (WebRTLSDR_WriteRegMask(dev, 0x11, 0b00000011, 0xff) != 0) return -1;
    // [7:6] pll digital regulator off [3] open drain high-Z
    if (WebRTLSDR_WriteRegMask(dev, 0x17, 0b11110100, 0xff) != 0) return -1;
    // [7] rf filter power off [4] agc pin = agc_in
    if (WebRTLSDR_WriteRegMask(dev, 0x19, 0b00001100, 0xff) != 0) return -1;
    return 0;
}

/* R8xx._setMux(), band filter registers
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r8xx.ts#L302-L316
 * Changes:
 *   - Opens the I2C repeater itself.
 *   - Writes only the three band filter registers (L311-L316) and runs
 *     after RTL2832Device::setCenterFrequency(), replacing the values its own
 *     multiplexer table gave them. RTL2832Device::setMux() has already
 *     written the remaining three registers (L317-L322) with the same
 *     values. */
int WebRTLSDR_R8xxSetMux(RTL2832Device &dev, double freq,
                         const WebRTLSDRMuxCfg *muxCfgs, size_t count)
{
    double freqMhz = freq / 1000000;
    size_t i;
    for (i = 0; i < count - 1; ++i) {
        if (freqMhz < muxCfgs[i + 1].freqMhz)
            break;
    }
    const WebRTLSDRMuxCfg &cfg = muxCfgs[i];

    auto gate = dev.i2cGate();
    if (!gate)
        return WebRTLSDR_Fail("openI2C", gate.error());
    // [3] open drain
    if (WebRTLSDR_WriteRegMask(dev, 0x17, cfg.openDrain, 0b00001000) != 0) return -1;
    // [7:6] tracking filter [1:0] RF filter
    if (WebRTLSDR_WriteRegMask(dev, 0x1a, cfg.rfMuxPoly, 0b11000011) != 0) return -1;
    // [7:4] LPNF [3:0] LPF
    if (WebRTLSDR_WriteRegMask(dev, 0x1b, cfg.tfC, 0b11111111) != 0) return -1;
    return 0;
}

/* ===========================================================================
 * MARK: - src/rtlsdr/r828d.ts
 * ======================================================================== */

/* MUX_CFGS_RTLSDRBLOGV4: RTL-SDR Blog V4 band filters
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r828d.ts#L98-L125
 * Changes: none besides the translation. */
const WebRTLSDRMuxCfg kWebRTLSDRMuxCfgsRtlSdrBlogV4[] = {
    {0, 0b0000, 0b00000010, 0b11011111},
    {2.2, 0b1000, 0b00000010, 0b11011111},
    {50, 0b1000, 0b00000010, 0b10111110},
    {55, 0b1000, 0b00000010, 0b10001011},
    {60, 0b1000, 0b00000010, 0b01111011},
    {65, 0b1000, 0b00000010, 0b01101001},
    {70, 0b1000, 0b00000010, 0b01011000},
    {75, 0b1000, 0b00000010, 0b01000100},
    {85, 0b0000, 0b00000010, 0b01000100},
    {90, 0b0000, 0b00000010, 0b00110100},
    {110, 0b0000, 0b00000010, 0b00100100},
    {112, 0b1000, 0b00000010, 0b00100100},
    {140, 0b1000, 0b00000010, 0b00010100},
    {172, 0b0000, 0b00000010, 0b00010100},
    {180, 0b0000, 0b00000010, 0b00010011},
    {242, 0b1000, 0b00000010, 0b00010011},
    {250, 0b1000, 0b00000010, 0b00010001},
    {280, 0b1000, 0b00000010, 0b00000000},
    {310, 0b1000, 0b01000001, 0b00000000},
    {588, 0b1000, 0b01000000, 0b00000000},
    //      ^       ^^    ^^    ^^^^^^^^
    //      |       ||    ||    ||||++++- LPF (0000: highest)
    //      |       ||    ||    ++++- LPNF (0000: highest)
    //      |       ||    ++- RF filter (00: high, 01: med, 10: low)
    //      |       ++- tracking filter (01: bypass)
    //      +- open drain (1: low Z)
};
const size_t kWebRTLSDRMuxCfgsRtlSdrBlogV4Count =
    sizeof(kWebRTLSDRMuxCfgsRtlSdrBlogV4) / sizeof(kWebRTLSDRMuxCfgsRtlSdrBlogV4[0]);

/* R828D.maybeInit(), RTL-SDR Blog V4 detection
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r828d.ts#L33
 * Changes: none besides the translation. */
bool WebRTLSDR_IsRtlSdrBlogV4(const char *manufacturer, const char *model)
{
    return strcmp(manufacturer, "RTLSDRBlog") == 0 && strcmp(model, "Blog V4") == 0;
}

/* R828D.setFrequency(), upconverter offset
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r828d.ts#L57-L60
 * Changes: returns the offset; the caller adds it to the tuner frequency. */
uint64_t WebRTLSDR_R828DUpconvert(bool isRtlSdrBlogV4, uint64_t freq)
{
    uint64_t upconvert = 0;
    if (isRtlSdrBlogV4 && freq < 28800000)
        upconvert = 28800000;
    return upconvert;
}

/* R828D.setFrequency(), input selection
 * https://github.com/jtarrio/webrtlsdr/blob/5699cec220cb0349e8f9144b7b71d3d03b5d9dbf/src/rtlsdr/r828d.ts#L62-L87
 * `input` holds the current input (webrtlsdr's this.input): 0 = air,
 * 1 = cable 1, 2 = cable 2, -1 = unknown.
 * Changes:
 *   - Opens the I2C repeater itself and writes the GPIO after closing it.
 *   - Updates `input` only after the registers were written.
 *   - The caller starts with -1 instead of webrtlsdr's 0, so the first tune
 *     always sets the input and the upconverter GPIO. */
int WebRTLSDR_R828DSelectInput(RTL2832Device &dev, bool isRtlSdrBlogV4, uint64_t freq, int *input)
{
    if (isRtlSdrBlogV4) {
        int in = freq <= 28800000 ? 2 : freq < 250000000 ? 1 : 0;
        if (*input != in) {
            {
                auto gate = dev.i2cGate();
                if (!gate)
                    return WebRTLSDR_Fail("openI2C", gate.error());
                if (in == 0) {
                    if (WebRTLSDR_WriteRegMask(dev, 0x06, 0x00, 0x08) != 0 ||
                        WebRTLSDR_WriteRegMask(dev, 0x05, 0x00, 0x60) != 0)
                        return -1;
                } else if (in == 1) {
                    if (WebRTLSDR_WriteRegMask(dev, 0x06, 0x00, 0x08) != 0 ||
                        WebRTLSDR_WriteRegMask(dev, 0x05, 0x60, 0x60) != 0)
                        return -1;
                } else {
                    if (WebRTLSDR_WriteRegMask(dev, 0x06, 0x08, 0x08) != 0 ||
                        WebRTLSDR_WriteRegMask(dev, 0x05, 0x20, 0x60) != 0)
                        return -1;
                }
            }
            // Turn the upconverter on or off.
            if (WebRTLSDR_SetGpioOutput(dev, 5) != 0 ||
                WebRTLSDR_SetGpioBit(dev, 5, in == 2 ? 0 : 1) != 0)
                return -1;
            *input = in;
        }
    } else {
        // Turn cable 1 LNA off above 345MHz, on below
        int in = freq > 345000000 ? 0 : 1;
        if (*input != in) {
            auto gate = dev.i2cGate();
            if (!gate)
                return WebRTLSDR_Fail("openI2C", gate.error());
            if (WebRTLSDR_WriteRegMask(dev, 0x05, in == 0 ? 0x00 : 0x60, 0x60) != 0)
                return -1;
            *input = in;
        }
    }
    return 0;
}
