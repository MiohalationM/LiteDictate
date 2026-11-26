import Foundation

/// Exact modifier set supported for configurable global hotkeys.
/// Explicitly excludes CapsLock (`.maskAlphaShift`).
public struct HotkeyModifierMask: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifierMask(rawValue: 1 << 0)
    public static let shift = HotkeyModifierMask(rawValue: 1 << 1)
    public static let option = HotkeyModifierMask(rawValue: 1 << 2)
    public static let control = HotkeyModifierMask(rawValue: 1 << 3)

    public var displaySymbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

public enum HotkeyTriggerMode: String, Codable, Hashable, Sendable {
    case toggle
    case pushToTalk

    public var displayTitle: String {
        switch self {
        case .toggle: return "按一下开始，再按结束"
        case .pushToTalk: return "按住说话，松开输入"
        }
    }

    public var shortTitle: String {
        switch self {
        case .toggle: return "按一下开关"
        case .pushToTalk: return "按住说话"
        }
    }
}

public struct HotkeyBinding: Codable, Hashable, Sendable {
    /// macOS virtual key code (default: 0x02 = kVK_ANSI_D).
    public var keyCode: UInt16
    /// Exact required modifier flags (extra Ctrl/Opt rejected; CapsLock ignored).
    public var modifiers: HotkeyModifierMask
    public var triggerMode: HotkeyTriggerMode
    public var strictLeftSideOnly: Bool

    public static let defaultBinding = HotkeyBinding(
        keyCode: 0x02,
        modifiers: [.command, .shift],
        triggerMode: .toggle,
        strictLeftSideOnly: false
    )

    public init(
        keyCode: UInt16 = 0x02,
        modifiers: HotkeyModifierMask = [.command, .shift],
        triggerMode: HotkeyTriggerMode = .toggle,
        strictLeftSideOnly: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.triggerMode = triggerMode
        self.strictLeftSideOnly = strictLeftSideOnly
    }

    public var keyLabel: String {
        Self.labelForKeyCode(keyCode)
    }

    public var displayString: String {
        "\(modifiers.displaySymbols)\(keyLabel)"
    }

    public static func labelForKeyCode(_ code: UInt16) -> String {
        switch code {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x31: return "Space"
        default: return String(format: "Key(0x%02X)", code)
        }
    }
}

public enum HotkeyEvent: Equatable, Sendable {
    case triggerStart(gestureGeneration: GestureGeneration)
    case triggerStop(gestureGeneration: GestureGeneration)
    case triggerToggle(gestureGeneration: GestureGeneration)
    case cancelEscape
    case systemReset(reason: String)
}

public protocol HotkeyControlling: AnyObject, Sendable {
    var isTapAlive: Bool { get }

    @discardableResult
    func start(
        binding: HotkeyBinding,
        disabledBundleIDs: Set<String>,
        shouldInterceptCancelEscape: AtomicBool,
        triggerKeyDebtActive: AtomicBool,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void
    ) -> Bool

    func stop()
    func updateBinding(_ binding: HotkeyBinding)
    func updateDisabledBundleIDs(_ bundleIDs: Set<String>)
    /// Temporarily suspends global hotkey interception (e.g., while recording a new shortcut in Settings).
    func setTemporarilySuspended(_ suspended: Bool)

    /// Live HID modifier query (`CGEventSource.flagsState(.hidSystemState)`)
    /// checking Command/Shift/Option/Control ONLY (explicitly excluding CapsLock).
    func areHIDModifiersClear() -> Bool
    func currentHIDModifierMask() -> HotkeyModifierMask
}
