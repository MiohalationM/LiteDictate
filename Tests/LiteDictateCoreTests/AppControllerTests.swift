import Foundation
import Testing
@testable import LiteDictateCore

// MARK: - AppController Test Doubles

private final class StubAudioDeviceManager: AudioDeviceManaging, @unchecked Sendable {
    func availableInputDevices() -> [AudioDeviceInfo] { [] }
    func resolveDevice(for mode: AudioSelectionMode) -> AudioDeviceResolution { AudioDeviceResolution(device: nil) }
    func startObservingChanges(_ onChange: @escaping @Sendable ([AudioDeviceInfo]) -> Void) {}
    func stopObservingChanges() {}
}

private final class StubAudioCapture: AudioCapturing, @unchecked Sendable {
    func startCapture(identity: CaptureIdentity, parameters: AudioCaptureParameters, onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) {}
    func stopCapture(identity: CaptureIdentity) {}
    func cancelCapture(identity: CaptureIdentity) {}
    func currentMeterLevel() -> Float { 0 }
}

private final class StubHotkeyController: HotkeyControlling, @unchecked Sendable {
    private let lock = NSLock()
    var tapAlive: Bool = false
    var canStartTap: Bool = false
    var startCallCount: Int = 0
    var stopCallCount: Int = 0
    var temporarilySuspended: Bool = false

    var isTapAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return tapAlive
    }

    func setCanStartTap(_ allowed: Bool) {
        lock.lock()
        canStartTap = allowed
        lock.unlock()
    }

    func start(
        binding: HotkeyBinding,
        disabledBundleIDs: Set<String>,
        shouldInterceptCancelEscape: AtomicBool,
        triggerKeyDebtActive: AtomicBool,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void
    ) -> Bool {
        lock.lock()
        startCallCount += 1
        let ok = canStartTap
        tapAlive = ok
        lock.unlock()
        return ok
    }

    func stop() {
        lock.lock()
        stopCallCount += 1
        tapAlive = false
        lock.unlock()
    }

    func updateBinding(_ binding: HotkeyBinding) {}
    func updateDisabledBundleIDs(_ bundleIDs: Set<String>) {}
    func setTemporarilySuspended(_ suspended: Bool) {
        lock.lock()
        temporarilySuspended = suspended
        lock.unlock()
    }
    func areHIDModifiersClear() -> Bool { true }
    func currentHIDModifierMask() -> HotkeyModifierMask { [] }
}

private final class StubPermissionManager: PermissionManaging, @unchecked Sendable {
    private let lock = NSLock()
    var microphone: AuthorizationState = .notDetermined
    var listenEventAccess: Bool = false
    var postEventAccess: Bool = false
    var accessibilityTrusted: Bool = false
    var secureInputEnabled: Bool = false

    var micPromptCount: Int = 0
    var axPromptCount: Int = 0
    var listenRequestCount: Int = 0
    var postRequestCount: Int = 0
    var micGrantOnPrompt: Bool = false

    func snapshot(eventTapAlive: Bool) -> PermissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PermissionSnapshot(
            microphone: microphone,
            listenEventAccess: listenEventAccess,
            postEventAccess: postEventAccess,
            accessibilityTrusted: accessibilityTrusted,
            pasteboardAccess: .standard,
            eventTapAlive: eventTapAlive,
            secureInputEnabled: secureInputEnabled
        )
    }

    func isSecureEventInputEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return secureInputEnabled
    }

    func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        micPromptCount += 1
        let granted = micGrantOnPrompt
        microphone = granted ? .granted : .denied
        lock.unlock()
        completion(granted)
    }

    func requestAccessibilityPrompt() {
        lock.lock()
        axPromptCount += 1
        lock.unlock()
    }

    @discardableResult
    func requestListenEventAccess() -> Bool {
        lock.lock()
        listenRequestCount += 1
        let val = listenEventAccess
        lock.unlock()
        return val
    }

    @discardableResult
    func requestPostEventAccess() -> Bool {
        lock.lock()
        postRequestCount += 1
        let val = postEventAccess
        lock.unlock()
        return val
    }

    func grantInputMonitoringAndAccessibility() {
        lock.lock()
        listenEventAccess = true
        accessibilityTrusted = true
        postEventAccess = true
        microphone = .granted
        lock.unlock()
    }

    func settingsURL(for pane: SystemSettingsPane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }
}

private final class StubFocusMonitor: FocusMonitoring, @unchecked Sendable {
    let focusGenerationCounter = AtomicUInt64(1)
    var currentFocusGeneration: UInt64 { focusGenerationCounter.load() }
    func captureInitialFocus() -> FocusContext {
        FocusContext(pid: 100, launchDate: nil, bundleIdentifier: "com.apple.TextEdit", focusGeneration: 1)
    }
    func beginMonitoring(requestID: RequestID, initialContext: FocusContext, onEvent: @escaping @Sendable (FocusEvent) -> Void) {}
    func stopMonitoring(requestID: RequestID) {}
    func isFrontmostMatching(pid: pid_t, launchDate: Date?) -> Bool { true }
    func isCurrentFocusedElementSecureTextField() -> Bool { false }
    func frontmostPID() -> pid_t? { 100 }
    func frontmostBundleIdentifier() -> String? { "com.apple.TextEdit" }
}

private final class StubDirectTextInjector: DirectTextInjecting, @unchecked Sendable {
    func isTerminalApplication(bundleIdentifier: String?) -> Bool { false }
    func isTextSafeForTerminal(_ text: String) -> Bool { true }
    func insertTextDirectly(
        _ text: String,
        targetPID: pid_t,
        targetBundleIdentifier: String?,
        expectedFocusGeneration: UInt64,
        currentFocusGeneration: @escaping @Sendable () -> UInt64,
        completion: @escaping @Sendable (DirectInjectionOutcome) -> Void
    ) {
        completion(.inserted(method: .verifiedAccessibility))
    }
}

private final class StubClipboardInjector: ClipboardInjecting, @unchecked Sendable {
    var readiness: ClipboardReadiness { .idle }
    func whenIdle(_ callback: @escaping @Sendable () -> Void) { callback() }
    func isTerminalApplication(bundleIdentifier: String?) -> Bool { false }
    func isTextSafeForTerminal(_ text: String) -> Bool { true }
    func preparePaste(text: String, targetBundleIdentifier: String?, completion: @escaping @Sendable (InjectionPreparationResult) -> Void) {
        completion(.ready(InjectionPreparation(transactionID: 1, expectedChangeCount: 1, hadSnapshot: false)))
    }
    func currentChangeCount() -> Int { 1 }
    func dispatchSyntheticPaste(
        preparation: InjectionPreparation,
        restoreDelayMs: Int,
        prePostGuard: (@Sendable () -> Bool)?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        completion(prePostGuard?() ?? true)
    }
    func restoreIfOwned(preparation: InjectionPreparation) {}
    func copyTextForUser(_ text: String) {}
}

private final class StubWorkerSupervisor: WorkerSupervising, ModelProbing, @unchecked Sendable {
    var currentState: WorkerLifecycleState { .stopped }
    var currentMemoryPressure: MemoryPressureLevel { .normal }
    var currentFootprintBytes: UInt64 { 0 }
    var probeHandler: @Sendable (String) -> Result<LDPProbeResultPayload, ModelProbeError> = { path in
        .success(LDPProbeResultPayload(
            modelPath: path,
            roles: ["asr"],
            arch: "qwen3_asr",
            variant: "0.6b",
            nativeSampleRate: 16_000,
            maxAudioMs: 30_000,
            supportsVocabulary: true
        ))
    }

    func setEventHandler(_ handler: @escaping @Sendable (WorkerSupervisorEvent) -> Void) {}
    func prepareWarmupIfAllowed(model: ModelDescriptor) {}
    func submitTranscription(_ request: WorkerTranscriptionRequest) {}
    func cancelTranscription(requestID: RequestID) {}
    func requestModelSwitch(to model: ModelDescriptor?) {}
    func shutdownGracefully(reason: String) {}
    func forceShutdownImmediately() {}

    func probeModel(at path: String, completion: @escaping @Sendable (Result<LDPProbeResultPayload, ModelProbeError>) -> Void) {
        completion(probeHandler(path))
    }
}

private final class StubLaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    private let lock = NSLock()
    var state: LaunchAtLoginState = .notRegistered
    var simulateRequiresApprovalOnEnable: Bool = false
    var openLoginItemsCount: Int = 0

    func currentState() -> LaunchAtLoginState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        if enabled {
            state = simulateRequiresApprovalOnEnable ? .requiresApproval : .enabled
        } else {
            state = .notRegistered
        }
        lock.unlock()
    }

    func openLoginItemsSettings() {
        lock.lock()
        openLoginItemsCount += 1
        lock.unlock()
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    func clear() {
        lock.lock()
        urls.removeAll()
        lock.unlock()
    }
}

@Suite("AppController Active Permission Pulling & Startup Auto-Registration")
struct AppControllerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-appctrl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Active permission commands invoke native TCC probes, fall back to System Settings, and restart EventTap on grant")
    func testActivePermissionPullingAndTapRecovery() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = await MainActor.run { AppStateStore() }
        let hotkey = StubHotkeyController()
        let perms = StubPermissionManager()
        let worker = StubWorkerSupervisor()
        let openedURLs = URLCollector()
        let relaunchTriggered = AtomicBool(false)

        let controller = AppController(
            appSupportDirectory: dir,
            stateStore: store,
            audioDeviceManager: StubAudioDeviceManager(),
            audioCapture: StubAudioCapture(),
            hotkeyController: hotkey,
            permissionManager: perms,
            focusMonitor: StubFocusMonitor(),
            directInjector: StubDirectTextInjector(),
            clipboardInjector: StubClipboardInjector(),
            workerSupervisor: worker,
            modelProber: worker,
            modelRegistry: ModelRegistry(appSupportDirectory: dir, discoveryDirectories: []),
            openURLHandler: { openedURLs.append($0) },
            relaunchHandler: { relaunchTriggered.store(true, ordering: .release) },
            settingsFallbackDelay: 0.02
        )
        controller.start()
        try? await Task.sleep(for: .milliseconds(30))

        // While permissions are missing, 1.0s polling timer is active.
        #expect(controller.isPermissionPollingActive == true)

        // 1. Input Monitoring actively calls requestListenEventAccess() AND falls back to .inputMonitoring Settings
        controller.dispatch(.requestInputMonitoringPermission)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(perms.listenRequestCount == 1)
        #expect(openedURLs.snapshot().contains(perms.settingsURL(for: .inputMonitoring)))

        // 2. Post Event actively calls requestPostEventAccess() + requestAccessibilityPrompt() AND falls back to .accessibility
        openedURLs.clear()
        controller.dispatch(.requestPostEventPermission)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(perms.postRequestCount == 1)
        #expect(perms.axPromptCount == 1)
        #expect(openedURLs.snapshot().contains(perms.settingsURL(for: .accessibility)))

        // 3. Accessibility actively calls requestAccessibilityPrompt() AND falls back to .accessibility
        openedURLs.clear()
        controller.dispatch(.requestAccessibilityPermission)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(perms.axPromptCount == 2)
        #expect(openedURLs.snapshot().contains(perms.settingsURL(for: .accessibility)))

        // 4. requestAllMissingPermissions invokes ALL missing probes and opens first missing Settings pane
        openedURLs.clear()
        controller.dispatch(.requestAllMissingPermissions)
        try? await Task.sleep(for: .milliseconds(160))
        #expect(perms.micPromptCount == 1)
        #expect(perms.listenRequestCount == 2)
        #expect(perms.postRequestCount == 2)
        #expect(perms.axPromptCount == 3)
        // Mic was denied on prompt, so priority opens .microphone pane first!
        #expect(openedURLs.snapshot().contains(perms.settingsURL(for: .microphone)))

        // 5. Granting permissions + refresh auto-restarts EventTap AND stops periodic polling timer (0 idle wakeups!)
        #expect(hotkey.isTapAlive == false)
        hotkey.setCanStartTap(true)
        perms.grantInputMonitoringAndAccessibility()
        controller.dispatch(.refreshPermissions)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(hotkey.isTapAlive == true)
        #expect(controller.isPermissionPollingActive == false)

        // 6. P1-13: setHotkeyRecordingActive suspends and resumes global EventTap cleanly
        controller.dispatch(.setHotkeyRecordingActive(true))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(hotkey.temporarilySuspended == true)
        controller.dispatch(.setHotkeyRecordingActive(false))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(hotkey.temporarilySuspended == false)

        // 7. Relaunch action runs cleanup + invokes relaunchHandler
        controller.dispatch(.relaunchApplication)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(relaunchTriggered.load() == true)
    }

    @Test("Startup auto-probes and activates ASR .gguf placed in modelsDirectory when models.json is empty")
    func testStartupAutoRegistersAppModelsDirectoryASR() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        let t3Dir = dir.appendingPathComponent("t3-models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: t3Dir, withIntermediateDirectories: true)

        let vadFile = modelsDir.appendingPathComponent("00-silero-vad.gguf")
        let qwenFile = modelsDir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
        let t3Symlink = t3Dir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
        try Data("vad".utf8).write(to: vadFile)
        try Data("qwen-asr".utf8).write(to: qwenFile)
        try FileManager.default.createSymbolicLink(at: t3Symlink, withDestinationURL: qwenFile)

        let worker = StubWorkerSupervisor()
        worker.probeHandler = { path in
            if path.contains("silero-vad") {
                return .failure(.unsupportedRole(roles: ["vad"], arch: "silero_vad", variant: "v6.2"))
            }
            return .success(LDPProbeResultPayload(
                modelPath: path,
                roles: ["asr"],
                arch: "qwen3_asr",
                variant: "0.6b",
                nativeSampleRate: 16_000,
                maxAudioMs: 30_000,
                supportsVocabulary: true
            ))
        }

        let store = await MainActor.run { AppStateStore() }
        let registry = ModelRegistry(appSupportDirectory: dir, discoveryDirectories: [modelsDir, t3Dir])
        let controller = AppController(
            appSupportDirectory: dir,
            stateStore: store,
            audioDeviceManager: StubAudioDeviceManager(),
            audioCapture: StubAudioCapture(),
            hotkeyController: StubHotkeyController(),
            permissionManager: StubPermissionManager(),
            focusMonitor: StubFocusMonitor(),
            directInjector: StubDirectTextInjector(),
            clipboardInjector: StubClipboardInjector(),
            workerSupervisor: worker,
            modelProber: worker,
            modelRegistry: registry,
            openURLHandler: { _ in },
            relaunchHandler: {},
            settingsFallbackDelay: 0.02
        )

        controller.start()

        for _ in 0..<40 {
            if registry.activeModel != nil { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        // Skipped non-ASR 00-silero-vad.gguf and auto-registered Qwen3-ASR-0.6B-Q8_0.gguf!
        #expect(registry.models.count == 1)
        #expect(registry.activeModel?.filePath == qwenFile.resolvingSymlinksInPath().standardizedFileURL.path)
        // Symlink in T3 folder is deduplicated cleanly (only the skipped VAD file remains unregistered, NOT Qwen symlink!)
        let remainingDiscovered = registry.discoverLocalModels()
        #expect(remainingDiscovered.allSatisfy { !$0.fileName.contains("Qwen3-ASR") })

        controller.dispatch(.prepareForQuit)
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test("Launch at Login toggle, requiresApproval fallback, language selection, and config file shortcuts")
    func testLaunchAtLoginAndQuickSettings() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = await MainActor.run { AppStateStore() }
        let worker = StubWorkerSupervisor()
        let loginManager = StubLaunchAtLoginManager()
        let openedURLs = URLCollector()

        let settingsOpened = AtomicBool(false)
        let controller = AppController(
            appSupportDirectory: dir,
            stateStore: store,
            audioDeviceManager: StubAudioDeviceManager(),
            audioCapture: StubAudioCapture(),
            hotkeyController: StubHotkeyController(),
            permissionManager: StubPermissionManager(),
            focusMonitor: StubFocusMonitor(),
            directInjector: StubDirectTextInjector(),
            clipboardInjector: StubClipboardInjector(),
            workerSupervisor: worker,
            modelProber: worker,
            modelRegistry: ModelRegistry(appSupportDirectory: dir, discoveryDirectories: []),
            launchAtLoginManager: loginManager,
            openURLHandler: { openedURLs.append($0) },
            relaunchHandler: {},
            openSettingsWindowHandler: { settingsOpened.store(true, ordering: .release) },
            settingsFallbackDelay: 0.02
        )
        controller.start()
        try? await Task.sleep(for: .milliseconds(40))

        let initialSnap = await MainActor.run { store.snapshot }
        #expect(initialSnap.launchAtLogin == .notRegistered)
        #expect(initialSnap.preferredLanguage == "auto")
        #expect(initialSnap.inputMode == .directTyping)
        #expect(initialSnap.playFeedbackSounds == true)

        // 1. Enable Launch at Login
        controller.dispatch(.setLaunchAtLogin(true))
        try? await Task.sleep(for: .milliseconds(40))
        let enabledSnap = await MainActor.run { store.snapshot }
        #expect(enabledSnap.launchAtLogin == .enabled)
        #expect(loginManager.openLoginItemsCount == 0)

        // 2. Disable Launch at Login
        controller.dispatch(.setLaunchAtLogin(false))
        try? await Task.sleep(for: .milliseconds(40))
        let disabledSnap = await MainActor.run { store.snapshot }
        #expect(disabledSnap.launchAtLogin == .notRegistered)

        // 3. `.requiresApproval` triggers openLoginItemsSettings() and user notice
        loginManager.simulateRequiresApprovalOnEnable = true
        controller.dispatch(.setLaunchAtLogin(true))
        try? await Task.sleep(for: .milliseconds(40))
        let approvalSnap = await MainActor.run { store.snapshot }
        #expect(approvalSnap.launchAtLogin == .requiresApproval)
        #expect(loginManager.openLoginItemsCount == 1)
        #expect(approvalSnap.lastNoticeMessage?.contains("登录项") == true)

        // 4. Input mode, feedback sound toggle, settings window, dictionary save & validation
        controller.dispatch(.setTextInputMode(.clipboardCompatibility))
        controller.dispatch(.setPlayFeedbackSounds(false))
        controller.dispatch(.openSettingsWindow)
        controller.dispatch(.saveVocabularyAndAliases(vocabText: "LiteDictate\nSwiftUI\n", aliasesJSON: "{\"LightDictate\":\"LiteDictate\"}"))
        controller.dispatch(.setPreferredLanguage("zh"))
        controller.dispatch(.openConfigFile(.vocab))
        controller.dispatch(.openConfigFile(.aliases))
        controller.dispatch(.openConfigFile(.appSupportFolder))
        try? await Task.sleep(for: .milliseconds(60))

        let finalSnap = await MainActor.run { store.snapshot }
        #expect(finalSnap.preferredLanguage == "zh")
        #expect(finalSnap.inputMode == .clipboardCompatibility)
        #expect(finalSnap.playFeedbackSounds == false)
        #expect(settingsOpened.load() == true)
        let savedDict = controller.loadVocabularyAndAliasesText()
        #expect(savedDict.vocabText.contains("LiteDictate"))
        #expect(savedDict.aliasesJSON.contains("LightDictate"))

        // Invalid aliases JSON surfaces friendly error without clobbering saved file
        controller.dispatch(.saveVocabularyAndAliases(vocabText: "Ignored", aliasesJSON: "{not valid json"))
        try? await Task.sleep(for: .milliseconds(40))
        let errSnap = await MainActor.run { store.snapshot }
        #expect(errSnap.lastErrorMessage?.contains("自动纠错词格式有误") == true)
        #expect(controller.loadVocabularyAndAliasesText().aliasesJSON.contains("LightDictate"))

        let opened = openedURLs.snapshot().map(\.lastPathComponent)
        #expect(opened.contains("vocab.txt"))
        #expect(opened.contains("aliases.json"))
        #expect(openedURLs.snapshot().contains(dir))

        controller.dispatch(.prepareForQuit)
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test("Legacy AppConfig JSON without inputMode/playFeedbackSounds decodes cleanly to .directTyping and true")
    func testLegacyAppConfigBackwardsCompatibility() throws {
        let legacyJSON = """
        {
          "audioSelection": { "smartAuto": {} },
          "disabledBundleIDs": [],
          "hotkey": { "keyCode": 2, "modifiers": 3, "strictLeftSideOnly": false, "triggerMode": "toggle" },
          "pasteRestoreDelayMs": 400,
          "preferredLanguage": "auto",
          "vocabPath": "/tmp/vocab.txt",
          "aliasesPath": "/tmp/aliases.json"
        }
        """
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.inputMode == .directTyping)
        #expect(decoded.playFeedbackSounds == true)
        #expect(decoded.pasteRestoreDelayMs == 400)
    }
}
