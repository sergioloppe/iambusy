import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            Kuando.dumpPackets()
        } else {
            BusyApp.main()
        }
    }
}

struct BusyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = KuandoController()

    private static let remainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.isConnected
                ? (controller.deviceName ?? "Busylight connected")
                : "No Busylight found")
            Divider()
            Button("Turn On (\(controller.color.name))") {
                controller.turnOn()
            }
            .disabled(!controller.isConnected)
            Button("Turn Off") {
                controller.turnOff()
            }
            .disabled(!controller.isConnected)
            if let end = controller.pomodoroEndDate {
                if let remaining = controller.pomodoroRemaining,
                   let text = Self.remainingFormatter.string(from: remaining) {
                    Text("\(text) remaining")
                }
                Text("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                // Not disabled while disconnected: an unplug leaves the
                // session running, and it still has to be cancellable.
                Button("Cancel Pomodoro") {
                    controller.turnOff()
                }
            } else {
                Menu("Pomodoro") {
                    ForEach([15, 20, 30, 45, 50, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            controller.startPomodoro(minutes: minutes)
                        }
                    }
                }
                .disabled(!controller.isConnected)
            }
            Picker("Color", selection: $controller.color) {
                ForEach(BusyColor.allCases, id: \.self) { color in
                    Text(color.name).tag(color)
                }
            }
            Picker("Intensity", selection: $controller.intensity) {
                Text("Low (10%)").tag(0.10)
                Text("Medium (25%)").tag(0.25)
                Text("High (50%)").tag(0.50)
                Text("Full (100%)").tag(1.0)
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: controller.pomodoroEndDate != nil
                ? "timer"
                : (controller.isOn ? "circle.fill" : "circle"))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
