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

public enum HotkeyKind: String, Codable, Hashable, Sendable {
    /// Traditional modifier(s) + non-modifier key combo (e.g. ⌘⇧D, ⌥Space).
    case keyCombo
    /// Dedicated single modifier / Fn key (e.g. Right ⌘, Right ⌥, Fn).
    case singleModifier
}

public struct HotkeyBinding: Codable, Hashable, Sendable {
    /// Whether this shortcut is a modifier+key combo or a standalone single modifier / Fn key.
    public var kind: HotkeyKind
    /// macOS virtual key code (default: 0x36 = kVK_RightCommand).
    public var keyCode: UInt16
    /// Exact required modifier flags (for `.keyCombo`, extra Ctrl/Opt rejected; CapsLock ignored).
    public var modifiers: HotkeyModifierMask
    public var triggerMode: HotkeyTriggerMode
    public var strictLeftSideOnly: Bool

    /// Default binding: Hold Right ⌘ Command to speak, release to insert.
    public static let rightCommandPTT = HotkeyBinding(
        kind: .singleModifier,
        keyCode: 0x36, // kVK_RightCommand
        modifiers: [.command],
        triggerMode: .pushToTalk,
        strictLeftSideOnly: false
    )

    public static let rightOptionPTT = HotkeyBinding(
        kind: .singleModifier,
        keyCode: 0x3D, // kVK_RightOption
        modifiers: [.option],
        triggerMode: .pushToTalk,
        strictLeftSideOnly: false
    )

    public static let fnPTT = HotkeyBinding(
        kind: .singleModifier,
        keyCode: 0x3F, // kVK_Function
        modifiers: [],
        triggerMode: .pushToTalk,
        strictLeftSideOnly: false
    )

    public static let cmdShiftD = HotkeyBinding(
        kind: .keyCombo,
        keyCode: 0x02, // kVK_ANSI_D
        modifiers: [.command, .shift],
        triggerMode: .toggle,
        strictLeftSideOnly: false
    )

    public static let defaultBinding = rightCommandPTT

    enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiers
        case triggerMode
        case strictLeftSideOnly
    }

    public init(
        kind: HotkeyKind = .keyCombo,
        keyCode: UInt16 = 0x02,
        modifiers: HotkeyModifierMask = [.command, .shift],
        triggerMode: HotkeyTriggerMode = .toggle,
        strictLeftSideOnly: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.triggerMode = triggerMode
        self.strictLeftSideOnly = strictLeftSideOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(HotkeyKind.self, forKey: .kind) ?? .keyCombo
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0x02
        modifiers = try c.decodeIfPresent(HotkeyModifierMask.self, forKey: .modifiers) ?? [.command, .shift]
        triggerMode = try c.decodeIfPresent(HotkeyTriggerMode.self, forKey: .triggerMode) ?? .toggle
        strictLeftSideOnly = try c.decodeIfPresent(Bool.self, forKey: .strictLeftSideOnly) ?? false
    }

    public var keyLabel: String {
        Self.labelForKeyCode(keyCode)
    }

    public var displayString: String {
        if kind == .singleModifier {
            return Self.singleModifierLabel(for: keyCode)
        }
        return "\(modifiers.displaySymbols)\(keyLabel)"
    }

    public static func singleModifierMask(for keyCode: UInt16) -> HotkeyModifierMask {
        switch keyCode {
        case 0x36, 0x37: return [.command]
        case 0x3A, 0x3D: return [.option]
        case 0x38, 0x3C: return [.shift]
        case 0x3B, 0x3E: return [.control]
        default: return []
        }
    }

    public static func isSingleModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F:
            return true
        default:
            return false
        }
    }

    public static func singleModifierLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0x36: return "右 ⌘"
        case 0x37: return "左 ⌘"
        case 0x3D: return "右 ⌥"
        case 0x3A: return "左 ⌥"
        case 0x3C: return "右 ⇧"
        case 0x38: return "左 ⇧"
        case 0x3E: return "右 ⌃"
        case 0x3B: return "左 ⌃"
        case 0x3F: return "Fn"
        default: return labelForKeyCode(keyCode)
        }
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
        case 0x36: return "右 ⌘"
        case 0x37: return "左 ⌘"
        case 0x3D: return "右 ⌥"
        case 0x3A: return "左 ⌥"
        case 0x3C: return "右 ⇧"
        case 0x38: return "左 ⇧"
        case 0x3E: return "右 ⌃"
        case 0x3B: return "左 ⌃"
        case 0x3F: return "Fn"
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
    case secureInputEnded
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

    /// Reconciles stale `swallowedTriggerKeyDown` / `triggerKeyDebtActive` against live HID key state
    /// (`CGEventSource.keyState(.hidSystemState, key:)`) in case a trigger `keyUp` was dropped by the OS or another app.
    func reconcileStaleTriggerKeyDebtWithLiveHID()
}

public extension HotkeyControlling {
    func reconcileStaleTriggerKeyDebtWithLiveHID() {}
}
