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

    var body: some Scene {
        MenuBarExtra {
            Text(controller.isConnected
                ? (controller.deviceName ?? "Busylight connected")
                : "No Busylight found")
            Divider()
            Button("Turn On (Red)") {
                controller.turnOn(red: 255, green: 0, blue: 0)
            }
            .disabled(!controller.isConnected)
            Button("Turn Off") {
                controller.turnOff()
            }
            .disabled(!controller.isConnected)
            if let end = controller.pomodoroEndDate {
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
