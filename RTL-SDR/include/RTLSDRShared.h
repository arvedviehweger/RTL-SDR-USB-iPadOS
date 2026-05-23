//
//  RTLSDRShared.h
//  RTL-SDR
//
//  Shared contract between the DriverKit extension (RTL_SDR_UserClient) and
//  the iPadOS host application (e.g. the Swift rtl_tcp server).
//
//  This header is intentionally plain C so it can be included from the dext
//  (C++), from a C client and from Swift via a bridging header.
//

#ifndef RTLSDR_SHARED_H
#define RTLSDR_SHARED_H

#include <stdint.h>

/* ---------------------------------------------------------------------------
 * External method selectors.
 * The host app invokes these with IOConnectCallScalarMethod() /
 * IOConnectCallStructMethod() on the connection returned by IOServiceOpen().
 * ------------------------------------------------------------------------- */
enum {
    kRTLSDRMethodStartStream       = 0,  /* no args                                   */
    kRTLSDRMethodStopStream        = 1,  /* no args                                   */
    kRTLSDRMethodSetCenterFreq     = 2,  /* scalarInput[0] = frequency in Hz          */
    kRTLSDRMethodSetSampleRate     = 3,  /* scalarInput[0] = sample rate in Hz        */
    kRTLSDRMethodSetTunerGainMode  = 4,  /* scalarInput[0] = 1 manual / 0 automatic   */
    kRTLSDRMethodSetTunerGain      = 5,  /* scalarInput[0] = gain in tenth dB         */
    kRTLSDRMethodSetAgcMode        = 6,  /* scalarInput[0] = 1 on / 0 off             */
    kRTLSDRMethodSetFreqCorrection = 7,  /* scalarInput[0] = ppm (reinterpret int32)  */
    kRTLSDRMethodSetTunerBandwidth = 8,  /* scalarInput[0] = bandwidth in Hz          */
    kRTLSDRMethodSetTestmode       = 9,  /* scalarInput[0] = 1 on / 0 off             */
    kRTLSDRMethodSetDirectSampling = 10, /* scalarInput[0] = 0 off / 1 I-ADC / 2 Q    */
    kRTLSDRMethodSetBiasTee        = 11, /* scalarInput[0] = 1 on / 0 off             */
    kRTLSDRMethodResetBuffer       = 12, /* no args                                   */
    kRTLSDRMethodSetGainByIndex    = 13, /* scalarInput[0] = index into the gain list */
    kRTLSDRMethodGetTunerType      = 14, /* scalarOutput[0] = enum rtlsdr_tuner       */
    kRTLSDRMethodGetDeviceInfo     = 15, /* structOutput   = RTLSDRDeviceInfo         */
    kRTLSDRMethodCount
};

/* ---------------------------------------------------------------------------
 * Memory types for IOConnectMapMemory64() / CopyClientMemoryForType().
 * ------------------------------------------------------------------------- */
enum {
    kRTLSDRMemoryTypeIQRing = 0          /* the shared IQ ring buffer */
};

/* ---------------------------------------------------------------------------
 * Shared IQ ring buffer.
 *
 * Single producer (the dext, on its streaming dispatch queue) and single
 * consumer (the host app). Samples are 8-bit unsigned interleaved I/Q exactly
 * as the RTL2832U delivers them - the same bytes rtl_tcp forwards verbatim.
 *
 * writeCount / readCount are free-running 64-bit byte counters; the modulo
 * into data[] is (count % dataSize). The number of bytes available to read is
 * (writeCount - readCount). The app must keep up; otherwise the producer
 * advances readCount and accounts the loss in dropCount.
 * ------------------------------------------------------------------------- */
#define RTLSDR_RING_DATA_SIZE   (2u * 1024u * 1024u)   /* 2 MiB payload */

typedef struct RTLSDRRingBuffer {
    volatile uint64_t writeCount;   /* total bytes ever produced by the dext   */
    volatile uint64_t readCount;    /* total bytes ever consumed by the app    */
    volatile uint64_t dropCount;    /* total bytes dropped (consumer too slow) */
    uint64_t          dataSize;     /* always RTLSDR_RING_DATA_SIZE            */
    uint8_t           data[RTLSDR_RING_DATA_SIZE];
} RTLSDRRingBuffer;

/* ---------------------------------------------------------------------------
 * Device information returned by kRTLSDRMethodGetDeviceInfo.
 * ------------------------------------------------------------------------- */
typedef struct RTLSDRDeviceInfo {
    uint32_t valid;                 /* 1 if the device is open and usable      */
    uint32_t tunerType;             /* enum rtlsdr_tuner                       */
    uint32_t sampleRate;            /* current sample rate in Hz               */
    uint32_t streaming;             /* 1 while IQ streaming is active           */
    char     manufacturer[256];
    char     product[256];
} RTLSDRDeviceInfo;

#endif /* RTLSDR_SHARED_H */
