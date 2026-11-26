import Foundation

public struct CoordinatorTimings: Sendable {
    public var toggleCooldownMs: Int
    public var preCommitHIDWaitMaxMs: Int
    public var preCommitHIDPollIntervalMs: Int
    public var failedPCMRetentionSeconds: TimeInterval
    public var recoveryTextRetentionSeconds: TimeInterval

    public static let production = CoordinatorTimings(
        toggleCooldownMs: LiteDictateConstants.toggleCooldownMs,
        preCommitHIDWaitMaxMs: LiteDictateConstants.preCommitHIDWaitMaxMs,
        preCommitHIDPollIntervalMs: 15,
        failedPCMRetentionSeconds: LiteDictateConstants.failedPCMRetentionSeconds,
        recoveryTextRetentionSeconds: LiteDictateConstants.recoveryTextRetentionSeconds
    )

    public init(
        toggleCooldownMs: Int = LiteDictateConstants.toggleCooldownMs,
        preCommitHIDWaitMaxMs: Int = LiteDictateConstants.preCommitHIDWaitMaxMs,
        preCommitHIDPollIntervalMs: Int = 15,
        failedPCMRetentionSeconds: TimeInterval = LiteDictateConstants.failedPCMRetentionSeconds,
        recoveryTextRetentionSeconds: TimeInterval = LiteDictateConstants.recoveryTextRetentionSeconds
    ) {
        self.toggleCooldownMs = toggleCooldownMs
        self.preCommitHIDWaitMaxMs = preCommitHIDWaitMaxMs
        self.preCommitHIDPollIntervalMs = preCommitHIDPollIntervalMs
        self.failedPCMRetentionSeconds = failedPCMRetentionSeconds
        self.recoveryTextRetentionSeconds = recoveryTextRetentionSeconds
    }
}

public struct CoordinatorSnapshotDelta: Equatable, Sendable {
    public let phase: InteractionPhase
    public let workerState: WorkerLifecycleState
    public let memoryPressure: MemoryPressureLevel
    public let workerFootprintBytes: UInt64
    public let isSecureInputPaused: Bool
    public let overlay: RecordingOverlayState
    public let recovery: RecoveryPayload?
    public let hasLastCommittedText: Bool
    public let isCoolingDown: Bool
    public let lastErrorMessage: String?
    public let lastNoticeMessage: String?
}

/// Single-owner serial interaction coordinator & synchronous 6-invariant commit arbiter.
/// Zero UI dependencies, zero transcript logging, strict privacy cleanup timers.
public final class RequestCoordinator: @unchecked Sendable {
    private let coordinatorQueue = DispatchQueue(label: "io.github.litedictate.coordinator", qos: .userInteractive)

    // Lock-free atomics exported to HotkeyController EventTap thread (never sync-queried).
    public let shouldInterceptCancelEscape = AtomicBool(false)
    public let triggerKeyDebtActive = AtomicBool(false)

    private let audioCapture: AudioCapturing
    private let hotkeyController: HotkeyControlling
    private let permissionManager: PermissionManaging
    private let focusMonitor: FocusMonitoring
    private let directInjector: DirectTextInjecting
    private let clipboardInjector: ClipboardInjecting
    private let workerSupervisor: WorkerSupervising
    private let modelRegistry: ModelRegistry
    private let timings: CoordinatorTimings
    private let nowProvider: @Sendable () -> Date
    private let selfPIDProvider: @Sendable () -> pid_t
    private let onLimitTruncatedSound: (@Sendable () -> Void)?
    private let onOpenMicrophoneSettingsNeeded: (@Sendable () -> Void)?

    private var onStateChange: (@Sendable (CoordinatorSnapshotDelta) -> Void)?

    // Mutable state exclusively owned by `coordinatorQueue`.
    private var config: AppConfig
    private var postProcessor: TextPostProcessor

    private var phase: InteractionPhase = .idle
    private var workerState: WorkerLifecycleState = .stopped
    private var memoryPressure: MemoryPressureLevel = .normal
    private var workerFootprintBytes: UInt64 = 0
    private var isCompilingMetalShaders: Bool = false
    private var isSecureInputPaused: Bool = false

    private var nextRequestID: RequestID = 0
    private var nextCaptureGeneration: CaptureGeneration = 0
    private var activeRequestID: RequestID = 0
    private var activeCaptureIdentity: CaptureIdentity?
    private var activeInferenceIdentity: InferenceIdentity?
    private var activeGestureGeneration: GestureGeneration?
    private var suppressedPTTGestureGeneration: GestureGeneration?
    private var activeFocusContext: FocusContext?
    private var activeModelForRequest: ModelDescriptor?
    private var activeCaptureStartDate: Date?
    private var activeCaptureLimitMs: Int = LiteDictateConstants.defaultCaptureLimitMs
    private var activeDeviceName: String?
    private var activeAudioInterrupted: Bool = false
    private var activeDroppedFrames: UInt64 = 0
    private var activeFirstFrameReceived: Bool = false
    private var activeAudioLevel: Float = 0.0
    private var lastOverlayLevelPublish: Date = .distantPast

    private var armToggleCooldownOnIdle: Bool = false
    private var toggleCooldownUntil: Date?
    private var cooldownClearTimer: DispatchWorkItem?

    // Pre-commit async wait state (strictly BEFORE clipboard write).
    private var preCommitRequestID: RequestID = 0
    private var preCommitText: String?
    private var preCommitClipboardReady: Bool = false
    private var preCommitHIDReady: Bool = false
    private var preCommitPollTimer: DispatchWorkItem?
    private var preCommitTimeoutTimer: DispatchWorkItem?

    // Privacy-bounded temporary retention (PCM <= 60s on failure/critical; text <= 5 min in RecoveryPanel).
    private var retainedPCM: PCMStore?
    private var retainedModelForRetry: ModelDescriptor?
    private var recoveryPayload: RecoveryPayload?
    private var pcmRetentionTimer: DispatchWorkItem?
    private var recoveryTextRetentionTimer: DispatchWorkItem?

    // P0-1 UX safety: single in-memory copy of the last committed text (5-min TTL, cleared on sleep/lock/quit, 0 disk, 0 logs).
    private var lastCommittedText: String?
    private var lastCommittedTextTimer: DispatchWorkItem?

    private var lastErrorMessage: String?
    private var lastNoticeMessage: String?

    public init(
        config: AppConfig,
        audioCapture: AudioCapturing,
        hotkeyController: HotkeyControlling,
        permissionManager: PermissionManaging,
        focusMonitor: FocusMonitoring,
        directInjector: DirectTextInjecting,
        clipboardInjector: ClipboardInjecting,
        workerSupervisor: WorkerSupervising,
        modelRegistry: ModelRegistry,
        postProcessor: TextPostProcessor? = nil,
        timings: CoordinatorTimings = .production,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        selfPIDProvider: @escaping @Sendable () -> pid_t = { ProcessInfo.processInfo.processIdentifier },
        onLimitTruncatedSound: (@Sendable () -> Void)? = nil,
        onOpenMicrophoneSettingsNeeded: (@Sendable () -> Void)? = nil
    ) {
        self.config = config
        self.audioCapture = audioCapture
        self.hotkeyController = hotkeyController
        self.permissionManager = permissionManager
        self.focusMonitor = focusMonitor
        self.directInjector = directInjector
        self.clipboardInjector = clipboardInjector
        self.workerSupervisor = workerSupervisor
        self.modelRegistry = modelRegistry
        self.postProcessor = postProcessor ?? TextPostProcessor.load(
            vocabPath: config.vocabPath,
            aliasesPath: config.aliasesPath
        )
        self.timings = timings
        self.nowProvider = nowProvider
        self.selfPIDProvider = selfPIDProvider
        self.onLimitTruncatedSound = onLimitTruncatedSound
        self.onOpenMicrophoneSettingsNeeded = onOpenMicrophoneSettingsNeeded

        self.workerState = workerSupervisor.currentState
        self.memoryPressure = workerSupervisor.currentMemoryPressure
        self.workerFootprintBytes = workerSupervisor.currentFootprintBytes

        self.shouldInterceptCancelEscape.store(false, ordering: .release)

        self.workerSupervisor.setEventHandler { [weak self] event in
            guard let self else { return }
            self.coordinatorQueue.async {
                self.handleWorkerEventLocked(event)
            }
        }
    }

    public func setStateChangeHandler(_ handler: @escaping @Sendable (CoordinatorSnapshotDelta) -> Void) {
        coordinatorQueue.async {
            self.onStateChange = handler
            self.publishStateLocked()
        }
    }

    public func updateConfig(_ newConfig: AppConfig) {
        coordinatorQueue.async {
            self.config = newConfig
            self.postProcessor = TextPostProcessor.load(
                vocabPath: newConfig.vocabPath,
                aliasesPath: newConfig.aliasesPath
            )
        }
    }

    public func reloadTextPostProcessor(_ processor: TextPostProcessor) {
        coordinatorQueue.async {
            self.postProcessor = processor
        }
    }

    /// Synchronous read helper for unit tests and diagnostics.
    public func currentSnapshotDelta() -> CoordinatorSnapshotDelta {
        coordinatorQueue.sync {
            buildSnapshotDeltaLocked()
        }
    }

    // MARK: - External Triggers

    public func handleHotkeyEvent(_ event: HotkeyEvent) {
        coordinatorQueue.async {
            switch event {
            case let .triggerToggle(gestureGen):
                self.handleToggleTriggerLocked(gestureGeneration: gestureGen)
            case let .triggerStart(gestureGen):
                self.handlePTTStartLocked(gestureGeneration: gestureGen)
            case let .triggerStop(gestureGen):
                self.handlePTTStopLocked(gestureGeneration: gestureGen)
            case .cancelEscape:
                self.handleCancelEscapeLocked()
            case let .systemReset(reason):
                self.handleSystemResetLocked(reason: reason)
            }
        }
    }

    public func toggleFromUI() {
        coordinatorQueue.async {
            self.handleToggleTriggerLocked(gestureGeneration: 0)
        }
    }

    public func cancelFromUI() {
        coordinatorQueue.async {
            self.cancelActiveRequestLocked(notice: nil)
        }
    }

    public func handleModelSwitched(to model: ModelDescriptor?) {
        coordinatorQueue.async {
            self.workerSupervisor.requestModelSwitch(to: model)
        }
    }

    public func copyLastCommittedText() {
        coordinatorQueue.async {
            guard let text = self.lastCommittedText, !text.isEmpty else {
                return
            }
            self.clipboardInjector.copyTextForUser(text)
            self.lastNoticeMessage = "已复制上一次识别的文字"
            self.publishStateLocked()
        }
    }

    public func handleSystemSleepOrLock(reason: String) {
        coordinatorQueue.async {
            self.cancelActiveRequestLocked(notice: nil)
            self.wipeAllPrivacyDataLocked()
            self.clearLastCommittedTextLocked()
            self.workerSupervisor.shutdownGracefully(reason: reason)
            self.publishStateLocked()
        }
    }

    public func prepareForQuit() {
        coordinatorQueue.async {
            self.cancelActiveRequestLocked(notice: nil)
            self.wipeAllPrivacyDataLocked()
            self.clearLastCommittedTextLocked()
            self.workerSupervisor.forceShutdownImmediately()
            self.publishStateLocked()
        }
    }

    // MARK: - Recovery Panel Commands

    public func recoveryCopy() {
        coordinatorQueue.async {
            guard self.phase == .recovery, let text = self.recoveryPayload?.text, !text.isEmpty else {
                return
            }
            self.clipboardInjector.copyTextForUser(text)
            self.wipeAllPrivacyDataLocked()
            self.lastNoticeMessage = "文字已复制"
            self.transitionToIdleLocked()
        }
    }

    public func recoveryPasteToFrontmost() {
        coordinatorQueue.async { [self] in
            guard phase == .recovery, let text = recoveryPayload?.text, !text.isEmpty else {
                return
            }
            let myPID = selfPIDProvider()
            guard let frontPID = focusMonitor.frontmostPID(), frontPID != myPID else {
                updateRecoveryNoticeLocked("请先点击目标输入框，再点击「插入当前窗口」")
                return
            }
            if permissionManager.isSecureEventInputEnabled() || focusMonitor.isCurrentFocusedElementSecureTextField() {
                updateRecoveryNoticeLocked("当前是密码输入框，为保护隐私不自动输入，可点击「复制文字」")
                return
            }
            let bundleID = focusMonitor.frontmostBundleIdentifier()
            let recoveryID = recoveryPayload?.id

            if config.inputMode == .directTyping {
                if directInjector.isTerminalApplication(bundleIdentifier: bundleID) &&
                    !directInjector.isTextSafeForTerminal(text) {
                    updateRecoveryNoticeLocked(InjectionBlockReason.terminalUnsafeCharacters.userMessage)
                    return
                }
                let expectedGen = focusMonitor.currentFocusGeneration
                let monitor = focusMonitor
                directInjector.insertTextDirectly(
                    text,
                    targetPID: frontPID,
                    targetBundleIdentifier: bundleID,
                    expectedFocusGeneration: expectedGen,
                    currentFocusGeneration: { monitor.currentFocusGeneration }
                ) { [weak coordinator = self] outcome in
                    guard let coordinator else { return }
                    coordinator.coordinatorQueue.async {
                        guard coordinator.phase == .recovery, coordinator.recoveryPayload?.id == recoveryID else { return }
                        switch outcome {
                        case .inserted:
                            coordinator.recordLastCommittedTextLocked(text)
                            coordinator.wipeAllPrivacyDataLocked()
                            coordinator.transitionToIdleLocked()
                        case let .partiallyInserted(remaining, reason):
                            let kept = remaining.isEmpty ? text : remaining
                            coordinator.enterRecoveryWithTextLocked(text: kept, reason: reason, keepRetainedPCM: false)
                        case let .blocked(blockReason):
                            coordinator.updateRecoveryNoticeLocked(blockReason.userMessage)
                        }
                    }
                }
                return
            }

            // Clipboard compatibility mode fallback
            if clipboardInjector.isTerminalApplication(bundleIdentifier: bundleID) &&
                !clipboardInjector.isTextSafeForTerminal(text) {
                updateRecoveryNoticeLocked(InjectionBlockReason.terminalUnsafeCharacters.userMessage)
                return
            }

            let targetBundle = bundleID
            let restoreDelay = config.pasteRestoreDelayMs

            clipboardInjector.whenIdle { [weak coordinator = self] in
                guard let coordinator else { return }
                coordinator.coordinatorQueue.async {
                    guard coordinator.phase == .recovery, coordinator.recoveryPayload?.id == recoveryID else { return }
                    guard let currentFrontPID = coordinator.focusMonitor.frontmostPID(), currentFrontPID != coordinator.selfPIDProvider() else {
                        coordinator.updateRecoveryNoticeLocked("目标窗口已失焦，请重新点击输入框后再试")
                        return
                    }
                    coordinator.clipboardInjector.preparePaste(text: text, targetBundleIdentifier: targetBundle) { [weak coord = coordinator] prepResult in
                        guard let coord else { return }
                        coord.coordinatorQueue.async {
                            guard coord.phase == .recovery, coord.recoveryPayload?.id == recoveryID else {
                                if case let .ready(prep) = prepResult {
                                    coord.clipboardInjector.restoreIfOwned(preparation: prep)
                                }
                                return
                            }
                            switch prepResult {
                            case let .blocked(reason):
                                coord.updateRecoveryNoticeLocked(reason.userMessage)
                            case let .ready(prep):
                                let frontStillExternal = (coord.focusMonitor.frontmostPID() != nil &&
                                    coord.focusMonitor.frontmostPID() != coord.selfPIDProvider())
                                let notSecure = !coord.permissionManager.isSecureEventInputEnabled() &&
                                    !coord.focusMonitor.isCurrentFocusedElementSecureTextField()
                                let changeMatches = (coord.clipboardInjector.currentChangeCount() == prep.expectedChangeCount)

                                guard frontStillExternal && notSecure && changeMatches else {
                                    coord.clipboardInjector.restoreIfOwned(preparation: prep)
                                    coord.updateRecoveryNoticeLocked("刚刚窗口或剪贴板有变化，请重试或直接复制")
                                    return
                                }

                                // P0-4: NEVER wipe Recovery data or return to Idle before async synthetic paste completes!
                                let prePostGuard: @Sendable () -> Bool = { [focusMonitor = coord.focusMonitor, permissionManager = coord.permissionManager, selfPIDProvider = coord.selfPIDProvider] in
                                    guard let frontPID = focusMonitor.frontmostPID(), frontPID != selfPIDProvider() else {
                                        return false
                                    }
                                    return !permissionManager.isSecureEventInputEnabled() &&
                                        !focusMonitor.isCurrentFocusedElementSecureTextField()
                                }
                                coord.clipboardInjector.dispatchSyntheticPaste(
                                    preparation: prep,
                                    restoreDelayMs: restoreDelay,
                                    prePostGuard: prePostGuard
                                ) { [weak finalCoord = coord] dispatched in
                                    guard let finalCoord else { return }
                                    finalCoord.coordinatorQueue.async {
                                        guard finalCoord.phase == .recovery, finalCoord.recoveryPayload?.id == recoveryID else {
                                            return
                                        }
                                        if dispatched {
                                            finalCoord.recordLastCommittedTextLocked(text)
                                            finalCoord.wipeAllPrivacyDataLocked()
                                            finalCoord.transitionToIdleLocked()
                                        } else {
                                            finalCoord.updateRecoveryNoticeLocked(InjectionBlockReason.eventPostFailed.userMessage)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Section 9.2 P2-2: `.critical` retry guard extends the 60s PCM retention countdown with a light notice
    /// instead of spawning a worker that would immediately be killed.
    public func recoveryRetry() {
        coordinatorQueue.async {
            guard self.phase == .recovery else { return }
            guard let pcm = self.retainedPCM, !pcm.isEmpty else {
                self.updateRecoveryNoticeLocked("保留语音已过期，请重新说话")
                return
            }

            // P2-2: `.critical` retry guard
            if self.memoryPressure == .critical {
                let newExpiry = self.nowProvider().addingTimeInterval(self.timings.failedPCMRetentionSeconds)
                self.armPCMRetentionTimerLocked(seconds: self.timings.failedPCMRetentionSeconds)
                if let current = self.recoveryPayload {
                    self.recoveryPayload = RecoveryPayload(
                        id: current.id,
                        text: current.text,
                        hasRetainedAudio: true,
                        reason: current.reason,
                        notice: "系统内存仍较紧张，已为你延长语音保留时间",
                        expiresAt: newExpiry,
                        canRetry: true,
                        canPaste: current.canPaste,
                        canCopy: current.canCopy
                    )
                }
                self.lastNoticeMessage = "系统内存仍较紧张，已为你延长语音保留时间"
                self.publishStateLocked()
                return
            }

            let modelResult = self.modelRegistry.verifyActiveModelForLaunch()
            guard case let .success(model) = modelResult else {
                self.updateRecoveryNoticeLocked("语音模型暂不可用，请在偏好设置中检查模型文件")
                return
            }

            self.recoveryTextRetentionTimer?.cancel()
            self.recoveryTextRetentionTimer = nil
            self.recoveryPayload = nil

            self.nextRequestID &+= 1
            self.activeRequestID = self.nextRequestID
            self.activeModelForRequest = model
            self.activeFocusContext = nil // Retried audio always routes to RecoveryPanel for safe manual insertion
            self.activeAudioInterrupted = true
            self.activeDroppedFrames = 0

            self.setPhaseLocked(.waitingWorkerReady)
            self.submitPCMToWorkerLocked(requestID: self.activeRequestID, model: model, pcm: pcm)
        }
    }

    public func recoveryDiscard() {
        coordinatorQueue.async {
            guard self.phase == .recovery else { return }
            self.wipeAllPrivacyDataLocked()
            self.transitionToIdleLocked()
        }
    }

    // MARK: - Hotkey State Handling (`coordinatorQueue` only)

    private func handleToggleTriggerLocked(gestureGeneration: GestureGeneration) {
        switch phase {
        case .idle, .recovery:
            // Section 6.1 P2-1: 600ms post-timeout cooldown prevents accidental immediate re-recording.
            if isCurrentlyInToggleCooldownLocked() {
                return
            }
            if phase == .recovery {
                wipeAllPrivacyDataLocked()
            }
            startNewRecordingLocked(gestureGeneration: gestureGeneration)

        case .arming, .recording:
            stopActiveRecordingLocked()

        default:
            // Ignore toggle while draining/transcribing/committing.
            break
        }
    }

    private func handlePTTStartLocked(gestureGeneration: GestureGeneration) {
        switch phase {
        case .idle, .recovery:
            if phase == .recovery {
                wipeAllPrivacyDataLocked()
            }
            startNewRecordingLocked(gestureGeneration: gestureGeneration)
        default:
            break
        }
    }

    private func handlePTTStopLocked(gestureGeneration: GestureGeneration) {
        // Section 6.1 P1-4: late release after auto-truncation is an idempotent no-op.
        if let suppressed = suppressedPTTGestureGeneration, suppressed == gestureGeneration {
            suppressedPTTGestureGeneration = nil
            return
        }
        guard activeGestureGeneration == gestureGeneration else {
            return
        }
        if phase == .arming || phase == .recording {
            stopActiveRecordingLocked()
        }
    }

    private func handleCancelEscapeLocked() {
        guard phase.shouldInterceptCancelEscape else {
            return
        }
        cancelActiveRequestLocked(notice: nil)
    }

    private func handleSystemResetLocked(reason: String) {
        isSecureInputPaused = permissionManager.isSecureEventInputEnabled()
        if phase == .arming || phase == .recording || phase == .draining ||
            phase == .waitingWorkerReady || phase == .transcribing ||
            phase == .validating || phase == .awaitingPreCommitReadiness ||
            phase == .preparingInjection || phase == .revalidating {
            cancelActiveRequestLocked(notice: "本次语音输入已自动取消")
        } else {
            publishStateLocked()
        }
    }

    // MARK: - Capture Lifecycle

    private func startNewRecordingLocked(gestureGeneration: GestureGeneration) {
        if permissionManager.isSecureEventInputEnabled() {
            isSecureInputPaused = true
            lastNoticeMessage = "当前是密码输入框，已暂停语音输入"
            publishStateLocked()
            return
        }
        isSecureInputPaused = false

        // P1-11: Gate on microphone authorization BEFORE calling audioCapture.startCapture!
        let micStatus = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive).microphone
        if micStatus != .granted {
            lastErrorMessage = "还没有开启麦克风权限，请在弹窗或系统设置中开启后重试"
            publishStateLocked()
            if micStatus == .notDetermined {
                permissionManager.requestMicrophoneAccess { [weak self] granted in
                    guard let self else { return }
                    self.coordinatorQueue.async {
                        if !granted {
                            self.onOpenMicrophoneSettingsNeeded?()
                        }
                    }
                }
            } else {
                onOpenMicrophoneSettingsNeeded?()
            }
            return
        }

        let modelResult = modelRegistry.verifyActiveModelForLaunch()
        let model: ModelDescriptor
        switch modelResult {
        case let .success(m):
            model = m
        case let .failure(err):
            lastErrorMessage = err.userMessage
            publishStateLocked()
            return
        }

        // Zero-IPC press-time focus capture (Section 8.2)
        let initialFocus = focusMonitor.captureInitialFocus()

        nextRequestID &+= 1
        nextCaptureGeneration &+= 1
        let reqID = nextRequestID
        let capID = CaptureIdentity(requestID: reqID, captureGeneration: nextCaptureGeneration)

        activeRequestID = reqID
        activeCaptureIdentity = capID
        activeInferenceIdentity = nil
        activeGestureGeneration = gestureGeneration
        activeFocusContext = initialFocus
        activeModelForRequest = model
        activeCaptureStartDate = nowProvider()
        activeCaptureLimitMs = model.capabilities.effectiveCaptureLimitMs
        activeDeviceName = nil
        activeAudioInterrupted = false
        activeDroppedFrames = 0
        activeFirstFrameReceived = false
        activeAudioLevel = 0.0
        armToggleCooldownOnIdle = false
        lastErrorMessage = nil
        lastNoticeMessage = nil

        setPhaseLocked(.arming)

        // Immediately start Input-only AUHAL capture.
        let params = AudioCaptureParameters(
            targetSampleRate: model.capabilities.nativeSampleRate,
            captureLimitMs: model.capabilities.effectiveCaptureLimitMs,
            maxSamplesForModel: model.capabilities.effectiveMaxSamples,
            selectionMode: config.audioSelection
        )
        audioCapture.startCapture(identity: capID, parameters: params) { [weak self] event in
            guard let self else { return }
            self.coordinatorQueue.async {
                self.handleAudioEventLocked(event)
            }
        }

        // Concurrently attach main-thread AXObserver (async, 0.15s timeout).
        focusMonitor.beginMonitoring(requestID: reqID, initialContext: initialFocus) { [weak self] focusEvent in
            guard let self else { return }
            self.coordinatorQueue.async {
                self.handleFocusEventLocked(focusEvent)
            }
        }

        // Concurrently trigger predictive cold-worker warmup if memory pressure is `.normal`.
        workerSupervisor.prepareWarmupIfAllowed(model: model)
    }

    private func stopActiveRecordingLocked() {
        guard let capID = activeCaptureIdentity, (phase == .arming || phase == .recording) else {
            return
        }
        setPhaseLocked(.draining)
        audioCapture.stopCapture(identity: capID)
    }

    private func handleAudioEventLocked(_ event: AudioCaptureEvent) {
        switch event {
        case let .captureStarted(identity, deviceName, fallbackNotice):
            guard identity == activeCaptureIdentity else { return }
            activeDeviceName = deviceName
            if let fallbackNotice {
                lastNoticeMessage = fallbackNotice
            }
            if phase == .arming {
                setPhaseLocked(.recording)
            } else {
                publishStateLocked()
            }

        case let .firstFrameReceived(identity):
            guard identity == activeCaptureIdentity else { return }
            activeFirstFrameReceived = true
            if phase == .arming {
                setPhaseLocked(.recording)
            } else {
                publishStateLocked()
            }

        case let .speechDetected(identity):
            guard identity == activeCaptureIdentity else { return }
            activeFirstFrameReceived = true
            publishStateLocked()

        case let .levelUpdate(identity, rmsLevel, _):
            guard identity == activeCaptureIdentity else { return }
            activeAudioLevel = max(0, min(1, rmsLevel))
            let now = nowProvider()
            // Throttle UI overlay projection to ~15 Hz (66 ms)
            if now.timeIntervalSince(lastOverlayLevelPublish) >= 0.066 {
                lastOverlayLevelPublish = now
                publishStateLocked()
            }

        case let .captureCompleted(result):
            handleCaptureCompletedLocked(result)

        case let .captureFailed(identity, reason):
            guard identity == activeCaptureIdentity else { return }
            activeCaptureIdentity = nil
            focusMonitor.stopMonitoring(requestID: identity.requestID)
            lastErrorMessage = reason
            transitionToIdleLocked()
        }
    }

    private func handleCaptureCompletedLocked(_ result: AudioCaptureResult) {
        guard result.identity == activeCaptureIdentity else {
            return // Silently discard stale capture completion
        }
        activeCaptureIdentity = nil
        activeAudioInterrupted = result.audioInterrupted
        activeDroppedFrames = result.droppedFrames
        if let notice = result.fallbackNotice {
            lastNoticeMessage = notice
        }

        if result.truncatedByLimit {
            if config.playFeedbackSounds {
                onLimitTruncatedSound?()
            }
            if config.hotkey.triggerMode == .pushToTalk {
                // P1-4: suppress late key-up for same gestureGeneration
                suppressedPTTGestureGeneration = activeGestureGeneration
            } else {
                // P2-1: arm 600ms cooldown once request returns to Idle
                armToggleCooldownOnIdle = true
            }
        }

        // Recall-oriented short utterance gate:
        // Never discard non-empty PCM that suffered audio interruption — route it onward to RecoveryPanel.
        let isShortDropped = result.pcm.isEmpty || (
            !result.audioInterrupted && (
                result.droppedByShortUtteranceGate ||
                result.durationMs < LiteDictateConstants.shortUtteranceMinDurationMs ||
                result.peakDBFS < LiteDictateConstants.shortUtteranceMinPeakDBFS
            )
        )

        if isShortDropped {
            focusMonitor.stopMonitoring(requestID: result.identity.requestID)
            retainedPCM = nil
            if result.audioInterrupted && result.pcm.isEmpty {
                lastErrorMessage = "麦克风收音意外中断，请再说一次"
            }
            transitionToIdleLocked()
            return
        }

        guard let model = activeModelForRequest else {
            focusMonitor.stopMonitoring(requestID: result.identity.requestID)
            transitionToIdleLocked()
            return
        }

        // Hard clamp samples before sending to worker (Section 5.2 / 4.3).
        let clampedPCM = result.pcm.clamped(maxSamples: model.capabilities.effectiveMaxSamples)
        retainedPCM = clampedPCM
        retainedModelForRetry = model

        // Section 9.1: `.critical` forbids spawning new inference; retain PCM <= 60s into RecoveryPanel.
        if memoryPressure == .critical {
            focusMonitor.stopMonitoring(requestID: result.identity.requestID)
            enterRecoveryWithRetainedPCMLocked(
                reason: "系统内存较紧张，已为你保留这段语音，稍后可点重试",
                notice: "内存缓解后点击「重试识别」即可继续"
            )
            return
        }

        setPhaseLocked(.waitingWorkerReady)
        submitPCMToWorkerLocked(requestID: result.identity.requestID, model: model, pcm: clampedPCM)
    }

    private func submitPCMToWorkerLocked(requestID: RequestID, model: ModelDescriptor, pcm: PCMStore) {
        let promptParams = postProcessor.inferencePromptParameters(for: model.capabilities)
        let preferredLang = model.preferredLanguage != "auto" ? model.preferredLanguage : config.preferredLanguage
        let req = WorkerTranscriptionRequest(
            requestID: requestID,
            model: model,
            pcm: pcm,
            language: preferredLang,
            vocabulary: promptParams.vocabulary,
            contextPrompt: promptParams.contextPrompt
        )
        workerSupervisor.submitTranscription(req)
    }

    // MARK: - Focus Events

    private func handleFocusEventLocked(_ event: FocusEvent) {
        switch event {
        case let .axInitialized(reqID, gen, success, isSecureField):
            guard reqID == activeRequestID, var ctx = activeFocusContext, ctx.focusGeneration == gen else {
                return
            }
            ctx.axInitialized = success
            ctx.isSecureTextField = isSecureField
            activeFocusContext = ctx

        case .focusInvalidated:
            // If we are in AwaitingPreCommitReadiness (before insertion/clipboard write!), bail immediately to RecoveryPanel.
            if phase == .awaitingPreCommitReadiness, let text = preCommitText {
                cancelPreCommitTimersLocked()
                focusMonitor.stopMonitoring(requestID: activeRequestID)
                enterRecoveryWithTextLocked(
                    text: text,
                    reason: "刚刚切换了窗口，文字已为你安全保留",
                    keepRetainedPCM: false
                )
            }
        }
    }

    // MARK: - Worker Events

    private func handleWorkerEventLocked(_ event: WorkerSupervisorEvent) {
        switch event {
        case let .stateChanged(newWorkerState, footprint):
            workerState = newWorkerState
            workerFootprintBytes = footprint
            publishStateLocked()

        case let .memoryPressureChanged(level):
            memoryPressure = level
            publishStateLocked()

        case let .metalShaderCompilationLikely(compiling):
            isCompilingMetalShaders = compiling
            publishStateLocked()

        case let .transcriptionStarted(identity):
            guard identity.requestID == activeRequestID, phase == .waitingWorkerReady else {
                return
            }
            activeInferenceIdentity = identity
            setPhaseLocked(.transcribing)

        case let .transcriptionSucceeded(identity, payload):
            // 3-key strict validation: (requestID, workerGeneration, attemptID) AND phase == .transcribing
            guard phase == .transcribing,
                  let expected = activeInferenceIdentity,
                  expected == identity,
                  identity.requestID == activeRequestID
            else {
                return
            }
            activeInferenceIdentity = nil

            let aliasedText = postProcessor.applyAliases(to: payload.text)
            guard !aliasedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty result -> free PCM immediately, return to Idle
                retainedPCM = nil
                retainedModelForRetry = nil
                focusMonitor.stopMonitoring(requestID: identity.requestID)
                transitionToIdleLocked()
                return
            }
            // Trim horizontal spaces only so newline/CR characters are preserved for strict terminal safety validation.
            let processedText = aliasedText.trimmingCharacters(in: .whitespaces)

            // Audio interruption or dropped frames MUST route to RecoveryPanel (Section 5.2).
            if activeAudioInterrupted || activeDroppedFrames > 0 || activeFocusContext == nil {
                focusMonitor.stopMonitoring(requestID: identity.requestID)
                let reason = activeAudioInterrupted || activeDroppedFrames > 0
                    ? "刚刚收音略有中断，请确认识别结果"
                    : "重新识别完成，可以插入或复制文字"
                enterRecoveryWithTextLocked(text: processedText, reason: reason, keepRetainedPCM: false)
                return
            }

            beginValidatingAndPreCommitLocked(requestID: identity.requestID, text: processedText)

        case let .transcriptionCancelled(identity, _):
            // P1-6: If an active inference is cancelled externally (e.g. graceful shutdown),
            // never leave RequestCoordinator stranded in `.transcribing` or `.waitingWorkerReady`!
            if activeInferenceIdentity == identity {
                activeInferenceIdentity = nil
                if phase == .transcribing || phase == .waitingWorkerReady {
                    focusMonitor.stopMonitoring(requestID: identity.requestID)
                    if retainedPCM != nil {
                        enterRecoveryWithRetainedPCMLocked(
                            reason: "本次识别已暂停，已为你保留这段语音",
                            notice: "可点击「重试识别」继续"
                        )
                    } else {
                        transitionToIdleLocked()
                    }
                    return
                }
            }
            publishStateLocked()

        case let .transcriptionFailed(identity, message, isCriticalAbort):
            if let identity, identity.requestID != activeRequestID {
                return
            }
            guard phase == .waitingWorkerReady || phase == .transcribing else {
                return
            }
            activeInferenceIdentity = nil
            focusMonitor.stopMonitoring(requestID: activeRequestID)

            if retainedPCM != nil {
                let reason = isCriticalAbort
                    ? "系统内存较紧张，已为你保留这段语音，稍后可点重试"
                    : "本次识别未完成，已为你保留语音，可以点重试"
                enterRecoveryWithRetainedPCMLocked(reason: reason, notice: isCriticalAbort ? nil : message)
            } else {
                lastErrorMessage = message
                transitionToIdleLocked()
            }

        case let .criticalMemoryInterruptedActiveJob(reqID):
            guard reqID == activeRequestID else { return }
            guard phase == .waitingWorkerReady || phase == .transcribing else { return }
            activeInferenceIdentity = nil
            focusMonitor.stopMonitoring(requestID: reqID)
            if retainedPCM != nil {
                enterRecoveryWithRetainedPCMLocked(
                    reason: "系统内存较紧张，已为你保留这段语音，稍后可点重试",
                    notice: "内存缓解后点击「重试识别」即可继续"
                )
            } else {
                transitionToIdleLocked()
            }
        }
    }

    // MARK: - Validating -> AwaitingPreCommitReadiness -> Direct Insertion or Clipboard Compatibility Commit

    private func isTerminalUnsafeLocked(text: String, bundleIdentifier: String?) -> Bool {
        if config.inputMode == .directTyping {
            return directInjector.isTerminalApplication(bundleIdentifier: bundleIdentifier) &&
                !directInjector.isTextSafeForTerminal(text)
        } else {
            return clipboardInjector.isTerminalApplication(bundleIdentifier: bundleIdentifier) &&
                !clipboardInjector.isTextSafeForTerminal(text)
        }
    }

    private func beginValidatingAndPreCommitLocked(requestID: RequestID, text: String) {
        setPhaseLocked(.validating)

        guard let focus = activeFocusContext else {
            enterRecoveryWithTextLocked(text: text, reason: "未找到原来的输入窗口，文字已为你安全保留", keepRetainedPCM: false)
            return
        }

        // Pre-check focus, secure input, and terminal safety BEFORE touching insertion/clipboard!
        if focusMonitor.currentFocusGeneration != focus.focusGeneration ||
            !focusMonitor.isFrontmostMatching(pid: focus.pid, launchDate: focus.launchDate) {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: "刚刚切换了窗口，文字已为你安全保留", keepRetainedPCM: false)
            return
        }
        if !focus.axInitialized {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: "当前窗口暂不支持自动输入，文字已为你安全保留", keepRetainedPCM: false)
            return
        }
        if permissionManager.isSecureEventInputEnabled() ||
            focus.isSecureTextField ||
            focusMonitor.isCurrentFocusedElementSecureTextField() {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: "当前是密码输入框，为保护隐私已暂停自动输入", keepRetainedPCM: false)
            return
        }
        if isTerminalUnsafeLocked(text: text, bundleIdentifier: focus.bundleIdentifier) {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(
                text: text,
                reason: InjectionBlockReason.terminalUnsafeCharacters.userMessage,
                keepRetainedPCM: false
            )
            return
        }

        // Enter AwaitingPreCommitReadiness (100% async, strictly BEFORE typing or writing clipboard!).
        setPhaseLocked(.awaitingPreCommitReadiness)
        preCommitRequestID = requestID
        preCommitText = text
        // Direct typing mode NEVER touches or waits on clipboard!
        preCommitClipboardReady = (config.inputMode == .directTyping) || (clipboardInjector.readiness == .idle)
        preCommitHIDReady = areHIDAndKeyDebtClearLocked()

        if preCommitClipboardReady && preCommitHIDReady {
            proceedAfterPreCommitReadinessLocked(requestID: requestID, text: text)
            return
        }

        // In clipboard compatibility mode only: wait asynchronously for prior clipboard restore -> Idle.
        if !preCommitClipboardReady {
            clipboardInjector.whenIdle { [weak self] in
                guard let self else { return }
                self.coordinatorQueue.async {
                    guard self.phase == .awaitingPreCommitReadiness,
                          self.preCommitRequestID == requestID,
                          let pendingText = self.preCommitText
                    else { return }
                    self.preCommitClipboardReady = true
                    // Re-check HID modifiers & key debt LIVE when clipboard becomes idle
                    // in case user pressed a modifier while waiting on clipboard restore.
                    if self.areHIDAndKeyDebtClearLocked() {
                        self.preCommitHIDReady = true
                        self.proceedAfterPreCommitReadinessLocked(requestID: requestID, text: pendingText)
                    } else {
                        self.preCommitHIDReady = false
                        if self.preCommitPollTimer == nil {
                            self.armPreCommitHIDWaitLocked(requestID: requestID)
                        }
                    }
                }
            }
        }

        // Poll HID modifiers & key debt asynchronously up to 500 ms (never blocks coordinator queue!).
        if !preCommitHIDReady {
            armPreCommitHIDWaitLocked(requestID: requestID)
        }
    }

    private func areHIDAndKeyDebtClearLocked() -> Bool {
        hotkeyController.areHIDModifiersClear() && !triggerKeyDebtActive.load(ordering: .acquire)
    }

    private func armPreCommitHIDWaitLocked(requestID: RequestID) {
        cancelPreCommitTimersLocked()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.phase == .awaitingPreCommitReadiness,
                  self.preCommitRequestID == requestID,
                  let text = self.preCommitText
            else { return }
            self.cancelPreCommitTimersLocked()
            self.focusMonitor.stopMonitoring(requestID: requestID)
            self.enterRecoveryWithTextLocked(
                text: text,
                reason: "按键尚未松开，文字已为你保留在这里",
                keepRetainedPCM: false
            )
        }
        preCommitTimeoutTimer = timeout
        coordinatorQueue.asyncAfter(deadline: .now() + .milliseconds(timings.preCommitHIDWaitMaxMs), execute: timeout)

        scheduleNextHIDPollLocked(requestID: requestID)
    }

    private func scheduleNextHIDPollLocked(requestID: RequestID) {
        let poll = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.phase == .awaitingPreCommitReadiness,
                  self.preCommitRequestID == requestID,
                  let text = self.preCommitText
            else { return }

            if self.areHIDAndKeyDebtClearLocked() {
                self.preCommitHIDReady = true
                self.cancelPreCommitTimersLocked()
                if self.preCommitClipboardReady {
                    self.proceedAfterPreCommitReadinessLocked(requestID: requestID, text: text)
                }
            } else {
                self.scheduleNextHIDPollLocked(requestID: requestID)
            }
        }
        preCommitPollTimer = poll
        coordinatorQueue.asyncAfter(deadline: .now() + .milliseconds(timings.preCommitHIDPollIntervalMs), execute: poll)
    }

    private func proceedAfterPreCommitReadinessLocked(requestID: RequestID, text: String) {
        if config.inputMode == .directTyping {
            proceedToDirectInsertionLocked(requestID: requestID, text: text)
        } else {
            proceedToPreparingInjectionLocked(requestID: requestID, text: text)
        }
    }

    /// Direct natural text insertion commit arbiter (DEFAULT mode — ZERO clipboard touch!).
    private func proceedToDirectInsertionLocked(requestID: RequestID, text: String) {
        cancelPreCommitTimersLocked()
        preCommitText = nil
        guard let focus = activeFocusContext else {
            enterRecoveryWithTextLocked(text: text, reason: "未找到原来的输入窗口，文字已为你安全保留", keepRetainedPCM: false)
            return
        }

        setPhaseLocked(.revalidating)

        // Synchronous commit arbiter verifying ALL direct-typing safety invariants before typing a single character.
        if let failReason = evaluateCoreCommitInvariantsLocked(requestID: requestID, text: text, focus: focus) {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: failReason, keepRetainedPCM: false)
            return
        }

        // All invariants satisfied -> CommitStarted (keep focusMonitor active during streaming so mid-stream switches abort!).
        setPhaseLocked(.commitStarted)

        let monitor = focusMonitor
        directInjector.insertTextDirectly(
            text,
            targetPID: focus.pid,
            targetBundleIdentifier: focus.bundleIdentifier,
            expectedFocusGeneration: focus.focusGeneration,
            currentFocusGeneration: { monitor.currentFocusGeneration }
        ) { [weak self] outcome in
            guard let self else { return }
            self.coordinatorQueue.async {
                self.focusMonitor.stopMonitoring(requestID: requestID)
                guard self.activeRequestID == requestID && self.phase == .commitStarted else {
                    return
                }
                // Free PCM immediately now that transcription result has been delivered or handed to RecoveryPanel.
                self.retainedPCM = nil
                self.retainedModelForRetry = nil
                self.pcmRetentionTimer?.cancel()
                self.pcmRetentionTimer = nil

                switch outcome {
                case .inserted:
                    self.recordLastCommittedTextLocked(text)
                    self.transitionToIdleLocked()
                case let .partiallyInserted(remainingText, reason):
                    let kept = remainingText.isEmpty ? text : remainingText
                    self.enterRecoveryWithTextLocked(text: kept, reason: reason, keepRetainedPCM: false)
                case let .blocked(blockReason):
                    self.enterRecoveryWithTextLocked(text: text, reason: blockReason.userMessage, keepRetainedPCM: false)
                }
            }
        }
    }

    private func proceedToPreparingInjectionLocked(requestID: RequestID, text: String) {
        cancelPreCommitTimersLocked()
        preCommitText = nil
        guard let focus = activeFocusContext else {
            enterRecoveryWithTextLocked(text: text, reason: "未找到原来的输入窗口，文字已为你安全保留", keepRetainedPCM: false)
            return
        }

        // Re-check focus right before touching clipboard.
        if focusMonitor.currentFocusGeneration != focus.focusGeneration ||
            !focusMonitor.isFrontmostMatching(pid: focus.pid, launchDate: focus.launchDate) {
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: "刚刚切换了窗口，文字已为你安全保留", keepRetainedPCM: false)
            return
        }

        setPhaseLocked(.preparingInjection)
        clipboardInjector.preparePaste(text: text, targetBundleIdentifier: focus.bundleIdentifier) { [weak self] prepResult in
            guard let self else { return }
            self.coordinatorQueue.async {
                self.handlePreparationCompletedLocked(
                    requestID: requestID,
                    text: text,
                    focus: focus,
                    result: prepResult
                )
            }
        }
    }

    /// Single Synchronous 6-Invariant Commit Arbiter for Clipboard Compatibility Mode (Section 8.3).
    private func handlePreparationCompletedLocked(
        requestID: RequestID,
        text: String,
        focus: FocusContext,
        result: InjectionPreparationResult
    ) {
        // Invariant 1 check if cancelled while preparing
        guard requestID == activeRequestID && phase == .preparingInjection else {
            if case let .ready(prep) = result {
                clipboardInjector.restoreIfOwned(preparation: prep)
            }
            return
        }

        switch result {
        case let .blocked(reason):
            focusMonitor.stopMonitoring(requestID: requestID)
            enterRecoveryWithTextLocked(text: text, reason: reason.userMessage, keepRetainedPCM: false)

        case let .ready(preparation):
            setPhaseLocked(.revalidating)

            // Synchronous verification of ALL 6 invariants on `coordinatorQueue`:
            let failReason = evaluateSixCommitInvariantsLocked(
                requestID: requestID,
                text: text,
                focus: focus,
                preparation: preparation
            )

            if let failReason {
                // Immediately restore clipboard if we still own changeCount, then route to RecoveryPanel!
                clipboardInjector.restoreIfOwned(preparation: preparation)
                focusMonitor.stopMonitoring(requestID: requestID)
                enterRecoveryWithTextLocked(text: text, reason: failReason, keepRetainedPCM: false)
                return
            }

            // All 6 invariants satisfied -> CommitStarted (point of no return).
            setPhaseLocked(.commitStarted)

            // Privacy guarantee: immediately free PCM on commit start!
            retainedPCM = nil
            retainedModelForRetry = nil
            pcmRetentionTimer?.cancel()
            pcmRetentionTimer = nil

            // P1-1: Keep focusMonitor running THROUGH dispatchSyntheticPaste and verify synchronously
            // on clipboardQueue right before posting Cmd+V!
            let prePostGuard: @Sendable () -> Bool = { [focusMonitor, permissionManager] in
                focusMonitor.currentFocusGeneration == focus.focusGeneration &&
                focusMonitor.isFrontmostMatching(pid: focus.pid, launchDate: focus.launchDate) &&
                !permissionManager.isSecureEventInputEnabled() &&
                !focusMonitor.isCurrentFocusedElementSecureTextField()
            }

            let restoreDelay = config.pasteRestoreDelayMs
            clipboardInjector.dispatchSyntheticPaste(
                preparation: preparation,
                restoreDelayMs: restoreDelay,
                prePostGuard: prePostGuard
            ) { [weak self] dispatched in
                guard let self else { return }
                self.coordinatorQueue.async {
                    self.focusMonitor.stopMonitoring(requestID: requestID)
                    if !dispatched {
                        self.enterRecoveryWithTextLocked(
                            text: text,
                            reason: InjectionBlockReason.eventPostFailed.userMessage,
                            keepRetainedPCM: false
                        )
                    } else if self.activeRequestID == requestID && self.phase == .commitStarted {
                        self.recordLastCommittedTextLocked(text)
                        self.transitionToIdleLocked()
                    }
                }
            }
        }
    }

    /// Core 5 safety invariants shared by BOTH Direct Typing and Clipboard Compatibility modes.
    private func evaluateCoreCommitInvariantsLocked(
        requestID: RequestID,
        text: String,
        focus: FocusContext
    ) -> String? {
        // 1. requestID still active & uncancelled
        guard requestID == activeRequestID && phase == .revalidating else {
            return "本次输入已取消"
        }
        // 2. focusGeneration unchanged, target pid+launchDate match, AND axInitialized == true
        guard focusMonitor.currentFocusGeneration == focus.focusGeneration,
              focusMonitor.isFrontmostMatching(pid: focus.pid, launchDate: focus.launchDate),
              focus.axInitialized
        else {
            return "刚刚切换了窗口，文字已为你安全保留"
        }
        // 3. !IsSecureEventInputEnabled() AND not AXSecureTextField
        guard !permissionManager.isSecureEventInputEnabled(),
              !focus.isSecureTextField,
              !focusMonitor.isCurrentFocusedElementSecureTextField()
        else {
            return "当前是密码输入框，为保护隐私已暂停自动输入"
        }
        // 4. Live HID modifiers (excluding CapsLock) all clear AND atomic key debt clear
        guard hotkeyController.areHIDModifiersClear(),
              !triggerKeyDebtActive.load(ordering: .acquire)
        else {
            return "按键尚未松开，文字已为你保留在这里"
        }
        // 5. Terminal safety verified
        if isTerminalUnsafeLocked(text: text, bundleIdentifier: focus.bundleIdentifier) {
            return InjectionBlockReason.terminalUnsafeCharacters.userMessage
        }
        return nil
    }

    /// Verifies all 6 Section 8.3 commit invariants synchronously for Clipboard Compatibility Mode.
    private func evaluateSixCommitInvariantsLocked(
        requestID: RequestID,
        text: String,
        focus: FocusContext,
        preparation: InjectionPreparation
    ) -> String? {
        if let coreFail = evaluateCoreCommitInvariantsLocked(requestID: requestID, text: text, focus: focus) {
            return coreFail
        }
        // 6. Pasteboard changeCount still equals what we wrote
        guard clipboardInjector.currentChangeCount() == preparation.expectedChangeCount else {
            return InjectionBlockReason.changeCountMismatch.userMessage
        }
        return nil
    }

    // MARK: - Recovery, Privacy & Cleanup Helpers

    private func enterRecoveryWithRetainedPCMLocked(reason: String, notice: String?) {
        cancelPreCommitTimersLocked()
        preCommitText = nil
        let expiry = nowProvider().addingTimeInterval(timings.failedPCMRetentionSeconds)
        recoveryPayload = RecoveryPayload(
            text: nil,
            hasRetainedAudio: retainedPCM != nil,
            reason: reason,
            notice: notice,
            expiresAt: expiry,
            canRetry: retainedPCM != nil,
            canPaste: false,
            canCopy: false
        )
        armPCMRetentionTimerLocked(seconds: timings.failedPCMRetentionSeconds)
        setPhaseLocked(.recovery)
    }

    private func enterRecoveryWithTextLocked(text: String, reason: String, keepRetainedPCM: Bool) {
        cancelPreCommitTimersLocked()
        preCommitText = nil
        if !keepRetainedPCM {
            retainedPCM = nil
            retainedModelForRetry = nil
            pcmRetentionTimer?.cancel()
            pcmRetentionTimer = nil
        }
        let expiry = nowProvider().addingTimeInterval(timings.recoveryTextRetentionSeconds)
        recoveryPayload = RecoveryPayload(
            text: text,
            hasRetainedAudio: retainedPCM != nil,
            reason: reason,
            notice: nil,
            expiresAt: expiry,
            canRetry: retainedPCM != nil,
            canPaste: true,
            canCopy: true
        )
        armRecoveryTextRetentionTimerLocked(seconds: timings.recoveryTextRetentionSeconds)
        setPhaseLocked(.recovery)
    }

    private func updateRecoveryNoticeLocked(_ notice: String) {
        guard let current = recoveryPayload else { return }
        recoveryPayload = RecoveryPayload(
            id: current.id,
            text: current.text,
            hasRetainedAudio: current.hasRetainedAudio,
            reason: current.reason,
            notice: notice,
            expiresAt: current.expiresAt,
            canRetry: current.canRetry,
            canPaste: current.canPaste,
            canCopy: current.canCopy
        )
        lastNoticeMessage = notice
        publishStateLocked()
    }

    private func cancelActiveRequestLocked(notice: String?) {
        cancelPreCommitTimersLocked()
        preCommitText = nil

        if let capID = activeCaptureIdentity {
            activeCaptureIdentity = nil
            audioCapture.cancelCapture(identity: capID)
        }
        if activeInferenceIdentity != nil || phase == .waitingWorkerReady || phase == .transcribing {
            workerSupervisor.cancelTranscription(requestID: activeRequestID)
            activeInferenceIdentity = nil
        }
        if activeRequestID != 0 {
            focusMonitor.stopMonitoring(requestID: activeRequestID)
        }

        // Privacy guarantee: Esc / cancel immediately discards retained PCM & text.
        wipeAllPrivacyDataLocked()
        lastNoticeMessage = notice
        transitionToIdleLocked()
    }

    private func recordLastCommittedTextLocked(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastCommittedText = text
        lastCommittedTextTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastCommittedText = nil
            self.lastCommittedTextTimer = nil
            self.publishStateLocked()
        }
        lastCommittedTextTimer = item
        coordinatorQueue.asyncAfter(deadline: .now() + timings.recoveryTextRetentionSeconds, execute: item)
    }

    private func clearLastCommittedTextLocked() {
        lastCommittedTextTimer?.cancel()
        lastCommittedTextTimer = nil
        lastCommittedText = nil
    }

    private func wipeAllPrivacyDataLocked() {
        pcmRetentionTimer?.cancel()
        pcmRetentionTimer = nil
        recoveryTextRetentionTimer?.cancel()
        recoveryTextRetentionTimer = nil
        retainedPCM = nil
        retainedModelForRetry = nil
        recoveryPayload = nil
        preCommitText = nil
    }

    private func transitionToIdleLocked() {
        cancelPreCommitTimersLocked()
        activeCaptureIdentity = nil
        activeInferenceIdentity = nil
        activeFocusContext = nil
        activeModelForRequest = nil
        activeCaptureStartDate = nil
        activeFirstFrameReceived = false
        activeAudioLevel = 0.0

        // Section 6.1 P2-1: Arm 600ms Toggle post-timeout cooldown when returning to Idle.
        if armToggleCooldownOnIdle && config.hotkey.triggerMode == .toggle {
            armToggleCooldownOnIdle = false
            let until = nowProvider().addingTimeInterval(Double(timings.toggleCooldownMs) / 1000.0)
            toggleCooldownUntil = until
            cooldownClearTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.toggleCooldownUntil = nil
                self.publishStateLocked()
            }
            cooldownClearTimer = timer
            coordinatorQueue.asyncAfter(deadline: .now() + .milliseconds(timings.toggleCooldownMs), execute: timer)
        } else {
            armToggleCooldownOnIdle = false
        }

        setPhaseLocked(.idle)
    }

    private func isCurrentlyInToggleCooldownLocked() -> Bool {
        guard let until = toggleCooldownUntil else { return false }
        if nowProvider() < until {
            return true
        }
        toggleCooldownUntil = nil
        return false
    }

    private func armPCMRetentionTimerLocked(seconds: TimeInterval) {
        pcmRetentionTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retainedPCM = nil
            self.retainedModelForRetry = nil
            if self.phase == .recovery {
                if let current = self.recoveryPayload, let text = current.text, !text.isEmpty {
                    self.recoveryPayload = RecoveryPayload(
                        id: current.id,
                        text: text,
                        hasRetainedAudio: false,
                        reason: current.reason,
                        notice: current.notice,
                        expiresAt: current.expiresAt,
                        canRetry: false,
                        canPaste: current.canPaste,
                        canCopy: current.canCopy
                    )
                    self.publishStateLocked()
                } else {
                    self.recoveryPayload = nil
                    self.transitionToIdleLocked()
                }
            }
        }
        pcmRetentionTimer = item
        coordinatorQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func armRecoveryTextRetentionTimerLocked(seconds: TimeInterval) {
        recoveryTextRetentionTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wipeAllPrivacyDataLocked()
            if self.phase == .recovery {
                self.transitionToIdleLocked()
            }
        }
        recoveryTextRetentionTimer = item
        coordinatorQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelPreCommitTimersLocked() {
        preCommitPollTimer?.cancel()
        preCommitPollTimer = nil
        preCommitTimeoutTimer?.cancel()
        preCommitTimeoutTimer = nil
    }

    private func setPhaseLocked(_ newPhase: InteractionPhase) {
        phase = newPhase
        // Lock-free atomic update read by EventTap thread without any lock or sync query!
        shouldInterceptCancelEscape.store(newPhase.shouldInterceptCancelEscape, ordering: .release)
        publishStateLocked()
    }

    private func buildSnapshotDeltaLocked() -> CoordinatorSnapshotDelta {
        let elapsedMs: Int
        if let start = activeCaptureStartDate, (phase == .arming || phase == .recording) {
            elapsedMs = max(0, Int(nowProvider().timeIntervalSince(start) * 1000))
        } else {
            elapsedMs = 0
        }

        let overlayVisible: Bool
        let statusText: String
        switch phase {
        case .arming:
            overlayVisible = true
            statusText = "正在启动麦克风…"
        case .recording:
            overlayVisible = true
            statusText = activeFirstFrameReceived ? "正在聆听…" : "准备聆听…"
        case .draining:
            overlayVisible = true
            statusText = "正在整理语音…"
        case .waitingWorkerReady:
            overlayVisible = true
            statusText = isCompilingMetalShaders
                ? "首次启动语音引擎，稍等几秒…"
                : "正在准备语音引擎…"
        case .transcribing:
            overlayVisible = true
            statusText = "正在识别…"
        case .validating, .awaitingPreCommitReadiness, .preparingInjection, .revalidating, .commitStarted:
            overlayVisible = true
            statusText = "正在输入文字…"
        case .idle, .recovery:
            overlayVisible = false
            statusText = ""
        }

        let overlay = RecordingOverlayState(
            isVisible: overlayVisible,
            phase: phase,
            isReadyForSpeech: activeFirstFrameReceived,
            audioLevel: (phase == .recording) ? activeAudioLevel : 0,
            elapsedMs: elapsedMs,
            captureLimitMs: activeCaptureLimitMs,
            statusText: statusText,
            isCompilingMetalShaders: isCompilingMetalShaders,
            activeDeviceName: activeDeviceName,
            noticeText: lastNoticeMessage
        )

        return CoordinatorSnapshotDelta(
            phase: phase,
            workerState: workerState,
            memoryPressure: memoryPressure,
            workerFootprintBytes: workerFootprintBytes,
            isSecureInputPaused: isSecureInputPaused,
            overlay: overlay,
            recovery: recoveryPayload,
            hasLastCommittedText: (lastCommittedText != nil),
            isCoolingDown: isCurrentlyInToggleCooldownLocked(),
            lastErrorMessage: lastErrorMessage,
            lastNoticeMessage: lastNoticeMessage
        )
    }

    private func publishStateLocked() {
        let delta = buildSnapshotDeltaLocked()
        onStateChange?(delta)
    }
}
