import BatteryKeeperSystem
import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// The root launch daemon: an XPC listener in front of ``HelperService``, plus the signal and sleep hooks
/// that restore the adapter.
public enum HelperDaemon {
    public static func run() -> Never {
        let log = Logger(subsystem: "io.damao.batterykeeper.helper", category: "daemon")

        let adapter: any AdapterSwitch
        do {
            adapter = try SMCAdapterSwitch()
        } catch {
            log.error("no adapter switch: \(String(describing: error), privacy: .public)")
            adapter = UnavailableAdapterSwitch()
        }
        let reader = BatteryReader(smc: nil)
        let service = HelperService(adapter: adapter, percent: { reader.percent() })
        service.start()

        // launchd stops the daemon with SIGTERM (unregistering, logout, shutdown).
        var signalSources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                log.notice("signal \(signalNumber), restoring the adapter and exiting")
                service.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        let power = SystemPowerWatcher { service.prepareForSleep() }
        power.start()

        let delegate = ListenerDelegate(service: service)
        let listener = NSXPCListener(machServiceName: HelperConstants.label)
        if let team = CodeSigning.ownTeamIdentifier() {
            listener.setConnectionCodeSigningRequirement(
                CodeSigning.requirement(identifier: HelperConstants.appIdentifier, team: team))
        } else {
            log.error("the helper is not signed with a team identity, refusing every connection")
            delegate.refuseAll = true
        }
        listener.delegate = delegate
        listener.resume()
        log.notice("helper started, protocol \(HelperConstants.protocolVersion)")

        withExtendedLifetime((signalSources, power, delegate, listener)) {
            RunLoop.main.run()
        }
        exit(0)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: HelperService
    var refuseAll = false

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !refuseAll else { return false }
        let owner = UUID()
        connection.exportedInterface = NSXPCInterface(with: (any BatteryKeeperHelperProtocol).self)
        connection.exportedObject = HelperConnection(service: service, owner: owner)
        let service = self.service
        connection.invalidationHandler = { service.connectionEnded(owner: owner) }
        connection.interruptionHandler = { service.connectionEnded(owner: owner) }
        connection.resume()
        return true
    }
}

/// The object a client connection talks to.
final class HelperConnection: NSObject, BatteryKeeperHelperProtocol, @unchecked Sendable {
    let service: HelperService
    let owner: UUID

    init(service: HelperService, owner: UUID) {
        self.service = service
        self.owner = owner
    }

    func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func setAdapterEnabled(_ enabled: Bool, leaseSeconds: Double, reply: @escaping @Sendable (NSError?) -> Void) {
        let error = service.request(enabled: enabled, leaseSeconds: leaseSeconds, owner: owner)
        reply(error.map { Self.nsError($0) })
    }

    func adapterState(reply: @escaping @Sendable (Bool, Double, NSError?) -> Void) {
        let state = service.state()
        reply(state.enabled, state.leaseRemaining, nil)
    }

    /// Errors cross XPC as plain `NSError`s with the description as the message.
    static func nsError(_ error: any Error) -> NSError {
        NSError(
            domain: "io.damao.batterykeeper.helper", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(describing: error)])
    }
}

/// Calls back before the system sleeps, through the root power domain.
final class SystemPowerWatcher: @unchecked Sendable {
    // iokit_common_msg(0x270) and (0x280); the macros do not import into Swift.
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemWillSleep: natural_t = 0xE000_0280

    private let onWillSleep: @Sendable () -> Void
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    init(onWillSleep: @escaping @Sendable () -> Void) {
        self.onWillSleep = onWillSleep
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &port,
            { refcon, _, messageType, argument in
                guard let refcon else { return }
                Unmanaged<SystemPowerWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
            }, &notifier)
        guard rootPort != 0, let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            onWillSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        default:
            break
        }
    }
}
