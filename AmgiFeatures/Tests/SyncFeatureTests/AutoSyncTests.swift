//
//  AutoSyncTests.swift
//  SyncFeatureTests
//

import Testing
import Foundation
import Dependencies
import Sharing
import Synchronization
import AnkiKit
import AnkiClients
import AppCore
@testable import SyncFeature

// Nested in `SyncCoordinatorTests` so its `.serialized` trait covers both:
// the two suites share the profile-scoped `UserDefaults` sync keys, and run
// in parallel they clear each other's state mid-test.
extension SyncCoordinatorTests {
@Suite("Automatic sync policy", .serialized)
@MainActor
struct AutoSyncTests {

    init() {
        UserDefaults.standard.removeObject(
            forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser()
        )
        UserDefaults.standard.removeObject(
            forKey: SyncPreferences.Keys.lastCollectionSyncedAtForCurrentUser()
        )
    }

    @Test
    func appOpenSyncsQuietlyWhenOnline() async throws {
        let calls = Counter()
        let env = Env()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary(cardsPulled: 2) }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            #expect(coordinator.isAutomaticSync)
            try await settle()
            #expect(calls.value == 1)
            #expect(coordinator.state == .success(SyncSummary(cardsPulled: 2)))
            #expect(env.cancelled.value == 1)
            #expect(!coordinator.autoSyncPending)
        }
    }

    @Test
    func offlineDefersToBackgroundWithoutCallingTheServer() async throws {
        let calls = Counter()
        let env = Env(online: false)
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary() }
        } operation: {
            let coordinator = SyncCoordinator(autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            try await settle()
            #expect(calls.value == 0)
            #expect(env.scheduled.value == 1)
            #expect(coordinator.autoSyncPending)
            #expect(coordinator.state == .idle)
        }
    }

    @Test
    func failedAutoSyncStaysQuietAndRetriesLater() async throws {
        let env = Env()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { throw URLError(.notConnectedToInternet) }
        } operation: {
            let coordinator = SyncCoordinator(autoSync: env.environment)
            await coordinator.requestAutoSync(.studyFinished)
            try await settle()
            #expect(coordinator.state == .idle)
            #expect(!SyncToastController.needsAttention(coordinator.state))
            #expect(env.scheduled.value == 1)
            #expect(coordinator.autoSyncPending)
        }
    }

    @Test
    func conflictStopsAndPromptsInsteadOfResolving() async throws {
        let env = Env()
        let fullSyncs = Counter()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { throw SyncError.fullSyncRequired }
            $0.syncClient.fullSync = { _ in fullSyncs.bump() }
        } operation: {
            let coordinator = SyncCoordinator(autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            try await settle()
            #expect(coordinator.state == .needsFullSync(.diverged))
            #expect(SyncToastController.needsAttention(coordinator.state))
            #expect(fullSyncs.value == 0)
        }
    }

    @Test
    func unresolvedConflictIsReaskedOnAppOpenWithoutSyncing() async throws {
        let calls = Counter()
        let env = Env()
        UserDefaults.standard.set(true, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary() }
        } operation: {
            let coordinator = SyncCoordinator(autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            await coordinator.requestAutoSync(.studyFinished)
            try await settle()
            #expect(calls.value == 0)
            #expect(coordinator.attentionRequest == 1)
        }
    }

    @Test
    func appOpenIsThrottledButStudyFinishedIsNot() async throws {
        let calls = Counter()
        let env = Env(throttle: .seconds(120))
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary() }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            try await settle()
            await coordinator.requestAutoSync(.appOpen)
            try await settle()
            #expect(calls.value == 1)
            await coordinator.requestAutoSync(.studyFinished)
            try await settle()
            #expect(calls.value == 2)
        }
    }

    @Test
    func studySessionHoldsSyncUntilItEnds() async throws {
        let calls = Counter()
        let env = Env()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary(cardsPushed: 4) }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            try await settle()  // observers register on a hop to the main actor
            NotificationCenter.default.post(name: .studySessionDidStart, object: nil)
            try await settle()
            await coordinator.requestAutoSync(.connectivityRestored)
            await coordinator.requestAutoSync(.appOpen)
            try await settle()
            #expect(calls.value == 0)
            #expect(coordinator.autoSyncPending)

            NotificationCenter.default.post(name: .studySessionDidEnd, object: nil)
            try await settle()
            #expect(calls.value == 1)
            #expect(coordinator.state == .success(SyncSummary(cardsPushed: 4)))
        }
    }

    @Test
    func connectivityRestoredOnlyActsWhenASyncIsOwed() async throws {
        let calls = Counter()
        let env = Env()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary() }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            await coordinator.requestAutoSync(.connectivityRestored)
            try await settle()
            #expect(calls.value == 0)

            env.online.withLock { $0 = false }
            await coordinator.requestAutoSync(.studyFinished)
            env.online.withLock { $0 = true }
            await coordinator.requestAutoSync(.connectivityRestored)
            try await settle()
            #expect(calls.value == 1)
        }
    }

    @Test
    func disabledOrSignedOutNeverSyncs() async throws {
        let calls = Counter()
        await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { calls.bump(); return SyncSummary() }
        } operation: {
            let off = SyncCoordinator(autoSync: Env(enabled: false).environment)
            await off.requestAutoSync(.appOpen)
            let signedOut = SyncCoordinator(autoSync: Env(configured: false).environment)
            await signedOut.requestAutoSync(.studyFinished)
            try? await settle()
            #expect(calls.value == 0)
        }
    }

    @Test
    func manualTapDuringAutoSyncAdoptsIt() async throws {
        let gate = Gate()
        let calls = Counter()
        let env = Env()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = {
                calls.bump()
                await gate.wait()
                return SyncSummary()
            }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            await coordinator.requestAutoSync(.appOpen)
            #expect(coordinator.isAutomaticSync)
            await coordinator.startSync()
            #expect(!coordinator.isAutomaticSync)
            await gate.open()
            try await settle()
            #expect(calls.value == 1)
        }
    }

    @Test
    func backgroundSyncReportsOutcome() async {
        let env = Env()
        await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { SyncSummary() }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1), autoSync: env.environment)
            #expect(await coordinator.runBackgroundSync())
        }
    }

    // MARK: - Toast

    @Test
    func quietToastHidesProgressAndNoOpSuccess() {
        let toast = SyncToastController()
        toast.handle(.syncing(message: "Connecting…"), quiet: true)
        #expect(toast.toast == nil)
        toast.handle(.success(SyncSummary()), quiet: true)
        #expect(toast.toast == nil)
        toast.handle(.success(SyncSummary(cardsPulled: 3)), quiet: true)
        #expect(toast.toast == .success(SyncToast.summaryMessage(for: SyncSummary(cardsPulled: 3))))
    }
}
}

// MARK: - Helpers

private func settle() async throws {
    try await Task.sleep(for: .milliseconds(40))
}

private final class Counter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private final class Env: Sendable {
    let online: Mutex<Bool>
    let scheduled = Counter()
    let cancelled = Counter()
    private let enabled: Bool
    private let configured: Bool
    private let throttle: Duration

    init(online: Bool = true, enabled: Bool = true, configured: Bool = true, throttle: Duration = .zero) {
        self.online = Mutex(online)
        self.enabled = enabled
        self.configured = configured
        self.throttle = throttle
    }

    var environment: AutoSyncEnvironment {
        AutoSyncEnvironment(
            isEnabled: { [enabled] in enabled },
            isConfigured: { [configured] in configured },
            isOnline: { [self] in online.withLock { $0 } },
            scheduleDeferred: { [scheduled] in scheduled.bump() },
            cancelDeferred: { [cancelled] in cancelled.bump() },
            appOpenThrottle: throttle
        )
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
