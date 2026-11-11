//
//  BackgroundSyncScheduler.swift
//  SyncFeature
//

import AppCore
import Foundation
import OSLog
import Synchronization
#if os(iOS)
import BackgroundTasks
#endif

/// Schedules a deferred automatic sync through `BGTaskScheduler`, so a sync
/// that could not run (offline, server unreachable) happens once the device
/// is back online, even if the app is not open.
///
/// Two requests go in together. The processing request carries
/// `requiresNetworkConnectivity`, so the system holds it until the network
/// is back — that is the "when I have internet again" half. The app-refresh
/// request runs sooner and more often but cannot require a network; when it
/// fires offline the coordinator simply defers again, re-submitting both.
///
/// Both identifiers must appear in `BGTaskSchedulerPermittedIdentifiers` in
/// `AmgiApp/Info.plist`, alongside the `fetch` and `processing` background
/// modes.
package enum BackgroundSyncScheduler {
    static let refreshIdentifier = "com.amgiapp.AmgiApp.sync.refresh"
    static let processingIdentifier = "com.amgiapp.AmgiApp.sync.processing"

    /// Registers the launch handlers. `BGTaskScheduler` requires this before
    /// the app finishes launching, so it is called from `AmgiRoot.bootstrap()`.
    /// `coordinator` returns nil when the collection failed to open, in which
    /// case the task completes immediately without touching the engine.
    @MainActor
    package static func register(coordinator: @escaping @MainActor () -> SyncCoordinator?) {
        #if os(iOS)
        for identifier in [refreshIdentifier, processingIdentifier] {
            // `using: .main` delivers the handler on the main queue, which is
            // what makes `assumeIsolated` sound.
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                let box = BackgroundTaskBox(task)
                MainActor.assumeIsolated {
                    run(box, coordinator: coordinator())
                }
            }
        }
        #endif
    }

    /// Submits (or replaces) both deferred-sync requests. Safe to call
    /// repeatedly — a new submission replaces a pending one with the same
    /// identifier.
    static func schedule() {
        #if os(iOS)
        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        for request in [processing, refresh] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // Simulator, Background App Refresh off, or too many pending
                // requests. The next launch syncs regardless, so this is a
                // lost optimisation, not lost data.
                Log.sync.notice("Could not schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    /// Drops any pending deferred sync — called once a sync has succeeded.
    static func cancelScheduled() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        #endif
    }
}

#if os(iOS)
private extension BackgroundSyncScheduler {
    @MainActor
    static func run(_ box: BackgroundTaskBox, coordinator: SyncCoordinator?) {
        guard let coordinator else {
            box.complete(success: false)
            return
        }
        let work = Task { @MainActor in
            let success = await coordinator.runBackgroundSync()
            box.complete(success: success)
        }
        box.task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                coordinator.cancel()
                // The FFI call cannot be interrupted; reschedule so whatever
                // did not make it out is retried in the next window.
                schedule()
            }
            box.complete(success: false)
        }
    }
}

/// `BGTask` is not `Sendable`, but its documented contract is thread-safe:
/// `setTaskCompleted` and `expirationHandler` may be used from any thread.
/// The box also guarantees `setTaskCompleted` fires exactly once — the
/// expiration handler and the sync's own completion can race.
private final class BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
    private let completed = Mutex(false)

    init(_ task: BGTask) { self.task = task }

    func complete(success: Bool) {
        let alreadyDone = completed.withLock { done in
            defer { done = true }
            return done
        }
        guard !alreadyDone else { return }
        task.setTaskCompleted(success: success)
    }
}
#endif
