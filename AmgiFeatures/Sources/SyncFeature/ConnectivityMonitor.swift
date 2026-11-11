//
//  ConnectivityMonitor.swift
//  SyncFeature
//

import Foundation
import Network
import Synchronization

/// Process-wide network reachability for automatic sync.
///
/// `@unchecked Sendable` because `NWPathMonitor` is not annotated; it is
/// configured once in `init` and only ever touched from its own queue after.
final class ConnectivityMonitor: @unchecked Sendable {
    static let shared = ConnectivityMonitor()

    /// Posted (on the monitor's queue) when the path goes from unusable to
    /// usable. `SyncCoordinator` hops to the main actor before acting on it.
    static let restoredNotification = Notification.Name("AmgiConnectivityRestored")

    private let monitor = NWPathMonitor()
    private let status = Mutex<NWPath.Status?>(nil)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status)
        }
        monitor.start(queue: DispatchQueue(label: "com.amgiapp.connectivity", qos: .utility))
    }

    /// Optimistic before the first path update arrives: an unknown network
    /// is tried, and a real failure falls back to the deferred path anyway.
    var isOnline: Bool {
        status.withLock { $0 } != .unsatisfied
    }

    private func update(_ new: NWPath.Status) {
        let previous = status.withLock { current in
            defer { current = new }
            return current
        }
        guard new == .satisfied, let previous, previous != .satisfied else { return }
        NotificationCenter.default.post(name: Self.restoredNotification, object: nil)
    }
}
