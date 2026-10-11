# RTL-SDR (USB) for iPadOS


An unofficial USBDriverKit driver for RTL2832U-based RTL-SDR receivers on
iPadOS, packaged together with a host app that re-publishes the IQ stream
as an **rtl_tcp-compatible TCP server**. It allows iPadOS (iOS) to access the
RTL-SDR via USB without a jailbreak.
This project is not affiliated with Realtek or RTL-SDR Blog.

The driver itself is a regular DriverKit extension that matches RTL2832U-based
USB SDR receivers and programs them with the `RTL2832Device` driver from
[gnuradio4-blocks](https://github.com/gnuradio/gnuradio4-blocks) (MIT). The
host app opens an
`IOUserClient` to that extension, maps a shared-memory ring buffer to receive
the IQ samples, and serves them over the network so that existing SDR clients
on any device (SDR++, GQRX, SDRangel, CubicSDR, SDR#, …) can use the iPad's
RTL-SDR exactly as if it were attached to a PC running `rtl_tcp`. It also has
a built-in FM radio.

## Features

- Tuners: R820T / R820T2 / R860, R828D (including the RTL-SDR Blog V4 with
  its HF upconverter) and E4000. FC0012, FC0013 and FC2580 are not supported.
- Bias tee, direct sampling (I or Q branch) and frequency correction for
  both the sample clock and the tuner.
- USB control transfers and asynchronous bulk IQ streaming via
  `IOUSBHostInterface::DeviceRequest` and `IOUSBHostPipe::AsyncIO`.
- Shared-memory IQ ring buffer between the dext and the host app, mapped
  with `IOConnectMapMemory64`.
- rtl_tcp-compatible TCP server on port 1234, with the universal command set
  `0x01–0x0E` plus `0x0A` (offset tuning) implemented.
- Survives backgrounding the app: audio background mode + idle-timer disable
  keep the server running when the screen locks or another app is opened.
- FM broadcast radio in stereo with favorites, reception indicator, Lock
  Screen and Control Center controls and AirPlay / Bluetooth output. The
  demodulator is plain Swift on Accelerate.
- One-shot self-test that exercises the whole stack (USB → dext → ring
  buffer → app → IQ) and shows the result as a checklist, with the detailed
  log one tap away.

## Architecture

```
        ┌──────────────────────────────────────────────┐
        │   SDR client app (SDR++, GQRX, SDRangel, …) │
        │   on any device in the network              │
        └──────────────────────┬───────────────────────┘
                               │  rtl_tcp protocol (TCP/1234)
        ┌──────────────────────┴───────────────────────┐
        │   RTL-SDR Host  (iPadOS app)                 │
        │   • TCP server  • control commands  • UI    │
        └──────────────────────┬───────────────────────┘
                               │  IOUserClient (IOKit)
                               │  + shared-memory IQ ring buffer
        ┌──────────────────────┴───────────────────────┐
        │   RTL_SDR  (DriverKit extension)             │
        │   • gnuradio4-blocks RTL2832Device + shims   │
        │   • USB control + async bulk-IN streaming   │
        └──────────────────────┬───────────────────────┘
                               │  USB  (USBDriverKit)
        ┌──────────────────────┴───────────────────────┐
        │   RTL2832U + tuner  (RTL-SDR dongle)         │
        └──────────────────────────────────────────────┘
```

Inside the dext, device control runs on one dispatch queue and the bulk-IN
completions of the IQ stream on a second one, so IQ keeps flowing while a
control command waits for the tuner's I2C bus.

## Requirements

- iPad with USB-C & M(x)-Series SoC, iPadOS 16 or later (DriverKit on iPad).
- An RTL2832U-based RTL-SDR receiver (Realtek vendor ID `0x0BDA` / `3034`).
- Xcode with the DriverKit SDK installed.
- An Apple Developer account with the DriverKit capability enabled for the bundle identifier(s).

## Project layout

```
RTL-SDR/                            ← driver extension target
├── RTL_SDR.iig / RTL_SDR.cpp       USBDriverKit interface driver, IQ stream
├── RTL2832Radio.cpp / .h           user client commands on RTL2832Device
├── WebRTLSDRPort.cpp / .h          code ported from webrtlsdr (Apache-2.0)
├── RTL_SDR_DEV.iig / .cpp          device-level driver (matching only)
├── RTL_SDR_UserClient.iig / .cpp   IOUserClient for the host app
├── Info.plist                      USB matching + UserClientProperties
├── RTL-SDR.entitlements            driverkit / transport.usb
└── include/RTLSDRShared.h          dext ↔ app IPC contract

Shim/                               ← platform layer for RTL2832Device (dext)
├── usb_driverkit.cpp / .h          USB transport on USBDriverKit
└── include/
    ├── print                       std::println → os_log
    └── gnuradio-4.0/common/
        └── USBDevice.hpp           upstream's USB interface on usb_driverkit

third_party/gnuradio4-blocks/       ← upstream gnuradio4-blocks (git submodule)
third_party/LICENSE.webrtlsdr       Apache-2.0 text for the webrtlsdr port

RTL-SDR Host/                       ← host application target
├── RTLSDRHostApp.swift             SwiftUI app, sidebar / tab layout
├── ReceiverModel.swift             device state; radio, server and test share it
├── Views/                          Radio, Network, Diagnostics, About + licenses
├── Radio/
│   ├── FMDemodulator.swift         IQ → stereo FM audio (Accelerate)
│   ├── FMReceiver.swift            device control, audio output, clock drift
│   └── NowPlaying.swift            Lock Screen / Control Center
├── RTLSDRClient.swift              wraps the IOKit user client
├── RTLTCPServer.swift              rtl_tcp-compatible NWListener server
├── BackgroundAudioKeeper.swift     audio-mode keep-alive
├── RTLSDRBridge.h / .c             C bridge: IOKit ↔ Swift
├── RTL-SDR-Host-Bridging-Header.h
├── RTLSDRShared.h                  copy of the dext IPC contract
├── Info.plist                      UIBackgroundModes=audio + usage strings
├── PrivacyInfo.xcprivacy           privacy manifest (UserDefaults: CA92.1)
├── RTL-SDR Host.entitlements       communicates-with-drivers
└── Assets / LaunchScreen.storyboard
```

## Build & install

1. **Clone with the submodule.** `git clone --recursive <repo>`, or
   `git submodule update --init` in an existing checkout.
2. **Pick your bundle IDs.** On iPadOS the dext bundle ID **must** start with
   the app's bundle ID, e.g. `com.example.rtlsdrhost` (app) and
   `com.example.rtlsdrhost.driver` (dext). Update the bundle IDs throughout
   the project (`Info.plist`, signing settings, `Create(this, "UserClient­
   Properties", …)` lookup name stays as-is).
3. **Enable DriverKit Capabilities** in your Apple Developer Account.
   For this project:
   - DriverKit
   - USB Transport, vendor ID `3034` (`0x0BDA`, Realtek)
   - UserClient Access for the dext bundle ID
     (e.g. `com.example.rtlsdrhost.driver`)
4. **Open in Xcode** and verify on the host-app target:
   - Bridging header: `RTL-SDR Host/RTL-SDR-Host-Bridging-Header.h`
   - Linked frameworks: `IOKit.framework` (explicit), `AVFoundation`
     (auto-linked through `import AVFoundation`), `Network` (auto-linked).
   - Entitlement: `com.apple.developer.driverkit.communicates-with-drivers`
   - `Info.plist`: `UIBackgroundModes = [audio]`,
     `NSLocalNetworkUsageDescription`.
5. **Build & run** the host-app target on a real iPad. The embedded dext is
   installed automatically. Next go to Settings -> Apps -> RTL-SDR-Host and enable the driver.
   When you change the dext, bump the build number (`CURRENT_PROJECT_VERSION`)
   before reinstalling. iPadOS keeps running its staged copy of the dext
   while the version stays the same. Replug the RTL-SDR afterwards.
6. Plug in the RTL-SDR. The dext matches the USB device and starts. You may run the connection test under Diagnostics in the RTL-SDR-Host app. The iPad
   console also shows lines like

   ```
   RTL_SDR::Start
   [RTL2832] found R820T/R820T2/R860 tuner
   RTL_SDR: started, tuner type = 5
   ```

## Usage

The app has four sections:

- **Radio.** An FM broadcast receiver. Tune with the scale (drag it), the
  arrow buttons or a favorite; the star saves the current station. Playback
  continues in the background and shows up on the Lock Screen and in Control
  Center, whose track buttons switch between favorites. The bars show the
  reception quality, estimated from how much the signal's envelope fluctuates
  (an FM signal's is constant). Stereo blends to mono as the reception gets
  weak. The options menu switches stereo off and sets the de-emphasis (50 µs,
  or 75 µs in the Americas and South Korea; picked from the region by
  default).
- **Network.** Turns on the rtl_tcp-compatible TCP server on port `1234` and
  shows the iPad's Wi-Fi address(es), each with a copy button. In any SDR
  client, add an rtl_tcp source pointing at `<iPad-IP>:1234`, or at
  `127.0.0.1:1234` for an SDR app on the same iPad. Streaming, frequency /
  sample-rate / gain / bias-T / direct-sampling control all work over the
  network in real time, just like a PC `rtl_tcp` instance. The section also
  shows the connected client with the frequency and sample rate it set; every
  command is listed under Activity.
- **Diagnostics.** The receiver's tuner and driver version, and the
  connection test: it opens the user client, fetches the device info,
  configures the device, streams for one second and reports whether IQ bytes
  arrived in the shared ring buffer. A health check for the whole pipeline.
- **About.** Version, source code and the licenses of all components. The
  texts are the repository's `LICENSE`, `NOTICE` and third-party license
  files, copied into the app bundle by the "Copy Licenses" build phases.

The radio, the server and the test share the receiver, so only one of them
runs at a time.

While the server is running the app stays alive in the background (audio
background mode + auto-lock disabled), so switching to another app or letting
the screen turn off does not interrupt the stream.

### How the radio works

The radio tunes the RTL-SDR 240 kHz (a quarter of the sample rate) above the
station, so the tuner's DC spike and IQ image stay out of the channel, and
samples at 960 kS/s. `FMDemodulator` shifts the station to 0 Hz and filters
the channel in one complex FIR filter (the shift by fs/4 folds into the taps
because the filter keeps every 4th sample) and demodulates at 240 kS/s.
From the multiplex it

- locks a PLL to the 19 kHz pilot and demodulates L−R with the coherent
  38 kHz subcarrier (the standard puts the zero crossings of pilot and
  subcarrier together). L−R gets 4 % more gain, the loss of the phase
  discriminator at 38 kHz; without that the separation stops at about
  33 dB, with it it reaches 56 dB on test signals. Between 28 and 18 dB
  carrier-to-noise ratio the audio blends to mono;
- resamples, low-pass filters both channels to 48 kHz and applies the
  de-emphasis.

The RTL-SDR's crystal and the audio hardware run on different clocks. The
audio buffer between them is held at about 150 ms by stretching the signal by
up to ±0.1 % in the resampler, which runs on the 240 kS/s signal where the
interpolation is practically flat across the audio band.

## Porting notes (`RTL2832Device` → USBDriverKit)

`RTL2832Device.hpp` (`blocks/sdr` in gnuradio4-blocks) is compiled from
`third_party/gnuradio4-blocks` without a single change. It is C++23 and
header-only; DriverKit's libc++ provides everything it uses except output to
stdout / stderr. `Shim/include` comes first in the header search path and
supplies the two missing pieces:

- **USB** (`USBDevice.hpp`, `usb_driverkit.cpp`). Upstream's USB interface
  (`controlOut`, `controlIn`, `bulkRead`, …) on the `IOUSBHostInterface` the
  dext was matched to. Control transfers go through
  `IOUSBHostInterface::DeviceRequest`. Device discovery is left to the IOKit
  personalities, so `enumerateUSBDevices()` reports the matched device.
- **`<print>`**. `std::println` writes to `os_log`.

`RTL2832Radio.cpp` maps the user client commands onto `RTL2832Device` with
`librtlsdr`'s semantics, so the API in `RTLSDRShared.h` is unchanged. It also
corrects the tuner frequency for the crystal's ppm error, which
`RTL2832Device` only does for the sample clock. What else `RTL2832Device`
does not do itself (bias tee, direct sampling, tuner standby, R828D input
switching, the RTL-SDR Blog V4's upconverter) is ported from
[webrtlsdr](https://github.com/jtarrio/webrtlsdr) (Apache-2.0) and works
through `RTL2832Device`'s public register access functions. All of that code
is in `WebRTLSDRPort.cpp`; each function there links to the exact webrtlsdr
lines it comes from and lists what was changed.

The IQ stream does not go through `RTL2832Device`: the dext keeps 32 bulk-IN
transfers of 32 KiB in flight with `IOUSBHostPipe::AsyncIO` and copies each
completion into the ring buffer. Buffers and `OSAction`s live from `Start` to
`Stop`; on teardown the dext waits until every aborted transfer has come back
before it releases them.

Updating `RTL2832Device` is a matter of moving the submodule to a newer
commit. If upstream starts using another platform function, the build fails
and the shim gets one more piece.

The dext exposes the device to the host app through an
`IOUserClient` with a small scalar-method API (`kRTLSDRMethod*` in
`RTLSDRShared.h`) plus a 2 MiB shared-memory IQ ring buffer mapped via
`IOConnectMapMemory64`.

## rtl_tcp protocol coverage

| Command id | Function                           | Status                                |
|-----------:|------------------------------------|---------------------------------------|
| `0x01`     | Set frequency                      | implemented                           |
| `0x02`     | Set sample rate                    | implemented                           |
| `0x03`     | Set tuner gain mode (auto/manual)  | implemented                           |
| `0x04`     | Set tuner gain (0.1 dB)            | implemented                           |
| `0x05`     | Set frequency correction (ppm)     | implemented                           |
| `0x06`     | Set IF stage gain                  | accepted, not yet mapped              |
| `0x07`     | Set test mode                      | implemented                           |
| `0x08`     | Set RTL2832 digital AGC            | implemented                           |
| `0x09`     | Set direct sampling                | implemented                           |
| `0x0A`     | Set offset tuning                  | implemented (no-op on R820T/R828D)\*  |
| `0x0B`     | Set RTL crystal                    | accepted, not yet mapped              |
| `0x0C`     | Set tuner crystal                  | accepted, not yet mapped              |
| `0x0D`     | Set tuner gain by index            | implemented                           |
| `0x0E`     | Set bias-T                         | implemented                           |

\* Offset tuning returns `-2`, as `librtlsdr` does for R820T/R828D — these
tuners do not support it. Same behaviour as upstream `rtl_tcp`.

## Status and known limitations

- Verified on hardware with an R820T2 dongle: streaming, tuning, auto and
  manual gain, RTL AGC, rtl_tcp clients (welle.io with DAB+, FM) and
  unplugging / replugging while streaming. E4000, R828D, the RTL-SDR Blog V4,
  direct sampling and the bias tee are not verified yet.
- Only one TCP client at a time is served. A new connection replaces the
  current one, so a client that vanished without closing its socket cannot
  block reconnects.
- RTL-SDR Blog V4 detection (via the USB manufacturer / product strings) is
  implemented but not yet verified on V4 hardware.
- The tuner's IF filter stays at the width `RTL2832Device` sets up; tuner
  bandwidth requests are accepted but have no effect.
- The dext cannot write files (DriverKit sandbox). Any IQ recording feature
  has to live in the host app, consuming the same ring buffer.

## License

Copyright 2026 Arved Viehweger.

Licensed under the **Apache License, Version 2.0** (`LICENSE`). Whoever
passes the code on, modified or not, has to include the license and the
attribution notices in `NOTICE`.

Exception: `RTLSDRShared.h`, the API between the driver extension and apps,
is under the **MIT License** (text in the file), so that apps talking to the
driver can include it freely.

Third-party code in the driver extension:

- `RTL2832Device` from [gnuradio4-blocks](https://github.com/gnuradio/gnuradio4-blocks)
  (`third_party/gnuradio4-blocks`, unmodified), **MIT License**.
- `RTL-SDR/WebRTLSDRPort.cpp` is ported from
  [webrtlsdr](https://github.com/jtarrio/webrtlsdr), Copyright 2024 Jacobo
  Tarrío Barreiro and 2013 Google Inc., **Apache License 2.0**
  (`third_party/LICENSE.webrtlsdr`). No other file contains webrtlsdr code.

## Acknowledgements

- The GNU Radio 4 authors and FAIR for `RTL2832Device` in
  [gnuradio4-blocks](https://github.com/gnuradio/gnuradio4-blocks), and
  Jacobo Tarrío for [webrtlsdr](https://github.com/jtarrio/webrtlsdr) and
  google/radioreceiver, which it is based on.
- The [Osmocom rtl-sdr](https://osmocom.org/projects/rtl-sdr/wiki) project and
  the `librtlsdr` authors, whose reverse engineering every RTL-SDR driver
  builds on.
- Apple's USBDriverKit, IOKit, Network, AVFoundation, Accelerate and
  MediaPlayer frameworks, and the
  WWDC '22 "Bring your driver to iPad with DriverKit" session that made any
  of this possible on iPadOS.
- DanBurkhardt's
  [DriverKitUserClientSample](https://github.com/DanBurkhardt/DriverKitUserClientSample),
  a useful reference for the host-app side of iPadOS DriverKit.
