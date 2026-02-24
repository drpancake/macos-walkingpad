import SwiftUI
import AppKit

@main
struct WalkingPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let ble = BLEManager()
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = " 🚶"
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 700)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(ble: ble)
        )

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        updateMenuBar()
    }

    func updateMenuBar() {
        guard let button = statusItem?.button else { return }

        let dot: String
        switch ble.connectionState {
        case .connected:
            dot = "🟢"
        case .scanning, .connecting, .discovering:
            dot = "🟡"
        case .bluetoothOff, .unauthorized, .disconnected:
            dot = "🔴"
        }

        if !ble.isConnected {
            button.title = "\(dot) 🚶"
            return
        }

        let icon = ble.speed >= 4.0 ? "🏃" : "🚶"
        let dist = menuBarDistance(ble.distance)

        if ble.speed > 0 {
            button.title = "\(dot) \(icon) \(String(format: "%.1f", ble.speed))km/h · \(dist)"
        } else {
            button.title = "\(dot) \(icon) \(dist)"
        }
    }

    func menuBarDistance(_ meters: Int) -> String {
        if meters >= 1000 {
            return String(format: "%.1fkm", Double(meters) / 1000.0)
        }
        return "\(meters)m"
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
