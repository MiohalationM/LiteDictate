import AppKit
import Foundation
import ServiceManagement

public enum LaunchAtLoginError: LocalizedError, Sendable {
    case requiresAppBundle

    public var errorDescription: String? {
        switch self {
        case .requiresAppBundle:
            return "需从 /Applications/LiteDictate.app 运行才能配置开机自动启动"
        }
    }
}

/// Native macOS 14.0+ Launch at Login manager backed by `SMAppService.mainApp` (no LaunchAgent plist hacks).
/// Gracefully reports `.unavailable` when executed outside a `.app` bundle (such as `swift test`).
public final class LaunchAtLoginManager: LaunchAtLoginManaging, Sendable {
    public init() {}

    private static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    public func currentState() -> LaunchAtLoginState {
        guard Self.isRunningFromAppBundle else {
            return .unavailable
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard Self.isRunningFromAppBundle else {
            throw LaunchAtLoginError.requiresAppBundle
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openLoginItemsSettings() {
        if Thread.isMainThread {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            DispatchQueue.main.async {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
