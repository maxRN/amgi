//
//  AutoSync.swift
//  SyncFeature
//

import AnkiSync
import AppCore
import Foundation

/// What asked for an automatic sync. Only `.appOpen` is throttled: the
/// others each mean there is something specific to push or pull.
package enum AutoSyncTrigger: String, Sendable {
    /// Cold launch, or the app returning to the foreground.
    case appOpen
    /// A review session closed.
    case studyFinished
    /// The network came back while a sync was owed.
    case connectivityRestored
    /// A `BGTaskScheduler` launch.
    case background
}

/// The world automatic sync consults, injected so `SyncCoordinator`'s
/// policy is testable without a keychain, a network or `BGTaskScheduler`.
package struct AutoSyncEnvironment: Sendable {
    /// The user has not turned automatic sync off.
    var isEnabled: @Sendable () -> Bool
    /// A server and credentials are stored. Without credentials auto sync
    /// stays silent — prompting for a login unasked would be a nag.
    var isConfigured: @Sendable () -> Bool
    var isOnline: @Sendable () -> Bool
    /// Ask the system to run a sync later, once online.
    var scheduleDeferred: @Sendable () -> Void
    /// Drop a pending deferred sync — the work it was for is done.
    var cancelDeferred: @Sendable () -> Void
    /// Minimum gap between two `.appOpen` syncs, so flicking between apps
    /// does not sync on every return.
    var appOpenThrottle: Duration

    package static let live = AutoSyncEnvironment(
        isEnabled: { SyncPreferences.isAutoSyncEnabled },
        isConfigured: {
            KeychainHelper.loadEndpoint() != nil && KeychainHelper.loadHostKey() != nil
        },
        isOnline: { ConnectivityMonitor.shared.isOnline },
        scheduleDeferred: { BackgroundSyncScheduler.schedule() },
        cancelDeferred: { BackgroundSyncScheduler.cancelScheduled() },
        appOpenThrottle: .seconds(120)
    )

    /// Never syncs on its own. The default for test and preview coordinators.
    package static let disabled = AutoSyncEnvironment(
        isEnabled: { false },
        isConfigured: { false },
        isOnline: { true },
        scheduleDeferred: {},
        cancelDeferred: {},
        appOpenThrottle: .zero
    )
}
