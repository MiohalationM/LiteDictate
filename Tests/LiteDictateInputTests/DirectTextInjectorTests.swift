import CoreGraphics
import Foundation
import XCTest
@testable import LiteDictateCore

private final class LockedOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: DirectInjectionOutcome?

    var value: DirectInjectionOutcome? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class MockAXDirectInserter: AXDirectInserting, @unchecked Sendable {
    private let lock = NSLock()
    var result: AXDirectInsertResult = .verified
    private(set) var callCount: Int = 0
    private(set) var lastText: String?
    private(set) var lastPID: pid_t = 0
    private(set) var lastTimeoutSeconds: Float = 0

    func attemptVerifiedInsert(
        text: String,
        guard insertGuard: AXDirectInsertGuard,
        timeoutSeconds: Float
    ) -> AXDirectInsertResult {
        lock.lock()
        callCount += 1
        lastText = text
        lastPID = insertGuard.targetPID
        lastTimeoutSeconds = timeoutSeconds
        let res = result
        lock.unlock()
        return res
    }
}

private final class MockAXFocusedTextSession: AXFocusedTextSession, @unchecked Sendable {
    private let lock = NSLock()
    var _elementPID: pid_t? = 1234
    var _role: String? = "AXTextArea"
    var _subrole: String?
    var _isWebBackedElement: Bool = false
    var _isSelectedTextSettable: Bool = true
    var _value: String = "Hello "
    var _selectedRange: CFRange = CFRange(location: 6, length: 0)

    var onReadBoundedValue: (@Sendable () -> Void)?
    var onSetSelectedText: (@Sendable (String) -> Void)?
    var shouldSimulateWrite: Bool = true
    var writeReturnValue: Bool = true
    private(set) var setSelectedTextCallCount: Int = 0

    var elementPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return _elementPID
    }

    var role: String? {
        lock.lock()
        defer { lock.unlock() }
        return _role
    }

    var subrole: String? {
        lock.lock()
        defer { lock.unlock() }
        return _subrole
    }

    var isWebBackedElement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWebBackedElement
    }

    var isSelectedTextSettable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSelectedTextSettable
    }

    func readSelectedRange() -> CFRange? {
        lock.lock()
        defer { lock.unlock() }
        return _selectedRange
    }

    func readBoundedValue() -> String? {
        lock.lock()
        let hook = onReadBoundedValue
        lock.unlock()
        hook?()

        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setSelectedText(_ text: String) -> Bool {
        lock.lock()
        setSelectedTextCallCount += 1
        let shouldWrite = shouldSimulateWrite
        let ret = writeReturnValue
        let hook = onSetSelectedText
        if shouldWrite && ret {
            let ns = _value as NSString
            let range = NSRange(location: _selectedRange.location, length: _selectedRange.length)
            _value = ns.replacingCharacters(in: range, with: text)
            _selectedRange = CFRange(location: _selectedRange.location + text.utf16.count, length: 0)
        }
        lock.unlock()

        hook?(text)
        return ret
    }
}

private final class RecordingUnicodeKeystrokePoster: UnicodeKeystrokePosting, @unchecked Sendable {
    private let lock = NSLock()
    var onBeforePost: (@Sendable (Int, DirectKeystrokeEvent) -> Bool)?
    private(set) var postedEvents: [DirectKeystrokeEvent] = []

    func postKeystroke(_ event: DirectKeystrokeEvent) -> Bool {
        lock.lock()
        let index = postedEvents.count
        let hook = onBeforePost
        lock.unlock()

        if let hook, !hook(index, event) {
            return false
        }

        lock.lock()
        postedEvents.append(event)
        lock.unlock()
        return true
    }

    func eventsSnapshot() -> [DirectKeystrokeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return postedEvents
    }
}

final class DirectTextInjectorTests: XCTestCase {
    private func makeInjector(
        axInserter: AXDirectInserting,
        poster: RecordingUnicodeKeystrokePoster = RecordingUnicodeKeystrokePoster(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { false },
        frontmostPIDProvider: @escaping @Sendable () -> pid_t? = { 1234 },
        postEventAccessProbe: @escaping @Sendable () -> Bool = { true }
    ) -> DirectTextInjector {
        DirectTextInjector(
            axInserter: axInserter,
            keystrokePoster: poster,
            isSecureInputEnabled: isSecureInputEnabled,
            frontmostPIDProvider: frontmostPIDProvider,
            postEventAccessProbe: postEventAccessProbe,
            pacingDelayNs: 0
        )
    }

    private func syncInsert(
        _ injector: DirectTextInjector,
        text: String,
        targetPID: pid_t = 1234,
        targetBundleID: String? = "com.apple.Notes",
        expectedFocusGen: UInt64 = 1,
        currentFocusGen: @escaping @Sendable () -> UInt64 = { 1 }
    ) -> DirectInjectionOutcome {
        let exp = expectation(description: "insertTextDirectly")
        let box = LockedOutcomeBox()
        injector.insertTextDirectly(
            text,
            targetPID: targetPID,
            targetBundleIdentifier: targetBundleID,
            expectedFocusGeneration: expectedFocusGen,
            currentFocusGeneration: currentFocusGen
        ) { outcome in
            box.value = outcome
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        return box.value!
    }

    func testVerifiedAXInsertSucceedsOnAllowlistedNativeAppsWithZeroKeystrokes() {
        for allowlistedBundle in ["com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.apple.iWork.Pages", "com.apple.MobileSMS"] {
            let ax = MockAXDirectInserter()
            ax.result = .verified
            let poster = RecordingUnicodeKeystrokePoster()
            let injector = makeInjector(axInserter: ax, poster: poster)

            let outcome = syncInsert(injector, text: "言落直接输入", targetBundleID: allowlistedBundle)
            XCTAssertEqual(outcome, .inserted(method: .verifiedAccessibility), "Expected Tier 1 for \(allowlistedBundle)")
            XCTAssertEqual(ax.callCount, 1)
            XCTAssertEqual(ax.lastText, "言落直接输入")
            XCTAssertEqual(ax.lastPID, 1234)
            XCTAssertEqual(ax.lastTimeoutSeconds, 0.15, accuracy: 0.001)
            XCTAssertTrue(poster.eventsSnapshot().isEmpty, "Tier 1 success must emit ZERO Unicode keystrokes")
        }

        // Embedded WebView inside an allowlisted app (e.g. Mail/Notes with AXDOMIdentifier/AXURL) MUST skip Tier 1!
        let webSession = MockAXFocusedTextSession()
        webSession._isWebBackedElement = true
        let liveAX = LiveAXDirectInserter(isProcessTrusted: { true }, sessionProvider: { _ in webSession })
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: liveAX, poster: poster)
        let webOutcome = syncInsert(injector, text: "Hi", targetBundleID: "com.apple.mail")
        XCTAssertEqual(webOutcome, .inserted(method: .unicodeKeystrokeStream))
        XCTAssertEqual(webSession.setSelectedTextCallCount, 0, "Web-backed element inside Mail must skip AX write")
        XCTAssertEqual(poster.eventsSnapshot().count, 2)
    }

    func testAXFalseSuccessIsCaughtAndFallsBackToUnicodeKeystrokeStream() {
        // 1. Verify pure readback verification rejects AX false-success (unchanged value/range)
        XCTAssertFalse(
            LiveAXDirectInserter.verifyPostWriteReadback(
                insertedText: "言落",
                preRange: CFRange(location: 5, length: 0),
                preValue: "Hello",
                postRange: CFRange(location: 5, length: 0),
                postValue: "Hello"
            ),
            "Must reject AX false-success when neither value nor range changed"
        )

        // Verify pure readback accepts real advancement (including 4-byte emoji UTF-16 length = 2)
        XCTAssertTrue(
            LiveAXDirectInserter.verifyPostWriteReadback(
                insertedText: "言🚀",
                preRange: CFRange(location: 6, length: 0),
                preValue: "Hello ",
                postRange: CFRange(location: 9, length: 0), // 1 + 2 = 3 UTF-16 units
                postValue: "Hello 言🚀"
            )
        )

        // Verify replacing an existing selection also verifies cleanly
        XCTAssertTrue(
            LiveAXDirectInserter.verifyPostWriteReadback(
                insertedText: "Swift",
                preRange: CFRange(location: 0, length: 3),
                preValue: "old text",
                postRange: CFRange(location: 5, length: 0),
                postValue: "Swift text"
            )
        )

        // Verify replacing a selection with IDENTICAL text verifies cleanly when caret advances (prevents double-typing!)
        XCTAssertTrue(
            LiveAXDirectInserter.verifyPostWriteReadback(
                insertedText: "hello",
                preRange: CFRange(location: 0, length: 5),
                preValue: "hello",
                postRange: CFRange(location: 5, length: 0),
                postValue: "hello"
            ),
            "Replacing selected text with identical text must verify when caret collapses to end of replacement"
        )

        // Verify AX false-success on identical selection where range does NOT collapse is STILL rejected
        XCTAssertFalse(
            LiveAXDirectInserter.verifyPostWriteReadback(
                insertedText: "hello",
                preRange: CFRange(location: 0, length: 5),
                preValue: "hello",
                postRange: CFRange(location: 0, length: 5),
                postValue: "hello"
            ),
            "Must still reject AX false-success when selection never collapsed"
        )

        // 2. When AX inserter reports `.unverifiedOrSkipped`, injector seamlessly falls back to Tier 2
        let ax = MockAXDirectInserter()
        ax.result = .unverifiedOrSkipped
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: ax, poster: poster)

        let outcome = syncInsert(injector, text: "你好", targetBundleID: "com.apple.TextEdit")
        XCTAssertEqual(outcome, .inserted(method: .unicodeKeystrokeStream))
        XCTAssertEqual(ax.callCount, 1)
        XCTAssertEqual(poster.eventsSnapshot().count, 2)
    }

    func testNonAllowlistedAppsIncludingSafariVulcanCodeAndUnknownSkipTier1DirectlyToUnicodeStream() {
        let nonAllowlistedBundles = [
            "com.apple.Safari",
            "ai.vulcan.code.desktop",
            "com.amazon.QuickWork.mac",
            "com.openai.chat",
            "com.unknown.ThirdPartyApp",
            "com.apple.Terminal",
            "com.mitchellh.ghostty",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "dev.t3.code",
            "com.google.Chrome",
            "company.thebrowser.Browser", // Arc
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.tinyspeck.slackmacgap",
            "notion.id",
            "com.hnc.Discord",
            "com.tencent.xinWeChat",
            "com.jetbrains.intellij",
            "com.jetbrains.goland",
            nil,
        ]

        for bundleID in nonAllowlistedBundles {
            let ax = MockAXDirectInserter()
            ax.result = .verified
            let poster = RecordingUnicodeKeystrokePoster()
            let injector = makeInjector(axInserter: ax, poster: poster)

            let outcome = syncInsert(injector, text: "OK", targetBundleID: bundleID)
            XCTAssertEqual(outcome, .inserted(method: .unicodeKeystrokeStream), "Expected Tier 2 for \(bundleID ?? "nil")")
            XCTAssertEqual(ax.callCount, 0, "Tier 1 MUST be skipped for \(bundleID ?? "nil")")
            XCTAssertEqual(poster.eventsSnapshot().count, 2)
        }
    }

    func testUnicodeStreamHandlesChineseMixedTextPunctuationEmojiAndUsesInertNonAVirtualKey() {
        let ax = MockAXDirectInserter()
        ax.result = .unverifiedOrSkipped
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: ax, poster: poster)

        let input = "你好, Swift! 🚀\n\t"
        let outcome = syncInsert(injector, text: input, targetBundleID: "com.google.Chrome")
        XCTAssertEqual(outcome, .inserted(method: .unicodeKeystrokeStream))

        let events = poster.eventsSnapshot()
        XCTAssertEqual(events.count, input.unicodeScalars.count)

        var reconstructed = ""
        var sawEmojiSurrogatePair = false

        for event in events {
            XCTAssertEqual(event.flagsRawValue, 0, "Synthetic keystroke must carry EMPTY modifier flags")
            XCTAssertEqual(event.userData, LiteDictateConstants.syntheticEventUserData, "Must tag with 0x4C444943 LDIC")
            XCTAssertNotEqual(event.virtualKey, 0x0000, "MUST NEVER use virtualKey 0x0000 (kVK_ANSI_A)!")

            switch event {
            case let .unicode(utf16Units, vk, _, _):
                XCTAssertEqual(vk, DirectTextInjector.inertUnicodeVirtualKey)
                XCTAssertTrue((1...2).contains(utf16Units.count), "Each Unicode event must be 1–2 UTF-16 code units")
                let str = String(utf16CodeUnits: utf16Units, count: utf16Units.count)
                if str == "🚀" {
                    XCTAssertEqual(utf16Units, [0xD83D, 0xDE80], "4-byte emoji surrogate pair must stay intact")
                    sawEmojiSurrogatePair = true
                }
                reconstructed += str
            case let .returnKey(vk, _, _):
                XCTAssertEqual(vk, DirectTextInjector.returnVirtualKey)
                reconstructed += "\n"
            case let .tabKey(vk, _, _):
                XCTAssertEqual(vk, DirectTextInjector.tabVirtualKey)
                reconstructed += "\t"
            }
        }

        XCTAssertTrue(sawEmojiSurrogatePair)
        XCTAssertEqual(reconstructed, input)
    }

    func testMidStreamFocusGenerationChangeAbortsAndReturnsExactRemainingText() {
        let ax = MockAXDirectInserter()
        ax.result = .unverifiedOrSkipped
        let poster = RecordingUnicodeKeystrokePoster()
        let focusGen = AtomicUInt64(7)

        // After typing the first 3 scalars ("言落A"), simulate a focus change (gen 7 -> 8)
        poster.onBeforePost = { index, _ in
            if index == 2 {
                focusGen.store(8, ordering: .release)
            }
            return true
        }

        let injector = makeInjector(axInserter: ax, poster: poster)

        let outcome = syncInsert(
            injector,
            text: "言落AB🚀末",
            targetBundleID: "com.google.Chrome",
            expectedFocusGen: 7,
            currentFocusGen: { focusGen.load(ordering: .acquire) }
        )

        XCTAssertEqual(
            outcome,
            .partiallyInserted(
                remainingText: "B🚀末",
                reason: DirectTextInjector.focusChangedAbortReason
            )
        )
        XCTAssertEqual(poster.eventsSnapshot().count, 3, "Must stop immediately after focusGeneration changed")
    }

    func testPreFlightFocusChangeReturnsFullRemainingTextWithoutAnyAXOrKeystrokes() {
        let ax = MockAXDirectInserter()
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: ax, poster: poster)

        let outcome = syncInsert(
            injector,
            text: "完整保留这段文字",
            targetBundleID: "com.apple.Notes",
            expectedFocusGen: 5,
            currentFocusGen: { 6 }
        )

        XCTAssertEqual(
            outcome,
            .partiallyInserted(
                remainingText: "完整保留这段文字",
                reason: DirectTextInjector.focusChangedAbortReason
            )
        )
        XCTAssertEqual(ax.callCount, 0)
        XCTAssertTrue(poster.eventsSnapshot().isEmpty)
    }

    func testTerminalUnsafeCharsBlockedBeforeAnyAXOrKeystrokeAndTabAllowed() {
        let ax = MockAXDirectInserter()
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: ax, poster: poster)

        for unsafe in ["ls -la\nwhoami", "cmd\r", "ctrl\u{0003}c", "del\u{007F}"] {
            let outcome = syncInsert(injector, text: unsafe, targetBundleID: "com.mitchellh.ghostty")
            XCTAssertEqual(outcome, .blocked(.terminalUnsafeCharacters), "Expected block for \(unsafe.debugDescription)")
        }
        XCTAssertEqual(ax.callCount, 0, "Terminal block must run BEFORE any AX call")
        XCTAssertTrue(poster.eventsSnapshot().isEmpty, "Terminal block must emit ZERO keystrokes")

        // Tab '\t' IS allowed in terminals and maps to kVK_Tab via Tier 2
        let tabOutcome = syncInsert(injector, text: "git\tdiff", targetBundleID: "com.apple.Terminal")
        XCTAssertEqual(tabOutcome, .inserted(method: .unicodeKeystrokeStream))
        XCTAssertEqual(ax.callCount, 0)
        let events = poster.eventsSnapshot()
        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(
            events[3],
            .tabKey(
                virtualKey: DirectTextInjector.tabVirtualKey,
                flagsRawValue: 0,
                userData: LiteDictateConstants.syntheticEventUserData
            )
        )
    }

    func testAXSecureTextFieldBlocksAndNeverFallsThroughToUnicodeTyping() {
        let ax = MockAXDirectInserter()
        ax.result = .secureTextFieldBlocked
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: ax, poster: poster)

        let outcome = syncInsert(injector, text: "password?", targetBundleID: "com.apple.Notes")
        XCTAssertEqual(outcome, .blocked(.eventPostFailed))
        XCTAssertEqual(ax.callCount, 1)
        XCTAssertTrue(poster.eventsSnapshot().isEmpty, "MUST NEVER fall through to typing into AXSecureTextField")
    }

    // MARK: - P0-1 Regression: Post-Event TCC Permission Gate

    func testPostEventDeniedBlocksTier2UnicodeStreamWithoutPostingEvents() {
        let ax = MockAXDirectInserter()
        ax.result = .unverifiedOrSkipped
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(
            axInserter: ax,
            poster: poster,
            postEventAccessProbe: { false }
        )

        let outcome = syncInsert(injector, text: "需要权限", targetBundleID: "com.google.Chrome")
        XCTAssertEqual(outcome, .blocked(.eventPostFailed))
        XCTAssertTrue(poster.eventsSnapshot().isEmpty, "Denied post-event permission MUST NOT post any keystrokes")

        // Also verify LiveUnicodeKeystrokePoster directly honors its postEventAccessProbe
        let livePoster = LiveUnicodeKeystrokePoster(postEventAccessProbe: { false })
        XCTAssertFalse(
            livePoster.postKeystroke(
                .unicode(
                    utf16Units: Array("a".utf16),
                    virtualKey: DirectTextInjector.inertUnicodeVirtualKey,
                    flagsRawValue: 0,
                    userData: LiteDictateConstants.syntheticEventUserData
                )
            )
        )
    }

    // MARK: - P0-2 Regression: AX Pre-Write & Post-Write Focus / PID / SecureInput Races

    func testAXPreWriteFocusChangeAbortsWithoutWritingOrFallingThrough() {
        let focusGen = AtomicUInt64(10)
        let session = MockAXFocusedTextSession()
        // Focus changes right after pre-write snapshot, IMMEDIATELY BEFORE AXUIElementSetAttributeValue!
        session.onReadBoundedValue = {
            focusGen.store(11, ordering: .release)
        }

        let liveAX = LiveAXDirectInserter(
            isProcessTrusted: { true },
            sessionProvider: { _ in session }
        )
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(axInserter: liveAX, poster: poster)

        let outcome = syncInsert(
            injector,
            text: "绝不写错窗口",
            targetPID: 1234,
            targetBundleID: "com.apple.Notes",
            expectedFocusGen: 10,
            currentFocusGen: { focusGen.load(ordering: .acquire) }
        )

        XCTAssertEqual(session.setSelectedTextCallCount, 0, "MUST NOT call AX write when focus shifted before write")
        XCTAssertEqual(
            outcome,
            .partiallyInserted(remainingText: "绝不写错窗口", reason: DirectTextInjector.preWriteChangedAbortReason)
        )
        XCTAssertTrue(poster.eventsSnapshot().isEmpty, "Must NOT fall through to Tier 2 after pre-write focus abort")
    }

    func testAXPreWriteSecureInputActivationBlocksWithoutWriting() {
        let secureInput = AtomicBool(false)
        let session = MockAXFocusedTextSession()
        session.onReadBoundedValue = {
            secureInput.store(true, ordering: .release)
        }

        let liveAX = LiveAXDirectInserter(
            isProcessTrusted: { true },
            sessionProvider: { _ in session }
        )
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(
            axInserter: liveAX,
            poster: poster,
            isSecureInputEnabled: { secureInput.load(ordering: .acquire) }
        )

        let outcome = syncInsert(injector, text: "secret", targetPID: 1234, targetBundleID: "com.apple.Notes")
        XCTAssertEqual(session.setSelectedTextCallCount, 0, "MUST NOT call AX write once Secure Input activates")
        XCTAssertEqual(outcome, .blocked(.eventPostFailed))
        XCTAssertTrue(poster.eventsSnapshot().isEmpty)
    }

    func testAXPostWriteFocusOrPIDChangeReturnsRecoveryNoticeWithoutTier2DoubleTyping() {
        let frontPID = AtomicUInt64(1234)
        let session = MockAXFocusedTextSession()
        // Focus/frontmost app shifts right DURING/AFTER setSelectedText!
        session.onSetSelectedText = { _ in
            frontPID.store(9999, ordering: .release)
        }

        let liveAX = LiveAXDirectInserter(
            isProcessTrusted: { true },
            sessionProvider: { _ in session }
        )
        let poster = RecordingUnicodeKeystrokePoster()
        let injector = makeInjector(
            axInserter: liveAX,
            poster: poster,
            frontmostPIDProvider: { pid_t(frontPID.load(ordering: .acquire)) }
        )

        let outcome = syncInsert(injector, text: "已写防重复", targetPID: 1234, targetBundleID: "com.apple.Notes")
        XCTAssertEqual(session.setSelectedTextCallCount, 1)
        XCTAssertEqual(
            outcome,
            .partiallyInserted(remainingText: "已写防重复", reason: DirectTextInjector.postWriteChangedAbortReason),
            "Must NOT claim silent .inserted and MUST NOT double-type via Tier 2"
        )
        XCTAssertTrue(poster.eventsSnapshot().isEmpty, "MUST NEVER fall through to Tier 2 double-typing after AX write")
    }

    func testLiveUnicodeKeystrokePosterAttachesUnicodeStringOnlyOnKeyDown() {
        let emojiUnits = Array("🚀".utf16)
        let event = DirectKeystrokeEvent.unicode(
            utf16Units: emojiUnits,
            virtualKey: DirectTextInjector.inertUnicodeVirtualKey,
            flagsRawValue: 0,
            userData: LiteDictateConstants.syntheticEventUserData
        )
        guard let (keyDown, keyUp) = LiveUnicodeKeystrokePoster.makeKeyEventPair(for: event) else {
            return XCTFail("Failed to construct CGEvent pair")
        }

        // keyDown carries full Unicode string, inert non-0x00 virtualKey, empty flags, LDIC userData
        XCTAssertEqual(keyDown.getIntegerValueField(.keyboardEventKeycode), Int64(DirectTextInjector.inertUnicodeVirtualKey))
        XCTAssertNotEqual(keyDown.getIntegerValueField(.keyboardEventKeycode), 0)
        XCTAssertEqual(keyDown.getIntegerValueField(.eventSourceUserData), 0x4C444943)
        XCTAssertEqual(keyDown.flags, [])

        var downLen = 0
        var downBuf = [UniChar](repeating: 0, count: 4)
        keyDown.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &downLen, unicodeString: &downBuf)
        XCTAssertEqual(String(utf16CodeUnits: downBuf, count: downLen), "🚀")

        // keyUp MUST NOT carry a Unicode string (prevents Electron/WebKit duplication or dropped events)
        XCTAssertEqual(keyUp.getIntegerValueField(.keyboardEventKeycode), Int64(DirectTextInjector.inertUnicodeVirtualKey))
        XCTAssertEqual(keyUp.getIntegerValueField(.eventSourceUserData), 0x4C444943)
        XCTAssertEqual(keyUp.flags, [])

        var upLen = 0
        var upBuf = [UniChar](repeating: 0, count: 4)
        keyUp.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &upLen, unicodeString: &upBuf)
        XCTAssertEqual(upLen, 0, "keyUp MUST NOT have keyboardSetUnicodeString attached")
    }
}
