// NotificationService.swift
// TECH-SPEC §4.1 `NotificationService` row, plan U9: `UNUserNotificationCenter`
// wrapper. Fires on OBSERVED status transitions only (dedup/relaunch logic
// lives in `HistoryViewModel`, which calls into this service once per
// genuine transition). Routing:
//   - ready -> success copy with question count (PRD F4.1).
//   - readyUnverified -> "agent status unknown" copy, NOT success copy.
//   - failed + errorCode == .auth -> routes to Settings -> API key (a
//     placeholder action here; SettingsWindow itself is U10 — see
//     `onOpenSettingsApiKey`, clearly marked below).
//   - failed (other) -> includes userMessage; action triggers
//     `captures.retry`.
// Clicking a ready/readyUnverified notification opens the deep link via the
// same `capturesMarkOpened`-then-open path as a History row (delegated back
// through `onOpenDeepLink`, wired by `AppDelegate` to
// `HistoryViewModel.openDeepLink`).
//
// @MainActor per TECH-SPEC §4.1's concurrency map.

import Foundation
import UserNotifications
import WhistleCore

// MARK: - UNUserNotificationCenter seam

/// Abstraction over `UNUserNotificationCenter` so tests never touch the real
/// notification center (which requires an authorized, running app + would
/// pop real system notifications during `xcodebuild test`).
public protocol UserNotificationCenting: AnyObject {
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)?)
}

extension UNUserNotificationCenter: UserNotificationCenting {
    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    public func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)?) {
        add(request, withCompletionHandler: completion)
    }
}

/// Test double — records every notification "posted" without touching
/// `UNUserNotificationCenter`.
public final class FakeUserNotificationCenter: UserNotificationCenting {
    public struct Posted: Equatable {
        public let identifier: String
        public let title: String
        public let body: String
        public let userInfo: [String: String]
    }

    public private(set) var authorizationRequested = false
    public private(set) var posted: [Posted] = []
    public var authorizationGranted = true

    public init() {}

    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        authorizationRequested = true
        completion(authorizationGranted)
    }

    public func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)?) {
        let content = request.content
        let userInfo = (content.userInfo as? [String: String]) ?? [:]
        posted.append(Posted(identifier: request.identifier, title: content.title, body: content.body, userInfo: userInfo))
        completion?(nil)
    }
}

// MARK: - Routing actions

/// What a notification click (or its action button) should do. `AppDelegate`
/// maps these to real behavior; tests assert directly on this enum so they
/// never need a real `UNNotification`.
public enum NotificationRoute: Equatable {
    /// Open the capture's deep link (calls `captures.markOpened` first).
    case openDeepLink(recordId: String)
    /// Route to Settings -> API key (the real SettingsWindow's API-key
    /// section, U10).
    case openSettingsApiKey
    /// Call `captures.retry` for this capture.
    case retry(recordId: String)
}

private enum UserInfoKey {
    static let route = "route"
    static let recordId = "recordId"
}

private enum RouteKind: String {
    case deepLink
    case settingsApiKey
    case retry
}

// MARK: - NotificationServiceProtocol

/// The seam `HistoryViewModel` depends on, so its tests can inject a fake
/// and assert exactly which notification fired for which transition without
/// touching `UNUserNotificationCenter` at all.
@MainActor
public protocol NotificationServiceProtocol: AnyObject {
    func notifyReady(_ record: ServerCaptureRecord)
    func notifyReadyUnverified(_ record: ServerCaptureRecord)
    func notifyFailed(_ record: ServerCaptureRecord)
}

@MainActor
public final class NotificationService: NSObject, NotificationServiceProtocol, UNUserNotificationCenterDelegate {
    private let center: any UserNotificationCenting
    private var authorizationRequested = false

    /// Invoked when a notification (or its action) resolves to a route.
    /// `AppDelegate` wires this to `HistoryViewModel.openDeepLink` /
    /// `captures.retry` / the Settings placeholder.
    public var onRoute: (NotificationRoute) -> Void = { _ in }

    public init(center: any UserNotificationCenting = UNUserNotificationCenter.current()) {
        self.center = center
        super.init()
        if let real = center as? UNUserNotificationCenter {
            real.delegate = self
        }
    }

    /// Requests notification authorization lazily — the first time a
    /// notification actually needs to be posted, not at app launch (plan U9:
    /// "request authorization lazily").
    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization { _ in }
    }

    // MARK: - Firing (called by HistoryViewModel on observed transitions)

    public func notifyReady(_ record: ServerCaptureRecord) {
        requestAuthorizationIfNeeded()
        let count = record.clarifyingQuestions?.count ?? 0
        let body = count > 0
            ? "Your capture is ready, with \(count) clarifying question\(count == 1 ? "" : "s")."
            : "Your capture is ready."
        post(
            identifier: "ready-\(record.id)",
            title: "Ready",
            body: body,
            route: .openDeepLink(recordId: record.id)
        )
    }

    public func notifyReadyUnverified(_ record: ServerCaptureRecord) {
        requestAuthorizationIfNeeded()
        post(
            identifier: "ready-unverified-\(record.id)",
            title: "Sent",
            body: "Agent status unknown — open in Conductor to check progress.",
            route: .openDeepLink(recordId: record.id)
        )
    }

    public func notifyFailed(_ record: ServerCaptureRecord) {
        requestAuthorizationIfNeeded()
        if record.errorCode == .auth {
            post(
                identifier: "failed-auth-\(record.id)",
                title: "Sign-in needed",
                body: "Your Conductor API key needs attention.",
                route: .openSettingsApiKey
            )
        } else {
            let message = record.error ?? "Something went wrong."
            post(
                identifier: "failed-\(record.id)",
                title: "Capture failed",
                body: message,
                route: .retry(recordId: record.id)
            )
        }
    }

    // MARK: - Posting

    private func post(identifier: String, title: String, body: String, route: NotificationRoute) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = Self.encodeRoute(route)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request, completion: nil)
    }

    private static func encodeRoute(_ route: NotificationRoute) -> [String: String] {
        switch route {
        case .openDeepLink(let recordId):
            return [UserInfoKey.route: RouteKind.deepLink.rawValue, UserInfoKey.recordId: recordId]
        case .openSettingsApiKey:
            return [UserInfoKey.route: RouteKind.settingsApiKey.rawValue]
        case .retry(let recordId):
            return [UserInfoKey.route: RouteKind.retry.rawValue, UserInfoKey.recordId: recordId]
        }
    }

    public static func decodeRoute(from userInfo: [String: String]) -> NotificationRoute? {
        guard let rawKind = userInfo[UserInfoKey.route], let kind = RouteKind(rawValue: rawKind) else { return nil }
        switch kind {
        case .deepLink:
            guard let recordId = userInfo[UserInfoKey.recordId] else { return nil }
            return .openDeepLink(recordId: recordId)
        case .settingsApiKey:
            return .openSettingsApiKey
        case .retry:
            guard let recordId = userInfo[UserInfoKey.recordId] else { return nil }
            return .retry(recordId: recordId)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (real notification-center path)

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even while the app is foregrounded (there is no
        // persistent status menu -- notifications are the only in-flight
        // status channel, TECH-SPEC §4.1).
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = (response.notification.request.content.userInfo as? [String: String]) ?? [:]
        if let route = Self.decodeRoute(from: userInfo) {
            onRoute(route)
        }
        completionHandler()
    }
}
