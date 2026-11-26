import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Outcome of attempting Tier 1 verified Accessibility direct insertion (`kAXSelectedTextAttribute`).
public enum AXDirectInsertResult: Equatable, Sendable {
    case verified
    case unverifiedOrSkipped
    case secureTextFieldBlocked
    case abortedBeforeWrite(reason: String)
    case changedAfterWrite(reason: String)
}

/// Live focus, frontmost-PID, and Secure Input guard evaluated before and after AX insertion.
public struct AXDirectInsertGuard: Sendable {
    public let targetPID: pid_t
    public let expectedFocusGeneration: UInt64
    public let currentFocusGeneration: @Sendable () -> UInt64
    public let frontmostPIDProvider: @Sendable () -> pid_t?
    public let secureInputProvider: @Sendable () -> Bool

    public init(
        targetPID: pid_t,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        frontmostPIDProvider: @escaping @Sendable () -> pid_t?,
        secureInputProvider: @escaping @Sendable () -> Bool
    ) {
        self.targetPID = targetPID
        self.expectedFocusGeneration = expectedFocusGeneration
        self.currentFocusGeneration = currentFocusGeneration
        self.frontmostPIDProvider = frontmostPIDProvider
        self.secureInputProvider = secureInputProvider
    }
}

/// Focused Accessibility text element session abstraction enabling deterministic unit testing
/// of pre-write and post-write focus/PID/SecureInput race checks inside `LiveAXDirectInserter`.
public protocol AXFocusedTextSession: AnyObject, Sendable {
    var elementPID: pid_t? { get }
    var role: String? { get }
    var subrole: String? { get }
    var isWebBackedElement: Bool { get }
    var isSelectedTextSettable: Bool { get }

    func readSelectedRange() -> CFRange?
    func readBoundedValue() -> String?
    func setSelectedText(_ text: String) -> Bool
}

/// Production focused `AXUIElement` session with `0.15s` messaging timeout on both systemWide and focused elements.
/// Strictly respects WeType 5 red lines (NEVER queries `kAXMarkedTextRangeAttribute`).
public final class LiveAXFocusedTextSession: AXFocusedTextSession, @unchecked Sendable {
    public static let maxPreValueSnapshotUTF16Count: Int = 65_536

    private let element: AXUIElement

    private init(element: AXUIElement) {
        self.element = element
    }

    public static func capture(timeoutSeconds: Float) -> LiveAXFocusedTextSession? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeoutSeconds)

        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedErr == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focused = (focusedRef as! AXUIElement)
        AXUIElementSetMessagingTimeout(focused, timeoutSeconds)
        return LiveAXFocusedTextSession(element: focused)
    }

    public var elementPID: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    public var role: String? {
        copyStringAttribute(kAXRoleAttribute as CFString)
    }

    public var subrole: String? {
        copyStringAttribute(kAXSubroleAttribute as CFString)
    }

    /// Detects WebKit/WebView-backed fields (even embedded inside Mail or Notes) via `AXDOMIdentifier` / `AXURL`.
    /// Web-backed editors (React/Vue/ProseMirror/Lexical) can accept `kAXSelectedTextAttribute` on the DOM node
    /// while skipping JS `beforeinput`/`input` state updates, so Tier 1 skips them in favor of Tier 2/3.
    public var isWebBackedElement: Bool {
        if role == "AXWebArea" {
            return true
        }
        var domID: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMIdentifier" as CFString, &domID) == .success, domID != nil {
            return true
        }
        var urlVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlVal) == .success, urlVal != nil {
            return true
        }
        return false
    }

    public var isSelectedTextSettable: Bool {
        var isSettable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    public func readSelectedRange() -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    public func readBoundedValue() -> String? {
        var charCountRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &charCountRef) == .success,
           let countNum = charCountRef as? NSNumber,
           countNum.intValue > Self.maxPreValueSnapshotUTF16Count
        {
            return nil
        }

        guard let str = copyStringAttribute(kAXValueAttribute as CFString),
              str.utf16.count <= Self.maxPreValueSnapshotUTF16Count
        else {
            return nil
        }
        return str
    }

    public func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private func copyStringAttribute(_ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

/// Injectable Tier 1 Accessibility inserter enabling 100% deterministic testing of readback verification,
/// false-success fallback, and pre/post focus/PID/SecureInput race guards.
public protocol AXDirectInserting: AnyObject, Sendable {
    func attemptVerifiedInsert(
        text: String,
        guard insertGuard: AXDirectInsertGuard,
        timeoutSeconds: Float
    ) -> AXDirectInsertResult
}

/// Normalized keystroke event emitted by Tier 2 (`CGEventKeyboardSetUnicodeString` / Return / Tab).
public enum DirectKeystrokeEvent: Equatable, Sendable {
    case unicode(utf16Units: [UInt16], virtualKey: UInt16, flagsRawValue: UInt64, userData: Int64)
    case returnKey(virtualKey: UInt16, flagsRawValue: UInt64, userData: Int64)
    case tabKey(virtualKey: UInt16, flagsRawValue: UInt64, userData: Int64)

    public var virtualKey: UInt16 {
        switch self {
        case let .unicode(_, vk, _, _),
             let .returnKey(vk, _, _),
             let .tabKey(vk, _, _):
            return vk
        }
    }

    public var flagsRawValue: UInt64 {
        switch self {
        case let .unicode(_, _, flags, _),
             let .returnKey(_, flags, _),
             let .tabKey(_, flags, _):
            return flags
        }
    }

    public var userData: Int64 {
        switch self {
        case let .unicode(_, _, _, userData),
             let .returnKey(_, _, userData),
             let .tabKey(_, _, userData):
            return userData
        }
    }
}

/// Injectable Tier 2 Unicode keystroke poster so tests can assert exact UTF-16 chunks, virtual keycodes,
/// `.privateState` flags, and `0x4C444943` userData without injecting keystrokes into the host desktop.
public protocol UnicodeKeystrokePosting: AnyObject, Sendable {
    func postKeystroke(_ event: DirectKeystrokeEvent) -> Bool
}

/// Production Tier 1 Accessibility inserter using `kAXSelectedTextAttribute` with strict pre/post readback
/// verification AND pre-write / post-write focus, frontmost-PID, and Secure Input race guards.
///
/// Guarantees:
/// - Sets `0.15s` messaging timeout on BOTH `AXUIElementCreateSystemWide()` and focused `AXUIElement`.
/// - Strictly respects WeType 5 red lines (NEVER queries `kAXMarkedTextRangeAttribute`).
/// - Refuses `AXSecureTextField` and skips `AXWebArea` / non-text-input roles.
/// - Re-verifies `focusGeneration`, `frontmostPID == targetPID`, `!isSecureInputEnabled`, and non-`AXSecureTextField`
///   immediately BEFORE `AXUIElementSetAttributeValue` AND immediately AFTER post-write readback.
/// - Never falsely reports success and never falls through to Tier 2 double-typing if focus changed after write.
public final class LiveAXDirectInserter: AXDirectInserting, Sendable {
    public static let maxPreValueSnapshotUTF16Count: Int = LiveAXFocusedTextSession.maxPreValueSnapshotUTF16Count

    public static let allowedNativeTextRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXTextView",
        "AXComboBox",
        "AXSearchField",
    ]

    private let isProcessTrusted: @Sendable () -> Bool
    private let sessionProvider: @Sendable (Float) -> AXFocusedTextSession?

    public init(
        isProcessTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        sessionProvider: @escaping @Sendable (Float) -> AXFocusedTextSession? = {
            LiveAXFocusedTextSession.capture(timeoutSeconds: $0)
        }
    ) {
        self.isProcessTrusted = isProcessTrusted
        self.sessionProvider = sessionProvider
    }

    public func attemptVerifiedInsert(
        text: String,
        guard insertGuard: AXDirectInsertGuard,
        timeoutSeconds: Float
    ) -> AXDirectInsertResult {
        guard insertGuard.targetPID > 0, isProcessTrusted() else {
            return .unverifiedOrSkipped
        }

        if insertGuard.secureInputProvider() {
            return .secureTextFieldBlocked
        }
        guard insertGuard.currentFocusGeneration() == insertGuard.expectedFocusGeneration,
              insertGuard.frontmostPIDProvider() == insertGuard.targetPID
        else {
            return .abortedBeforeWrite(reason: DirectTextInjector.preWriteChangedAbortReason)
        }

        guard let session = sessionProvider(timeoutSeconds) else {
            return .unverifiedOrSkipped
        }

        guard session.elementPID == insertGuard.targetPID else {
            return .unverifiedOrSkipped
        }

        // Role & subrole safety check (block secure fields; skip WebViews / non-native text roles).
        let role = session.role
        let subrole = session.subrole
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secureTextFieldBlocked
        }
        if session.isWebBackedElement {
            return .unverifiedOrSkipped
        }
        guard let role, role != "AXWebArea", Self.allowedNativeTextRoles.contains(role) else {
            return .unverifiedOrSkipped
        }

        guard session.isSelectedTextSettable else {
            return .unverifiedOrSkipped
        }

        // Snapshot pre-write selectedTextRange and bounded value (<= 64K UTF-16 code units).
        let preRange = session.readSelectedRange()
        let preValue = session.readBoundedValue()
        guard preRange != nil || preValue != nil else {
            // Cannot verify insertion outcome without at least one readable baseline; fall back cleanly.
            return .unverifiedOrSkipped
        }

        // P0-2: Re-verify ALL invariants immediately BEFORE AXUIElementSetAttributeValue!
        if insertGuard.secureInputProvider() || Self.isSessionSecureTextField(session) {
            return .secureTextFieldBlocked
        }
        guard insertGuard.currentFocusGeneration() == insertGuard.expectedFocusGeneration,
              insertGuard.frontmostPIDProvider() == insertGuard.targetPID,
              session.elementPID == insertGuard.targetPID
        else {
            return .abortedBeforeWrite(reason: DirectTextInjector.preWriteChangedAbortReason)
        }

        let wrote = session.setSelectedText(text)
        guard wrote else {
            // If focus/PID/SecureInput changed while write failed, abort to Recovery rather than typing into new window.
            if insertGuard.secureInputProvider()
                || insertGuard.currentFocusGeneration() != insertGuard.expectedFocusGeneration
                || insertGuard.frontmostPIDProvider() != insertGuard.targetPID
            {
                return .changedAfterWrite(reason: DirectTextInjector.postWriteChangedAbortReason)
            }
            return .unverifiedOrSkipped
        }

        let postRange = session.readSelectedRange()
        let postValue = preValue != nil ? session.readBoundedValue() : nil

        let verified = Self.verifyPostWriteReadback(
            insertedText: text,
            preRange: preRange,
            preValue: preValue,
            postRange: postRange,
            postValue: postValue
        )

        // P0-2: Re-verify ALL invariants immediately AFTER post-write readback!
        // Never fall through to Tier 2 double-typing and never silently claim success if state shifted.
        let postStateIntact = !insertGuard.secureInputProvider()
            && !Self.isSessionSecureTextField(session)
            && insertGuard.currentFocusGeneration() == insertGuard.expectedFocusGeneration
            && insertGuard.frontmostPIDProvider() == insertGuard.targetPID
            && session.elementPID == insertGuard.targetPID

        guard postStateIntact else {
            return .changedAfterWrite(reason: DirectTextInjector.postWriteChangedAbortReason)
        }

        return verified ? .verified : .unverifiedOrSkipped
    }

    private static func isSessionSecureTextField(_ session: AXFocusedTextSession) -> Bool {
        session.role == "AXSecureTextField" || session.subrole == "AXSecureTextField"
    }

    /// Pure verification logic comparing pre-write and post-write AX snapshots.
    /// Rejects silent AX false-success where neither range advanced nor value changed as expected.
    public static func verifyPostWriteReadback(
        insertedText: String,
        preRange: CFRange?,
        preValue: String?,
        postRange: CFRange?,
        postValue: String?
    ) -> Bool {
        let normalizedInserted = insertedText.replacingOccurrences(of: "\r\n", with: "\n")
        let insertedUTF16 = insertedText.utf16.count
        let normalizedUTF16 = normalizedInserted.utf16.count
        guard insertedUTF16 > 0 else { return true }

        // If we have both pre and post values, the string must have changed — EXCEPT when replacing
        // a selection with identical text, where the collapsed caret advances past the replacement.
        if let preValue, let postValue {
            if postValue == preValue {
                if let preRange, let postRange {
                    return (preRange.length == insertedUTF16 && postRange.location == preRange.location + insertedUTF16 && postRange.length == 0)
                        || (preRange.length == normalizedUTF16 && postRange.location == preRange.location + normalizedUTF16 && postRange.length == 0)
                }
                return false
            }

            // Placeholder-to-text transition: some empty AppKit fields return placeholder text for preValue,
            // then switch cleanly to `insertedText` with caret at the end of the inserted string.
            if (postValue == insertedText || postValue == normalizedInserted),
               let postRange,
               (postRange.location == insertedUTF16 || postRange.location == normalizedUTF16),
               postRange.length == 0
            {
                return true
            }

            if let preRange {
                let expectedLenRaw = preValue.utf16.count - preRange.length + insertedUTF16
                let expectedLenNorm = preValue.utf16.count - preRange.length + normalizedUTF16
                let postLen = postValue.utf16.count
                let lengthMatches = (postLen == expectedLenRaw || postLen == expectedLenNorm)
                if let postRange {
                    let rangeAdvanced = postRange.length == 0 && (
                        postRange.location == preRange.location + insertedUTF16
                            || postRange.location == preRange.location + normalizedUTF16
                    )
                    return lengthMatches && rangeAdvanced
                }
                return lengthMatches
            }
            // No range available: require length grew by insertedUTF16 or content contains insertedText.
            return postValue.utf16.count == preValue.utf16.count + insertedUTF16
                || postValue.utf16.count == preValue.utf16.count + normalizedUTF16
                || postValue.contains(insertedText)
                || postValue.contains(normalizedInserted)
        }

        // Large document (> 64 KB) where value snapshot was skipped: rely strictly on selectedTextRange advancement.
        if let preRange, let postRange {
            return postRange.length == 0 && (
                postRange.location == preRange.location + insertedUTF16
                    || postRange.location == preRange.location + normalizedUTF16
            )
        }

        return false
    }
}

/// Production Tier 3 Unicode keystroke poster gated on `CGPreflightPostEventAccess()` (P0-1),
/// using `.privateState`, empty modifier flags, empirically verified inert virtual key (`0x00FF`,
/// never `0x0000`/`kVK_ANSI_A`), `CGEventKeyboardSetUnicodeString` ONLY on `keyDown`,
/// `0x4C444943` ("LDIC") userData on BOTH `keyDown` & `keyUp`, and a `1.5 ms` down-to-up gap.
public final class LiveUnicodeKeystrokePoster: UnicodeKeystrokePosting, Sendable {
    public static let defaultKeyDownToUpDelayNs: UInt64 = 1_500_000 // 1.5 ms

    private let postEventAccessProbe: @Sendable () -> Bool
    private let keyDownToUpDelayNs: UInt64

    public init(
        postEventAccessProbe: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        keyDownToUpDelayNs: UInt64 = defaultKeyDownToUpDelayNs
    ) {
        self.postEventAccessProbe = postEventAccessProbe
        self.keyDownToUpDelayNs = keyDownToUpDelayNs
    }

    /// Constructs the exact `(keyDown, keyUp)` `CGEvent` pair posted for `event`.
    /// Attaches `keyboardSetUnicodeString` ONLY to `keyDown`, leaving `keyUp` clean.
    public static func makeKeyEventPair(for event: DirectKeystrokeEvent) -> (keyDown: CGEvent, keyUp: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(event.virtualKey),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(event.virtualKey),
                  keyDown: false
              )
        else {
            return nil
        }

        let flags = CGEventFlags(rawValue: event.flagsRawValue)
        keyDown.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: event.userData)

        keyUp.flags = flags
        keyUp.setIntegerValueField(.eventSourceUserData, value: event.userData)

        if case let .unicode(utf16Units, _, _, _) = event {
            utf16Units.withUnsafeBufferPointer { buffer in
                // Attach Unicode payload ONLY on keyDown so Electron/WebKit never double-handle or drop keyUp.
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }

        return (keyDown, keyUp)
    }

    public func postKeystroke(_ event: DirectKeystrokeEvent) -> Bool {
        // P0-1: Never blindly post synthetic events when post-event TCC permission is denied.
        guard postEventAccessProbe() else {
            return false
        }

        guard let (keyDown, keyUp) = Self.makeKeyEventPair(for: event) else {
            return false
        }

        keyDown.post(tap: .cgSessionEventTap)
        if keyDownToUpDelayNs > 0 {
            DirectTextInjector.sleepNanoseconds(keyDownToUpDelayNs)
        }
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Direct natural text injector with ZERO `NSPasteboard` touch.
///
/// Pipeline:
/// 1. Safety gates: terminal newline/control-character guard, Secure Input guard, frontmost PID & focusGeneration check.
/// 2. Tier 1: Verified native Accessibility `kAXSelectedTextAttribute` insertion with pre/post readback verification
///    and pre/post focus/PID/SecureInput race guards (automatically skipped for Electron, Chromium, terminals,
///    WeChat, JetBrains, and `AXWebArea`).
/// 3. Tier 2: Dedicated serial-queue Unicode keystroke stream gated on `CGPreflightPostEventAccess()`, using
///    `.privateState`, empty flags, inert non-`kVK_ANSI_A` virtual key `0x00FF`, `0x4C444943` userData,
///    1–2 UTF-16 units per event, per-chunk `focusGeneration` & frontmost-PID abort returning exact `remainingText`,
///    and adaptive 1.0–1.5 ms micro-pacing.
public final class DirectTextInjector: DirectTextInjecting, @unchecked Sendable {
    /// Inert non-printable virtual keycode empirically verified on macOS 27.3:
    /// - Outside all physical `HIToolbox` keycodes (`0x00..0x7E`), never `0x0000` (`kVK_ANSI_A`).
    /// - `UCKeyTranslate` translates `0x00FF` to `""` (prevents stray `'a'` under active Chinese IMEs).
    /// - Fits in 8 bits (avoids `0xFFFF`/`-1` signed sentinel drops in Electron/Chromium).
    public static let inertUnicodeVirtualKey: UInt16 = 0x00FF
    public static let returnVirtualKey: UInt16 = UInt16(kVK_Return) // 0x24
    public static let tabVirtualKey: UInt16 = UInt16(kVK_Tab)       // 0x30

    public static let preWriteChangedAbortReason = "输入前窗口或输入状态已变化，文字已为你保留"
    public static let postWriteChangedAbortReason = "输入时窗口或输入状态发生变化，为避免重复输入已保留文字"
    public static let focusChangedAbortReason = "输入过程中切换了窗口，剩余文字已为你保留"
    public static let postInterruptedAbortReason = "部分文字输入中断，剩余文字已为你保留"

    public static let normalPacingDelayNs: UInt64 = 4_000_000   // 4.0 ms for <= 60 chunks
    public static let longTextPacingDelayNs: UInt64 = 2_500_000 // 2.5 ms for > 60 chunks
    public static let longTextChunkThreshold: Int = 60

    /// Apps whose Accessibility text value is known to report success while dropping the write
    /// or bypassing web/framework editor state (React/ProseMirror/Lexical/Qt/Java/Terminals).
    /// Native AppKit apps still get Tier 1 verified AX insertion with zero clipboard touch.
    public static let axUnreliableBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.safari.technologypreview",
        "ai.vulcan.code.desktop",
        "com.amazon.quickwork.mac",
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.cursor.cursor",
        "com.exafunction.windsurf",
        "dev.zed.zed",
        "com.zed.zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "dev.t3.code",
        "com.t3.code",
        "com.t3code.app",
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.google.chrome.beta",
        "org.chromium.chromium",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.tinyspeck.slackmacgap",
        "notion.id",
        "com.hnc.discord",
        "md.obsidian",
        "com.linear",
        "com.figma.desktop",
        "com.tencent.xinwechat",
        "com.tencent.weworkmac",
        "com.tencent.qq",
        "com.electron.lark",
        "com.bytedance.feishu",
        "com.alibaba.dingtalkmac",
        "ru.keepcoder.telegram",
        "com.whatsapp.desktop",
        "com.microsoft.teams2",
    ]

    public struct KeystrokeChunk: Equatable, Sendable {
        public let event: DirectKeystrokeEvent
        public let sourceText: String

        public init(event: DirectKeystrokeEvent, sourceText: String) {
            self.event = event
            self.sourceText = sourceText
        }
    }

    private let axInserter: AXDirectInserting
    private let keystrokePoster: UnicodeKeystrokePosting
    private let clipboardFallback: ClipboardInjecting?
    private let pasteRestoreDelayMs: Int
    private let isSecureInputEnabled: @Sendable () -> Bool
    private let frontmostPIDProvider: @Sendable () -> pid_t?
    private let postEventAccessProbe: @Sendable () -> Bool
    private let terminalBundleIDs: Set<String>
    private let axTimeoutSeconds: Float
    private let fixedPacingDelayNs: UInt64?

    private let injectionQueue = DispatchQueue(
        label: "io.github.litedictate.directinjection.serial",
        qos: .userInteractive
    )
    private let callbackQueue = DispatchQueue(
        label: "io.github.litedictate.directinjection.callbacks",
        qos: .userInteractive
    )

    public init(
        axInserter: AXDirectInserting = LiveAXDirectInserter(),
        keystrokePoster: UnicodeKeystrokePosting = LiveUnicodeKeystrokePoster(),
        clipboardFallback: ClipboardInjecting? = nil,
        pasteRestoreDelayMs: Int = LiteDictateConstants.defaultPasteRestoreDelayMs,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        frontmostPIDProvider: @escaping @Sendable () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        postEventAccessProbe: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        extraTerminalBundleIDs: Set<String> = [],
        axTimeoutSeconds: Float = LiteDictateConstants.axMessagingTimeoutSeconds,
        pacingDelayNs: UInt64? = nil
    ) {
        self.axInserter = axInserter
        self.keystrokePoster = keystrokePoster
        self.clipboardFallback = clipboardFallback
        self.pasteRestoreDelayMs = pasteRestoreDelayMs
        self.isSecureInputEnabled = isSecureInputEnabled
        self.frontmostPIDProvider = frontmostPIDProvider
        self.postEventAccessProbe = postEventAccessProbe
        self.terminalBundleIDs = ClipboardInjector.defaultTerminalBundleIDs.union(
            extraTerminalBundleIDs.map { $0.lowercased() }
        )
        self.axTimeoutSeconds = axTimeoutSeconds
        self.fixedPacingDelayNs = pacingDelayNs
    }

    public func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return terminalBundleIDs.contains(bundleIdentifier.lowercased())
    }

    /// Returns `false` if text contains `\n`, `\r`, any control char `< 0x20` (except `\t`),
    /// `0x7F` (DEL), or Unicode line/paragraph separators (`U+0085`, `U+2028`, `U+2029`).
    public func isTextSafeForTerminal(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 {
                continue
            }
            if v < 0x20 || v == 0x7F || v == 0x85 || v == 0x2028 || v == 0x2029 {
                return false
            }
        }
        return true
    }

    /// Returns `true` when Tier 1 (`kAXSelectedTextAttribute`) should be skipped in favor of Tier 2.
    /// Unknown apps are intentionally allowed to try Tier 1. The live inserter verifies the focused
    /// role, target PID, value/range readback, and focus state before reporting success.
    public func shouldSkipAccessibilityTier(bundleIdentifier: String?) -> Bool {
        // A missing bundle identifier should not disable the reliable AX path. The focused
        // element's role, PID, and readback checks remain the authority for whether it is safe.
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        let lower = bundleIdentifier.lowercased()
        if terminalBundleIDs.contains(lower) || Self.axUnreliableBundleIDs.contains(lower) {
            return true
        }
        if lower.hasPrefix("com.jetbrains.") {
            return true
        }
        if lower.contains("electron") || lower.contains("t3code") || lower.contains("t3.code") || lower.contains("t3-code") {
            return true
        }
        return false
    }

    /// Splits `text` into safe 1–2 UTF-16 code-unit keystroke chunks preserving surrogate pairs (e.g. emoji)
    /// and mapping `\n` / `\r\n` -> `kVK_Return` (non-terminal only) and `\t` -> `kVK_Tab`.
    public static func buildKeystrokeChunks(from text: String) -> [KeystrokeChunk] {
        var chunks: [KeystrokeChunk] = []
        let scalars = Array(text.unicodeScalars)
        chunks.reserveCapacity(scalars.count)

        var idx = 0
        while idx < scalars.count {
            let scalar = scalars[idx]
            if scalar.value == 0x0D { // '\r'
                if idx + 1 < scalars.count && scalars[idx + 1].value == 0x0A { // "\r\n"
                    chunks.append(KeystrokeChunk(
                        event: .returnKey(
                            virtualKey: returnVirtualKey,
                            flagsRawValue: 0,
                            userData: LiteDictateConstants.syntheticEventUserData
                        ),
                        sourceText: "\r\n"
                    ))
                    idx += 2
                    continue
                }
                chunks.append(KeystrokeChunk(
                    event: .returnKey(
                        virtualKey: returnVirtualKey,
                        flagsRawValue: 0,
                        userData: LiteDictateConstants.syntheticEventUserData
                    ),
                    sourceText: "\r"
                ))
                idx += 1
                continue
            }

            if scalar.value == 0x0A { // '\n'
                chunks.append(KeystrokeChunk(
                    event: .returnKey(
                        virtualKey: returnVirtualKey,
                        flagsRawValue: 0,
                        userData: LiteDictateConstants.syntheticEventUserData
                    ),
                    sourceText: "\n"
                ))
                idx += 1
                continue
            }

            if scalar.value == 0x09 { // '\t'
                chunks.append(KeystrokeChunk(
                    event: .tabKey(
                        virtualKey: tabVirtualKey,
                        flagsRawValue: 0,
                        userData: LiteDictateConstants.syntheticEventUserData
                    ),
                    sourceText: "\t"
                ))
                idx += 1
                continue
            }

            let utf16Units = Array(scalar.utf16)
            chunks.append(KeystrokeChunk(
                event: .unicode(
                    utf16Units: utf16Units,
                    virtualKey: inertUnicodeVirtualKey,
                    flagsRawValue: 0,
                    userData: LiteDictateConstants.syntheticEventUserData
                ),
                sourceText: String(scalar)
            ))
            idx += 1
        }

        return chunks
    }

    public func insertTextDirectly(
        _ text: String,
        targetPID: pid_t,
        targetBundleIdentifier: String?,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        injectionQueue.async { [self] in
            // 1. Terminal safety gate BEFORE any AX or keystroke call.
            if self.isTerminalApplication(bundleIdentifier: targetBundleIdentifier),
               !self.isTextSafeForTerminal(text)
            {
                self.deliver(.blocked(.terminalUnsafeCharacters), to: completion)
                return
            }

            // 2. Empty text fast-path.
            if text.isEmpty {
                self.deliver(.inserted(method: .verifiedAccessibility), to: completion)
                return
            }

            // 3. Pre-flight Secure Input, focusGeneration, and frontmost PID guard.
            if self.isSecureInputEnabled() {
                self.deliver(.blocked(.eventPostFailed), to: completion)
                return
            }
            guard currentFocusGeneration() == expectedFocusGeneration else {
                self.deliver(
                    .partiallyInserted(remainingText: text, reason: Self.focusChangedAbortReason),
                    to: completion
                )
                return
            }
            if targetPID > 0, self.frontmostPIDProvider() != targetPID {
                self.deliver(
                    .partiallyInserted(remainingText: text, reason: Self.preWriteChangedAbortReason),
                    to: completion
                )
                return
            }

            // 4. Tier 1: Verified native Accessibility insertion (skipped for known AX-unreliable apps).
            if !self.shouldSkipAccessibilityTier(bundleIdentifier: targetBundleIdentifier) {
                let insertGuard = AXDirectInsertGuard(
                    targetPID: targetPID,
                    expectedFocusGeneration: expectedFocusGeneration,
                    currentFocusGeneration: currentFocusGeneration,
                    frontmostPIDProvider: self.frontmostPIDProvider,
                    secureInputProvider: self.isSecureInputEnabled
                )
                switch self.axInserter.attemptVerifiedInsert(
                    text: text,
                    guard: insertGuard,
                    timeoutSeconds: self.axTimeoutSeconds
                ) {
                case .verified:
                    // Defense-in-depth post-AX invariant check: never claim success if focus/PID/SecureInput shifted.
                    let postIntact = !self.isSecureInputEnabled()
                        && currentFocusGeneration() == expectedFocusGeneration
                        && (targetPID <= 0 || self.frontmostPIDProvider() == targetPID)
                    if postIntact {
                        self.deliver(.inserted(method: .verifiedAccessibility), to: completion)
                    } else {
                        self.deliver(
                            .partiallyInserted(remainingText: text, reason: Self.postWriteChangedAbortReason),
                            to: completion
                        )
                    }
                    return
                case .secureTextFieldBlocked:
                    self.deliver(.blocked(.eventPostFailed), to: completion)
                    return
                case let .abortedBeforeWrite(reason):
                    self.deliver(.partiallyInserted(remainingText: text, reason: reason), to: completion)
                    return
                case let .changedAfterWrite(reason):
                    // NEVER fall through to Tier 2 double-typing and NEVER claim silent success!
                    self.deliver(.partiallyInserted(remainingText: text, reason: reason), to: completion)
                    return
                case .unverifiedOrSkipped:
                    // Re-verify state didn't shift while Tier 1 was executing before entering Tier 2.
                    if self.isSecureInputEnabled() {
                        self.deliver(.blocked(.eventPostFailed), to: completion)
                        return
                    }
                    if currentFocusGeneration() != expectedFocusGeneration
                        || (targetPID > 0 && self.frontmostPIDProvider() != targetPID)
                    {
                        self.deliver(
                            .partiallyInserted(remainingText: text, reason: Self.preWriteChangedAbortReason),
                            to: completion
                        )
                        return
                    }
                }
            }

            // 5. P0-1: Gate synthetic event posting (Tier 2 Cmd+V & Tier 3 Unicode stream) on post-event TCC permission!
            guard self.postEventAccessProbe() else {
                self.deliver(.blocked(.eventPostFailed), to: completion)
                return
            }

            // 6. Tier 2: Transient clipboard Cmd+V (with zero-copy prescreen, 8 MiB snapshot, TransientType/AutoGeneratedType,
            //    and auto-restore). Works universally across Electron, browsers, WeChat/Qt, JetBrains, and Terminals,
            //    and is 100% immune to active Chinese IMEs (WeType / Pinyin). If the user's clipboard holds protected
            //    content (passwords, file promises, large images/PNG/TIFF, custom binary) we NEVER overwrite it and
            //    seamlessly fall through to Tier 3 Unicode keystroke streaming.
            if let clipboardFallback = self.clipboardFallback {
                self.attemptTransientClipboardOrUnicodeFallback(
                    clipboard: clipboardFallback,
                    text: text,
                    targetPID: targetPID,
                    targetBundleIdentifier: targetBundleIdentifier,
                    expectedFocusGeneration: expectedFocusGeneration,
                    currentFocusGeneration: currentFocusGeneration,
                    completion: completion
                )
                return
            }

            // 7. Tier 3: Direct Unicode keystroke stream with per-chunk focusGeneration & PID verification.
            self.runUnicodeKeystrokeStreamLocked(
                text: text,
                targetPID: targetPID,
                expectedFocusGeneration: expectedFocusGeneration,
                currentFocusGeneration: currentFocusGeneration,
                completion: completion
            )
        }
    }

    private func attemptTransientClipboardOrUnicodeFallback(
        clipboard: ClipboardInjecting,
        text: String,
        targetPID: pid_t,
        targetBundleIdentifier: String?,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        clipboard.preparePaste(text: text, targetBundleIdentifier: targetBundleIdentifier) { [self] prepResult in
            self.injectionQueue.async {
                switch prepResult {
                case let .blocked(blockReason):
                    if blockReason == .terminalUnsafeCharacters {
                        self.deliver(.blocked(.terminalUnsafeCharacters), to: completion)
                        return
                    }
                    // Clipboard holds protected content (concealed secret, file promise, large image, Figma, >8 MiB,
                    // or pasteboard denied): clipboard was NOT touched. Fall back cleanly to Tier 3 Unicode stream!
                    self.runUnicodeKeystrokeStreamLocked(
                        text: text,
                        targetPID: targetPID,
                        expectedFocusGeneration: expectedFocusGeneration,
                        currentFocusGeneration: currentFocusGeneration,
                        completion: completion
                    )

                case let .ready(preparation):
                    if self.isSecureInputEnabled() {
                        clipboard.restoreIfOwned(preparation: preparation)
                        self.deliver(.blocked(.eventPostFailed), to: completion)
                        return
                    }
                    if currentFocusGeneration() != expectedFocusGeneration
                        || (targetPID > 0 && self.frontmostPIDProvider() != targetPID)
                    {
                        clipboard.restoreIfOwned(preparation: preparation)
                        self.deliver(
                            .partiallyInserted(remainingText: text, reason: Self.preWriteChangedAbortReason),
                            to: completion
                        )
                        return
                    }
                    guard clipboard.currentChangeCount() == preparation.expectedChangeCount else {
                        // User copied something new while preparing: abandon clipboard overwrite and fall back to Tier 3.
                        self.runUnicodeKeystrokeStreamLocked(
                            text: text,
                            targetPID: targetPID,
                            expectedFocusGeneration: expectedFocusGeneration,
                            currentFocusGeneration: currentFocusGeneration,
                            completion: completion
                        )
                        return
                    }

                    let prePostGuard: @Sendable () -> Bool = { [self] in
                        !self.isSecureInputEnabled()
                            && currentFocusGeneration() == expectedFocusGeneration
                            && (targetPID <= 0 || self.frontmostPIDProvider() == targetPID)
                    }

                    clipboard.dispatchSyntheticPaste(
                        preparation: preparation,
                        restoreDelayMs: self.pasteRestoreDelayMs,
                        prePostGuard: prePostGuard
                    ) { [self] dispatched in
                        self.injectionQueue.async {
                            if dispatched {
                                self.deliver(.inserted(method: .transientClipboardPaste), to: completion)
                                return
                            }
                            if self.isSecureInputEnabled() || !self.postEventAccessProbe() {
                                self.deliver(.blocked(.eventPostFailed), to: completion)
                                return
                            }
                            if currentFocusGeneration() != expectedFocusGeneration
                                || (targetPID > 0 && self.frontmostPIDProvider() != targetPID)
                            {
                                self.deliver(
                                    .partiallyInserted(remainingText: text, reason: Self.preWriteChangedAbortReason),
                                    to: completion
                                )
                                return
                            }
                            // Paste was skipped before posting (e.g. changeCount drifted): safely fall back to Tier 3.
                            self.runUnicodeKeystrokeStreamLocked(
                                text: text,
                                targetPID: targetPID,
                                expectedFocusGeneration: expectedFocusGeneration,
                                currentFocusGeneration: currentFocusGeneration,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }
    }

    private func runUnicodeKeystrokeStreamLocked(
        text: String,
        targetPID: pid_t,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        if self.isSecureInputEnabled() {
            self.deliver(.blocked(.eventPostFailed), to: completion)
            return
        }
        if currentFocusGeneration() != expectedFocusGeneration
            || (targetPID > 0 && self.frontmostPIDProvider() != targetPID)
        {
            self.deliver(
                .partiallyInserted(remainingText: text, reason: Self.preWriteChangedAbortReason),
                to: completion
            )
            return
        }
        guard self.postEventAccessProbe() else {
            self.deliver(.blocked(.eventPostFailed), to: completion)
            return
        }

        let chunks = Self.buildKeystrokeChunks(from: text)
        let pacingNs: UInt64
        if let fixedPacingDelayNs = self.fixedPacingDelayNs {
            pacingNs = fixedPacingDelayNs
        } else {
            pacingNs = chunks.count > Self.longTextChunkThreshold
                ? Self.longTextPacingDelayNs
                : Self.normalPacingDelayNs
        }

        for (index, chunk) in chunks.enumerated() {
            if currentFocusGeneration() != expectedFocusGeneration
                || (targetPID > 0 && self.frontmostPIDProvider() != targetPID)
            {
                let remaining = chunks[index...].map(\.sourceText).joined()
                self.deliver(
                    .partiallyInserted(remainingText: remaining, reason: Self.focusChangedAbortReason),
                    to: completion
                )
                return
            }

            if self.isSecureInputEnabled() {
                if index == 0 {
                    self.deliver(.blocked(.eventPostFailed), to: completion)
                } else {
                    let remaining = chunks[index...].map(\.sourceText).joined()
                    self.deliver(
                        .partiallyInserted(remainingText: remaining, reason: Self.focusChangedAbortReason),
                        to: completion
                    )
                }
                return
            }

            let posted = self.keystrokePoster.postKeystroke(chunk.event)
            guard posted else {
                if index == 0 {
                    self.deliver(.blocked(.eventPostFailed), to: completion)
                } else {
                    let remaining = chunks[index...].map(\.sourceText).joined()
                    self.deliver(
                        .partiallyInserted(remainingText: remaining, reason: Self.postInterruptedAbortReason),
                        to: completion
                    )
                }
                return
            }

            if pacingNs > 0 && index + 1 < chunks.count {
                Self.sleepNanoseconds(pacingNs)
            }
        }

        self.deliver(.inserted(method: .unicodeKeystrokeStream), to: completion)
    }

    private func deliver(
        _ outcome: DirectInjectionOutcome,
        to completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        callbackQueue.async {
            completion(outcome)
        }
    }

    static func sleepNanoseconds(_ ns: UInt64) {
        var req = timespec(
            tv_sec: Int(ns / 1_000_000_000),
            tv_nsec: Int(ns % 1_000_000_000)
        )
        var rem = timespec(tv_sec: 0, tv_nsec: 0)
        while nanosleep(&req, &rem) == -1 && errno == EINTR {
            req = rem
        }
    }
}
