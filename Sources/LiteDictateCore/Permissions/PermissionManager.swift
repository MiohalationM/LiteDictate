import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Injectable capability probe set enabling deterministic unit testing alongside real macOS probing.
public struct PermissionProbes: Sendable {
    public let microphoneStatus: @Sendable () -> AuthorizationState
    public let listenEventAccess: @Sendable () -> Bool
    public let postEventAccess: @Sendable () -> Bool
    public let accessibilityTrusted: @Sendable () -> Bool
    public let pasteboardAccess: @Sendable () -> PasteboardAccessState
    public let secureInputEnabled: @Sendable () -> Bool
    public let requestMicrophone: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    public let requestAccessibility: @Sendable () -> Void
    public let requestListenEvent: @Sendable () -> Bool
    public let requestPostEvent: @Sendable () -> Bool

    public init(
        microphoneStatus: @escaping @Sendable () -> AuthorizationState,
        listenEventAccess: @escaping @Sendable () -> Bool,
        postEventAccess: @escaping @Sendable () -> Bool,
        accessibilityTrusted: @escaping @Sendable () -> Bool,
        pasteboardAccess: @escaping @Sendable () -> PasteboardAccessState,
        secureInputEnabled: @escaping @Sendable () -> Bool,
        requestMicrophone: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
        requestAccessibility: @escaping @Sendable () -> Void,
        requestListenEvent: @escaping @Sendable () -> Bool,
        requestPostEvent: @escaping @Sendable () -> Bool
    ) {
        self.microphoneStatus = microphoneStatus
        self.listenEventAccess = listenEventAccess
        self.postEventAccess = postEventAccess
        self.accessibilityTrusted = accessibilityTrusted
        self.pasteboardAccess = pasteboardAccess
        self.secureInputEnabled = secureInputEnabled
        self.requestMicrophone = requestMicrophone
        self.requestAccessibility = requestAccessibility
        self.requestListenEvent = requestListenEvent
        self.requestPostEvent = requestPostEvent
    }

    public static let live = PermissionProbes(
        microphoneStatus: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .denied:
                return .denied
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            @unknown default:
                return .denied
            }
        },
        listenEventAccess: {
            CGPreflightListenEventAccess()
        },
        postEventAccess: {
            CGPreflightPostEventAccess()
        },
        accessibilityTrusted: {
            AXIsProcessTrusted()
        },
        pasteboardAccess: {
            PermissionManager.livePasteboardAccessState()
        },
        secureInputEnabled: {
            IsSecureEventInputEnabled()
        },
        requestMicrophone: { completion in
            PermissionManager.runOnMainThreadAsync {
                PermissionManager.activateForSystemPromptOnMainThread()
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    completion(granted)
                }
            }
        },
        requestAccessibility: {
            PermissionManager.runOnMainThreadSync {
                PermissionManager.activateForSystemPromptOnMainThread()
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        },
        requestListenEvent: {
            PermissionManager.runOnMainThreadSync {
                PermissionManager.activateForSystemPromptOnMainThread()
                return CGRequestListenEventAccess()
            }
        },
        requestPostEvent: {
            PermissionManager.runOnMainThreadSync {
                PermissionManager.activateForSystemPromptOnMainThread()
                return CGRequestPostEventAccess()
            }
        }
    )
}

/// Independent per-capability macOS 14.0+ permission manager.
/// Never infers one capability from another and safely guards macOS 15.4+ `NSPasteboard.accessBehavior`.
public final class PermissionManager: PermissionManaging, Sendable {
    private let probes: PermissionProbes

    public init(probes: PermissionProbes = .live) {
        self.probes = probes
    }

    public func snapshot(eventTapAlive: Bool) -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: probes.microphoneStatus(),
            listenEventAccess: probes.listenEventAccess(),
            postEventAccess: probes.postEventAccess(),
            accessibilityTrusted: probes.accessibilityTrusted(),
            pasteboardAccess: probes.pasteboardAccess(),
            eventTapAlive: eventTapAlive,
            secureInputEnabled: probes.secureInputEnabled()
        )
    }

    public func isSecureEventInputEnabled() -> Bool {
        probes.secureInputEnabled()
    }

    public func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        probes.requestMicrophone(completion)
    }

    public func requestAccessibilityPrompt() {
        probes.requestAccessibility()
    }

    @discardableResult
    public func requestListenEventAccess() -> Bool {
        probes.requestListenEvent()
    }

    @discardableResult
    public func requestPostEventAccess() -> Bool {
        probes.requestPostEvent()
    }

    public func settingsURL(for pane: SystemSettingsPane) -> URL {
        let raw: String
        switch pane {
        case .microphone:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .inputMonitoring:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .privacy:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }
        return URL(string: raw)!
    }

    @discardableResult
    public func openSystemSettings(for pane: SystemSettingsPane) -> Bool {
        let url = settingsURL(for: pane)
        return Self.runOnMainThreadSync {
            let opened = NSWorkspace.shared.open(url)
            if let settingsApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systempreferences"
            ).first {
                _ = settingsApp.activate(options: [.activateAllWindows])
            }
            return opened
        }
    }

    @MainActor
    static func activateForSystemPromptOnMainThread() {
        NSApp?.activate(ignoringOtherApps: true)
    }

    static func runOnMainThreadSync<T: Sendable>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    static func runOnMainThreadAsync(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        }
    }

    /// Queries `NSPasteboard.general.accessBehavior` on macOS 15.4+ (with `#available` + runtime selector check),
    /// falling back gracefully to `.standard` on macOS 14.x / early 15.x.
    public static func livePasteboardAccessState() -> PasteboardAccessState {
        if #available(macOS 15.4, *) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.responds(to: #selector(getter: NSPasteboard.accessBehavior)) else {
                return .standard
            }
            switch pasteboard.accessBehavior {
            case .alwaysAllow:
                return .alwaysAllow
            case .alwaysDeny:
                return .alwaysDeny
            case .ask:
                return .ask
            case .default:
                return .default
            @unknown default:
                return .default
            }
        } else {
            return .standard
        }
    }
}
