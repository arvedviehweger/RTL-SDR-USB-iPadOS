# Talking to the RTLBridge driver from your own app

`RTLSDRShared.h` is the complete contract between the RTLBridge DriverKit
extension (dext) and any app that wants to use an RTL-SDR on iPadOS. With it,
your app can tune the receiver, change gain and sample rate, and read the raw
IQ samples straight from shared memory, without going through the rtl_tcp
server.

The header is plain C and, like the rest of the project, licensed under the
**Apache License 2.0**. You can copy it into your app, open or closed
source; see [License](#license) for what that requires.

## How it works

```
 your app                                    RTLBridge dext
 ────────                                    ──────────────
 IOServiceOpen("RTL_SDR")  ───────────────▶  RTL_SDR_UserClient
 IOConnectCallScalarMethod(kRTLSDRMethod*) ▶ tunes / configures the RTL2832U
 IOConnectMapMemory64(kRTLSDRMemoryTypeIQRing)
        ◀──────── RTLSDRRingBuffer (2 MiB, shared memory) ◀── USB bulk IQ
```

1. The dext matches the RTL-SDR on USB and registers an IOKit service named
   **`RTL_SDR`**.
2. Your app opens a user-client connection to that service.
3. Control commands are **external methods**: one selector from the
   `kRTLSDRMethod*` enum, at most one scalar argument.
4. IQ samples arrive in a **shared ring buffer** that you map into your
   process once and then poll.

## Requirements

- **iPadOS 26 or later** on an iPad with a USB-C port (DriverKit support).
- **RTLBridge must be installed** on the iPad, and the user must have enabled
  its driver under *Settings → Apps → RTLBridge*. The dext ships inside
  RTLBridge; your app does not bundle a driver.
- A supported receiver: USB ID `0x0BDA:0x2838` or `0x0BDA:0x2832` (RTL2832U), e.g. the
  RTL-SDR Blog V3/V4 and most generic R820T/R828D/E4000 dongles.
- Your app needs the entitlement
  `com.apple.developer.driverkit.communicates-with-drivers` set to `true`.
  It has to be requested from Apple and must be in your provisioning profile.
  The dext already allows third-party clients
  (`com.apple.developer.driverkit.allow-third-party-userclients`).

## Adding the header

Copy `RTLSDRShared.h` into your project.

- **C / Objective-C:** `#include "RTLSDRShared.h"`.
- **Swift:** add it to your bridging header (or a module map). The IOKit
  calls themselves are awkward from Swift on iPadOS, so the easiest route is a
  small C file that wraps them, as RTLBridge does in
  [`RTLSDRBridge.c`](../../RTL-SDR%20Host/RTLSDRBridge.c) /
  [`RTLSDRBridge.h`](../../RTL-SDR%20Host/RTLSDRBridge.h). You may copy those
  too, under the same terms as the header.

## Step by step

### 1. Find the service and open a connection

```c
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include "RTLSDRShared.h"

io_connect_t rtlsdr_open(void)
{
    io_service_t service = IOServiceGetMatchingService(
        0 /* default main port */, IOServiceNameMatching("RTL_SDR"));
    if (service == IO_OBJECT_NULL)
        return IO_OBJECT_NULL;          /* no dongle, or driver not enabled */

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return (kr == KERN_SUCCESS) ? conn : IO_OBJECT_NULL;
}
```

Match the name **exactly** `"RTL_SDR"`. There is also an `RTL_SDR_DEV`
service (the device-level driver); it has no user client.

To react to the dongle being plugged in or removed, register
`IOServiceAddMatchingNotification` for `kIOMatchedNotification` and
`kIOTerminatedNotification` with the same matching dictionary
(see `rtlsdrhost_watch_service` in `RTLSDRBridge.c`).

### 2. Send commands

Every command takes zero or one 64-bit scalar input. A helper:

```c
static kern_return_t rtlsdr_call(io_connect_t c, uint32_t sel,
                                 uint64_t arg, uint64_t *out)
{
    uint64_t in[1] = { arg }, res[1] = { 0 };
    uint32_t resCount = 1;
    kern_return_t kr = IOConnectCallScalarMethod(c, sel, in, 1, res, &resCount);
    if (out) *out = resCount ? res[0] : 0;
    return kr;
}

rtlsdr_call(c, kRTLSDRMethodSetSampleRate,    2048000,   NULL);
rtlsdr_call(c, kRTLSDRMethodSetCenterFreq,    100000000, NULL);   /* 100 MHz */
rtlsdr_call(c, kRTLSDRMethodSetTunerGainMode, 1,         NULL);   /* manual */
rtlsdr_call(c, kRTLSDRMethodSetTunerGain,     (uint64_t)(int64_t)297, NULL); /* 29.7 dB */
```

### 3. Map the IQ ring buffer

```c
mach_vm_address_t addr = 0;
mach_vm_size_t    size = 0;
kern_return_t kr = IOConnectMapMemory64(c, kRTLSDRMemoryTypeIQRing,
                                        mach_task_self(), &addr, &size,
                                        kIOMapAnywhere);
RTLSDRRingBuffer *ring = (RTLSDRRingBuffer *)(uintptr_t)addr;
/* ring->dataSize == RTLSDR_RING_DATA_SIZE */
```

The mapping stays valid until you close the connection or the dongle goes
away.

### 4. Start streaming and read samples

```c
rtlsdr_call(c, kRTLSDRMethodResetBuffer, 0, NULL);
rtlsdr_call(c, kRTLSDRMethodStartStream, 0, NULL);

uint64_t cursor = ring->writeCount;          /* skip any old backlog */
ring->readCount = cursor;

for (;;) {
    uint64_t w = __atomic_load_n(&ring->writeCount, __ATOMIC_ACQUIRE);
    uint64_t avail = w - cursor;
    if (avail == 0) { usleep(10000); continue; }   /* nothing new yet */

    if (avail > ring->dataSize) {                  /* we were lapped */
        cursor = w - ring->dataSize;
        avail  = ring->dataSize;
    }

    uint64_t off   = cursor % ring->dataSize;
    uint64_t first = ring->dataSize - off;
    if (first > avail) first = avail;
    process(ring->data + off, first);              /* your DSP */
    if (avail > first)
        process(ring->data, avail - first);        /* wrapped part */

    cursor += avail;
    __atomic_store_n(&ring->readCount, cursor, __ATOMIC_RELEASE);
}
```

When you are done:

```c
rtlsdr_call(c, kRTLSDRMethodStopStream, 0, NULL);
IOConnectUnmapMemory64(c, kRTLSDRMemoryTypeIQRing, mach_task_self(), addr);
IOServiceClose(c);
```

## The ring buffer in detail

| Field        | Written by | Meaning                                              |
|--------------|------------|------------------------------------------------------|
| `writeCount` | dext       | Total bytes ever produced. Updated *after* the data is copied, so everything below it is valid. |
| `readCount`  | app        | Total bytes you have consumed. Tells the dext how much room is left. |
| `dropCount`  | dext       | Total bytes the dext had to overwrite because you were too slow. |
| `dataSize`   | dext       | Always `RTLSDR_RING_DATA_SIZE` (2 MiB).              |
| `data[]`     | dext       | Sample payload; index with `count % dataSize`.       |

- The counters are **free-running 64-bit byte counts**, never reset while the
  dext is loaded. Available bytes are `writeCount - readCount`.
- Samples are **8-bit unsigned, interleaved I/Q** (`I0 Q0 I1 Q1 …`), exactly
  what the RTL2832U delivers and what `rtl_tcp` sends. Convert with
  `(x - 127.5f) / 127.5f`. One complex sample is 2 bytes.
- 2 MiB is about **0.5 s at 2.048 MS/s**. If you fall further behind, the dext
  pushes `readCount` forward and adds the lost bytes to `dropCount`. Keep your
  own cursor (as above) instead of trusting `readCount`, and treat
  `writeCount - cursor > dataSize` as "lapped".
- Do the heavy DSP off the reading thread: copy out, publish `readCount`,
  then process.
- There is **one ring per dongle**, shared by every open connection. Only one
  consumer should read at a time, so don't run your app's stream while the
  RTLBridge server or radio is streaming.

## Command reference

All selectors use `IOConnectCallScalarMethod` with one scalar input (use `0`
where none is needed), except `GetDeviceInfo`. Commands return
`kIOReturnSuccess` or `kIOReturnError` if the tuner rejected the value, and
`kIOReturnNotReady` if the dongle is gone.

| Selector | Argument | Notes |
|---|---|---|
| `kRTLSDRMethodStartStream` (0) | – | Starts USB bulk transfers into the ring. |
| `kRTLSDRMethodStopStream` (1) | – | Stops streaming. |
| `kRTLSDRMethodSetCenterFreq` (2) | frequency in Hz | |
| `kRTLSDRMethodSetSampleRate` (3) | rate in Hz | Valid: 225 001–300 000 Hz or 900 001–3 200 000 Hz (as librtlsdr). Above ~2.4 MS/s the USB link may drop samples. |
| `kRTLSDRMethodSetTunerGainMode` (4) | `1` manual, `0` auto | Must be manual for `SetTunerGain`. |
| `kRTLSDRMethodSetTunerGain` (5) | gain in tenths of a dB | Signed; cast through `int64_t`. Takes effect in manual mode only. |
| `kRTLSDRMethodSetAgcMode` (6) | `1` on, `0` off | RTL2832U digital AGC. |
| `kRTLSDRMethodSetFreqCorrection` (7) | ppm | Signed `int32` in the low 32 bits. Setting the value it already has returns `kIOReturnError` (like librtlsdr's `-2`); treat that as harmless. |
| `kRTLSDRMethodSetTunerBandwidth` (8) | Hz | Accepted for librtlsdr compatibility, but currently ignored: the IF filter stays at its default. |
| `kRTLSDRMethodSetTestmode` (9) | `1` on, `0` off | Counter pattern instead of samples. |
| `kRTLSDRMethodSetDirectSampling` (10) | `0` off, `1` I-ADC, `2` Q-ADC | HF reception on supported dongles. |
| `kRTLSDRMethodSetBiasTee` (11) | `1` on, `0` off | Powers an LNA over the antenna port. |
| `kRTLSDRMethodResetBuffer` (12) | – | Flushes the dongle's FIFO. Call before `StartStream`. |
| `kRTLSDRMethodSetGainByIndex` (13) | index | rtl_tcp-style index into the tuner's gain table. |
| `kRTLSDRMethodGetTunerType` (14) | – | `scalarOutput[0]`: `1` E4000, `5` R820T, `6` R828D, `0` unknown (librtlsdr `enum rtlsdr_tuner`). |
| `kRTLSDRMethodGetDeviceInfo` (15) | – | Struct output, see below. |
| `kRTLSDRMethodSetOffsetTuning` (16) | `1` on, `0` off | |

### Device info

```c
RTLSDRDeviceInfo info;
size_t size = sizeof(info);
kern_return_t kr = IOConnectCallStructMethod(c, kRTLSDRMethodGetDeviceInfo,
                                             NULL, 0, &info, &size);
if (kr == KERN_SUCCESS && info.valid)
    printf("%s %s, dext %s\n", info.manufacturer, info.product, info.dextVersion);
```

`dextVersion` (`"version (build)"`, e.g. `"1.0 (17)"`) is empty on older dexts. Use it if you
depend on behaviour added in a newer RTLBridge.

## Compatibility

New selectors and struct fields are added at the end; existing numbers and
offsets are not changed, so a header copied today keeps working with newer
dexts. An older dext answers unknown selectors with `kIOReturnBadArgument`;
use `info.dextVersion` to check for a minimum version.

## Troubleshooting

- **`IOServiceGetMatchingService` returns nothing:** the dongle is not plugged
  in, RTLBridge is not installed, or its driver is not enabled in Settings.
- **`IOServiceOpen` fails:** your app is missing the
  `communicates-with-drivers` entitlement, or the profile doesn't include it.
- **`writeCount` never moves after `StartStream`:** another app stopped the
  stream, or the dongle was unplugged. Check `info.streaming`.
- **`dropCount` keeps growing:** your read loop is too slow; poll more often
  or move processing off the reading thread.
- The dext logs every start/stop to the unified log under the `[rtlsdr]`
  prefix (Console.app, connected iPad).

## License

`RTLSDRShared.h`, the code samples in this README and `RTLSDRBridge.c/.h` are
licensed under the [Apache License, Version 2.0](../../LICENSE). If you ship
an app that contains them (in source or compiled form), you have to:

- include a copy of the Apache License 2.0, for example on your app's
  licenses / acknowledgements screen,
- keep the copyright and license notice at the top of any file you copy,
- mark files you changed as modified, and
- reproduce the attribution notices from [`NOTICE`](../../NOTICE) that apply
  to what you copied (for the header alone: "Copyright 2026 Arved Viehweger").

Your own code that merely includes the header can use any license.
