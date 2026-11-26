import CoreGraphics
import Foundation

/// Virtual key codes used by the hotkey state machine.
public enum HotkeyVirtualKeyCode {
    public static let ansiD: UInt16 = 0x02
    public static let ansiV: UInt16 = 0x09
    public static let escape: UInt16 = 0x35
}

/// Device-dependent left/right modifier mask bits from `<IOKit/hidsystem/IOLLEvent.h>`.
public enum DeviceModifierFlags {
    public static let leftControl: UInt64 = 0x0000_0001
    public static let leftShift: UInt64 = 0x0000_0002
    public static let rightShift: UInt64 = 0x0000_0004
    public static let leftCommand: UInt64 = 0x0000_0008
    public static let rightCommand: UInt64 = 0x0000_0010
    public static let leftOption: UInt64 = 0x0000_0020
    public static let rightOption: UInt64 = 0x0000_0040
    public static let rightControl: UInt64 = 0x0000_2000
}

/// Normalized input events fed into `HotkeyDebtMachine`.
public enum RawKeyEventKind: Equatable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
    case tapDisabledByTimeout
    case tapDisabledByUserInput
    case systemSleepOrLock
    case secureInputActivated
}

/// Pure value representation of an event seen by the EventTap callback.
public struct RawKeyEvent: Equatable, Sendable {
    public let kind: RawKeyEventKind
    public let keyCode: UInt16
    public let isAutorepeat: Bool
    /// Raw `CGEventFlags.rawValue` (may include device-dependent left/right bits and CapsLock).
    public let rawFlags: UInt64
    public let eventSourceUserData: Int64
    public let frontmostBundleID: String?

    public init(
        kind: RawKeyEventKind,
        keyCode: UInt16 = 0,
        isAutorepeat: Bool = false,
        rawFlags: UInt64 = 0,
        eventSourceUserData: Int64 = 0,
        frontmostBundleID: String? = nil
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.isAutorepeat = isAutorepeat
        self.rawFlags = rawFlags
        self.eventSourceUserData = eventSourceUserData
        self.frontmostBundleID = frontmostBundleID
    }
}

/// Disposition returned to the EventTap callback.
public enum HotkeyEventAction: Equatable, Sendable {
    case passThrough
    case swallow
}

/// Deterministic output of `HotkeyDebtMachine.process(_:)`.
public struct HotkeyMachineDecision: Equatable, Sendable {
    public let action: HotkeyEventAction
    public let emittedEvents: [HotkeyEvent]

    public init(action: HotkeyEventAction, emittedEvents: [HotkeyEvent] = []) {
        self.action = action
        self.emittedEvents = emittedEvents
    }
}

/// Pure, deterministic, EventTap-decoupled hotkey & paired key-debt state machine.
///
/// Ownership contract:
/// - Owned exclusively by the EventTap thread in production (zero locks inside callback).
/// - Reads `shouldInterceptCancelEscape` lock-free (`acquire`) — never queries coordinator synchronously.
/// - Mirrors `swallowedTriggerKeyDown` lock-free (`release`) to `triggerKeyDebtActive` for the commit arbiter.
public final class HotkeyDebtMachine {
    public private(set) var binding: HotkeyBinding
    public private(set) var disabledBundleIDs: Set<String>

    private let shouldInterceptCancelEscape: AtomicBool
    private let triggerKeyDebtActive: AtomicBool
    private let temporarilySuspended: AtomicBool?

    /// Paired debt for the trigger key: once trigger `keyDown` is swallowed,
    /// all subsequent autorepeats and `keyUp` for `swallowedTriggerKeyCode` MUST be swallowed
    /// even if modifiers are released first or recording already ended.
    public private(set) var swallowedTriggerKeyDown: Bool = false
    public private(set) var swallowedTriggerKeyCode: UInt16?

    /// Paired debt for Escape (`kVK_Escape`).
    public private(set) var swallowedEscapeKeyDown: Bool = false

    /// Active Push-To-Talk chord state.
    public private(set) var pttActive: Bool = false
    public private(set) var activePTTGeneration: GestureGeneration?

    /// Monotonic gesture generation counter for PTT idempotency and request correlation.
    public private(set) var gestureGeneration: GestureGeneration = 0

    /// Set `true` after tap disabled / sleep / lock / Secure Input until all relevant keys are released.
    public private(set) var suppressUntilRelease: Bool = false

    /// Tracks whether the trigger key was physically down when `suppressUntilRelease` engaged.
    public private(set) var waitingForTriggerReleaseAfterReset: Bool = false
    private var triggerKeyCodePendingReleaseAfterReset: UInt16?

    public init(
        binding: HotkeyBinding = .defaultBinding,
        disabledBundleIDs: Set<String> = [],
        shouldInterceptCancelEscape: AtomicBool,
        triggerKeyDebtActive: AtomicBool,
        temporarilySuspended: AtomicBool? = nil
    ) {
        self.binding = binding
        self.disabledBundleIDs = disabledBundleIDs
        self.shouldInterceptCancelEscape = shouldInterceptCancelEscape
        self.triggerKeyDebtActive = triggerKeyDebtActive
        self.temporarilySuspended = temporarilySuspended
        self.triggerKeyDebtActive.store(false, ordering: .release)
    }

    /// Resets transient key-debt and PTT state cleanly when entering or leaving temporary suspension
    /// (e.g., while Settings is recording a new shortcut).
    public func resetDebtForSuspendOrResume() {
        swallowedTriggerKeyDown = false
        swallowedTriggerKeyCode = nil
        swallowedEscapeKeyDown = false
        pttActive = false
        activePTTGeneration = nil
        suppressUntilRelease = false
        waitingForTriggerReleaseAfterReset = false
        triggerKeyCodePendingReleaseAfterReset = nil
        triggerKeyDebtActive.store(false, ordering: .release)
    }

    public func updateBinding(_ newBinding: HotkeyBinding) {
        self.binding = newBinding
    }

    public func updateDisabledBundleIDs(_ bundleIDs: Set<String>) {
        self.disabledBundleIDs = bundleIDs
    }

    /// Clears stale `suppressUntilRelease` when live HID state confirms no relevant modifiers are held
    /// and the trigger key was not held across the reset (e.g., after screen unlock, system wake,
    /// idle tap timeout, or Secure Input ending).
    public func clearSuppressionIfKeysReleased(currentRawFlags: UInt64) {
        guard suppressUntilRelease, !waitingForTriggerReleaseAfterReset else {
            return
        }
        let currentMods = Self.extractModifierMask(from: currentRawFlags)
        if currentMods.intersection(binding.modifiers).isEmpty {
            suppressUntilRelease = false
        }
    }

    /// Reconciles `suppressUntilRelease` when Secure Input transitions `true -> false` right as a
    /// new user event arrives (because macOS withholds intermediate `keyUp`/`flagsChanged` while Secure Input is active).
    /// Preserves suppression if a trigger key was held across reset or an autorepeat is still firing.
    public func reconcileSuppressionAfterSecureInputEnded(
        incomingKind: RawKeyEventKind,
        incomingIsAutorepeat: Bool,
        currentRawFlags: UInt64
    ) {
        guard suppressUntilRelease, !waitingForTriggerReleaseAfterReset else {
            return
        }
        let currentMods = Self.extractModifierMask(from: currentRawFlags)
        if currentMods.intersection(binding.modifiers).isEmpty {
            suppressUntilRelease = false
            return
        }
        // If Secure Input just ended and the first observed event is a non-chord flags transition
        // (e.g. pressing Cmd first on the way to Cmd+Shift+D) rather than an autorepeat of a held key,
        // lift stale suppression so the very first Cmd+Shift+D after Secure Input works immediately.
        if incomingKind == .flagsChanged && !Self.matchesModifiers(rawFlags: currentRawFlags, binding: binding) {
            suppressUntilRelease = false
        } else if incomingKind == .keyDown && !incomingIsAutorepeat && !Self.matchesModifiers(rawFlags: currentRawFlags, binding: binding) {
            suppressUntilRelease = false
        }
    }

    /// Extracts ONLY `[.command, .shift, .option, .control]` from raw `CGEventFlags`.
    /// Explicitly IGNORES CapsLock (`.maskAlphaShift`), numeric pad, fn, help, and device bits.
    @inline(__always)
    public static func extractModifierMask(from rawFlags: UInt64) -> HotkeyModifierMask {
        let flags = CGEventFlags(rawValue: rawFlags)
        var mask: HotkeyModifierMask = []
        if flags.contains(.maskCommand) { mask.insert(.command) }
        if flags.contains(.maskShift) { mask.insert(.shift) }
        if flags.contains(.maskAlternate) { mask.insert(.option) }
        if flags.contains(.maskControl) { mask.insert(.control) }
        return mask
    }

    /// Exact modifier matching against `binding`:
    /// - Requires exact equality on `[.command, .shift, .option, .control]` (rejects extra Ctrl/Opt).
    /// - Explicitly ignores CapsLock (`.maskAlphaShift`).
    /// - When `binding.strictLeftSideOnly == true`, verifies left-side device bits are set
    ///   and right-side device bits are clear for every required modifier.
    public static func matchesModifiers(rawFlags: UInt64, binding: HotkeyBinding) -> Bool {
        let extracted = extractModifierMask(from: rawFlags)
        guard extracted == binding.modifiers else {
            return false
        }

        guard binding.strictLeftSideOnly else {
            return true
        }

        if binding.modifiers.contains(.command) {
            guard (rawFlags & DeviceModifierFlags.leftCommand) != 0,
                  (rawFlags & DeviceModifierFlags.rightCommand) == 0
            else { return false }
        }
        if binding.modifiers.contains(.shift) {
            guard (rawFlags & DeviceModifierFlags.leftShift) != 0,
                  (rawFlags & DeviceModifierFlags.rightShift) == 0
            else { return false }
        }
        if binding.modifiers.contains(.option) {
            guard (rawFlags & DeviceModifierFlags.leftOption) != 0,
                  (rawFlags & DeviceModifierFlags.rightOption) == 0
            else { return false }
        }
        if binding.modifiers.contains(.control) {
            guard (rawFlags & DeviceModifierFlags.leftControl) != 0,
                  (rawFlags & DeviceModifierFlags.rightControl) == 0
            else { return false }
        }
        return true
    }

    /// Processes one normalized input/system event and returns whether to swallow or pass through
    /// plus any semantic `HotkeyEvent`s to dispatch asynchronously.
    public func process(_ event: RawKeyEvent) -> HotkeyMachineDecision {
        // RULE 0 (LINE 1): Never intercept our own synthetic Cmd+V ("LDIC" = 0x4C444943).
        if event.eventSourceUserData == LiteDictateConstants.syntheticEventUserData {
            return HotkeyMachineDecision(action: .passThrough)
        }

        // RULE 0.5 (P1-13): Pass all keystrokes through untouched while temporarily suspended (e.g. shortcut recorder).
        if temporarilySuspended?.load(ordering: .acquire) == true {
            return HotkeyMachineDecision(action: .passThrough)
        }

        // RULE 1: System / tap reset events.
        switch event.kind {
        case .tapDisabledByTimeout:
            return handleSystemReset(reason: "tapDisabledByTimeout")
        case .tapDisabledByUserInput:
            return handleSystemReset(reason: "tapDisabledByUserInput")
        case .systemSleepOrLock:
            return handleSystemReset(reason: "systemSleepOrLock")
        case .secureInputActivated:
            return handleSystemReset(reason: "secureInputActivated")
        case .keyDown, .keyUp, .flagsChanged:
            break
        }

        // RULE 2: Paired key-debt clearing ALWAYS runs before bundle blacklist or trigger logic
        // so an already-swallowed keyDown NEVER leaks autorepeats or keyUp and NEVER strands debt.
        if swallowedTriggerKeyDown, let debtKeyCode = swallowedTriggerKeyCode, event.keyCode == debtKeyCode {
            switch event.kind {
            case .keyDown:
                // Swallow all autorepeats (or duplicate keyDown) regardless of current modifiers.
                return HotkeyMachineDecision(action: .swallow)
            case .keyUp:
                swallowedTriggerKeyDown = false
                swallowedTriggerKeyCode = nil
                triggerKeyDebtActive.store(false, ordering: .release)

                if pttActive, let gen = activePTTGeneration {
                    pttActive = false
                    activePTTGeneration = nil
                    return HotkeyMachineDecision(
                        action: .swallow,
                        emittedEvents: [.triggerStop(gestureGeneration: gen)]
                    )
                }
                return HotkeyMachineDecision(action: .swallow)
            case .flagsChanged:
                break
            default:
                break
            }
        }

        if swallowedEscapeKeyDown, event.keyCode == HotkeyVirtualKeyCode.escape {
            switch event.kind {
            case .keyDown:
                return HotkeyMachineDecision(action: .swallow)
            case .keyUp:
                swallowedEscapeKeyDown = false
                return HotkeyMachineDecision(action: .swallow)
            case .flagsChanged:
                break
            default:
                break
            }
        }

        // RULE 3: Post-reset suppression until all relevant keys are released.
        if suppressUntilRelease {
            return handleSuppressedEvent(event)
        }

        // RULE 4: Modifier flag transitions (never swallow flagsChanged).
        if event.kind == .flagsChanged {
            if pttActive, let gen = activePTTGeneration {
                // In PTT mode, releasing any required modifier ends the PTT gesture,
                // while `swallowedTriggerKeyDown` stays true until trigger keyUp clears debt.
                if !Self.matchesModifiers(rawFlags: event.rawFlags, binding: binding) {
                    pttActive = false
                    activePTTGeneration = nil
                    return HotkeyMachineDecision(
                        action: .passThrough,
                        emittedEvents: [.triggerStop(gestureGeneration: gen)]
                    )
                }
            }
            return HotkeyMachineDecision(action: .passThrough)
        }

        // RULE 5: Global Escape cancellation — lock-free `acquire` read, never sync coordinator call.
        if event.kind == .keyDown, event.keyCode == HotkeyVirtualKeyCode.escape {
            let activeModifiers = Self.extractModifierMask(from: event.rawFlags)
            // Only plain Escape (ignoring CapsLock) cancels; preserve Cmd+Opt+Esc etc.
            if activeModifiers.isEmpty, shouldInterceptCancelEscape.load(ordering: .acquire) {
                swallowedEscapeKeyDown = true
                // Cancel any active PTT state so later trigger keyUp doesn't emit a redundant stop,
                // while keeping `swallowedTriggerKeyDown` intact so the trigger keyUp is still swallowed.
                pttActive = false
                activePTTGeneration = nil
                return HotkeyMachineDecision(
                    action: .swallow,
                    emittedEvents: [.cancelEscape]
                )
            }
            return HotkeyMachineDecision(action: .passThrough)
        }

        // RULE 6: Disabled bundle IDs pass-through for new hotkey triggers.
        if let bundleID = event.frontmostBundleID, disabledBundleIDs.contains(bundleID) {
            return HotkeyMachineDecision(action: .passThrough)
        }

        // RULE 7: New trigger chord detection.
        if event.kind == .keyDown,
           !event.isAutorepeat,
           event.keyCode == binding.keyCode,
           Self.matchesModifiers(rawFlags: event.rawFlags, binding: binding)
        {
            gestureGeneration &+= 1
            let currentGeneration = gestureGeneration

            swallowedTriggerKeyDown = true
            swallowedTriggerKeyCode = binding.keyCode
            triggerKeyDebtActive.store(true, ordering: .release)

            switch binding.triggerMode {
            case .toggle:
                return HotkeyMachineDecision(
                    action: .swallow,
                    emittedEvents: [.triggerToggle(gestureGeneration: currentGeneration)]
                )
            case .pushToTalk:
                pttActive = true
                activePTTGeneration = currentGeneration
                return HotkeyMachineDecision(
                    action: .swallow,
                    emittedEvents: [.triggerStart(gestureGeneration: currentGeneration)]
                )
            }
        }

        return HotkeyMachineDecision(action: .passThrough)
    }

    private func handleSystemReset(reason: String) -> HotkeyMachineDecision {
        let hadTriggerHeld = swallowedTriggerKeyDown
        let heldKeyCode = swallowedTriggerKeyCode

        swallowedTriggerKeyDown = false
        swallowedTriggerKeyCode = nil
        swallowedEscapeKeyDown = false
        pttActive = false
        activePTTGeneration = nil
        triggerKeyDebtActive.store(false, ordering: .release)

        suppressUntilRelease = true
        waitingForTriggerReleaseAfterReset = hadTriggerHeld
        triggerKeyCodePendingReleaseAfterReset = heldKeyCode

        return HotkeyMachineDecision(
            action: .passThrough,
            emittedEvents: [.systemReset(reason: reason)]
        )
    }

    private func handleSuppressedEvent(_ event: RawKeyEvent) -> HotkeyMachineDecision {
        let currentMods = Self.extractModifierMask(from: event.rawFlags)
        let relevantModsStillHeld = !currentMods.intersection(binding.modifiers).isEmpty

        switch event.kind {
        case .keyUp:
            var shouldSwallow = false
            if waitingForTriggerReleaseAfterReset,
               let pendingCode = triggerKeyCodePendingReleaseAfterReset,
               event.keyCode == pendingCode
            {
                waitingForTriggerReleaseAfterReset = false
                triggerKeyCodePendingReleaseAfterReset = nil
                shouldSwallow = true
            } else if event.keyCode == binding.keyCode {
                waitingForTriggerReleaseAfterReset = false
                triggerKeyCodePendingReleaseAfterReset = nil
            }

            if !waitingForTriggerReleaseAfterReset && !relevantModsStillHeld {
                suppressUntilRelease = false
            }
            return HotkeyMachineDecision(action: shouldSwallow ? .swallow : .passThrough)

        case .flagsChanged:
            if !waitingForTriggerReleaseAfterReset && !relevantModsStillHeld {
                suppressUntilRelease = false
            }
            return HotkeyMachineDecision(action: .passThrough)

        case .keyDown:
            if waitingForTriggerReleaseAfterReset,
               let pendingCode = triggerKeyCodePendingReleaseAfterReset,
               event.keyCode == pendingCode
            {
                // Swallow lingering autorepeats of the key that was held across the reset.
                return HotkeyMachineDecision(action: .swallow)
            }
            // Do not fire any hotkey while suppressed.
            return HotkeyMachineDecision(action: .passThrough)

        default:
            return HotkeyMachineDecision(action: .passThrough)
        }
    }
}
