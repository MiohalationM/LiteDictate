import CoreGraphics
import Foundation
import XCTest
@testable import LiteDictateCore

private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
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

private final class MockPasteboard: PasteboardAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _changeCount: Int = 10
    private var _accessState: PasteboardAccessState = .standard
    private var items: [PasteboardSnapshotItem] = []
    private var _failAllReads: Bool = false
    private var _failSingleItemWrite: Bool = false
    private(set) var readDataCallCount: Int = 0
    private(set) var writeCallCount: Int = 0

    func setFailAllReads(_ fail: Bool) {
        lock.lock()
        _failAllReads = fail
        lock.unlock()
    }

    func setFailSingleItemWrite(_ fail: Bool) {
        lock.lock()
        _failSingleItemWrite = fail
        lock.unlock()
    }

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _changeCount
    }

    func setAccessState(_ state: PasteboardAccessState) {
        lock.lock()
        _accessState = state
        lock.unlock()
    }

    func accessState() -> PasteboardAccessState {
        lock.lock()
        defer { lock.unlock() }
        return _accessState
    }

    func setItems(_ newItems: [PasteboardSnapshotItem], incrementChangeCount: Bool = true) {
        lock.lock()
        items = newItems
        if incrementChangeCount {
            _changeCount += 1
        }
        lock.unlock()
    }

    func currentItems() -> [PasteboardSnapshotItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func currentUTF8String() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = items.first,
              let rep = first.representations.first(where: { $0.type == ClipboardInjector.PasteboardMarkerType.utf8String })
        else { return nil }
        return String(data: rep.data, encoding: .utf8)
    }

    func inspectItemMetadata() -> [PasteboardItemMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return items.enumerated().map { idx, item in
            PasteboardItemMetadata(itemIndex: idx, types: item.representations.map(\.type))
        }
    }

    func readData(itemIndex: Int, type: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        readDataCallCount += 1
        if _failAllReads { return nil }
        guard itemIndex >= 0, itemIndex < items.count else { return nil }
        return items[itemIndex].representations.first(where: { $0.type == type })?.data
    }

    @discardableResult
    func clearAndWriteSingleItem(_ representations: [(type: String, data: Data)]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        writeCallCount += 1
        _changeCount += 1
        if _failSingleItemWrite {
            // Simulates `clearContents()` succeeded then `writeObjects()` returned `false`.
            items = []
            return nil
        }
        items = [PasteboardSnapshotItem(representations: representations)]
        return _changeCount
    }

    @discardableResult
    func clearAndRestoreItems(_ restoredItems: [PasteboardSnapshotItem]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        writeCallCount += 1
        _changeCount += 1
        items = restoredItems
        return _changeCount
    }

    @discardableResult
    func clearAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        writeCallCount += 1
        _changeCount += 1
        items = []
        return _changeCount
    }
}

private final class RecordingPastePoster: SyntheticPastePosting, @unchecked Sendable {
    private let lock = NSLock()
    var shouldSucceed = true
    private(set) var postedSpecs: [SyntheticPasteSpec] = []

    func postCmdV(_ spec: SyntheticPasteSpec) -> Bool {
        lock.lock()
        postedSpecs.append(spec)
        let ok = shouldSucceed
        lock.unlock()
        return ok
    }
}

final class ClipboardInjectorTests: XCTestCase {
    private func makeInjector(
        pasteboard: MockPasteboard = MockPasteboard(),
        poster: RecordingPastePoster = RecordingPastePoster(),
        postEventAccessProbe: @escaping @Sendable () -> Bool = { true },
        budgetBytes: Int = LiteDictateConstants.clipboardSnapshotBudgetBytes,
        minDelayMs: Int = 10
    ) -> (ClipboardInjector, MockPasteboard, RecordingPastePoster) {
        let injector = ClipboardInjector(
            pasteboard: pasteboard,
            pastePoster: poster,
            postEventAccessProbe: postEventAccessProbe,
            snapshotBudgetBytes: budgetBytes,
            minRestoreDelayMs: minDelayMs,
            maxRestoreDelayMs: 700
        )
        return (injector, pasteboard, poster)
    }

    private func syncPrepare(
        _ injector: ClipboardInjector,
        text: String,
        targetBundleID: String? = "com.apple.Notes"
    ) -> InjectionPreparationResult {
        let exp = expectation(description: "preparePaste")
        let outBox = LockedValue<InjectionPreparationResult?>(nil)
        injector.preparePaste(text: text, targetBundleIdentifier: targetBundleID) { res in
            outBox.value = res
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        return outBox.value!
    }

    private func syncDispatch(
        _ injector: ClipboardInjector,
        preparation: InjectionPreparation,
        restoreDelayMs: Int = 40
    ) -> Bool {
        let exp = expectation(description: "dispatchSyntheticPaste")
        let flag = AtomicBool(false)
        injector.dispatchSyntheticPaste(preparation: preparation, restoreDelayMs: restoreDelayMs) { ok in
            flag.store(ok, ordering: .release)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        return flag.load(ordering: .acquire)
    }

    // MARK: - Tier 1 Zero-Copy Prescreening

    func testTier1RejectsConcealedTypeWithZeroDataReads() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("s3cr3t!".utf8)),
                (type: ClipboardInjector.PasteboardMarkerType.concealed, data: Data()),
            ]),
        ])

        let result = syncPrepare(injector, text: "hello")
        XCTAssertEqual(result, .blocked(.concealedContent))
        XCTAssertEqual(pb.readDataCallCount, 0, "Tier 1 prescreening MUST be zero-copy")
        XCTAssertEqual(pb.writeCallCount, 0, "Blocked paste MUST NOT overwrite clipboard")
        XCTAssertEqual(injector.readiness, .idle)
    }

    func testTier1RejectsFilePromisesWithZeroDataReads() {
        let promiseTypes = [
            "com.apple.NSFilePromiseItemMetaData",
            "com.apple.pasteboard.promised-file-url",
            "NSFilePromise",
            "NSPromiseContentsPboardType",
        ]

        for promiseType in promiseTypes {
            let (injector, pb, _) = makeInjector()
            pb.setItems([
                PasteboardSnapshotItem(representations: [
                    (type: promiseType, data: Data([0x01, 0x02])),
                ]),
            ])

            let result = syncPrepare(injector, text: "hello")
            XCTAssertEqual(result, .blocked(.filePromise), "Failed for type \(promiseType)")
            XCTAssertEqual(pb.readDataCallCount, 0)
            XCTAssertEqual(pb.writeCallCount, 0)
        }
    }

    func testTier1RejectsRiskyLargeImagesAndUnknownBinaryOnlyItems() {
        for riskyType in ["public.png", "public.tiff", "com.adobe.pdf", "public.jpeg", "com.figma.clipboard"] {
            let (injector, pb, _) = makeInjector()
            pb.setItems([
                PasteboardSnapshotItem(representations: [
                    (type: riskyType, data: Data(repeating: 0xAA, count: 64)),
                ]),
            ])

            let result = syncPrepare(injector, text: "hello")
            XCTAssertEqual(result, .blocked(.largeImageOrUnsupported), "Failed for type \(riskyType)")
            XCTAssertEqual(pb.readDataCallCount, 0)
            XCTAssertEqual(pb.writeCallCount, 0)
        }
    }

    // MARK: - Tier 2 8 MiB Bounded Snapshot Budget

    func testTier2RejectsSnapshotOver8MiBBudgetAndPreservesClipboard() {
        let (injector, pb, _) = makeInjector()
        let overBudget = Data(repeating: 0x41, count: LiteDictateConstants.clipboardSnapshotBudgetBytes + 1)
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: overBudget),
            ]),
        ])

        let result = syncPrepare(injector, text: "dictated text")
        XCTAssertEqual(result, .blocked(.snapshotExceededBudget))
        XCTAssertEqual(pb.writeCallCount, 0)
        XCTAssertEqual(injector.readiness, .idle)
    }

    func testTier2AllowsSnapshotExactlyAt8MiBAndRestoresIt() {
        // Use a smaller custom budget here (1024 bytes) to verify boundary <= vs > cleanly without allocating 8 MiB twice,
        // and verify default budget constant equals 8 MiB.
        XCTAssertEqual(LiteDictateConstants.clipboardSnapshotBudgetBytes, 8 * 1024 * 1024)

        let (injector, pb, _) = makeInjector(budgetBytes: 1024)
        let exactData = Data(repeating: 0x42, count: 1024)
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: exactData),
            ]),
        ])

        let result = syncPrepare(injector, text: "dictated")
        guard case let .ready(prep) = result else {
            return XCTFail("Expected .ready at exact budget, got \(result)")
        }
        XCTAssertTrue(prep.hadSnapshot)
        injector.restoreIfOwned(preparation: prep)

        let idleExp = expectation(description: "idle after rollback")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)

        XCTAssertEqual(pb.currentItems().first?.representations.first?.data, exactData)
    }

    func testPasteboardAccessAlwaysDenyBlocksBeforeTouch() {
        let (injector, pb, _) = makeInjector()
        pb.setAccessState(.alwaysDeny)

        let result = syncPrepare(injector, text: "hello")
        XCTAssertEqual(result, .blocked(.pasteboardAccessDenied))
        XCTAssertEqual(pb.writeCallCount, 0)
    }

    func testTier2UnreadableWhitelistedItemBlocksAndNeverWipesClipboard() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("user-secret-text".utf8)),
            ]),
        ])
        pb.setFailAllReads(true) // Simulates macOS 15.4+ `.ask` user denial or dead source app

        let result = syncPrepare(injector, text: "dictated")
        XCTAssertEqual(result, .blocked(.pasteboardAccessDenied))
        XCTAssertEqual(pb.writeCallCount, 0, "MUST NOT overwrite or clear clipboard when snapshot read failed")
        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "user-secret-text")
    }

    // MARK: - Transient / AutoGenerated Tagging & Synthetic Cmd+V Spec

    func testTransientAndAutoGeneratedTagsAndSyntheticCmdVSpec() {
        let (injector, pb, poster) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("original".utf8)),
            ]),
        ])

        let prepResult = syncPrepare(injector, text: "言落测试")
        guard case let .ready(prep) = prepResult else {
            return XCTFail("Expected .ready, got \(prepResult)")
        }

        // Verify written pasteboard item carries UTF-8 text + TransientType + AutoGeneratedType
        let writtenTypes = Set(pb.currentItems().first?.representations.map(\.type) ?? [])
        XCTAssertEqual(writtenTypes, [
            ClipboardInjector.PasteboardMarkerType.utf8String,
            ClipboardInjector.PasteboardMarkerType.transient,
            ClipboardInjector.PasteboardMarkerType.autoGenerated,
        ])
        XCTAssertEqual(pb.currentUTF8String(), "言落测试")
        XCTAssertEqual(injector.currentChangeCount(), prep.expectedChangeCount)

        // Dispatch synthetic Cmd+V
        let dispatched = syncDispatch(injector, preparation: prep, restoreDelayMs: 30)
        XCTAssertTrue(dispatched)
        XCTAssertEqual(poster.postedSpecs.count, 1)
        XCTAssertEqual(poster.postedSpecs.first?.virtualKey, HotkeyVirtualKeyCode.ansiV)
        XCTAssertEqual(poster.postedSpecs.first?.flagsRawValue, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(poster.postedSpecs.first?.userData, 0x4C444943)

        // Wait for restore timer to finish -> original content restored
        let idleExp = expectation(description: "restored and idle")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)

        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "original")
    }

    func testCopyTextForUserHasNoTransientOrAutoGeneratedTags() {
        let (injector, pb, _) = makeInjector()
        injector.copyTextForUser("manual copy")

        let exp = expectation(description: "copy settled")
        injector.whenIdle { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let types = pb.currentItems().first?.representations.map(\.type) ?? []
        XCTAssertEqual(types, [ClipboardInjector.PasteboardMarkerType.utf8String])
        XCTAssertEqual(pb.currentUTF8String(), "manual copy")
    }

    // MARK: - Serial Non-Cancelling Restore Queue & ChangeCount Abandonment

    func testSerialNonCancellingRestoreQueueWaitsForPriorRestore() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("original-user-clip".utf8)),
            ]),
        ])

        // Start TX1 with a 250ms restore window (resilient under parallel test CPU contention)
        guard case let .ready(prep1) = syncPrepare(injector, text: "first") else {
            return XCTFail("TX1 prepare failed")
        }
        let tx1DispatchedAt = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(syncDispatch(injector, preparation: prep1, restoreDelayMs: 250))
        XCTAssertEqual(injector.readiness, .busy)

        // Immediately queue TX2 while TX1 is in `.awaitingRestore`.
        // TX1's restore timer MUST NOT be cancelled; TX2 MUST wait until TX1 finishes restoring!
        let tx2ReadyExp = expectation(description: "TX2 prepared only after TX1 restored")
        let tx2PreparedAtBox = LockedValue<CFAbsoluteTime>(0)
        let tx2PrepBox = LockedValue<InjectionPreparation?>(nil)

        injector.preparePaste(text: "second", targetBundleIdentifier: "com.apple.Notes") { res in
            tx2PreparedAtBox.value = CFAbsoluteTimeGetCurrent()
            if case let .ready(p) = res {
                tx2PrepBox.value = p
            }
            tx2ReadyExp.fulfill()
        }

        wait(for: [tx2ReadyExp], timeout: 2.0)

        let elapsedMs = (tx2PreparedAtBox.value - tx1DispatchedAt) * 1000.0
        XCTAssertGreaterThanOrEqual(elapsedMs, 200.0, "TX2 must wait for TX1's 250ms restore timer without cancelling it")
        let tx2Prep = tx2PrepBox.value
        XCTAssertNotNil(tx2Prep)

        // Now dispatch TX2 and let it restore -> snapshot captured by TX2 MUST be "original-user-clip" (restored by TX1), NOT "first"!
        XCTAssertTrue(syncDispatch(injector, preparation: tx2Prep!, restoreDelayMs: 30))

        let finalIdleExp = expectation(description: "TX2 restored and idle")
        injector.whenIdle { finalIdleExp.fulfill() }
        wait(for: [finalIdleExp], timeout: 2.0)

        XCTAssertEqual(pb.currentUTF8String(), "original-user-clip")
    }

    func testChangeCountMismatchAbandonsRestore() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("before".utf8)),
            ]),
        ])

        guard case let .ready(prep) = syncPrepare(injector, text: "injected") else {
            return XCTFail("Expected .ready")
        }
        XCTAssertTrue(syncDispatch(injector, preparation: prep, restoreDelayMs: 300))

        // Before the 300ms restore timer fires, the user copies something new!
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("user-fresh-copy".utf8)),
            ]),
        ], incrementChangeCount: true)

        let idleExp = expectation(description: "restore timer completes and abandons overwrite")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)

        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "user-fresh-copy", "Restore MUST be abandoned when changeCount changed")
    }

    func testRestoreIfOwnedDoesNotCancelInFlightRestoreTimer() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("keep-me".utf8)),
            ]),
        ])

        guard case let .ready(prep) = syncPrepare(injector, text: "dictated") else {
            return XCTFail("Expected .ready")
        }
        XCTAssertTrue(syncDispatch(injector, preparation: prep, restoreDelayMs: 300))

        // Calling restoreIfOwned after dispatch MUST NOT cancel `.awaitingRestore`
        injector.restoreIfOwned(preparation: prep)
        XCTAssertEqual(injector.readiness, .busy)

        let idleExp = expectation(description: "timer naturally finishes")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)
        XCTAssertEqual(pb.currentUTF8String(), "keep-me")
    }

    // MARK: - Terminal Safety Guard

    func testTerminalApplicationDetectionAndControlCharGuard() {
        let (injector, pb, _) = makeInjector()

        let terminals = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.wezterm",
        ]
        for bundleID in terminals {
            XCTAssertTrue(injector.isTerminalApplication(bundleIdentifier: bundleID), "Expected terminal: \(bundleID)")
        }
        XCTAssertFalse(injector.isTerminalApplication(bundleIdentifier: "com.apple.Notes"))
        XCTAssertFalse(injector.isTerminalApplication(bundleIdentifier: "com.apple.dt.Xcode"))
        XCTAssertFalse(injector.isTerminalApplication(bundleIdentifier: nil))

        // Safe terminal strings (including horizontal tab '\t' and CJK UTF-8)
        XCTAssertTrue(injector.isTextSafeForTerminal("git status"))
        XCTAssertTrue(injector.isTextSafeForTerminal("echo\thello 世界"))

        // Unsafe terminal strings: \n, \r, < 0x20 (except \t), 0x7F
        XCTAssertFalse(injector.isTextSafeForTerminal("rm -rf /\n"))
        XCTAssertFalse(injector.isTextSafeForTerminal("cmd\r"))
        XCTAssertFalse(injector.isTextSafeForTerminal("bad\u{0000}nul"))
        XCTAssertFalse(injector.isTextSafeForTerminal("bad\u{0003}etx"))
        XCTAssertFalse(injector.isTextSafeForTerminal("bad\u{001B}esc"))
        XCTAssertFalse(injector.isTextSafeForTerminal("bad\u{007F}del"))

        // Terminal with newline MUST block before touching pasteboard
        let blocked = syncPrepare(injector, text: "ls -la\nwhoami", targetBundleID: "com.mitchellh.ghostty")
        XCTAssertEqual(blocked, .blocked(.terminalUnsafeCharacters))
        XCTAssertEqual(pb.writeCallCount, 0)

        // Terminal with tab is allowed
        let tabAllowed = syncPrepare(injector, text: "git diff\t--stat", targetBundleID: "com.apple.Terminal")
        guard case let .ready(prep) = tabAllowed else {
            return XCTFail("Tab should be allowed in terminal, got \(tabAllowed)")
        }
        injector.restoreIfOwned(preparation: prep)

        let idleExp = expectation(description: "idle after tab test")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)

        // Non-terminal app allows newlines freely
        let notesMultiline = syncPrepare(injector, text: "line 1\nline 2", targetBundleID: "com.apple.Notes")
        if case let .ready(notesPrep) = notesMultiline {
            injector.restoreIfOwned(preparation: notesPrep)
        } else {
            XCTFail("Expected non-terminal multiline to succeed, got \(notesMultiline)")
        }
    }

    // MARK: - gpt-6.2-sol Remediation Regressions (P0-1, P1-1, P1-2, P1-3, P1-4)

    func testPostEventDeniedGateRestoresSnapshotAndNeverPostsCmdV() {
        let (injector, pb, poster) = makeInjector(postEventAccessProbe: { false })
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("preserve-me".utf8)),
            ]),
        ])

        guard case let .ready(prep) = syncPrepare(injector, text: "dictated") else {
            return XCTFail("Expected .ready")
        }
        XCTAssertFalse(syncDispatch(injector, preparation: prep, restoreDelayMs: 30))
        XCTAssertTrue(poster.postedSpecs.isEmpty, "Denied post-event permission MUST NOT post Cmd+V")
        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "preserve-me")

        // Verify LiveSyntheticPastePoster directly respects its postEventAccessProbe
        let livePoster = LiveSyntheticPastePoster(postEventAccessProbe: { false })
        XCTAssertFalse(livePoster.postCmdV(.standardCmdV))
    }

    func testPrePostGuardRejectionRestoresSnapshotBecomesIdleAndSkipsPost() {
        let (injector, pb, poster) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("original-clip".utf8)),
            ]),
        ])

        guard case let .ready(prep) = syncPrepare(injector, text: "dictated") else {
            return XCTFail("Expected .ready")
        }

        let guardCalled = AtomicBool(false)
        let exp = expectation(description: "dispatchSyntheticPaste with failing prePostGuard")
        let outcome = AtomicBool(true)
        injector.dispatchSyntheticPaste(
            preparation: prep,
            restoreDelayMs: 40,
            prePostGuard: {
                guardCalled.store(true, ordering: .release)
                return false
            }
        ) { ok in
            outcome.store(ok, ordering: .release)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(guardCalled.load(ordering: .acquire))
        XCTAssertFalse(outcome.load(ordering: .acquire))
        XCTAssertTrue(poster.postedSpecs.isEmpty, "Failed prePostGuard MUST NOT post Cmd+V")
        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "original-clip")
    }

    func testWriteObjectsFailureRestoresSnapshotAndBlocksWithAccessDenied() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("user-original".utf8)),
            ]),
        ])
        pb.setFailSingleItemWrite(true)

        let result = syncPrepare(injector, text: "dictated")
        XCTAssertEqual(result, .blocked(.pasteboardAccessDenied))
        XCTAssertEqual(injector.readiness, .idle)
        XCTAssertEqual(pb.currentUTF8String(), "user-original", "Best-effort restore must recover snapshot when writeObjects fails")
    }

    func testMixedWhitelistedAndCustomNonMarkerTypeRejectedZeroCopy() {
        let (injector, pb, _) = makeInjector()
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("fallback text".utf8)),
                (type: "com.figma.clipboard", data: Data([0x01, 0x02, 0x03])),
            ]),
        ])

        let result = syncPrepare(injector, text: "hello")
        XCTAssertEqual(result, .blocked(.largeImageOrUnsupported))
        XCTAssertEqual(pb.readDataCallCount, 0, "Mixed whitelisted + custom type MUST reject at zero-copy Tier 1")
        XCTAssertEqual(pb.writeCallCount, 0)
        XCTAssertEqual(pb.currentItems().first?.representations.count, 2)

        // Benign marker alongside whitelisted text MUST still succeed
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("plain".utf8)),
                (type: "org.nspasteboard.source", data: Data("com.apple.Notes".utf8)),
            ]),
        ])
        if case let .ready(prep) = syncPrepare(injector, text: "ok") {
            injector.restoreIfOwned(preparation: prep)
        } else {
            XCTFail("Whitelisted text + benign marker should succeed")
        }
    }

    func testOverflowSafeSnapshotBudgetCheckHandlesIntMax() {
        let budget = LiteDictateConstants.clipboardSnapshotBudgetBytes
        XCTAssertTrue(ClipboardInjector.wouldExceedSnapshotBudget(currentBytes: 100, addingBytes: Int.max, budgetBytes: budget))
        XCTAssertTrue(ClipboardInjector.wouldExceedSnapshotBudget(currentBytes: budget, addingBytes: 1, budgetBytes: budget))
        XCTAssertFalse(ClipboardInjector.wouldExceedSnapshotBudget(currentBytes: budget - 10, addingBytes: 10, budgetBytes: budget))
        XCTAssertTrue(ClipboardInjector.wouldExceedSnapshotBudget(currentBytes: budget - 10, addingBytes: 11, budgetBytes: budget))
        XCTAssertTrue(ClipboardInjector.wouldExceedSnapshotBudget(currentBytes: 0, addingBytes: -1, budgetBytes: budget))
    }

    func testCommonBrowserAndEditorClipboardCompanionTypesSnapshotAndRestoreCleanly() {
        let (injector, pb, poster) = makeInjector()
        let vscodeData = Data("{\"mode\":\"swift\"}".utf8)
        let webCustom = Data([0x01, 0x02, 0x03, 0x04])
        pb.setItems([
            PasteboardSnapshotItem(representations: [
                (type: ClipboardInjector.PasteboardMarkerType.utf8String, data: Data("let x = 1".utf8)),
                (type: "NSStringPboardType", data: Data("let x = 1".utf8)),
                (type: "org.chromium.web-custom-data", data: webCustom),
                (type: "Apple HTML pasteboard type", data: Data("<pre>let x = 1</pre>".utf8)),
                (type: "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", data: vscodeData),
            ]),
        ])

        guard case let .ready(prep) = syncPrepare(injector, text: "语音输入测试", targetBundleID: "com.microsoft.VSCode") else {
            return XCTFail("Expected browser/editor text copy with companion metadata to snapshot cleanly")
        }
        XCTAssertTrue(syncDispatch(injector, preparation: prep, restoreDelayMs: 25))
        XCTAssertEqual(poster.postedSpecs.count, 1)

        let idleExp = expectation(description: "restored browser/editor clipboard")
        injector.whenIdle { idleExp.fulfill() }
        wait(for: [idleExp], timeout: 2.0)

        XCTAssertEqual(pb.currentUTF8String(), "let x = 1")
        let restoredTypes = Set(pb.currentItems().first?.representations.map(\.type) ?? [])
        XCTAssertTrue(restoredTypes.contains("org.chromium.web-custom-data"))
        XCTAssertTrue(restoredTypes.contains("dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"))
    }
}
