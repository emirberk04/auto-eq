import AppKit
import SwiftUI

/// Menu bar shell: a status item whose button opens the SwiftUI popover. All state lives in `AppModel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        updateIcon()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.updateIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareForQuit()
        model.engine.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { model.setSpectrumVisible(true) }
    func popoverDidClose(_ notification: Notification) { model.setSpectrumVisible(false) }

    private func updateIcon() {
        let status = model.status
        let symbol: String
        switch status.state {
        case .running:
            if status.permissionSuspect || !status.warnings.isEmpty || model.profileError != nil {
                symbol = "exclamationmark.triangle"
            } else {
                symbol = model.design?.eqEnabled == true ? "headphones" : "headphones.circle"
            }
        case .waitingForSource, .stopped: symbol = "headphones.circle"
        case .failed: symbol = "exclamationmark.triangle"
        }
        guard symbol != currentSymbol else { return }
        currentSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "S12 Adaptive EQ")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private var currentSymbol = ""
}

/// `--render-ui <png>`: draws the popover with fake data into a PNG, for checking the layout
/// without audio or a menu bar.
@MainActor
enum UIRenderer {
    static func render(to path: String, dark: Bool, visualizer: Visualizer? = nil) {
        let model = AppModel(startEngine: false)
        model.loadPreviewData()
        if let visualizer { model.previewVisualizer(visualizer) }
        let host = NSHostingView(rootView: PopoverView(model: model).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("rendered \(Int(size.width))×\(Int(size.height)) → \(path)")
    }
}
