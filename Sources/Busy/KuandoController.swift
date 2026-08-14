import AppKit
import Foundation
import IOKit.hid
import os

enum BusyColor: String, CaseIterable {
    case red, green, yellow, purple, blue, orange

    var name: String { rawValue.capitalized }

    var rgb: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .red: return (255, 0, 0)
        case .green: return (0, 255, 0)
        case .yellow: return (255, 255, 0)
        case .purple: return (128, 0, 255)
        case .blue: return (0, 0, 255)
        case .orange: return (255, 128, 0)
        }
    }
}

// Prefixed so a generic name in NSGlobalDomain or the argument domain
// can't shadow the stored value.
private enum DefaultsKey {
    static let intensity = "io.kadmos.iambusy.intensity"
    static let color = "io.kadmos.iambusy.color"
}

/// Owns the HID connection to the first attached Kuando Busylight and the
/// keepalive refresh that the hardware requires while lit.
final class KuandoController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?
    @Published private(set) var pomodoroEndDate: Date?
    /// Republished every second while a session runs; menu items are plain
    /// strings, so the countdown only ticks if something invalidates them.
    @Published private(set) var pomodoroRemaining: TimeInterval?

    /// Brightness 0.0-1.0, applied by scaling the RGB values; the device has
    /// no separate brightness control.
    @Published var intensity = KuandoController.storedIntensity() {
        didSet {
            UserDefaults.standard.set(intensity, forKey: DefaultsKey.intensity)
            if isOn { sendCurrentColor() }
        }
    }

    @Published var color = BusyColor(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.color) ?? "") ?? .red {
        didSet {
            UserDefaults.standard.set(color.rawValue, forKey: DefaultsKey.color)
            // A running pomodoro keeps going; only the lit color changes.
            if isOn, !isBlinking {
                currentColor = color.rgb
                sendCurrentColor()
            }
        }
    }

    private static let logger = Logger(subsystem: "io.kadmos.iambusy", category: "hid")
    private static let completionHold: TimeInterval = 10
    private static let completionBlinkTenths: UInt8 = 5
    private static let intensitySteps: [Double] = [0.10, 0.25, 0.50, 1.0]

    /// Clamped to the picker's steps so a stray stored value can't leave the
    /// menu with no selected row.
    private static func storedIntensity() -> Double {
        guard let stored = UserDefaults.standard.object(forKey: DefaultsKey.intensity) as? Double,
              intensitySteps.contains(stored) else { return 0.25 }
        return stored
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var keepAliveTimer: DispatchSourceTimer?
    private var countdownTimer: DispatchSourceTimer?
    private var pomodoroSession = 0
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var currentColor: (red: UInt8, green: UInt8, blue: UInt8) = (0, 0, 0)
    /// A blink is a device-side program, so every resend (wake, reconnect,
    /// intensity change) has to replay it instead of a steady color.
    private var isBlinking = false

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

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, isOn else { return }
            sendCurrentColor()
            startKeepAlive()
        }
    }

    deinit {
        keepAliveTimer?.cancel()
        countdownTimer?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func turnOn() {
        light(color.rgb, blinking: false)
    }

    func turnOff() {
        cancelPomodoro()
        stopKeepAlive()
        isOn = false
        isBlinking = false
        currentColor = (0, 0, 0)
        send(Kuando.offPacket())
    }

    func startPomodoro(minutes: Int) {
        let duration = TimeInterval(minutes) * 60
        turnOn()

        let session = pomodoroSession
        let end = Date(timeIntervalSinceNow: duration)
        pomodoroEndDate = end
        startCountdown(until: end)
        // Wall-clock deadlines so the transitions still line up with the
        // displayed end time after the machine sleeps.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + duration) { [weak self] in
            guard let self, pomodoroSession == session else { return }
            light(BusyColor.green.rgb, blinking: true)

            let holdSession = pomodoroSession
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + Self.completionHold) { [weak self] in
                guard let self, pomodoroSession == holdSession else { return }
                turnOff()
            }
        }
    }

    private func light(_ rgb: (red: UInt8, green: UInt8, blue: UInt8), blinking: Bool) {
        cancelPomodoro()
        currentColor = rgb
        isBlinking = blinking
        isOn = true
        sendCurrentColor()
        startKeepAlive()
    }

    private func cancelPomodoro() {
        pomodoroSession += 1
        pomodoroEndDate = nil
        countdownTimer?.cancel()
        countdownTimer = nil
        pomodoroRemaining = nil
    }

    private func startCountdown(until end: Date) {
        pomodoroRemaining = end.timeIntervalSinceNow
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        // Recomputed from the wall-clock end date each tick, so the display
        // snaps back to the right value after the machine sleeps.
        timer.setEventHandler { [weak self] in
            self?.pomodoroRemaining = max(0, end.timeIntervalSinceNow)
        }
        timer.resume()
        countdownTimer = timer
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
            guard let self else { return }
            // A KeepAlive step replaces the device program, which would kill
            // a running blink; replaying the blink refreshes the device too.
            if isBlinking {
                sendCurrentColor()
            } else {
                send(Kuando.keepAlivePacket())
            }
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

    /// The completion blink runs at full brightness, so `intensity` only
    /// applies to steady colors.
    private func sendCurrentColor() {
        if isBlinking {
            send(Kuando.blinkPacket(
                red: currentColor.red,
                green: currentColor.green,
                blue: currentColor.blue,
                onTenths: Self.completionBlinkTenths,
                offTenths: Self.completionBlinkTenths
            ))
        } else {
            send(Kuando.jumpPacket(
                red: dimmed(currentColor.red),
                green: dimmed(currentColor.green),
                blue: dimmed(currentColor.blue)
            ))
        }
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
