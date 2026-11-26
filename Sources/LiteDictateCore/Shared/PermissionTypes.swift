import Foundation

public enum AuthorizationState: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
}

public enum PasteboardAccessState: String, Codable, Equatable, Sendable {
    /// macOS 14.x / early 15.x where `NSPasteboard.accessBehavior` is unavailable.
    case standard
    case alwaysAllow
    case alwaysDeny
    case ask
    case `default`
}

public enum SystemSettingsPane: String, Sendable {
    case microphone
    case inputMonitoring
    case accessibility
    case privacy
}

public struct PermissionSnapshot: Equatable, Sendable {
    public let microphone: AuthorizationState
    public let listenEventAccess: Bool
    public let postEventAccess: Bool
    public let accessibilityTrusted: Bool
    public let pasteboardAccess: PasteboardAccessState
    public let eventTapAlive: Bool
    public let secureInputEnabled: Bool

    public init(
        microphone: AuthorizationState = .notDetermined,
        listenEventAccess: Bool = false,
        postEventAccess: Bool = false,
        accessibilityTrusted: Bool = false,
        pasteboardAccess: PasteboardAccessState = .standard,
        eventTapAlive: Bool = false,
        secureInputEnabled: Bool = false
    ) {
        self.microphone = microphone
        self.listenEventAccess = listenEventAccess
        self.postEventAccess = postEventAccess
        self.accessibilityTrusted = accessibilityTrusted
        self.pasteboardAccess = pasteboardAccess
        self.eventTapAlive = eventTapAlive
        self.secureInputEnabled = secureInputEnabled
    }

    public var canCaptureAudio: Bool {
        microphone == .granted
    }

    public var canMonitorGlobalHotkey: Bool {
        listenEventAccess && eventTapAlive
    }

    public var canAutoPaste: Bool {
        postEventAccess && accessibilityTrusted && !secureInputEnabled && pasteboardAccess != .alwaysDeny
    }

    public var allCorePermissionsGranted: Bool {
        microphone == .granted && listenEventAccess && postEventAccess && accessibilityTrusted
    }
}

public protocol PermissionManaging: AnyObject, Sendable {
    func snapshot(eventTapAlive: Bool) -> PermissionSnapshot
    func isSecureEventInputEnabled() -> Bool
    func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void)
    func requestAccessibilityPrompt()
    @discardableResult func requestListenEventAccess() -> Bool
    @discardableResult func requestPostEventAccess() -> Bool
    func settingsURL(for pane: SystemSettingsPane) -> URL
}
