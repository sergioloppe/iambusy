import AppKit
import Foundation
import IOKit.hid
import os

/// Owns the HID connection to the first attached Kuando Busylight and the
/// keepalive refresh that the hardware requires while lit.
final class KuandoController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?

    /// Brightness 0.0-1.0, applied by scaling the RGB values; the device has
    /// no separate brightness control.
    @Published var intensity: Double = 0.25 {
        didSet {
            if isOn { sendCurrentColor() }
        }
    }

    private static let logger = Logger(subsystem: "io.kadmos.iambusy", category: "hid")

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var keepAliveTimer: DispatchSourceTimer?
    private var terminationObserver: NSObjectProtocol?
    private var currentColor: (red: UInt8, green: UInt8, blue: UInt8) = (0, 0, 0)

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching = Kuando.deviceIDs.map { id -> [String: Int] in
            [kIOHIDVendorIDKey: id.vendorID, kIOHIDProductIDKey: id.productID]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KuandoController>.fromOpaque(context)
                .takeUnretainedValue()
                .deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KuandoController>.fromOpaque(context)
                .takeUnretainedValue()
                .deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            Self.logger.error("IOHIDManagerOpen failed: \(opened, privacy: .public)")
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.turnOff()
        }
    }

    deinit {
        keepAliveTimer?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func turnOn(red: UInt8, green: UInt8, blue: UInt8) {
        currentColor = (red, green, blue)
        isOn = true
        sendCurrentColor()
        startKeepAlive()
    }

    func turnOff() {
        stopKeepAlive()
        isOn = false
        currentColor = (0, 0, 0)
        send(Kuando.offPacket())
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Kuando.refreshInterval,
            repeating: Kuando.refreshInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.send(Kuando.keepAlivePacket())
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private func deviceMatched(_ matched: IOHIDDevice) {
        guard device == nil else { return }
        device = matched
        isConnected = true
        deviceName = IOHIDDeviceGetProperty(matched, kIOHIDProductKey as CFString) as? String
        if isOn {
            sendCurrentColor()
        }
    }

    private func sendCurrentColor() {
        send(Kuando.jumpPacket(
            red: dimmed(currentColor.red),
            green: dimmed(currentColor.green),
            blue: dimmed(currentColor.blue)
        ))
    }

    private func dimmed(_ value: UInt8) -> UInt8 {
        UInt8(max(0, min(Double(value) * intensity, 255)).rounded())
    }

    private func deviceRemoved(_ removed: IOHIDDevice) {
        guard let current = device, CFEqual(current, removed) else { return }
        device = nil
        isConnected = false
        deviceName = nil
    }

    @discardableResult
    private func send(_ packet: [UInt8]) -> Bool {
        guard let device else { return false }
        let result = packet.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
        }
        return result == kIOReturnSuccess
    }
}
