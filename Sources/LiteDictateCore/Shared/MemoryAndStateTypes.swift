import Foundation

public enum MemoryPressureLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical

    public var displayTitle: String {
        switch self {
        case .normal: return "内存充足"
        case .warning: return "内存较紧"
        case .critical: return "内存紧张"
        }
    }
}

public enum WorkerLifecycleState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case warmModel
    case busy
    case cancelling
    case stopping

    public var displayTitle: String {
        switch self {
        case .stopped: return "待命中"
        case .starting: return "正在准备语音模型"
        case .warmModel: return "已就绪"
        case .busy: return "正在识别"
        case .cancelling: return "正在取消"
        case .stopping: return "正在释放内存"
        }
    }
}

public enum InteractionPhase: String, Codable, Equatable, Sendable {
    case idle
    case arming
    case recording
    case draining
    case waitingWorkerReady
    case transcribing
    case validating
    case awaitingPreCommitReadiness
    case preparingInjection
    case revalidating
    case commitStarted
    case recovery

    /// Whether global Escape should be intercepted to cancel the active dictation.
    /// True during capture, inference, validation, and pre-commit wait (before clipboard write).
    /// MUST be `false` in `.idle`, `.preparingInjection`, `.revalidating`, `.commitStarted`, and `.recovery` (never breaks Vim/IDE Escape).
    public var shouldInterceptCancelEscape: Bool {
        switch self {
        case .arming, .recording, .draining, .waitingWorkerReady, .transcribing, .validating, .awaitingPreCommitReadiness:
            return true
        case .idle, .preparingInjection, .revalidating, .commitStarted, .recovery:
            return false
        }
    }
}

public struct RecoveryPayload: Equatable, Sendable {
    public let id: UUID
    public let text: String?
    public let hasRetainedAudio: Bool
    public let reason: String
    public let notice: String?
    public let expiresAt: Date
    public let canRetry: Bool
    public let canPaste: Bool
    public let canCopy: Bool

    public init(
        id: UUID = UUID(),
        text: String?,
        hasRetainedAudio: Bool,
        reason: String,
        notice: String? = nil,
        expiresAt: Date,
        canRetry: Bool,
        canPaste: Bool,
        canCopy: Bool
    ) {
        self.id = id
        self.text = text
        self.hasRetainedAudio = hasRetainedAudio
        self.reason = reason
        self.notice = notice
        self.expiresAt = expiresAt
        self.canRetry = canRetry
        self.canPaste = canPaste
        self.canCopy = canCopy
    }
}

/// Single in-memory recent dictation entry (max 5 kept in RAM, cleared on sleep/lock/quit, 0 disk, 0 logs).
public struct RecentTranscriptEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    /// Compact single-line preview for menu bar display.
    public func menuPreview(maxCharacters: Int = 22) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "…"
    }
}

public struct RecordingOverlayState: Equatable, Sendable {
    public let isVisible: Bool
    public let phase: InteractionPhase
    public let isReadyForSpeech: Bool
    public let audioLevel: Float
    public let elapsedMs: Int
    public let captureLimitMs: Int
    public let statusText: String
    public let isCompilingMetalShaders: Bool
    public let activeDeviceName: String?
    public let noticeText: String?
    public let toastMessage: String?

    public var isToast: Bool {
        toastMessage != nil
    }

    public static let hidden = RecordingOverlayState(
        isVisible: false,
        phase: .idle,
        isReadyForSpeech: false,
        audioLevel: 0,
        elapsedMs: 0,
        captureLimitMs: LiteDictateConstants.defaultCaptureLimitMs,
        statusText: "",
        isCompilingMetalShaders: false,
        activeDeviceName: nil,
        noticeText: nil,
        toastMessage: nil
    )

    public init(
        isVisible: Bool,
        phase: InteractionPhase,
        isReadyForSpeech: Bool,
        audioLevel: Float,
        elapsedMs: Int,
        captureLimitMs: Int,
        statusText: String,
        isCompilingMetalShaders: Bool = false,
        activeDeviceName: String? = nil,
        noticeText: String? = nil,
        toastMessage: String? = nil
    ) {
        self.isVisible = isVisible
        self.phase = phase
        self.isReadyForSpeech = isReadyForSpeech
        self.audioLevel = audioLevel
        self.elapsedMs = elapsedMs
        self.captureLimitMs = captureLimitMs
        self.statusText = statusText
        self.isCompilingMetalShaders = isCompilingMetalShaders
        self.activeDeviceName = activeDeviceName
        self.noticeText = noticeText
        self.toastMessage = toastMessage
    }
}

public enum LaunchAtLoginState: String, Codable, Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case unavailable
}

public enum ConfigFileTarget: String, Equatable, Sendable {
    case vocab
    case aliases
    case appSupportFolder
}

public protocol LaunchAtLoginManaging: AnyObject, Sendable {
    func currentState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openLoginItemsSettings()
}

/// 100% immutable UI state projection from LiteDictateCore to the Thin AppKit Shell.
public struct AppStateSnapshot: Equatable, Sendable {
    public let phase: InteractionPhase
    public let workerState: WorkerLifecycleState
    public let memoryPressure: MemoryPressureLevel
    public let workerFootprintBytes: UInt64
    public let isSecureInputPaused: Bool
    public let activeModelID: String?
    public let models: [ModelDescriptor]
    public let discoveredModels: [DiscoveredModelCandidate]
    public let isImportingModel: Bool
    public let lastErrorMessage: String?
    public let lastNoticeMessage: String?
    public let audioSelection: AudioSelectionMode
    public let availableDevices: [AudioDeviceInfo]
    public let resolvedDevice: AudioDeviceInfo?
    public let isBluetoothWarningActive: Bool
    public let hotkey: HotkeyBinding
    public let preferredLanguage: String
    public let inputMode: TextInputMode
    public let playFeedbackSounds: Bool
    public let modelIdleUnloadPolicy: ModelIdleUnloadPolicy
    public let launchAtLogin: LaunchAtLoginState
    public let permissions: PermissionSnapshot
    public let overlay: RecordingOverlayState
    public let recovery: RecoveryPayload?
    public let hasLastCommittedText: Bool
    public let recentHistory: [RecentTranscriptEntry]
    public let isCoolingDown: Bool

    public var activeModel: ModelDescriptor? {
        guard let activeModelID else { return nil }
        return models.first { $0.id == activeModelID }
    }

    public init(
        phase: InteractionPhase = .idle,
        workerState: WorkerLifecycleState = .stopped,
        memoryPressure: MemoryPressureLevel = .normal,
        workerFootprintBytes: UInt64 = 0,
        isSecureInputPaused: Bool = false,
        activeModelID: String? = nil,
        models: [ModelDescriptor] = [],
        discoveredModels: [DiscoveredModelCandidate] = [],
        isImportingModel: Bool = false,
        lastErrorMessage: String? = nil,
        lastNoticeMessage: String? = nil,
        audioSelection: AudioSelectionMode = .smartAuto,
        availableDevices: [AudioDeviceInfo] = [],
        resolvedDevice: AudioDeviceInfo? = nil,
        isBluetoothWarningActive: Bool = false,
        hotkey: HotkeyBinding = .defaultBinding,
        preferredLanguage: String = "auto",
        inputMode: TextInputMode = .directTyping,
        playFeedbackSounds: Bool = true,
        modelIdleUnloadPolicy: ModelIdleUnloadPolicy = .twoMinutes,
        launchAtLogin: LaunchAtLoginState = .unavailable,
        permissions: PermissionSnapshot = PermissionSnapshot(),
        overlay: RecordingOverlayState = .hidden,
        recovery: RecoveryPayload? = nil,
        hasLastCommittedText: Bool = false,
        recentHistory: [RecentTranscriptEntry] = [],
        isCoolingDown: Bool = false
    ) {
        self.phase = phase
        self.workerState = workerState
        self.memoryPressure = memoryPressure
        self.workerFootprintBytes = workerFootprintBytes
        self.isSecureInputPaused = isSecureInputPaused
        self.activeModelID = activeModelID
        self.models = models
        self.discoveredModels = discoveredModels
        self.isImportingModel = isImportingModel
        self.lastErrorMessage = lastErrorMessage
        self.lastNoticeMessage = lastNoticeMessage
        self.audioSelection = audioSelection
        self.availableDevices = availableDevices
        self.resolvedDevice = resolvedDevice
        self.isBluetoothWarningActive = isBluetoothWarningActive
        self.hotkey = hotkey
        self.preferredLanguage = preferredLanguage
        self.inputMode = inputMode
        self.playFeedbackSounds = playFeedbackSounds
        self.modelIdleUnloadPolicy = modelIdleUnloadPolicy
        self.launchAtLogin = launchAtLogin
        self.permissions = permissions
        self.overlay = overlay
        self.recovery = recovery
        self.hasLastCommittedText = hasLastCommittedText || !recentHistory.isEmpty
        self.recentHistory = recentHistory
        self.isCoolingDown = isCoolingDown
    }
}

/// Semantic commands dispatched from Thin AppKit UI Shell to LiteDictateCore.
public enum AppActionCommand: Sendable {
    case toggleRecording
    case cancelCurrentRequest
    case selectModel(id: String)
    case importModel(url: URL, storageMode: ModelStorageMode)
    case relinkModel(id: String, newURL: URL)
    case removeModel(id: String)
    case rescanDiscoveredModels
    case setAudioSelection(AudioSelectionMode)
    case setTriggerMode(HotkeyTriggerMode)
    case setHotkeyBinding(HotkeyBinding)
    case setHotkeyRecordingActive(Bool)
    case setPreferredLanguage(String)
    case setTextInputMode(TextInputMode)
    case setPlayFeedbackSounds(Bool)
    case setModelIdleUnloadPolicy(ModelIdleUnloadPolicy)
    case setPasteRestoreDelayMs(Int)
    case setLaunchAtLogin(Bool)
    case openLoginItemsSettings
    case openSettingsWindow
    case openConfigFile(ConfigFileTarget)
    case saveVocabularyAndAliases(vocabText: String, aliasesJSON: String)
    case copyLastCommittedText
    case copyHistoryItem(id: UUID)
    case clearRecentHistory
    case recoveryCopy
    case recoveryPasteToFrontmost
    case recoveryRetry
    case recoveryDiscard
    case refreshPermissions
    case requestMicrophonePermission
    case requestAccessibilityPermission
    case requestInputMonitoringPermission
    case requestPostEventPermission
    case requestAllMissingPermissions
    case openSystemSettings(SystemSettingsPane)
    case relaunchApplication
    case shutdownWorkerNow
    case prepareForQuit
}
