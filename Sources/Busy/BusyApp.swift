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
            Picker("Intensity", selection: $controller.intensity) {
                Text("Low (10%)").tag(0.10)
                Text("Medium (25%)").tag(0.25)
                Text("High (50%)").tag(0.50)
                Text("Full (100%)").tag(1.0)
            }
            Divider()
            Button("Quit") {
                controller.turnOff()
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: controller.isOn ? "circle.fill" : "circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
