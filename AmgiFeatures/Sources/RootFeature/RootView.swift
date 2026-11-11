//
//  RootView.swift
//  RootFeature
//
//  Created by Vladimir Gusev on 29.08.2026.
//

public import SwiftUI
import AppCore
import AppShared
import Theme
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import ReaderFeature
import ReviewFeature
import Sharing
import SyncFeature

/// The app's whole view composition. The host target supplies only `@main`.
///
/// Owns the routing between onboarding, the tab bar, and the startup-error
/// screen; the cross-cutting flows above the tabs (sync, deck import, the
/// review cover); and the root chrome (`.themedRoot()`, the app font, the
/// profile re-id, the deep link, the scene-phase widget refresh).
public struct RootView: View {
    public init() {}

    @Shared(.onboardingCompleted) private var onboardingCompleted
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.appStorage(AppearancePreferences.Keys.appFont))
    private var appFontRaw: String = AppFont.system.rawValue

    @Dependency(\.collectionStore) private var store
    @Dependency(\.deckClient) private var deckClient
    @Bindable private var accountStore = AccountStore.shared

    @State private var pendingReviewDeckId: DeckID?
    @State private var showImport = false
    @State private var refreshID = UUID()

    @Shared(.appStorage(ReaderPreferences.Keys.showTab))
    private var showReaderTab: Bool = true

    public var body: some View {
        routed
            // Rebuild the entire view tree when the active profile changes —
            // every screen holds state derived from the previously open
            // collection. `.id(_:)` sets identity for `routed` and its
            // subtree only; it does not touch state held on `RootView`
            // itself, so `pendingReviewDeckId` needs the explicit clear
            // below.
            .id(accountStore.selectedID)
            .onChange(of: accountStore.selectedID) { pendingReviewDeckId = nil }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await writeWidgetSnapshot() }
                }
            }
            .onOpenURL { url in
                guard url.scheme == "amgi",
                      url.host == "review",
                      let deckIdStr = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "deckId" })?.value,
                      let deckId = Int64(deckIdStr)
                else { return }
                Task { pendingReviewDeckId = await resolveReviewDeck(DeckID(deckId)) }
            }
            .themedRoot()
            .environment(\.appFont, AppFont(rawValue: appFontRaw) ?? .system)
    }

    /// Deck id 0 is the widget's "All Decks" aggregate, not a real deck:
    /// `setCurrentDeck(0)` succeeds but the engine's queue builder then falls
    /// back to the Default deck, so the tap opened an empty session while the
    /// widget showed cards due. Resolve it to the top-level deck with the most
    /// due cards instead (Default if nothing is due, matching the engine).
    private func resolveReviewDeck(_ deckId: DeckID) async -> DeckID {
        guard deckId.rawValue == 0 else { return deckId }
        let topLevel = (try? await deckClient.fetchTree()) ?? []
        return topLevel
            .filter { $0.counts.total > 0 }
            .max { $0.counts.total < $1.counts.total }?
            .id ?? DeckID(1)
    }

    @ViewBuilder
    private var routed: some View {
        if let startupError = AmgiRoot.startupError {
            StartupErrorView(message: startupError)
        } else if onboardingCompleted {
            main
        } else {
            OnboardingView()
        }
    }

    private var main: some View {
        MainTabView(
            refreshID: refreshID,
            showReaderTab: showReaderTab,
            onImport: { showImport = true },
            onSelectStudyDeck: { pendingReviewDeckId = $0 }
        )
        .alert(
            "Couldn't switch profile",
            isPresented: $accountStore.hasSwitchFailure
        ) {
            Button("OK", role: .cancel) { accountStore.switchFailure = nil }
        } message: {
            Text(accountStore.switchFailure ?? "")
        }
        // still drives the tabs not yet on CollectionStore
        .syncFlow { refreshID = UUID() }
        .deckImport(isPresented: $showImport) {
            store.invalidateAll()
            refreshID = UUID()
        }
        .fullScreenCover(item: $pendingReviewDeckId) { deckId in
            ReviewView(deckId: deckId) {
                pendingReviewDeckId = nil
                store.invalidateAll()
                refreshID = UUID()
            }
        }
        .environment(\.lookupPopup, ReaderLookupPopup())
        .environment(\.dictionarySettings, ReaderDictionarySettings())
    }
}
