import AppKit
import Foundation

/// Top-level Core facade wiring all subsystems, config persistence, workspace sleep/lock hooks,
/// and projecting immutable `AppStateSnapshot` values to `AppStateStore`.
public final class AppController: @unchecked Sendable {
    public let stateStore: AppStateStore
    public let modelRegistry: ModelRegistry
    public let coordinator: RequestCoordinator

    private let appSupportDirectory: URL
    private let configFileURL: URL
    private let stateQueue = DispatchQueue(label: "io.github.litedictate.appcontroller", qos: .userInitiated)

    private let audioDeviceManager: AudioDeviceManaging
    private let audioCapture: AudioCapturing
    private let hotkeyController: HotkeyControlling
    private let permissionManager: PermissionManaging
    private let focusMonitor: FocusMonitoring
    private let directInjector: DirectTextInjecting
    private let clipboardInjector: ClipboardInjecting
    private let workerSupervisor: WorkerSupervising
    private let modelProber: ModelProbing
    private let launchAtLoginManager: LaunchAtLoginManaging
    private let openURLHandler: @Sendable (URL) -> Void
    private let relaunchHandler: @Sendable () -> Void
    private let openSettingsWindowHandler: (@Sendable () -> Void)?
    private let settingsFallbackDelay: TimeInterval

    private var config: AppConfig
    private var latestCoordinatorDelta: CoordinatorSnapshotDelta
    private var availableDevices: [AudioDeviceInfo] = []
    private var discoveredModels: [DiscoveredModelCandidate] = []
    private var isImportingModel: Bool = false
    private var controllerErrorMessage: String?
    private var controllerNoticeMessage: String?
    private var permissionSnapshot: PermissionSnapshot = PermissionSnapshot()
    private var launchAtLoginState: LaunchAtLoginState = .unavailable
    private var permissionRefreshTimer: DispatchSourceTimer?
    private let pollingActiveAtomic = AtomicBool(false)
    private let lifecycleObservers = MainThreadLifecycleObservers()

    /// Exposed for verification & tests: `false` in steady authorized idle state (0 periodic wakeups).
    public var isPermissionPollingActive: Bool {
        pollingActiveAtomic.load(ordering: .acquire)
    }

    @MainActor
    private final class MainThreadLifecycleObservers {
        private var workspaceObservers: [NSObjectProtocol] = []
        private var appObservers: [NSObjectProtocol] = []
        private var distributedLockObserver: NSObjectProtocol?

        nonisolated init() {}

        func install(
            onSleepOrLock: @escaping @Sendable (String) -> Void,
            onWakeOrActivate: @escaping @Sendable () -> Void
        ) {
            remove()
            let nc = NSWorkspace.shared.notificationCenter
            let willSleep = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                onSleepOrLock("system_will_sleep")
            }
            let screensSleep = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { _ in
                onSleepOrLock("screen_did_sleep")
            }
            let didWake = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                onWakeOrActivate()
            }
            let screensDidWake = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { _ in
                onWakeOrActivate()
            }
            let didActivate = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                onWakeOrActivate()
            }
            let screenLock = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: nil
            ) { _ in
                onSleepOrLock("screen_locked")
            }
            workspaceObservers = [willSleep, screensSleep, didWake, screensDidWake]
            appObservers = [didActivate]
            distributedLockObserver = screenLock
        }

        func remove() {
            let nc = NSWorkspace.shared.notificationCenter
            for o in workspaceObservers { nc.removeObserver(o) }
            workspaceObservers.removeAll()
            for o in appObservers { NotificationCenter.default.removeObserver(o) }
            appObservers.removeAll()
            if let dist = distributedLockObserver {
                DistributedNotificationCenter.default().removeObserver(dist)
                distributedLockObserver = nil
            }
        }
    }

    public init(
        appSupportDirectory: URL = AppConfig.defaultAppSupportDirectory(),
        stateStore: AppStateStore,
        audioDeviceManager: AudioDeviceManaging,
        audioCapture: AudioCapturing,
        hotkeyController: HotkeyControlling,
        permissionManager: PermissionManaging,
        focusMonitor: FocusMonitoring,
        directInjector: DirectTextInjecting,
        clipboardInjector: ClipboardInjecting,
        workerSupervisor: WorkerSupervising,
        modelProber: ModelProbing,
        modelRegistry: ModelRegistry? = nil,
        launchAtLoginManager: LaunchAtLoginManaging = LaunchAtLoginManager(),
        onCaptureReadySound: (@Sendable () -> Void)? = nil,
        onCommitSuccessSound: (@Sendable () -> Void)? = nil,
        onLimitTruncatedSound: (@Sendable () -> Void)? = nil,
        openURLHandler: (@Sendable (URL) -> Void)? = nil,
        relaunchHandler: (@Sendable () -> Void)? = nil,
        openSettingsWindowHandler: (@Sendable () -> Void)? = nil,
        settingsFallbackDelay: TimeInterval = 0.35
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.configFileURL = appSupportDirectory.appendingPathComponent("config.json")
        self.stateStore = stateStore
        self.audioDeviceManager = audioDeviceManager
        self.audioCapture = audioCapture
        self.hotkeyController = hotkeyController
        self.permissionManager = permissionManager
        self.focusMonitor = focusMonitor
        self.directInjector = directInjector
        self.clipboardInjector = clipboardInjector
        self.workerSupervisor = workerSupervisor
        self.modelProber = modelProber
        self.launchAtLoginManager = launchAtLoginManager
        self.openSettingsWindowHandler = openSettingsWindowHandler
        self.settingsFallbackDelay = max(0, settingsFallbackDelay)
        self.openURLHandler = openURLHandler ?? { url in
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        self.relaunchHandler = relaunchHandler ?? {
            Self.defaultRelaunchApplication()
        }

        let loadedConfig = Self.loadConfig(from: configFileURL, appSupportDir: appSupportDirectory)
        self.config = loadedConfig

        let registry = modelRegistry ?? ModelRegistry(appSupportDirectory: appSupportDirectory)
        self.modelRegistry = registry

        let openURL = self.openURLHandler
        self.coordinator = RequestCoordinator(
            config: loadedConfig,
            audioCapture: audioCapture,
            hotkeyController: hotkeyController,
            permissionManager: permissionManager,
            focusMonitor: focusMonitor,
            directInjector: directInjector,
            clipboardInjector: clipboardInjector,
            workerSupervisor: workerSupervisor,
            modelRegistry: registry,
            onCaptureReadySound: onCaptureReadySound,
            onCommitSuccessSound: onCommitSuccessSound,
            onLimitTruncatedSound: onLimitTruncatedSound,
            onOpenMicrophoneSettingsNeeded: {
                openURL(permissionManager.settingsURL(for: .microphone))
            }
        )
        self.latestCoordinatorDelta = self.coordinator.currentSnapshotDelta()

        self.coordinator.setStateChangeHandler { [weak self] delta in
            guard let self else { return }
            self.stateQueue.async {
                self.latestCoordinatorDelta = delta
                self.projectSnapshotLocked()
            }
        }
    }

    private static func defaultRelaunchApplication() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    deinit {
        permissionRefreshTimer?.cancel()
    }

    public func start() {
        stateQueue.async { [self] in
            ensureSupportDirectoryAndDefaultFilesLocked()
            availableDevices = audioDeviceManager.availableInputDevices()
            _ = modelRegistry.refreshFileStatuses()
            discoveredModels = modelRegistry.discoverLocalModels()

            audioDeviceManager.startObservingChanges { [weak controller = self] devices in
                guard let controller else { return }
                controller.stateQueue.async {
                    controller.availableDevices = devices
                    controller.projectSnapshotLocked()
                }
            }

            _ = hotkeyController.start(
                binding: config.hotkey,
                disabledBundleIDs: Set(config.disabledBundleIDs),
                shouldInterceptCancelEscape: coordinator.shouldInterceptCancelEscape,
                triggerKeyDebtActive: coordinator.triggerKeyDebtActive,
                onEvent: { [weak controller = self] event in
                    controller?.coordinator.handleHotkeyEvent(event)
                }
            )

            permissionSnapshot = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive)
            workerSupervisor.updateWarmTTLSeconds(config.modelIdleUnloadPolicy.ttlSeconds)
            launchAtLoginState = launchAtLoginManager.currentState()
            installWorkspaceLifecycleObservers()
            installPermissionPollingTimerLocked()
            projectSnapshotLocked()

            // If models.json has no registered models yet, automatically probe & activate the first
            // valid ASR .gguf found directly in LiteDictate's own `modelsDirectory`.
            if modelRegistry.models.isEmpty {
                let localAppModels = modelRegistry.discoverModelsInAppModelsDirectory()
                if !localAppModels.isEmpty {
                    autoRegisterFirstValidAppModelLocked(candidates: localAppModels, index: 0)
                }
            }
        }
    }

    private func autoRegisterFirstValidAppModelLocked(candidates: [DiscoveredModelCandidate], index: Int) {
        guard index < candidates.count, modelRegistry.models.isEmpty else {
            isImportingModel = false
            discoveredModels = modelRegistry.discoverLocalModels()
            projectSnapshotLocked()
            return
        }
        let candidate = candidates[index]
        isImportingModel = true
        projectSnapshotLocked()

        // Use .reference since file is already in modelsDirectory (never re-copy 850 MB or risk deleting shared symlink target).
        modelRegistry.importModel(
            from: URL(fileURLWithPath: candidate.filePath),
            storageMode: .reference,
            prober: modelProber
        ) { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                switch result {
                case let .success(descriptor):
                    self.isImportingModel = false
                    _ = self.modelRegistry.selectActiveModel(id: descriptor.id)
                    self.discoveredModels = self.modelRegistry.discoverLocalModels()
                    self.controllerErrorMessage = nil
                    self.controllerNoticeMessage = "已自动加载模型：\(descriptor.displayName)"
                    self.projectSnapshotLocked()
                case .failure:
                    self.autoRegisterFirstValidAppModelLocked(candidates: candidates, index: index + 1)
                }
            }
        }
    }

    /// Single entry point for ALL Thin AppKit UI actions.
    public func dispatch(_ command: AppActionCommand) {
        stateQueue.async {
            self.handleCommandLocked(command)
        }
    }

    private func handleCommandLocked(_ command: AppActionCommand) {
        switch command {
        case .toggleRecording:
            coordinator.toggleFromUI()

        case .cancelCurrentRequest:
            coordinator.cancelFromUI()

        case let .selectModel(id):
            controllerErrorMessage = nil
            if let selected = modelRegistry.selectActiveModel(id: id) {
                coordinator.handleModelSwitched(to: selected)
                controllerNoticeMessage = "已切换模型：\(selected.displayName)"
            }
            projectSnapshotLocked()

        case let .importModel(url, storageMode):
            guard !isImportingModel else { return }
            isImportingModel = true
            controllerErrorMessage = nil
            controllerNoticeMessage = "正在校验并导入模型…"
            projectSnapshotLocked()

            modelRegistry.importModel(from: url, storageMode: storageMode, prober: modelProber) { [weak self] result in
                guard let self else { return }
                self.stateQueue.async {
                    self.isImportingModel = false
                    switch result {
                    case let .success(descriptor):
                        _ = self.modelRegistry.selectActiveModel(id: descriptor.id)
                        self.coordinator.handleModelSwitched(to: descriptor)
                        self.discoveredModels = self.modelRegistry.discoverLocalModels()
                        self.controllerErrorMessage = nil
                        self.controllerNoticeMessage = "已导入并启用模型：\(descriptor.displayName)"
                    case let .failure(err):
                        self.controllerErrorMessage = err.userMessage
                        self.controllerNoticeMessage = nil
                    }
                    self.projectSnapshotLocked()
                }
            }

        case let .relinkModel(id, newURL):
            guard !isImportingModel else { return }
            isImportingModel = true
            controllerErrorMessage = nil
            controllerNoticeMessage = "正在重新定位并校验模型…"
            projectSnapshotLocked()

            modelRegistry.relinkModel(id: id, newURL: newURL, prober: modelProber) { [weak self] result in
                guard let self else { return }
                self.stateQueue.async {
                    self.isImportingModel = false
                    switch result {
                    case let .success(descriptor):
                        self.controllerErrorMessage = nil
                        self.controllerNoticeMessage = "模型已重新定位：\(descriptor.displayName)"
                        if self.modelRegistry.activeModelID == descriptor.id {
                            self.coordinator.handleModelSwitched(to: descriptor)
                        }
                    case let .failure(err):
                        self.controllerErrorMessage = err.userMessage
                        self.controllerNoticeMessage = nil
                    }
                    self.projectSnapshotLocked()
                }
            }

        case let .removeModel(id):
            let wasActive = (modelRegistry.activeModelID == id)
            if modelRegistry.removeModel(id: id) {
                discoveredModels = modelRegistry.discoverLocalModels()
                if wasActive {
                    coordinator.handleModelSwitched(to: modelRegistry.activeModel)
                }
                controllerNoticeMessage = "已移除模型"
            }
            projectSnapshotLocked()

        case .rescanDiscoveredModels:
            _ = modelRegistry.refreshFileStatuses()
            discoveredModels = modelRegistry.discoverLocalModels()
            projectSnapshotLocked()

        case let .setAudioSelection(mode):
            config.audioSelection = mode
            saveConfigLocked()
            coordinator.updateConfig(config)
            let resolution = audioDeviceManager.resolveDevice(for: mode)
            if resolution.isBluetoothHFPWarning {
                controllerNoticeMessage = "提示：使用蓝牙耳机麦克风时，系统可能会切到通话模式，影响音乐音质并稍有延迟"
            } else if let fallback = resolution.fallbackNotice {
                controllerNoticeMessage = fallback
            } else {
                controllerNoticeMessage = nil
            }
            projectSnapshotLocked()

        case let .setTriggerMode(mode):
            config.hotkey.triggerMode = mode
            saveConfigLocked()
            hotkeyController.updateBinding(config.hotkey)
            coordinator.updateConfig(config)
            projectSnapshotLocked()

        case let .setHotkeyBinding(binding):
            config.hotkey = binding
            saveConfigLocked()
            hotkeyController.updateBinding(binding)
            coordinator.updateConfig(config)
            projectSnapshotLocked()

        case let .setHotkeyRecordingActive(active):
            // P1-13: Suspend global EventTap while Preferences is recording a new shortcut.
            hotkeyController.setTemporarilySuspended(active)

        case .copyLastCommittedText:
            coordinator.copyLastCommittedText()

        case let .copyHistoryItem(id):
            coordinator.copyHistoryItem(id: id)

        case .clearRecentHistory:
            coordinator.clearRecentHistory()

        case let .setPreferredLanguage(lang):
            config.preferredLanguage = lang
            saveConfigLocked()
            coordinator.updateConfig(config)
            projectSnapshotLocked()

        case let .setTextInputMode(mode):
            config.inputMode = mode
            saveConfigLocked()
            coordinator.updateConfig(config)
            controllerNoticeMessage = (mode == .directTyping)
                ? "已切换为直接输入文字（不占用剪贴板）"
                : "已切换为剪贴板兼容模式"
            projectSnapshotLocked()

        case let .setPlayFeedbackSounds(enabled):
            config.playFeedbackSounds = enabled
            saveConfigLocked()
            coordinator.updateConfig(config)
            projectSnapshotLocked()

        case let .setModelIdleUnloadPolicy(policy):
            config.modelIdleUnloadPolicy = policy
            saveConfigLocked()
            workerSupervisor.updateWarmTTLSeconds(policy.ttlSeconds)
            coordinator.updateConfig(config)
            controllerNoticeMessage = "空闲模型释放已设为：\(policy.displayTitle)"
            projectSnapshotLocked()

        case let .setPasteRestoreDelayMs(delay):
            let clamped = min(
                LiteDictateConstants.maxPasteRestoreDelayMs,
                max(LiteDictateConstants.minPasteRestoreDelayMs, delay)
            )
            config.pasteRestoreDelayMs = clamped
            saveConfigLocked()
            coordinator.updateConfig(config)
            projectSnapshotLocked()

        case let .setLaunchAtLogin(enabled):
            controllerErrorMessage = nil
            do {
                try launchAtLoginManager.setEnabled(enabled)
                launchAtLoginState = launchAtLoginManager.currentState()
                if launchAtLoginState == .requiresApproval {
                    controllerNoticeMessage = "开机自动启动需在「系统设置 → 通用 → 登录项」中批准言落"
                    launchAtLoginManager.openLoginItemsSettings()
                } else if enabled && launchAtLoginState == .enabled {
                    controllerNoticeMessage = "已开启开机自动启动"
                } else if !enabled {
                    controllerNoticeMessage = "已关闭开机自动启动"
                }
            } catch {
                launchAtLoginState = launchAtLoginManager.currentState()
                if launchAtLoginState == .requiresApproval {
                    controllerNoticeMessage = "开机自动启动需在「系统设置 → 通用 → 登录项」中批准言落"
                    launchAtLoginManager.openLoginItemsSettings()
                } else {
                    controllerErrorMessage = "切换开机自动启动失败：\(error.localizedDescription)"
                }
            }
            projectSnapshotLocked()

        case .openLoginItemsSettings:
            launchAtLoginManager.openLoginItemsSettings()

        case .openSettingsWindow:
            if let handler = openSettingsWindowHandler {
                DispatchQueue.main.async {
                    handler()
                }
            }

        case let .openConfigFile(target):
            ensureSupportDirectoryAndDefaultFilesLocked()
            let targetURL: URL
            switch target {
            case .vocab:
                targetURL = URL(fileURLWithPath: config.vocabPath)
            case .aliases:
                targetURL = URL(fileURLWithPath: config.aliasesPath)
            case .appSupportFolder:
                targetURL = appSupportDirectory
            }
            openURLHandler(targetURL)

        case let .saveVocabularyAndAliases(vocabText, aliasesJSON):
            ensureSupportDirectoryAndDefaultFilesLocked()
            let trimmedAliases = aliasesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedAliases = trimmedAliases.isEmpty ? "{}\n" : aliasesJSON
            guard let aliasData = normalizedAliases.data(using: .utf8),
                  ((try? JSONDecoder().decode([String: String].self, from: aliasData)) != nil ||
                   (try? JSONDecoder().decode([AliasRule].self, from: aliasData)) != nil)
            else {
                controllerErrorMessage = "自动纠错词格式有误，请按 {\"错别字\": \"正确词\"} 填写"
                controllerNoticeMessage = nil
                projectSnapshotLocked()
                return
            }
            do {
                try vocabText.write(toFile: config.vocabPath, atomically: true, encoding: .utf8)
                try normalizedAliases.write(toFile: config.aliasesPath, atomically: true, encoding: .utf8)
                coordinator.updateConfig(config)
                controllerErrorMessage = nil
                controllerNoticeMessage = "词库已保存并立即生效"
            } catch {
                controllerErrorMessage = "保存词库失败：\(error.localizedDescription)"
            }
            projectSnapshotLocked()

        case .recoveryCopy:
            coordinator.recoveryCopy()

        case .recoveryPasteToFrontmost:
            coordinator.recoveryPasteToFrontmost()

        case .recoveryRetry:
            coordinator.recoveryRetry()

        case .recoveryDiscard:
            coordinator.recoveryDiscard()

        case .refreshPermissions:
            refreshPermissionsAndRestartTapIfNeededLocked()

        case .requestMicrophonePermission:
            let snap = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive)
            if snap.microphone == .notDetermined {
                permissionManager.requestMicrophoneAccess { [weak self] granted in
                    guard let self else { return }
                    self.stateQueue.async {
                        self.refreshPermissionsAndRestartTapIfNeededLocked()
                        if !granted {
                            self.controllerNoticeMessage = "请在系统设置 → 隐私与安全性 → 麦克风 中勾选 LiteDictate"
                            self.openSettingsLocked(.microphone)
                            self.projectSnapshotLocked()
                        }
                    }
                }
            } else if snap.microphone != .granted {
                controllerNoticeMessage = "请在系统设置 → 隐私与安全性 → 麦克风 中勾选 LiteDictate"
                openSettingsLocked(.microphone)
                refreshPermissionsAndRestartTapIfNeededLocked()
            } else {
                refreshPermissionsAndRestartTapIfNeededLocked()
            }

        case .requestAccessibilityPermission:
            permissionManager.requestAccessibilityPrompt()
            refreshPermissionsAndRestartTapIfNeededLocked()
            scheduleSettingsFallbackLocked(delay: settingsFallbackDelay) { controller in
                controller.refreshPermissionsAndRestartTapIfNeededLocked()
                if !controller.permissionSnapshot.accessibilityTrusted {
                    controller.controllerNoticeMessage = "已向系统注册 LiteDictate，请在「辅助功能」中打开开关"
                    controller.openSettingsLocked(.accessibility)
                    controller.projectSnapshotLocked()
                }
            }

        case .requestInputMonitoringPermission:
            _ = permissionManager.requestListenEventAccess()
            refreshPermissionsAndRestartTapIfNeededLocked()
            scheduleSettingsFallbackLocked(delay: settingsFallbackDelay) { controller in
                controller.refreshPermissionsAndRestartTapIfNeededLocked()
                if !controller.permissionSnapshot.listenEventAccess {
                    controller.controllerNoticeMessage = "已向系统注册 LiteDictate，请在「输入监控」中打开开关"
                    controller.openSettingsLocked(.inputMonitoring)
                    controller.projectSnapshotLocked()
                }
            }

        case .requestPostEventPermission:
            _ = permissionManager.requestPostEventAccess()
            let snap = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive)
            if !snap.accessibilityTrusted {
                permissionManager.requestAccessibilityPrompt()
            }
            refreshPermissionsAndRestartTapIfNeededLocked()
            scheduleSettingsFallbackLocked(delay: settingsFallbackDelay) { controller in
                controller.refreshPermissionsAndRestartTapIfNeededLocked()
                if !controller.permissionSnapshot.postEventAccess {
                    controller.controllerNoticeMessage = "已向系统注册 LiteDictate，请在「辅助功能」中打开开关以允许自动输入文字"
                    controller.openSettingsLocked(.accessibility)
                    controller.projectSnapshotLocked()
                }
            }

        case .requestAllMissingPermissions:
            let snap = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive)
            if snap.microphone == .notDetermined {
                permissionManager.requestMicrophoneAccess { [weak self] _ in
                    guard let self else { return }
                    self.stateQueue.async {
                        self.refreshPermissionsAndRestartTapIfNeededLocked()
                    }
                }
            }
            if !snap.listenEventAccess {
                _ = permissionManager.requestListenEventAccess()
            }
            if !snap.postEventAccess {
                _ = permissionManager.requestPostEventAccess()
            }
            if !snap.accessibilityTrusted {
                permissionManager.requestAccessibilityPrompt()
            }
            refreshPermissionsAndRestartTapIfNeededLocked()

            scheduleSettingsFallbackLocked(delay: settingsFallbackDelay + 0.10) { controller in
                controller.refreshPermissionsAndRestartTapIfNeededLocked()
                let updated = controller.permissionSnapshot
                let targetPane: SystemSettingsPane?
                if updated.microphone == .denied || updated.microphone == .restricted {
                    targetPane = .microphone
                } else if !updated.accessibilityTrusted || !updated.postEventAccess {
                    targetPane = .accessibility
                } else if !updated.listenEventAccess {
                    targetPane = .inputMonitoring
                } else {
                    targetPane = nil
                }

                if let pane = targetPane {
                    controller.controllerNoticeMessage = "已向系统设置注册 LiteDictate，请在打开的设置页勾选开关（授权后如热键未生效可点击重启）"
                    controller.openSettingsLocked(pane)
                    controller.projectSnapshotLocked()
                }
            }

        case let .openSystemSettings(pane):
            openSettingsLocked(pane)

        case .relaunchApplication:
            performQuitCleanupLocked()
            relaunchHandler()

        case .shutdownWorkerNow:
            workerSupervisor.shutdownGracefully(reason: "user_requested")

        case .prepareForQuit:
            performQuitCleanupLocked()
        }
    }

    /// Loads current `vocab.txt` and `aliases.json` text for the Preferences window editor.
    public func loadVocabularyAndAliasesText() -> (vocabText: String, aliasesJSON: String) {
        stateQueue.sync {
            ensureSupportDirectoryAndDefaultFilesLocked()
            let vocab = (try? String(contentsOfFile: config.vocabPath, encoding: .utf8)) ?? ""
            let aliases = (try? String(contentsOfFile: config.aliasesPath, encoding: .utf8)) ?? "{\n}\n"
            return (vocab, aliases)
        }
    }

    private func performQuitCleanupLocked() {
        stopPermissionPollingTimerLocked()
        removeWorkspaceLifecycleObservers()
        audioDeviceManager.stopObservingChanges()
        hotkeyController.stop()
        coordinator.prepareForQuit()
    }

    private func openSettingsLocked(_ pane: SystemSettingsPane) {
        let url = permissionManager.settingsURL(for: pane)
        openURLHandler(url)
    }

    private func scheduleSettingsFallbackLocked(
        delay: TimeInterval,
        action: @escaping @Sendable (AppController) -> Void
    ) {
        stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    private func refreshPermissionsAndRestartTapIfNeededLocked() {
        let wasAlive = hotkeyController.isTapAlive
        let snap = permissionManager.snapshot(eventTapAlive: wasAlive)
        // On macOS, `.defaultTap` can activate as soon as Input Monitoring OR Accessibility is granted.
        if !wasAlive && (snap.listenEventAccess || snap.accessibilityTrusted) && !snap.secureInputEnabled {
            _ = hotkeyController.start(
                binding: config.hotkey,
                disabledBundleIDs: Set(config.disabledBundleIDs),
                shouldInterceptCancelEscape: coordinator.shouldInterceptCancelEscape,
                triggerKeyDebtActive: coordinator.triggerKeyDebtActive,
                onEvent: { [weak self] event in
                    self?.coordinator.handleHotkeyEvent(event)
                }
            )
        }
        permissionSnapshot = permissionManager.snapshot(eventTapAlive: hotkeyController.isTapAlive)
        coordinator.syncSecureInputState(permissionSnapshot.secureInputEnabled)
        launchAtLoginState = launchAtLoginManager.currentState()
        updatePermissionPollingCadenceLocked()
        projectSnapshotLocked()
    }

    private func stopPermissionPollingTimerLocked() {
        permissionRefreshTimer?.cancel()
        permissionRefreshTimer = nil
        pollingActiveAtomic.store(false, ordering: .release)
    }

    /// Idle CPU optimization: poll at 1.0s ONLY while any core permission is missing or EventTap is inactive.
    /// Once all core permissions are granted and EventTap is alive, stop the timer completely (0 periodic wakeups!).
    private func installPermissionPollingTimerLocked() {
        let needsPolling = !permissionSnapshot.allCorePermissionsGranted || !permissionSnapshot.eventTapAlive
        guard needsPolling else {
            stopPermissionPollingTimerLocked()
            return
        }
        guard permissionRefreshTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let tapAlive = self.hotkeyController.isTapAlive
            let next = self.permissionManager.snapshot(eventTapAlive: tapAlive)
            // Auto-recover EventTap once Input Monitoring/Accessibility is granted and Secure Input ends.
            if !tapAlive && (next.listenEventAccess || next.accessibilityTrusted) && !next.secureInputEnabled {
                self.refreshPermissionsAndRestartTapIfNeededLocked()
                return
            }
            if next != self.permissionSnapshot {
                self.permissionSnapshot = next
                self.updatePermissionPollingCadenceLocked()
                self.projectSnapshotLocked()
            } else if next.allCorePermissionsGranted && next.eventTapAlive {
                self.stopPermissionPollingTimerLocked()
            }
        }
        permissionRefreshTimer = timer
        pollingActiveAtomic.store(true, ordering: .release)
        timer.resume()
    }

    private func updatePermissionPollingCadenceLocked() {
        let needsPolling = !permissionSnapshot.allCorePermissionsGranted || !permissionSnapshot.eventTapAlive
        if needsPolling {
            installPermissionPollingTimerLocked()
        } else {
            stopPermissionPollingTimerLocked()
        }
    }

    private func installWorkspaceLifecycleObservers() {
        let observers = lifecycleObservers
        let coord = coordinator
        Task { @MainActor [weak self] in
            observers.install(
                onSleepOrLock: { reason in
                    coord.handleSystemSleepOrLock(reason: reason)
                },
                onWakeOrActivate: { [weak self] in
                    self?.dispatch(.refreshPermissions)
                }
            )
        }
    }

    private func removeWorkspaceLifecycleObservers() {
        let observers = lifecycleObservers
        Task { @MainActor in
            observers.remove()
        }
    }

    private func projectSnapshotLocked() {
        let resolution = audioDeviceManager.resolveDevice(for: config.audioSelection)
        let delta = latestCoordinatorDelta
        let mergedError = delta.lastErrorMessage ?? controllerErrorMessage
        let mergedNotice = delta.lastNoticeMessage ?? controllerNoticeMessage
        // Query live Secure Input directly as the single source of truth so stale pause flags can never stick.
        let securePaused = permissionManager.isSecureEventInputEnabled()

        let snapshot = AppStateSnapshot(
            phase: delta.phase,
            workerState: delta.workerState,
            memoryPressure: delta.memoryPressure,
            workerFootprintBytes: delta.workerFootprintBytes,
            isSecureInputPaused: securePaused,
            activeModelID: modelRegistry.activeModelID,
            models: modelRegistry.models,
            discoveredModels: discoveredModels,
            isImportingModel: isImportingModel,
            lastErrorMessage: mergedError,
            lastNoticeMessage: mergedNotice,
            audioSelection: config.audioSelection,
            availableDevices: availableDevices,
            resolvedDevice: resolution.device,
            isBluetoothWarningActive: resolution.isBluetoothHFPWarning,
            hotkey: config.hotkey,
            preferredLanguage: config.preferredLanguage,
            inputMode: config.inputMode,
            playFeedbackSounds: config.playFeedbackSounds,
            modelIdleUnloadPolicy: config.modelIdleUnloadPolicy,
            launchAtLogin: launchAtLoginState,
            permissions: permissionSnapshot,
            overlay: delta.overlay,
            recovery: delta.recovery,
            hasLastCommittedText: delta.hasLastCommittedText,
            recentHistory: delta.recentHistory,
            isCoolingDown: delta.isCoolingDown
        )

        let store = self.stateStore
        Task { @MainActor in
            store.publish(snapshot)
        }
    }

    // MARK: - Config Persistence

    private func ensureSupportDirectoryAndDefaultFilesLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFileURL.path) {
            saveConfigLocked()
        }
        if !fm.fileExists(atPath: config.vocabPath) {
            let template = "# LiteDictate 自定义热词（每行一个词条，最多 50 词）\n# SwiftUI\n# LiteDictate\n"
            try? template.write(toFile: config.vocabPath, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: config.aliasesPath) {
            let template = "{\n  \"Swift UI\": \"SwiftUI\",\n  \"LightDictate\": \"LiteDictate\"\n}\n"
            try? template.write(toFile: config.aliasesPath, atomically: true, encoding: .utf8)
        }
    }

    private static func loadConfig(from url: URL, appSupportDir: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig.defaultConfig(appSupportDir: appSupportDir)
        }
        return decoded
    }

    private func saveConfigLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFileURL, options: .atomic)
    }
}
