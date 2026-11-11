//
//  AppGroup.swift
//  AppCore
//
//  Created by Vladimir Gusev on 20.08.2026.
//

public import Foundation

/// The App Group container shared by the app, the widget extension, and the
/// watch.
///
/// The identifier is a build setting, not a literal: `AMGI_APP_GROUP` in
/// `AmgiApp/Identity.xcconfig` (overridable per developer in a gitignored
/// `Local.xcconfig`) feeds both `.entitlements` files and the `AmgiAppGroup`
/// key in the app's and the widget's Info.plist, which is read here. That
/// keeps code and entitlements from drifting apart — a mismatch silently
/// splits the container in two, and the symptom (the widget reading an empty
/// store) looks nothing like a typo. `Theme/UserDefaults+AppGroup.swift`
/// repeats the lookup because Theme is deliberately dependency-free.
///
/// Processes without the key (the watch, previews, package tests) fall back
/// to the upstream default.
public enum AppGroup: Sendable {
    public static let identifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AmgiAppGroup") as? String
            ?? "group.com.amgiapp"

    /// Shared defaults, falling back to `.standard` when the entitlement is
    /// missing, which is the case in previews and unit tests.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
