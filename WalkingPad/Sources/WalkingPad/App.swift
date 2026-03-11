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
            button.title = "🚶"
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 10)
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

        let text: String
        if !ble.isConnected {
            text = "\(dot)🚶"
        } else {
            text = "\(dot)🚶\(menuBarDailyProgress())"
        }

        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = -2
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
            .paragraphStyle: para,
        ])
    }

    func menuBarDailyProgress() -> String {
        let km = Double(ble.dailyDistance) / 1000.0
        if ble.goalReached {
            return String(format: "%.1fkm ✓", km)
        }
        return String(format: "%.1f/5km", km)
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
