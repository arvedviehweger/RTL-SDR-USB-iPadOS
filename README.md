# RTL-SDR (USB) for iPadOS


A unofficial USBDriverKit port of [`librtlsdr`](https://github.com/librtlsdr/librtlsdr)
for iPadOS, packaged together with a host app that re-publishes the IQ stream
as an **rtl_tcp-compatible TCP server**. The port of `librtlsdr` to USBDriverKit 
finally allows iPadOS (iOS) to access the RTL-SDR via USB without a jailbreak.
This project is not affiliated with Realtek or RTL-SDR Blog.

The driver itself is a regular DriverKit extension that matches RTL2832U-based
USB SDR receivers and runs the `librtlsdr` core. The host app opens an
`IOUserClient` to that extension, maps a shared-memory ring buffer to receive
the IQ samples, and serves them over the network so that existing SDR clients
on any device (SDR++, GQRX, SDRangel, CubicSDR, SDR#, …) can use the iPad's
RTL-SDR exactly as if it were attached to a PC running `rtl_tcp`.

`librtlsdr` is built **unmodified** from upstream, included as a git
submodule. The dext supplies the platform underneath it instead: small shims
that implement the parts of libusb, pthreads and libc that `librtlsdr` uses on
top of USBDriverKit and DriverKit.

Verified to work with R820T2 & E4000 tuners.

## Features

- All upstream tuner support: R820T / R820T2, R828D, E4000, FC0012, FC0013,
  FC2580, straight from upstream `librtlsdr`.
- USB control transfers and asynchronous bulk IQ streaming via
  `IOUSBHostInterface::DeviceRequest` and `IOUSBHostPipe::AsyncIO`.
- Shared-memory IQ ring buffer between the dext and the host app, mapped
  with `IOConnectMapMemory64`.
- rtl_tcp-compatible TCP server on port 1234, with the universal command set
  `0x01–0x0E` plus `0x0A` (offset tuning) implemented.
- Survives backgrounding the app: audio background mode + idle-timer disable
  keep the server running when the screen locks or another app is opened.
- One-shot self-test that exercises the whole stack (USB → dext → ring
  buffer → app → IQ) and prints results to an on-screen log.

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
        │   • upstream librtlsdr + DriverKit shims     │
        │   • USB control + async bulk-IN streaming   │
        └──────────────────────┬───────────────────────┘
                               │  USB  (USBDriverKit)
        ┌──────────────────────┴───────────────────────┐
        │   RTL2832U + tuner  (RTL-SDR dongle)         │
        └──────────────────────────────────────────────┘
```

Inside the dext, device control runs on one dispatch queue and the libusb
event loop of `rtlsdr_read_async()` on a second one, the same split as
upstream's control thread and async thread. `librtlsdr`'s own I2C mutex
coordinates the two.

## Requirements

- iPad with USB-C & M(x)-Series SoC, iPadOS 16 or later (DriverKit on iPad).
- An RTL2832U-based RTL-SDR receiver (Realtek vendor ID `0x0BDA` / `3034`).
- Xcode with the DriverKit SDK installed.
- An Apple Developer account with the DriverKit capability enabled for the bundle identifier(s).

## Project layout

```
RTL-SDR/                            ← driver extension target
├── RTL_SDR.iig / RTL_SDR.cpp       USBDriverKit interface driver
├── RTL_SDR_DEV.iig / .cpp          device-level driver (matching only)
├── RTL_SDR_UserClient.iig / .cpp   IOUserClient for the host app
├── Info.plist                      USB matching + UserClientProperties
├── RTL-SDR.entitlements            driverkit / transport.usb
└── include/RTLSDRShared.h          dext ↔ app IPC contract

Shim/                               ← platform layer for librtlsdr (dext)
├── libusb_driverkit.cpp / .h       libusb on USBDriverKit
├── pthread_driverkit.cpp           pthreads on IOLock / IODispatchQueue
├── libc_driverkit.cpp              malloc, fprintf → os_log, usleep, …
└── include/                        stand-ins for <libusb.h>, <pthread.h>,
                                    <stdio.h>, … and rtl_app_ver.h

third_party/librtlsdr/              ← upstream librtlsdr (git submodule)

RTL-SDR Host/                       ← host application target
├── ViewController.swift            UI (test button, rtl_tcp server)
├── RTLSDRClient.swift              wraps the IOKit user client
├── RTLTCPServer.swift              rtl_tcp-compatible NWListener server
├── BackgroundAudioKeeper.swift     audio-mode keep-alive
├── RTLSDRBridge.h / .c             C bridge: IOKit ↔ Swift
├── RTL-SDR-Host-Bridging-Header.h
├── RTLSDRShared.h                  copy of the dext IPC contract
├── Info.plist                      UIBackgroundModes=audio + usage strings
├── RTL-SDR Host.entitlements       communicates-with-drivers
└── AppDelegate / SceneDelegate / Assets / Main.storyboard
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
6. Plug in the RTL-SDR. The dext matches the USB device and starts. You may use the "Test Connection" feature of the RTL-SDR-Host app. The iPad
   console also shows lines like

   ```
   RTL_SDR::Start
   RTL_SDR: started, tuner type = 5
   [rtlsdr] Found Rafael Micro R820T/2 tuner
   ```

## Usage

The app has two actions:

- **Test connection.** Opens the user client, fetches the device info,
  configures the device, streams for one second and reports whether IQ bytes
  arrived in the shared ring buffer. A health check for the whole pipeline.
- **Start rtl_tcp server.** Starts the rtl_tcp-compatible TCP server on port
  `1234` and shows the iPad's WiFi address(es). In any SDR client, add an
  rtl_tcp source pointing at `<iPad-IP>:1234`. Streaming, frequency /
  sample-rate / gain / bias-T / direct-sampling control all work over the
  network in real time, just like a PC `rtl_tcp` instance.

While the server is running the app stays alive in the background (audio
background mode + auto-lock disabled), so switching to another app or letting
the screen turn off does not interrupt the stream.

## Porting notes (`librtlsdr` → USBDriverKit)

`librtlsdr` is compiled from `third_party/librtlsdr` without a single change.
Everything DriverKit lacks is provided underneath it by `Shim/`, and only the
upstream sources see those headers (per-file compiler flags in the Xcode
project):

- **libusb** (`libusb_driverkit.cpp`). The one libusb device is the
  `IOUSBHostInterface` the dext was matched to, so upstream's
  `rtlsdr_open(&dev, 0)` finds it by vendor/product ID as usual. Control
  transfers go through `IOUSBHostInterface::DeviceRequest`, bulk transfers
  through `IOUSBHostPipe::IO` / `AsyncIO`. The libusb event loop in
  `rtlsdr_read_async()` sleeps on a reentrant `IODispatchQueue` while the
  bulk-IN completions are delivered to that same queue, and calls the
  transfer callbacks there, as libusb does on its event thread. Transfers
  freed while still in flight keep their buffer and `OSAction` until the
  aborted completion has come back.
- **pthreads** (`pthread_driverkit.cpp`). Mutexes map to `IOLock` /
  `IORecursiveLock`, threads to blocks on their own `IODispatchQueue`.
  Condition variables poll; upstream only waits on one in the soft-AGC worker,
  which is off by default.
- **libc** (`libc_driverkit.cpp`). `malloc`/`free` on `IOMalloc`, `fprintf` /
  `printf` to `os_log`, `usleep` on `IOSleep`, an empty environment, and the
  odd function DriverKit declares but does not export (`isspace`).
- **Not built.** The UDP control server and the RPC client are optional in
  upstream and stay disabled; there are no BSD sockets in DriverKit.

Updating `librtlsdr` is a matter of moving the submodule to a newer commit.
If upstream starts using a libusb, pthread or libc function the shims do not
cover yet, the build fails at link time and the shim gets one more function.

The dext exposes `librtlsdr` to the host app through an
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

\* `rtlsdr_set_offset_tuning()` returns `-2` for R820T/R828D in `librtlsdr`
itself — these tuners do not support offset tuning. Same behaviour as
upstream `rtl_tcp`.

## Status and known limitations

- Only one TCP client at a time is served. A new connection replaces the
  current one, so a client that vanished without closing its socket cannot
  block reconnects.
- RTL-SDR Blog V4 detection (via the USB manufacturer / product strings) is
  implemented but not yet verified on V4 hardware.
- The dext cannot write files (DriverKit sandbox). Any IQ recording feature
  has to live in the host app, consuming the same ring buffer.

## License

Copyright © 2026 Arved Viehweger. The DriverKit driver, its shims and the
Swift host app in this repository are released under the same terms as the
upstream library — see below.

The driver extension links `librtlsdr` (unmodified, from
`third_party/librtlsdr`), which is licensed under the
**GNU General Public License v2 or later**. The driver extension is a
derivative work of `librtlsdr` and is therefore distributed under the same
terms. The Swift host app is original code but talks to the GPL-licensed
extension, therefore this project as a whole is GPL-licensed.

Note that GPL terms are widely considered incompatible with Apple's App
Store distribution terms. The App Store-licensed binary download imposes
restrictions that GPL does not allow. Personal & sideloaded
distribution are not affected.

## Acknowledgements

- The `librtlsdr` authors — Steve Markgraf, Dimitri Stolnikov and the
  upstream community at
  [librtlsdr/librtlsdr](https://github.com/librtlsdr/librtlsdr).
- Apple's USBDriverKit, IOKit, Network and AVFoundation frameworks, and the
  WWDC '22 "Bring your driver to iPad with DriverKit" session that made any
  of this possible on iPadOS.
- DanBurkhardt's
  [DriverKitUserClientSample](https://github.com/DanBurkhardt/DriverKitUserClientSample),
  a useful reference for the host-app side of iPadOS DriverKit.
