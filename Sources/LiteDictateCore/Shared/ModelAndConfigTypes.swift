import Foundation

public enum ModelStorageMode: String, Codable, Equatable, Sendable {
    case reference
    case copied
}

public struct FileStatFingerprint: Codable, Equatable, Sendable {
    public let dev: UInt64
    public let ino: UInt64
    public let fileSizeBytes: UInt64
    public let mtimeSec: Int64
    public let mtimeNsec: Int64

    public init(
        dev: UInt64,
        ino: UInt64,
        fileSizeBytes: UInt64,
        mtimeSec: Int64,
        mtimeNsec: Int64 = 0
    ) {
        self.dev = dev
        self.ino = ino
        self.fileSizeBytes = fileSizeBytes
        self.mtimeSec = mtimeSec
        self.mtimeNsec = mtimeNsec
    }
}

public struct ModelCapabilities: Codable, Equatable, Sendable {
    public let arch: String
    public let variant: String
    public let roles: [String]
    public let nativeSampleRate: Int
    public let maxAudioMs: Int
    public let languages: [String]
    public let supportsLanguageDetect: Bool
    public let supportsStreaming: Bool
    public let supportsVocabulary: Bool
    public let supportsContextPrompt: Bool
    public let supportsInitialPrompt: Bool
    public let supportsPnc: Bool
    public let supportsItn: Bool
    public let supportsCancellation: Bool

    public static let minSupportedSampleRate: Int = 8_000
    public static let maxSupportedSampleRate: Int = 48_000
    public static let minSupportedMaxAudioMs: Int = 1_000
    public static let maxSupportedMaxAudioMs: Int = 600_000

    public static func sanitizeSampleRate(_ raw: Int) -> Int {
        guard raw >= minSupportedSampleRate && raw <= maxSupportedSampleRate else {
            return LiteDictateConstants.defaultSampleRate
        }
        return raw
    }

    public static func sanitizeMaxAudioMs(_ raw: Int) -> Int {
        guard raw > 0 else {
            return LiteDictateConstants.defaultMaxAudioMs
        }
        return min(maxSupportedMaxAudioMs, max(minSupportedMaxAudioMs, raw))
    }

    public init(
        arch: String = "unknown",
        variant: String = "",
        roles: [String] = ["asr"],
        nativeSampleRate: Int = LiteDictateConstants.defaultSampleRate,
        maxAudioMs: Int = LiteDictateConstants.defaultMaxAudioMs,
        languages: [String] = [],
        supportsLanguageDetect: Bool = true,
        supportsStreaming: Bool = false,
        supportsVocabulary: Bool = false,
        supportsContextPrompt: Bool = false,
        supportsInitialPrompt: Bool = false,
        supportsPnc: Bool = false,
        supportsItn: Bool = false,
        supportsCancellation: Bool = true
    ) {
        self.arch = arch
        self.variant = variant
        self.roles = roles
        self.nativeSampleRate = Self.sanitizeSampleRate(nativeSampleRate)
        self.maxAudioMs = Self.sanitizeMaxAudioMs(maxAudioMs)
        self.languages = languages
        self.supportsLanguageDetect = supportsLanguageDetect
        self.supportsStreaming = supportsStreaming
        self.supportsVocabulary = supportsVocabulary
        self.supportsContextPrompt = supportsContextPrompt
        self.supportsInitialPrompt = supportsInitialPrompt
        self.supportsPnc = supportsPnc
        self.supportsItn = supportsItn
        self.supportsCancellation = supportsCancellation
    }

    enum CodingKeys: String, CodingKey {
        case arch, variant, roles, nativeSampleRate, maxAudioMs, languages
        case supportsLanguageDetect, supportsStreaming, supportsVocabulary
        case supportsContextPrompt, supportsInitialPrompt, supportsPnc, supportsItn, supportsCancellation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? "unknown"
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? ""
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? ["asr"]
        let sr = try c.decodeIfPresent(Int.self, forKey: .nativeSampleRate) ?? LiteDictateConstants.defaultSampleRate
        nativeSampleRate = Self.sanitizeSampleRate(sr)
        let maxMs = try c.decodeIfPresent(Int.self, forKey: .maxAudioMs) ?? LiteDictateConstants.defaultMaxAudioMs
        maxAudioMs = Self.sanitizeMaxAudioMs(maxMs)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        supportsLanguageDetect = try c.decodeIfPresent(Bool.self, forKey: .supportsLanguageDetect) ?? true
        supportsStreaming = try c.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? false
        supportsVocabulary = try c.decodeIfPresent(Bool.self, forKey: .supportsVocabulary) ?? false
        supportsContextPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsContextPrompt) ?? false
        supportsInitialPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsInitialPrompt) ?? false
        supportsPnc = try c.decodeIfPresent(Bool.self, forKey: .supportsPnc) ?? false
        supportsItn = try c.decodeIfPresent(Bool.self, forKey: .supportsItn) ?? false
        supportsCancellation = try c.decodeIfPresent(Bool.self, forKey: .supportsCancellation) ?? true
    }

    public var isASRModel: Bool {
        roles.contains { $0.lowercased() == "asr" }
    }

    /// Dynamic safe capture limit: `min(29_500, max(5_000, maxAudioMs - 500))`.
    public var effectiveCaptureLimitMs: Int {
        min(
            LiteDictateConstants.defaultCaptureLimitMs,
            max(LiteDictateConstants.minCaptureLimitMs, maxAudioMs - 500)
        )
    }

    public var effectiveMaxSamples: Int {
        (effectiveCaptureLimitMs * nativeSampleRate) / 1000
    }
}

public struct ModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var filePath: String
    public var storageMode: ModelStorageMode
    public var fileSizeBytes: UInt64
    public var statFingerprint: FileStatFingerprint?
    public var capabilities: ModelCapabilities
    public var preferredLanguage: String
    public var isFileMissing: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case filePath
        case storageMode
        case fileSizeBytes
        case statFingerprint
        case capabilities
        case preferredLanguage
    }

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        filePath: String,
        storageMode: ModelStorageMode,
        fileSizeBytes: UInt64,
        statFingerprint: FileStatFingerprint?,
        capabilities: ModelCapabilities,
        preferredLanguage: String = "auto",
        isFileMissing: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.filePath = filePath
        self.storageMode = storageMode
        self.fileSizeBytes = fileSizeBytes
        self.statFingerprint = statFingerprint
        self.capabilities = capabilities
        self.preferredLanguage = preferredLanguage
        self.isFileMissing = isFileMissing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        filePath = try c.decode(String.self, forKey: .filePath)
        storageMode = try c.decode(ModelStorageMode.self, forKey: .storageMode)
        fileSizeBytes = try c.decode(UInt64.self, forKey: .fileSizeBytes)
        statFingerprint = try c.decodeIfPresent(FileStatFingerprint.self, forKey: .statFingerprint)
        capabilities = try c.decode(ModelCapabilities.self, forKey: .capabilities)
        preferredLanguage = try c.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? "auto"
        isFileMissing = false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(filePath, forKey: .filePath)
        try c.encode(storageMode, forKey: .storageMode)
        try c.encode(fileSizeBytes, forKey: .fileSizeBytes)
        try c.encodeIfPresent(statFingerprint, forKey: .statFingerprint)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(preferredLanguage, forKey: .preferredLanguage)
    }
}

public struct DiscoveredModelCandidate: Equatable, Identifiable, Sendable {
    public var id: String { filePath }
    public let filePath: String
    public let fileName: String
    public let fileSizeBytes: UInt64

    public init(filePath: String, fileName: String, fileSizeBytes: UInt64) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
    }
}

public enum TextInputMode: String, Codable, Equatable, Sendable {
    case directTyping
    case clipboardCompatibility

    public var displayTitle: String {
        switch self {
        case .directTyping:
            return "直接输入文字（推荐，不占用剪贴板）"
        case .clipboardCompatibility:
            return "剪贴板兼容模式（适合极少数老旧软件）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .directTyping: return "直接输入（不占剪贴板）"
        case .clipboardCompatibility: return "剪贴板兼容模式"
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var hotkey: HotkeyBinding
    public var audioSelection: AudioSelectionMode
    public var preferredLanguage: String
    public var disabledBundleIDs: [String]
    public var pasteRestoreDelayMs: Int
    public var vocabPath: String
    public var aliasesPath: String
    public var inputMode: TextInputMode
    public var playFeedbackSounds: Bool

    enum CodingKeys: String, CodingKey {
        case hotkey
        case audioSelection
        case preferredLanguage
        case disabledBundleIDs
        case pasteRestoreDelayMs
        case vocabPath
        case aliasesPath
        case inputMode
        case playFeedbackSounds
    }

    public init(
        hotkey: HotkeyBinding = .defaultBinding,
        audioSelection: AudioSelectionMode = .smartAuto,
        preferredLanguage: String = "auto",
        disabledBundleIDs: [String] = [],
        pasteRestoreDelayMs: Int = LiteDictateConstants.defaultPasteRestoreDelayMs,
        vocabPath: String,
        aliasesPath: String,
        inputMode: TextInputMode = .directTyping,
        playFeedbackSounds: Bool = true
    ) {
        self.hotkey = hotkey
        self.audioSelection = audioSelection
        self.preferredLanguage = preferredLanguage
        self.disabledBundleIDs = disabledBundleIDs
        self.pasteRestoreDelayMs = min(
            LiteDictateConstants.maxPasteRestoreDelayMs,
            max(LiteDictateConstants.minPasteRestoreDelayMs, pasteRestoreDelayMs)
        )
        self.vocabPath = vocabPath
        self.aliasesPath = aliasesPath
        self.inputMode = inputMode
        self.playFeedbackSounds = playFeedbackSounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaultConfig()
        hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey) ?? defaults.hotkey
        audioSelection = try c.decodeIfPresent(AudioSelectionMode.self, forKey: .audioSelection) ?? defaults.audioSelection
        preferredLanguage = try c.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? defaults.preferredLanguage
        disabledBundleIDs = try c.decodeIfPresent([String].self, forKey: .disabledBundleIDs) ?? defaults.disabledBundleIDs
        let rawDelay = try c.decodeIfPresent(Int.self, forKey: .pasteRestoreDelayMs) ?? defaults.pasteRestoreDelayMs
        pasteRestoreDelayMs = min(
            LiteDictateConstants.maxPasteRestoreDelayMs,
            max(LiteDictateConstants.minPasteRestoreDelayMs, rawDelay)
        )
        vocabPath = try c.decodeIfPresent(String.self, forKey: .vocabPath) ?? defaults.vocabPath
        aliasesPath = try c.decodeIfPresent(String.self, forKey: .aliasesPath) ?? defaults.aliasesPath
        inputMode = try c.decodeIfPresent(TextInputMode.self, forKey: .inputMode) ?? .directTyping
        playFeedbackSounds = try c.decodeIfPresent(Bool.self, forKey: .playFeedbackSounds) ?? true
    }

    public static func defaultAppSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiteDictate", isDirectory: true)
    }

    public static func defaultConfig(appSupportDir: URL = defaultAppSupportDirectory()) -> AppConfig {
        AppConfig(
            hotkey: .defaultBinding,
            audioSelection: .smartAuto,
            preferredLanguage: "auto",
            disabledBundleIDs: [],
            pasteRestoreDelayMs: LiteDictateConstants.defaultPasteRestoreDelayMs,
            vocabPath: appSupportDir.appendingPathComponent("vocab.txt").path,
            aliasesPath: appSupportDir.appendingPathComponent("aliases.json").path,
            inputMode: .directTyping,
            playFeedbackSounds: true
        )
    }
}
