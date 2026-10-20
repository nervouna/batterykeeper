import AppKit
import BatteryKeeperCore
import SwiftUI

/// The menu bar item: draws the icon and toggles the popover.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let windows: WindowController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var lastIcon: StatusIconModel?

    init(model: AppModel, windows: WindowController) {
        self.model = model
        self.windows = windows
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imageHugsTitle = true
        }
        let content = PopoverView(
            model: model,
            openStatistics: { [weak self] in self?.open { $0.showStatistics() } },
            openSettings: { [weak self] in self?.open { $0.showSettings() } })
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        model.onChange = { [weak self] in self?.update() }
        update()
    }

    func update() {
        let icon = StatusIconModel.make(snapshot: model.snapshot, settings: model.settings.icon, cycleRunning: model.cycle != nil)
        guard icon != lastIcon, let button = item.button else { return }
        lastIcon = icon
        button.image = StatusIconRenderer.image(for: icon)
        if icon.text.isEmpty {
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.attributedTitle = NSAttributedString(
                string: icon.text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
            button.imagePosition = button.image == nil ? .noImage : .imageLeading
        }
        button.toolTip = Texts.status(icon.status)
        button.setAccessibilityLabel("BatteryKeeper, \(icon.text), \(Texts.status(icon.status))")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func open(_ action: (WindowController) -> Void) {
        popover.performClose(nil)
        action(windows)
    }
}

/// Opens the Statistics and Settings windows, one of each.
@MainActor
final class WindowController {
    private let model: AppModel
    private var statistics: NSWindow?
    private var settings: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showStatistics() {
        let window = statistics ?? makeWindow(
            title: String(localized: "BatteryKeeper Statistics"), size: NSSize(width: 760, height: 520),
            content: StatisticsView(model: model))
        statistics = window
        present(window)
    }

    func showSettings() {
        let window = settings ?? makeWindow(
            title: String(localized: "BatteryKeeper Settings"), size: NSSize(width: 520, height: 560),
            content: SettingsView(model: model))
        settings = window
        present(window)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
