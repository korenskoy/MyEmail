//
//  NotificationService.swift
//  MyEmail
//
//  UNUserNotificationCenter wrapper. Posts notifications for new messages.
//  Click → navigate to message via userInfo { accountID, folderID, messageUID }.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    /// Set by AppDelegate to handle notification clicks.
    var onNotificationClick: ((UUID, UUID, UInt32) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let settings = await center.notificationSettings()
        LogService.log(.info, .notifications,
                       "Current settings: " +
                       "status=\(settings.authorizationStatus.rawValue) " +
                       "alert=\(settings.alertSetting.rawValue) " +
                       "sound=\(settings.soundSetting.rawValue) " +
                       "badge=\(settings.badgeSetting.rawValue) " +
                       "center=\(settings.notificationCenterSetting.rawValue)")

        // requestAuthorization only prompts when status == .notDetermined.
        // If .denied (or bundle lost its registration), re-prompt is silently no-op.
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                LogService.log(.info, .notifications,
                               "Prompt result: \(granted ? "granted" : "denied")")
            } catch {
                LogService.log(.error, .notifications,
                               "Authorization prompt failed", detail: "\(error)")
            }
        case .denied:
            LogService.log(.warning, .notifications,
                           "Notifications denied — open System Settings → " +
                           "Notifications → MyEmail (or reset via `tccutil reset " +
                           "Notifications ru.korenskoy.MyEmail` and relaunch)")
        case .authorized, .provisional, .ephemeral:
            LogService.log(.info, .notifications,
                           "Already authorized (no prompt shown)")
        @unknown default:
            LogService.log(.warning, .notifications,
                           "Unknown auth status: \(settings.authorizationStatus.rawValue)")
        }
    }

    // MARK: - Post notification for new message

    func postNewMessage(
        from: String, subject: String,
        accountID: UUID, folderID: UUID, messageUID: UInt32
    ) {
        let identifier = "\(accountID)-\(folderID)-\(messageUID)"
        LogService.log(.info, .notifications,
                       "Posting notification",
                       detail: "id=\(identifier) from=\(from) subj=\(subject)")

        // Check current authorization before posting — silent denial is the usual culprit
        center.getNotificationSettings { settings in
            LogService.log(.debug, .notifications,
                           "Auth status=\(settings.authorizationStatus.rawValue) " +
                           "alert=\(settings.alertSetting.rawValue) " +
                           "sound=\(settings.soundSetting.rawValue) " +
                           "badge=\(settings.badgeSetting.rawValue)",
                           detail: "id=\(identifier)")
        }

        let content = UNMutableNotificationContent()
        content.title = from
        content.body = subject
        content.sound = .default
        content.userInfo = [
            "accountID": accountID.uuidString,
            "folderID": folderID.uuidString,
            "messageUID": Int(messageUID)
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                LogService.log(.error, .notifications,
                               "Failed to post notification",
                               detail: "id=\(identifier) err=\(error)")
            } else {
                LogService.log(.info, .notifications,
                               "Notification delivered to center",
                               detail: "id=\(identifier)")
            }
        }
    }

    // MARK: - Update badge

    func updateBadge(count: Int) {
        center.setBadgeCount(count) { error in
            if let error {
                LogService.log(.error, .notifications,
                               "Failed to set badge", detail: "\(error)")
            }
        }
    }

    // MARK: - Setup delegate

    func setupDelegate() {
        center.delegate = self
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: @preconcurrency UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let accountStr = info["accountID"] as? String,
              let folderStr = info["folderID"] as? String,
              let uid = info["messageUID"] as? Int,
              let accountID = UUID(uuidString: accountStr),
              let folderID = UUID(uuidString: folderStr)
        else {
            completionHandler()
            return
        }

        Task { @MainActor in
            onNotificationClick?(accountID, folderID, UInt32(uid))
            NSApp.activate()
        }
        completionHandler()
    }

    // Show notification even when app is frontmost
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
