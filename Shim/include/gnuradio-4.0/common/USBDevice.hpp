//
//  USBDevice.hpp
//  RTL-SDR
//
//  Stand-in for gnuradio4-blocks' blocks/common/include/gnuradio-4.0/common/
//  USBDevice.hpp. Upstream implements this interface with Linux usbdevfs
//  ioctls and leaves a stub for every other platform. This version has the
//  same types and member functions and sends the transfers through
//  USBDriverKit (Shim/usb_driverkit.cpp).
//
//  The dext's header search path finds this file instead of upstream's, so
//  RTL2832Device.hpp compiles unmodified.
//
//  Device discovery is DriverKit's job: the dext is matched to its device
//  through the IOKit personalities in Info.plist and registers it with
//  usb_driverkit_attach(). enumerateUSBDevices() reports that one device and
//  ignores the VID/PID filter, so every matched dongle can be opened.
//

#ifndef GNURADIO_USB_DEVICE_HPP
#define GNURADIO_USB_DEVICE_HPP

#include <algorithm>
#include <cstdint>
#include <expected>
#include <format>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "../../../usb_driverkit.h"

namespace gr::blocks::common {

struct USBDeviceId {
    std::uint16_t    vendorId;
    std::uint16_t    productId;
    std::string_view description;
};

struct USBDeviceInfo {
    std::uint16_t vendorId  = 0;
    std::uint16_t productId = 0;
    std::uint8_t  busNum    = 0;
    std::uint8_t  devNum    = 0;
    std::string   devPath;
    std::string   product;
    std::string   manufacturer;
    bool          accessible = false;
};

[[nodiscard]] inline bool canAccessUSBDevice(const USBDeviceInfo&) { return usb_driverkit_attached(); }

inline std::vector<USBDeviceInfo> enumerateUSBDevices(std::span<const USBDeviceId> = {}) {
    std::vector<USBDeviceInfo> result;
    if (!usb_driverkit_attached()) {
        return result;
    }
    const char*   manufacturer = "";
    const char*   product      = "";
    USBDeviceInfo info;
    usb_driverkit_get_info(&info.vendorId, &info.productId, &manufacturer, &product);
    info.devPath      = "driverkit";
    info.manufacturer = manufacturer;
    info.product      = product;
    info.accessible   = true;
    result.push_back(std::move(info));
    return result;
}

struct USBDevice {
    using Result = std::expected<void, std::string>;

    bool _open = false;

    USBDevice()                            = default;
    USBDevice(const USBDevice&)            = delete;
    USBDevice& operator=(const USBDevice&) = delete;
    ~USBDevice() { close(); }

    [[nodiscard]] bool isOpen() const { return _open; }

    // The interface was opened by the dext before it attached it.
    [[nodiscard]] Result open(const USBDeviceInfo&, int = 0) {
        if (!usb_driverkit_attached()) {
            return std::unexpected(std::string("USBDevice: no device attached"));
        }
        _open = true;
        return {};
    }

    void close() { _open = false; }

    [[nodiscard]] Result controlOut(std::uint8_t bmRequestType, std::uint8_t bRequest, std::uint16_t wValue, std::uint16_t wIndex, std::span<const std::uint8_t> data, unsigned timeoutMs = 300) {
        std::uint16_t sent = 0;
        std::int32_t  ret  = usb_driverkit_control(bmRequestType, bRequest, wValue, wIndex, const_cast<std::uint8_t*>(data.data()), static_cast<std::uint16_t>(data.size()), timeoutMs, &sent);
        if (ret != 0) {
            return std::unexpected(transferError("control OUT", ret));
        }
        return {};
    }

    [[nodiscard]] std::expected<std::vector<std::uint8_t>, std::string> controlIn(std::uint8_t bmRequestType, std::uint8_t bRequest, std::uint16_t wValue, std::uint16_t wIndex, std::uint16_t length, unsigned timeoutMs = 300) {
        // like upstream: request at least 8 bytes, return what arrived
        std::vector<std::uint8_t> buf(std::max<std::uint16_t>(length, 8));
        std::uint16_t             got = 0;
        std::int32_t              ret = usb_driverkit_control(bmRequestType, bRequest, wValue, wIndex, buf.data(), static_cast<std::uint16_t>(buf.size()), timeoutMs, &got);
        if (ret != 0) {
            return std::unexpected(transferError("control IN", ret));
        }
        buf.resize(got);
        return buf;
    }

    [[nodiscard]] std::expected<std::size_t, std::string> bulkRead(std::uint8_t endpoint, std::span<std::uint8_t> buf, unsigned timeoutMs = 100) {
        std::uint32_t got = 0;
        std::int32_t  ret = usb_driverkit_bulk_read(endpoint, buf.data(), static_cast<std::uint32_t>(buf.size()), timeoutMs, &got);
        if (ret != 0 && !(ret == kTimeout && got == 0)) {
            return std::unexpected(transferError("bulk read", ret));
        }
        return static_cast<std::size_t>(got); // a timeout is no error, just no data yet
    }

    [[nodiscard]] Result reset() {
        if (std::int32_t ret = usb_driverkit_reset(); ret != 0) {
            return std::unexpected(transferError("USB reset", ret));
        }
        return {};
    }

    [[nodiscard]] Result clearHalt(std::uint8_t endpoint) {
        if (std::int32_t ret = usb_driverkit_clear_halt(endpoint); ret != 0) {
            return std::unexpected(transferError(std::format("clear halt on endpoint 0x{:02X}", endpoint), ret));
        }
        return {};
    }

private:
    static constexpr std::int32_t kTimeout = static_cast<std::int32_t>(0xE00002D6); // kIOReturnTimeout

    [[nodiscard]] static std::string transferError(std::string_view op, std::int32_t ret) { return std::format("{} failed: IOReturn 0x{:08X}", op, static_cast<std::uint32_t>(ret)); }
};

} // namespace gr::blocks::common

#endif // GNURADIO_USB_DEVICE_HPP
