import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var windows: WindowController?
    private var statusItem: StatusItemController?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windows = WindowController(model: model)
        self.windows = windows
        statusItem = StatusItemController(model: model, windows: windows)
        model.start()
        #if DEBUG
        startDebugCommands()
        #endif
    }

    #if DEBUG
    /// Debug builds open their windows on a distributed notification, so that scripts can capture them:
    /// name `io.damao.batterykeeper.debug.show`, object `popover`, `settings`, `statistics`, `close`, `installHelper`, `startCycle` or `cancelCycle`.
    private func startDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.damao.batterykeeper.debug.show"), object: nil, queue: .main
        ) { [weak self] notification in
            let what = notification.object as? String
            MainActor.assumeIsolated {
                switch what {
                case "popover": self?.statusItem?.showPopover()
                case "settings": self?.windows?.showSettings()
                case "statistics": self?.windows?.showStatistics()
                case "close": self?.statusItem?.closePopover()
                case "installHelper": self?.model.installHelper()
                case "startCycle": self?.model.startCycle()
                case "cancelCycle": self?.model.cancelCycle()
                default: break
                }
            }
        }
    }
    #endif

    /// Launching the app again while it runs opens Settings: the way back when the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.showSettings()
        return false
    }

    /// Restores the adapter before quitting, if a cycle had cut it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        Task {
            await model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
