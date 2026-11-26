import Foundation
import Testing
@testable import LiteDictateCore

// MARK: - Deterministic Test Doubles

private final class MockClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class MockAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    var startedIdentities: [CaptureIdentity] = []
    var stoppedIdentities: [CaptureIdentity] = []
    var cancelledIdentities: [CaptureIdentity] = []
    private var eventHandlers: [CaptureIdentity: @Sendable (AudioCaptureEvent) -> Void] = [:]

    func startCapture(
        identity: CaptureIdentity,
        parameters: AudioCaptureParameters,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) {
        lock.lock()
        startedIdentities.append(identity)
        eventHandlers[identity] = onEvent
        lock.unlock()
        onEvent(.captureStarted(identity: identity, deviceName: "Built-in Mic", fallbackNotice: nil))
        onEvent(.firstFrameReceived(identity: identity))
    }

    func stopCapture(identity: CaptureIdentity) {
        lock.lock()
        stoppedIdentities.append(identity)
        lock.unlock()
    }

    func cancelCapture(identity: CaptureIdentity) {
        lock.lock()
        cancelledIdentities.append(identity)
        lock.unlock()
    }

    func currentMeterLevel() -> Float { 0.25 }

    func emitCompleted(_ result: AudioCaptureResult) {
        lock.lock()
        let handler = eventHandlers[result.identity]
        lock.unlock()
        handler?(.captureCompleted(result))
    }
}

private final class MockHotkeyController: HotkeyControlling, @unchecked Sendable {
    private let lock = NSLock()
    var isTapAlive: Bool = true
    var hidModifiersClear: Bool = true

    func start(
        binding: HotkeyBinding,
        disabledBundleIDs: Set<String>,
        shouldInterceptCancelEscape: AtomicBool,
        triggerKeyDebtActive: AtomicBool,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void
    ) -> Bool { true }

    func stop() {}
    func updateBinding(_ binding: HotkeyBinding) {}
    func updateDisabledBundleIDs(_ bundleIDs: Set<String>) {}
    func setTemporarilySuspended(_ suspended: Bool) {}

    func areHIDModifiersClear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hidModifiersClear
    }

    func currentHIDModifierMask() -> HotkeyModifierMask {
        areHIDModifiersClear() ? [] : [.command]
    }

    func setHIDModifiersClear(_ clear: Bool) {
        lock.lock()
        hidModifiersClear = clear
        lock.unlock()
    }
}

private final class MockPermissionManager: PermissionManaging, @unchecked Sendable {
    private let lock = NSLock()
    var secureInput: Bool = false
    var micStatus: AuthorizationState = .granted
    var micRequestCount: Int = 0

    func snapshot(eventTapAlive: Bool) -> PermissionSnapshot {
        lock.lock()
        let mic = micStatus
        let sec = secureInput
        lock.unlock()
        return PermissionSnapshot(
            microphone: mic,
            listenEventAccess: true,
            postEventAccess: true,
            accessibilityTrusted: true,
            pasteboardAccess: .standard,
            eventTapAlive: eventTapAlive,
            secureInputEnabled: sec
        )
    }

    func setMicrophoneStatus(_ status: AuthorizationState) {
        lock.lock()
        micStatus = status
        lock.unlock()
    }

    func isSecureEventInputEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return secureInput
    }

    func setSecureInput(_ enabled: Bool) {
        lock.lock()
        secureInput = enabled
        lock.unlock()
    }

    func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        micRequestCount += 1
        lock.unlock()
        completion(false)
    }
    func requestAccessibilityPrompt() {}
    func requestListenEventAccess() -> Bool { true }
    func requestPostEventAccess() -> Bool { true }
    func settingsURL(for pane: SystemSettingsPane) -> URL { URL(string: "x-apple.systempreferences:com.apple.preference.security")! }
}

private final class MockFocusMonitor: FocusMonitoring, @unchecked Sendable {
    let focusGenerationCounter = AtomicUInt64(1)
    private let lock = NSLock()
    var targetPID: pid_t = 500
    var targetLaunchDate: Date = Date(timeIntervalSince1970: 1_600_000_000)
    var targetBundleID: String? = "com.apple.TextEdit"
    var autoAXSuccess: Bool = true
    var isSecureTextField: Bool = false
    private var activeHandler: (@Sendable (FocusEvent) -> Void)?

    var currentFocusGeneration: UInt64 {
        focusGenerationCounter.load(ordering: .acquire)
    }

    func captureInitialFocus() -> FocusContext {
        lock.lock()
        let pid = targetPID
        let ld = targetLaunchDate
        let bid = targetBundleID
        lock.unlock()
        return FocusContext(
            pid: pid,
            launchDate: ld,
            bundleIdentifier: bid,
            focusGeneration: currentFocusGeneration,
            axInitialized: false,
            isSecureTextField: false
        )
    }

    func beginMonitoring(requestID: RequestID, initialContext: FocusContext, onEvent: @escaping @Sendable (FocusEvent) -> Void) {
        lock.lock()
        activeHandler = onEvent
        let axOk = autoAXSuccess
        let secure = isSecureTextField
        lock.unlock()
        onEvent(.axInitialized(requestID: requestID, focusGeneration: initialContext.focusGeneration, success: axOk, isSecureTextField: secure))
    }

    func stopMonitoring(requestID: RequestID) {
        lock.lock()
        activeHandler = nil
        lock.unlock()
    }

    func invalidateFocus(reason: String = "changed") {
        let next = focusGenerationCounter.increment()
        lock.lock()
        let h = activeHandler
        lock.unlock()
        h?(.focusInvalidated(newGeneration: next, reason: reason))
    }

    func isFrontmostMatching(pid: pid_t, launchDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return targetPID == pid && targetLaunchDate == launchDate
    }

    func isCurrentFocusedElementSecureTextField() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isSecureTextField
    }

    func frontmostPID() -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        return targetPID
    }

    func frontmostBundleIdentifier() -> String? {
        lock.lock(); defer { lock.unlock() }
        return targetBundleID
    }

    func setFrontmost(pid: pid_t, bundleID: String?, secure: Bool = false, axOk: Bool = true) {
        lock.lock()
        targetPID = pid
        targetBundleID = bundleID
        isSecureTextField = secure
        autoAXSuccess = axOk
        lock.unlock()
    }
}

private final class MockDirectTextInjector: DirectTextInjecting, @unchecked Sendable {
    private let lock = NSLock()
    var insertedTexts: [String] = []
    var scriptedOutcome: DirectInjectionOutcome = .inserted(method: .verifiedAccessibility)

    func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return id == "com.apple.terminal" || id == "com.googlecode.iterm2"
    }

    func isTextSafeForTerminal(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar.value == 0x7F {
                return false
            }
            if scalar.value < 0x20 && scalar != "\t" {
                return false
            }
        }
        return true
    }

    func setOutcome(_ outcome: DirectInjectionOutcome) {
        lock.lock()
        scriptedOutcome = outcome
        lock.unlock()
    }

    func insertTextDirectly(
        _ text: String,
        targetPID: pid_t,
        targetBundleIdentifier: String?,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        lock.lock()
        insertedTexts.append(text)
        let outcome = scriptedOutcome
        lock.unlock()
        completion(outcome)
    }
}

private final class MockClipboardInjector: ClipboardInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy: Bool = false
    private var idleWaiters: [@Sendable () -> Void] = []
    var changeCountValue: Int = 10
    var simulateChangeCountDriftAfterPrepare: Bool = false
    var blockReason: InjectionBlockReason?
    var dispatchPasteSucceeds: Bool = true
    var preparePasteCallCount: Int = 0
    var dispatchPasteTexts: [String] = []
    var prePostGuardEvaluatedCount: Int = 0
    var restoreIfOwnedCallCount: Int = 0
    var copiedUserTexts: [String] = []
    private var lastPreparedText: String = ""

    var readiness: ClipboardReadiness {
        lock.lock(); defer { lock.unlock() }
        return isBusy ? .busy : .idle
    }

    func setBusy(_ busy: Bool) {
        lock.lock()
        isBusy = busy
        let waiters = busy ? [] : idleWaiters
        if !busy { idleWaiters.removeAll() }
        lock.unlock()
        for w in waiters { w() }
    }

    func whenIdle(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if !isBusy {
            lock.unlock()
            callback()
            return
        }
        idleWaiters.append(callback)
        lock.unlock()
    }

    func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return id == "com.apple.terminal" || id == "com.googlecode.iterm2"
    }

    func isTextSafeForTerminal(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar.value == 0x7F {
                return false
            }
            if scalar.value < 0x20 && scalar != "\t" {
                return false
            }
        }
        return true
    }

    func preparePaste(text: String, targetBundleIdentifier: String?, completion: @escaping @Sendable (InjectionPreparationResult) -> Void) {
        lock.lock()
        preparePasteCallCount += 1
        if let reason = blockReason {
            lock.unlock()
            completion(.blocked(reason))
            return
        }
        changeCountValue += 1
        let expected = changeCountValue
        if simulateChangeCountDriftAfterPrepare {
            changeCountValue += 1
        }
        lastPreparedText = text
        lock.unlock()
        completion(.ready(InjectionPreparation(transactionID: UInt64(expected), expectedChangeCount: expected, hadSnapshot: true)))
    }

    func currentChangeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return changeCountValue
    }

    func dispatchSyntheticPaste(
        preparation: InjectionPreparation,
        restoreDelayMs: Int,
        prePostGuard: (@Sendable () -> Bool)?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        if let guardFn = prePostGuard {
            lock.lock()
            prePostGuardEvaluatedCount += 1
            lock.unlock()
            if !guardFn() {
                restoreIfOwned(preparation: preparation)
                completion(false)
                return
            }
        }
        lock.lock()
        let ok = dispatchPasteSucceeds
        if ok {
            dispatchPasteTexts.append(lastPreparedText)
        }
        lock.unlock()
        completion(ok)
    }

    func restoreIfOwned(preparation: InjectionPreparation) {
        lock.lock()
        restoreIfOwnedCallCount += 1
        lock.unlock()
    }

    func copyTextForUser(_ text: String) {
        lock.lock()
        copiedUserTexts.append(text)
        lock.unlock()
    }
}

private final class MockWorkerSupervisor: WorkerSupervising, @unchecked Sendable {
    private let lock = NSLock()
    var currentState: WorkerLifecycleState = .stopped
    var currentMemoryPressure: MemoryPressureLevel = .normal
    var currentFootprintBytes: UInt64 = 0

    var warmupModels: [ModelDescriptor] = []
    var submittedRequests: [WorkerTranscriptionRequest] = []
    var cancelledRequestIDs: [RequestID] = []
    var switchedModels: [ModelDescriptor?] = []
    var shutdownCount: Int = 0

    private var eventHandler: (@Sendable (WorkerSupervisorEvent) -> Void)?
    private var attemptCounter: AttemptID = 0

    func setEventHandler(_ handler: @escaping @Sendable (WorkerSupervisorEvent) -> Void) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func prepareWarmupIfAllowed(model: ModelDescriptor) {
        lock.lock()
        warmupModels.append(model)
        lock.unlock()
    }

    func submitTranscription(_ request: WorkerTranscriptionRequest) {
        lock.lock()
        submittedRequests.append(request)
        attemptCounter += 1
        let identity = InferenceIdentity(requestID: request.requestID, workerGeneration: 1, attemptID: attemptCounter)
        let handler = eventHandler
        lock.unlock()
        handler?(.transcriptionStarted(identity))
    }

    func completeLastTranscription(text: String) {
        lock.lock()
        guard let req = submittedRequests.last else { lock.unlock(); return }
        let identity = InferenceIdentity(requestID: req.requestID, workerGeneration: 1, attemptID: attemptCounter)
        let handler = eventHandler
        lock.unlock()
        handler?(.transcriptionSucceeded(identity, LDPResultPayload(text: text)))
    }

    func emitCancelledLastTranscription() {
        lock.lock()
        guard let req = submittedRequests.last else { lock.unlock(); return }
        let identity = InferenceIdentity(requestID: req.requestID, workerGeneration: 1, attemptID: attemptCounter)
        let handler = eventHandler
        lock.unlock()
        handler?(.transcriptionCancelled(identity, stage: "external_shutdown"))
    }

    func emitPressure(_ level: MemoryPressureLevel) {
        lock.lock()
        currentMemoryPressure = level
        let handler = eventHandler
        lock.unlock()
        handler?(.memoryPressureChanged(level))
    }

    func cancelTranscription(requestID: RequestID) {
        lock.lock()
        cancelledRequestIDs.append(requestID)
        lock.unlock()
    }

    func requestModelSwitch(to model: ModelDescriptor?) {
        lock.lock()
        switchedModels.append(model)
        lock.unlock()
    }

    func shutdownGracefully(reason: String) {
        lock.lock()
        shutdownCount += 1
        lock.unlock()
    }

    func forceShutdownImmediately() {
        lock.lock()
        shutdownCount += 1
        lock.unlock()
    }
}

// MARK: - Test Harness

private struct CoordinatorHarness {
    let tempDir: URL
    let clock: MockClock
    let audio: MockAudioCapture
    let hotkey: MockHotkeyController
    let perms: MockPermissionManager
    let focus: MockFocusMonitor
    let direct: MockDirectTextInjector
    let clipboard: MockClipboardInjector
    let worker: MockWorkerSupervisor
    let registry: ModelRegistry
    let coordinator: RequestCoordinator
    let model: ModelDescriptor

    init(
        triggerMode: HotkeyTriggerMode = .toggle,
        inputMode: TextInputMode = .directTyping,
        timings: CoordinatorTimings = CoordinatorTimings(
            toggleCooldownMs: 600,
            preCommitHIDWaitMaxMs: 120,
            preCommitHIDPollIntervalMs: 10,
            failedPCMRetentionSeconds: 0.25,
            recoveryTextRetentionSeconds: 0.25
        )
    ) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir

        let gguf = dir.appendingPathComponent("qwen3-asr.gguf")
        try Data("gguf".utf8).write(to: gguf)

        let reg = ModelRegistry(appSupportDirectory: dir, discoveryDirectories: [])
        let desc = ModelDescriptor(
            id: "qwen-1",
            displayName: "Qwen3-ASR",
            filePath: gguf.path,
            storageMode: .reference,
            fileSizeBytes: 4,
            statFingerprint: ModelRegistry.statFingerprint(forPath: gguf.path),
            capabilities: ModelCapabilities(arch: "qwen3_asr", roles: ["asr"], nativeSampleRate: 16_000, maxAudioMs: 30_000, supportsVocabulary: true)
        )
        reg.registerPreprobedModel(desc, setActive: true)

        var cfg = AppConfig.defaultConfig(appSupportDir: dir)
        cfg.hotkey.triggerMode = triggerMode
        cfg.inputMode = inputMode

        let clock = MockClock()
        let audio = MockAudioCapture()
        let hotkey = MockHotkeyController()
        let perms = MockPermissionManager()
        let focus = MockFocusMonitor()
        let direct = MockDirectTextInjector()
        let clipboard = MockClipboardInjector()
        let worker = MockWorkerSupervisor()

        let coord = RequestCoordinator(
            config: cfg,
            audioCapture: audio,
            hotkeyController: hotkey,
            permissionManager: perms,
            focusMonitor: focus,
            directInjector: direct,
            clipboardInjector: clipboard,
            workerSupervisor: worker,
            modelRegistry: reg,
            postProcessor: TextPostProcessor(vocabulary: ["SwiftUI"], aliases: [AliasRule(from: "Swift UI", to: "SwiftUI")]),
            timings: timings,
            nowProvider: { clock.now() },
            selfPIDProvider: { 999 }
        )

        self.clock = clock
        self.audio = audio
        self.hotkey = hotkey
        self.perms = perms
        self.focus = focus
        self.direct = direct
        self.clipboard = clipboard
        self.worker = worker
        self.registry = reg
        self.coordinator = coord
        self.model = desc
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func validPCM() -> PCMStore {
        PCMStore(sampleRate: 16_000, samples: [Float](repeating: 0.2, count: 8_000))
    }

    func waitUntil(_ condition: () -> Bool, timeoutMs: Int = 1000) async {
        let attempts = max(1, timeoutMs / 10)
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite("RequestCoordinator State Machine, 6-Invariant Commit Arbiter & Privacy")
struct RequestCoordinatorTests {
    @Test("Default direct typing path inserts with ZERO clipboard touch, applies aliases, and clears Escape intercept in Idle")
    func testHappyPathDirectTypingZeroClipboardTouch() async throws {
        let h = try CoordinatorHarness(inputMode: .directTyping)
        defer { h.cleanup() }

        // Even if clipboard were busy, direct typing must NEVER wait on or touch clipboard!
        h.clipboard.setBusy(true)
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == true)
        #expect(h.worker.warmupModels.count == 1)

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 2))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .draining }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == true)

        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == true)

        h.worker.completeLastTranscription(text: "Hello Swift UI")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }

        #expect(h.direct.insertedTexts == ["Hello SwiftUI"])
        #expect(h.clipboard.preparePasteCallCount == 0)
        #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)
        #expect(h.coordinator.currentSnapshotDelta().recovery == nil)
    }

    @Test("Direct typing routes partiallyInserted remainingText and blocked outcomes to RecoveryPanel without touching clipboard")
    func testDirectTypingPartialAndBlockedRouteToRecovery() async throws {
        // 1. Mid-stream focus change -> partiallyInserted(remainingText)
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.direct.setOutcome(.partiallyInserted(remainingText: "剩余文字", reason: "输入过程中切换了窗口，剩余文字已为你保留"))

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "前半句剩余文字")

            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "剩余文字")
            #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)

            // Clicking [插入当前窗口] in directTyping mode uses directInjector (still 0 clipboard calls!)
            h.direct.setOutcome(.inserted(method: .unicodeKeystrokeStream))
            h.coordinator.recoveryPasteToFrontmost()
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }
            #expect(h.direct.insertedTexts.last == "剩余文字")
            #expect(h.clipboard.preparePasteCallCount == 0)
        }

        // 2. Blocked outcome routes full text to RecoveryPanel
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.direct.setOutcome(.blocked(.eventPostFailed))

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Blocked text")

            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Blocked text")
        }
    }

    @Test("Optional clipboardCompatibility mode commits via serial ClipboardInjector")
    func testClipboardCompatibilityModeHappyPath() async throws {
        let h = try CoordinatorHarness(inputMode: .clipboardCompatibility)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Hello Swift UI")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }

        #expect(h.clipboard.dispatchPasteTexts == ["Hello SwiftUI"])
        #expect(h.direct.insertedTexts.isEmpty)
    }

    @Test("Async AwaitingPreCommitReadiness waits BEFORE typing or writing clipboard; HID timeout never pollutes clipboard")
    func testPreCommitWaitNeverPollutesClipboardOnHIDTimeout() async throws {
        let h = try CoordinatorHarness(inputMode: .clipboardCompatibility)
        defer { h.cleanup() }

        // Simulate user still holding Command modifier
        h.hotkey.setHIDModifiersClear(false)

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Keep clipboard clean")

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        // Clipboard MUST NOT have been written at all!
        #expect(h.clipboard.preparePasteCallCount == 0)
        #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Keep clipboard clean")
        // Escape intercept MUST be false while RecoveryPanel is shown!
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)
    }

    @Test("Commit arbiter rejects clipboard changeCount drift in compatibility mode, calls restoreIfOwned, and routes to RecoveryPanel")
    func testCommitArbiterChangeCountInvariant() async throws {
        let h = try CoordinatorHarness(inputMode: .clipboardCompatibility)
        defer { h.cleanup() }

        h.clipboard.simulateChangeCountDriftAfterPrepare = true

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -12.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Sensitive text")

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        #expect(h.clipboard.restoreIfOwnedCallCount == 1)
        #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Sensitive text")
    }

    @Test("Commit arbiter rejects focus invalidation, terminal newline, and Secure Input")
    func testCommitArbiterFocusAndTerminalGuards() async throws {
        // 1. Focus invalidation
        do {
            let h = try CoordinatorHarness()
            defer { h.cleanup() }
            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            h.focus.invalidateFocus(reason: "switched window")
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -12.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Do not paste into wrong window")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        }

        // 2. Terminal safety blocks newline
        do {
            let h = try CoordinatorHarness()
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "com.apple.Terminal")
            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -12.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "rm -rf /\n")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        }

        // 3. Secure Input blocks auto-paste
        do {
            let h = try CoordinatorHarness()
            defer { h.cleanup() }
            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -12.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.perms.setSecureInput(true)
            h.worker.completeLastTranscription(text: "secret")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
            #expect(h.clipboard.dispatchPasteTexts.isEmpty)
        }
    }

    @Test("Toggle 600ms post-timeout cooldown blocks immediate accidental restart")
    func testTogglePostTimeoutCooldown() async throws {
        let h = try CoordinatorHarness(triggerMode: .toggle)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 29_500,
            peakDBFS: -12.0,
            audioInterrupted: false,
            droppedFrames: 0,
            truncatedByLimit: true
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Long dictation")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }

        // Immediately pressing toggle within 600ms MUST be ignored!
        #expect(h.coordinator.currentSnapshotDelta().isCoolingDown == true)
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 2))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(h.coordinator.currentSnapshotDelta().phase == .idle)
        #expect(h.audio.startedIdentities.count == 1)

        // Advance logical clock past 600ms cooldown -> next toggle starts recording cleanly!
        h.clock.advance(by: 0.65)
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 3))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        #expect(h.audio.startedIdentities.count == 2)
    }

    @Test("PTT upper-limit idempotency ignores late key release for same gestureGeneration")
    func testPTTUpperLimitIdempotency() async throws {
        let h = try CoordinatorHarness(triggerMode: .pushToTalk)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerStart(gestureGeneration: 99))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)

        // Capture auto-truncates at 29.5s while key is still held
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 29_500,
            peakDBFS: -12.0,
            audioInterrupted: false,
            droppedFrames: 0,
            truncatedByLimit: true
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }

        // User releases PTT key late (same gestureGeneration = 99) -> MUST be idempotent no-op!
        h.coordinator.handleHotkeyEvent(.triggerStop(gestureGeneration: 99))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.coordinator.currentSnapshotDelta().phase == .transcribing)
        #expect(h.audio.stoppedIdentities.isEmpty)
    }

    @Test("RecoveryPanel .critical retry guard extends 60s retention countdown without spawning worker")
    func testCriticalRetryGuard() async throws {
        let h = try CoordinatorHarness(
            timings: CoordinatorTimings(
                toggleCooldownMs: 600,
                preCommitHIDWaitMaxMs: 120,
                preCommitHIDPollIntervalMs: 10,
                failedPCMRetentionSeconds: 60.0,
                recoveryTextRetentionSeconds: 300.0
            )
        )
        defer { h.cleanup() }

        // Enter critical memory pressure
        h.worker.emitPressure(.critical)
        await h.waitUntil { h.coordinator.currentSnapshotDelta().memoryPressure == .critical }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 2_000,
            peakDBFS: -15.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        #expect(h.worker.submittedRequests.isEmpty)
        let firstExpiry = try #require(h.coordinator.currentSnapshotDelta().recovery?.expiresAt)

        // Advance clock by 20s and click [重试] while still in .critical -> MUST NOT submit worker, extends expiry +60s!
        h.clock.advance(by: 20)
        h.coordinator.recoveryRetry()
        try? await Task.sleep(for: .milliseconds(40))

        #expect(h.worker.submittedRequests.isEmpty)
        let afterRetry = try #require(h.coordinator.currentSnapshotDelta().recovery)
        #expect(afterRetry.expiresAt > firstExpiry)
        #expect(afterRetry.notice?.contains("延长语音保留时间") == true)
        #expect(h.coordinator.currentSnapshotDelta().phase == .recovery)

        // Once pressure recovers to .normal, [重试] submits retained PCM!
        h.worker.emitPressure(.normal)
        await h.waitUntil { h.coordinator.currentSnapshotDelta().memoryPressure == .normal }
        h.coordinator.recoveryRetry()
        await h.waitUntil { h.worker.submittedRequests.count == 1 }
        #expect(h.coordinator.currentSnapshotDelta().phase == .transcribing)
    }

    @Test("Privacy cleanup: Esc cancel, sleep/lock, and retention expiry wipe PCM and recovery text")
    func testPrivacyCleanupAndTimers() async throws {
        // 1. Recovery text auto-expires after retention window
        let h = try CoordinatorHarness(
            timings: CoordinatorTimings(
                toggleCooldownMs: 600,
                preCommitHIDWaitMaxMs: 50,
                preCommitHIDPollIntervalMs: 10,
                failedPCMRetentionSeconds: 0.12,
                recoveryTextRetentionSeconds: 0.12
            )
        )
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 600,
            peakDBFS: -14.0,
            audioInterrupted: true, // forces RecoveryPanel
            droppedFrames: 2
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Temporary private text")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Temporary private text")

        // Auto-expires back to idle
        await h.waitUntil({ h.coordinator.currentSnapshotDelta().phase == .idle }, timeoutMs: 800)
        #expect(h.coordinator.currentSnapshotDelta().recovery == nil)

        // 2. Esc immediately cancels recording & clears shouldInterceptCancelEscape
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 2))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == true)
        h.coordinator.handleHotkeyEvent(.cancelEscape)
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)
        #expect(h.audio.cancelledIdentities.count == 1)

        // 3. System sleep/lock wipes recovery immediately and requests worker shutdown
        h.worker.emitPressure(.critical)
        await h.waitUntil { h.coordinator.currentSnapshotDelta().memoryPressure == .critical }
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 3))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID3 = try #require(h.audio.startedIdentities.last)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID3,
            pcm: h.validPCM(),
            durationMs: 600,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

        h.coordinator.handleSystemSleepOrLock(reason: "screen_locked")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }
        #expect(h.coordinator.currentSnapshotDelta().recovery == nil)
        #expect(h.worker.shutdownCount >= 1)
    }

    @Test("Esc during AwaitingPreCommitReadiness cancels immediately without touching clipboard")
    func testEscapeDuringPreCommitReadinessCancelsCleanly() async throws {
        let h = try CoordinatorHarness(
            inputMode: .clipboardCompatibility,
            timings: CoordinatorTimings(
                toggleCooldownMs: 600,
                preCommitHIDWaitMaxMs: 500,
                preCommitHIDPollIntervalMs: 15,
                failedPCMRetentionSeconds: 60,
                recoveryTextRetentionSeconds: 300
            )
        )
        defer { h.cleanup() }

        h.clipboard.setBusy(true)
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 600,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Cancel before clipboard write")

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .awaitingPreCommitReadiness }
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == true)

        h.coordinator.handleHotkeyEvent(.cancelEscape)
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }
        #expect(h.clipboard.preparePasteCallCount == 0)
        #expect(h.coordinator.shouldInterceptCancelEscape.load() == false)
    }

    @Test("Audio interruption with non-empty PCM is never discarded by short-utterance gate")
    func testAudioInterruptedNotDroppedByShortGate() async throws {
        let h = try CoordinatorHarness()
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 90,
            peakDBFS: -70.0,
            audioInterrupted: true,
            droppedFrames: 1,
            droppedByShortUtteranceGate: true
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Interrupted short clip")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Interrupted short clip")
    }

    @Test("Re-pressing modifier during clipboard whenIdle wait re-checks live HID before touching clipboard")
    func testLiveHIDRecheckWhenClipboardBecomesIdle() async throws {
        let h = try CoordinatorHarness(
            inputMode: .clipboardCompatibility,
            timings: CoordinatorTimings(
                toggleCooldownMs: 600,
                preCommitHIDWaitMaxMs: 120,
                preCommitHIDPollIntervalMs: 10,
                failedPCMRetentionSeconds: 60,
                recoveryTextRetentionSeconds: 300
            )
        )
        defer { h.cleanup() }

        h.clipboard.setBusy(true)
        h.hotkey.setHIDModifiersClear(true)

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Wait for modifier release")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .awaitingPreCommitReadiness }

        // User holds Command right before prior clipboard restore finishes!
        h.hotkey.setHIDModifiersClear(false)
        h.clipboard.setBusy(false)

        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        // Because live HID was re-checked, clipboard was NEVER written!
        #expect(h.clipboard.preparePasteCallCount == 0)
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Wait for modifier release")
    }

    @Test("P0-4 & P1-1: recoveryPasteToFrontmost keeps Recovery visible on failed paste and uses prePostGuard")
    func testRecoveryPasteKeepsPanelOnFailureAndEvaluatesPrePostGuard() async throws {
        let h = try CoordinatorHarness(inputMode: .clipboardCompatibility)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: true,
            droppedFrames: 1
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Keep me safe")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

        // Failure on synthetic paste MUST keep RecoveryPanel intact with text!
        h.clipboard.dispatchPasteSucceeds = false
        h.coordinator.recoveryPasteToFrontmost()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.clipboard.prePostGuardEvaluatedCount == 1)
        #expect(h.coordinator.currentSnapshotDelta().phase == .recovery)
        #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Keep me safe")

        // Succeeding clears RecoveryPanel and records lastCommittedText!
        h.clipboard.dispatchPasteSucceeds = true
        h.coordinator.recoveryPasteToFrontmost()
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }
        #expect(h.coordinator.currentSnapshotDelta().recovery == nil)
        #expect(h.coordinator.currentSnapshotDelta().hasLastCommittedText == true)
    }

    @Test("P0-1 UX safety: lastCommittedText can be copied from menu and wipes on lock/sleep/quit")
    func testLastCommittedTextCopyAndPrivacyWipe() async throws {
        let h = try CoordinatorHarness(inputMode: .directTyping)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 500,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
        h.worker.completeLastTranscription(text: "Important sentence")
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }

        #expect(h.coordinator.currentSnapshotDelta().hasLastCommittedText == true)
        h.coordinator.copyLastCommittedText()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.clipboard.copiedUserTexts == ["Important sentence"])

        h.coordinator.handleSystemSleepOrLock(reason: "screen_locked")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.coordinator.currentSnapshotDelta().hasLastCommittedText == false)
    }

    @Test("P1-6: External transcriptionCancelled cleanly moves retained PCM to RecoveryPanel without stranding")
    func testExternalTranscriptionCancelledDoesNotStrand() async throws {
        let h = try CoordinatorHarness(inputMode: .directTyping)
        defer { h.cleanup() }

        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
        let capID = try #require(h.audio.startedIdentities.first)
        h.audio.emitCompleted(AudioCaptureResult(
            identity: capID,
            pcm: h.validPCM(),
            durationMs: 600,
            peakDBFS: -14.0,
            audioInterrupted: false,
            droppedFrames: 0
        ))
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }

        h.worker.emitCancelledLastTranscription()
        await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }
        #expect(h.coordinator.currentSnapshotDelta().recovery?.canRetry == true)
    }

    @Test("P1-11: Unapproved microphone blocks startCapture and requests mic permission before touching AUHAL")
    func testMicrophonePermissionGateBlocksAUHAL() async throws {
        let h = try CoordinatorHarness(inputMode: .directTyping)
        defer { h.cleanup() }

        h.perms.setMicrophoneStatus(.notDetermined)
        h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(h.audio.startedIdentities.isEmpty)
        #expect(h.perms.micRequestCount == 1)
        #expect(h.coordinator.currentSnapshotDelta().phase == .idle)
        #expect(h.coordinator.currentSnapshotDelta().lastErrorMessage?.contains("麦克风权限") == true)
    }

    @Test("Direct typing succeeds when AXObserver axInitialized is false, while still enforcing focus, frontmost, and secure guards")
    func testDirectTypingDoesNotBlockOnAXInitializedFalse() async throws {
        // 1. Direct typing with axInitialized == false succeeds cleanly
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "ai.vulcan.code.desktop", secure: false, axOk: false)

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Hello Swift UI")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .idle }

            #expect(h.direct.insertedTexts == ["Hello SwiftUI"])
            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.coordinator.currentSnapshotDelta().recovery == nil)
        }

        // 2. Direct typing with axInitialized == false STILL blocks if focusGeneration changed
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "ai.vulcan.code.desktop", secure: false, axOk: false)

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            h.focus.invalidateFocus(reason: "switched window")
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Should stay in recovery")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

            #expect(h.direct.insertedTexts.isEmpty)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Should stay in recovery")
        }

        // 3. Direct typing with axInitialized == false STILL blocks if frontmost PID changed
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "ai.vulcan.code.desktop", secure: false, axOk: false)

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.focus.setFrontmost(pid: 777, bundleID: "com.apple.Safari", secure: false, axOk: false)
            h.worker.completeLastTranscription(text: "Wrong frontmost app")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

            #expect(h.direct.insertedTexts.isEmpty)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Wrong frontmost app")
        }

        // 4. Direct typing with axInitialized == false STILL blocks if secure text field is active
        do {
            let h = try CoordinatorHarness(inputMode: .directTyping)
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "ai.vulcan.code.desktop", secure: true, axOk: false)

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Password field text")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

            #expect(h.direct.insertedTexts.isEmpty)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Password field text")
        }

        // 5. Clipboard compatibility mode STILL requires axInitialized == true
        do {
            let h = try CoordinatorHarness(inputMode: .clipboardCompatibility)
            defer { h.cleanup() }
            h.focus.setFrontmost(pid: 500, bundleID: "com.example.LegacyApp", secure: false, axOk: false)

            h.coordinator.handleHotkeyEvent(.triggerToggle(gestureGeneration: 1))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recording }
            let capID = try #require(h.audio.startedIdentities.first)
            h.audio.emitCompleted(AudioCaptureResult(
                identity: capID,
                pcm: h.validPCM(),
                durationMs: 500,
                peakDBFS: -14.0,
                audioInterrupted: false,
                droppedFrames: 0
            ))
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .transcribing }
            h.worker.completeLastTranscription(text: "Legacy app fallback")
            await h.waitUntil { h.coordinator.currentSnapshotDelta().phase == .recovery }

            #expect(h.clipboard.preparePasteCallCount == 0)
            #expect(h.coordinator.currentSnapshotDelta().recovery?.text == "Legacy app fallback")
        }
    }

    @Test("Perceptual dBFS audio level mapping stays calm in silence and responds strongly to normal speech")
    func testPerceptualAudioLevelMappingRespondsStronglyToNormalSpeech() {
        // Quiet room floor (~-58 dBFS RMS, -48 dBFS peak) stays calm near 0
        let silence = RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: 0.0012, peakDBFS: -48.0)
        #expect(silence <= 0.05)

        // Typical MacBook Air normal speaking volume (-28 dBFS RMS ~= 0.04 linear, -16 dBFS peak)
        let normalSpeech = RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: 0.04, peakDBFS: -16.0)
        #expect(normalSpeech >= 0.65)
        #expect(normalSpeech <= 0.90)

        // Strong speaking (-20 dBFS RMS ~= 0.10 linear, -8 dBFS peak) reaches near-full excursion
        let strongSpeech = RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: 0.10, peakDBFS: -8.0)
        #expect(strongSpeech >= 0.85)
        #expect(strongSpeech <= 1.0)
        #expect(strongSpeech > normalSpeech)

        // Non-finite / negative values clamp safely into [0, 1]
        #expect(RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: .nan, peakDBFS: .nan) == 0.0)
        #expect(RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: -0.5, peakDBFS: -120.0) == 0.0)
        #expect(RequestCoordinator.normalizedDisplayAudioLevel(rmsLevel: .infinity, peakDBFS: .infinity) == 0.0)
    }
}
