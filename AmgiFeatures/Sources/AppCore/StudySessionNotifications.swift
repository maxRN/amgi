//
//  StudySessionNotifications.swift
//  AppCore
//

public import Foundation

/// Study-session lifecycle, broadcast so the sync layer can react without
/// `ReviewFeature` importing `SyncFeature` (a feature→feature edge). Posted
/// on the main thread by `ReviewView`; observed by `SyncCoordinator`, which
/// holds automatic syncs off while a session runs and pushes the session's
/// progress once it ends.
extension Notification.Name {
    public static let studySessionDidStart = Notification.Name("AmgiStudySessionDidStart")
    public static let studySessionDidEnd = Notification.Name("AmgiStudySessionDidEnd")
}
