import Foundation
import ServiceManagement

/// Where the privileged helper stands.
public enum HelperStatus: Sendable, Equatable {
    /// Registered and allowed to run.
    case enabled
    /// Registered, waiting for the user to allow it in System Settings → Login Items.
    case requiresApproval
    /// Not registered. `SMAppService` also reports a daemon that was never registered as "not found";
    /// a bundle that really lacks the helper shows up as an error when registering.
    case notRegistered
}

public struct HelperError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// Registers the helper with `SMAppService` and talks to it over XPC.
@MainActor
public final class HelperClient {
    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    /// Called when the connection to the helper breaks (the helper exited or was restarted). The helper
    /// restores the adapter when that happens, so a client that had it cut must ask again.
    public var onConnectionLost: (() -> Void)?

    public init() {}

    public var status: HelperStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
    }

    /// Registers the helper. The first registration leaves it waiting for the user's approval.
    public func register() throws(HelperError) {
        do {
            try service.register()
        } catch {
            throw HelperError(description: error.localizedDescription)
        }
    }

    public func unregister() async throws(HelperError) {
        connection?.invalidate()
        connection = nil
        do {
            try await service.unregister()
        } catch {
            throw HelperError(description: error.localizedDescription)
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func protocolVersion() async throws(HelperError) -> Int {
        try await call { (proxy, continuation: CheckedContinuation<Int, any Error>) in
            proxy.protocolVersion { continuation.resume(returning: $0) }
        }
    }

    public func setAdapterEnabled(_ enabled: Bool, lease: TimeInterval = HelperConstants.leaseDuration) async throws(HelperError) {
        try await call { (proxy, continuation: CheckedContinuation<Void, any Error>) in
            proxy.setAdapterEnabled(enabled, leaseSeconds: lease) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Whether the adapter powers the Mac, and the seconds left on the lease.
    public func adapterState() async throws(HelperError) -> (enabled: Bool, leaseRemaining: TimeInterval) {
        let state = try await call { (proxy, continuation: CheckedContinuation<AdapterState, any Error>) in
            proxy.adapterState { enabled, remaining, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: AdapterState(enabled: enabled, leaseRemaining: remaining))
                }
            }
        }
        return (state.enabled, state.leaseRemaining)
    }

    // MARK: - Connection

    private struct AdapterState: Sendable {
        var enabled: Bool
        var leaseRemaining: TimeInterval
    }

    /// Runs one call on the helper. An XPC error (no helper, a refused connection) fails the call.
    private func call<T: Sendable>(
        _ body: (any BatteryKeeperHelperProtocol, CheckedContinuation<T, any Error>) -> Void
    ) async throws(HelperError) -> T {
        let connection = try currentConnection()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    continuation.resume(throwing: error)
                }
                // The interface is set to this protocol, so the cast cannot fail.
                body(proxy as! any BatteryKeeperHelperProtocol, continuation)
            }
        } catch {
            throw HelperError(description: error.localizedDescription)
        }
    }

    private func currentConnection() throws(HelperError) -> NSXPCConnection {
        if let connection { return connection }
        guard let team = CodeSigning.ownTeamIdentifier() else {
            throw HelperError(description: "BatteryKeeper is not signed with a team identity")
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any BatteryKeeperHelperProtocol).self)
        connection.setCodeSigningRequirement(CodeSigning.requirement(identifier: HelperConstants.label, team: team))
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connectionLost(connection) }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connectionLost(connection) }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func connectionLost(_ lost: NSXPCConnection) {
        guard connection === lost else { return }
        connection = nil
        lost.invalidate()
        onConnectionLost?()
    }
}
