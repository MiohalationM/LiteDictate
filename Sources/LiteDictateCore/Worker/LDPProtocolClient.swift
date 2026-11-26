import Darwin
import Foundation

// MARK: - LDP1 Wire Constants & Types

public enum LDPMessageType: UInt16, Sendable, Equatable {
    // Host -> Worker
    case warmup = 0x01
    case transcribe = 0x02
    case cancel = 0x03
    case shutdown = 0x04
    case ping = 0x05
    case probeModel = 0x06

    // Worker -> Host
    case ready = 0x81
    case result = 0x82
    case error = 0x83
    case bye = 0x84
    case pong = 0x85
    case cancelled = 0x86
    case probeResult = 0x87
}

public enum LDPErrorCode: UInt32, Sendable, Equatable {
    case protocolError = 1
    case busy = 2
    case invalidPayload = 3
    case modelNotLoaded = 4
    case modelLoad = 5
    case unsupportedRole = 6
    case inference = 7
    case internalError = 8
}

public enum LDPProtocolError: Error, Equatable, Sendable {
    case invalidHeaderLength(Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownMessageType(UInt16)
    case payloadTooLarge(UInt32)
    case nonFiniteAudioSamples
    case tooManyVocabularyEntries(Int)
    case emptyAudioPayload
    case eof
    case ioFailure(errno: Int32)
    case invalidJSONPayload(String)
}

/// 32-byte naturally aligned little-endian LDP1 frame header matching `Worker/` C++17 `LDPFrameHeader` byte-for-byte.
public struct LDPFrameHeader: Equatable, Sendable {
    public static let byteSize = 32
    public static let magic: (UInt8, UInt8, UInt8, UInt8) = (0x4C, 0x44, 0x50, 0x31) // "LDP1"
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    public let msgType: LDPMessageType
    public let requestID: UInt64
    public let attemptID: UInt64
    public let payloadLen: UInt32
    public let statusOrFlags: UInt32

    public init(
        version: UInt16 = LDPFrameHeader.currentVersion,
        msgType: LDPMessageType,
        requestID: UInt64 = 0,
        attemptID: UInt64 = 0,
        payloadLen: UInt32 = 0,
        statusOrFlags: UInt32 = 0
    ) {
        self.version = version
        self.msgType = msgType
        self.requestID = requestID
        self.attemptID = attemptID
        self.payloadLen = payloadLen
        self.statusOrFlags = statusOrFlags
    }

    public func encode() -> Data {
        var data = Data(count: Self.byteSize)
        data.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            p[0] = Self.magic.0
            p[1] = Self.magic.1
            p[2] = Self.magic.2
            p[3] = Self.magic.3

            var v = version.littleEndian
            var mt = msgType.rawValue.littleEndian
            var rid = requestID.littleEndian
            var aid = attemptID.littleEndian
            var plen = payloadLen.littleEndian
            var sof = statusOrFlags.littleEndian

            memcpy(p.advanced(by: 4), &v, 2)
            memcpy(p.advanced(by: 6), &mt, 2)
            memcpy(p.advanced(by: 8), &rid, 8)
            memcpy(p.advanced(by: 16), &aid, 8)
            memcpy(p.advanced(by: 24), &plen, 4)
            memcpy(p.advanced(by: 28), &sof, 4)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> LDPFrameHeader {
        guard data.count == Self.byteSize else {
            throw LDPProtocolError.invalidHeaderLength(data.count)
        }
        return try data.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            guard p[0] == magic.0, p[1] == magic.1, p[2] == magic.2, p[3] == magic.3 else {
                throw LDPProtocolError.invalidMagic
            }

            var v: UInt16 = 0
            var mtRaw: UInt16 = 0
            var rid: UInt64 = 0
            var aid: UInt64 = 0
            var plen: UInt32 = 0
            var sof: UInt32 = 0

            memcpy(&v, p.advanced(by: 4), 2)
            memcpy(&mtRaw, p.advanced(by: 6), 2)
            memcpy(&rid, p.advanced(by: 8), 8)
            memcpy(&aid, p.advanced(by: 16), 8)
            memcpy(&plen, p.advanced(by: 24), 4)
            memcpy(&sof, p.advanced(by: 28), 4)

            let version = UInt16(littleEndian: v)
            guard version == currentVersion else {
                throw LDPProtocolError.unsupportedVersion(version)
            }
            let msgTypeValue = UInt16(littleEndian: mtRaw)
            guard let msgType = LDPMessageType(rawValue: msgTypeValue) else {
                throw LDPProtocolError.unknownMessageType(msgTypeValue)
            }
            let payloadLen = UInt32(littleEndian: plen)
            guard Int(payloadLen) <= LiteDictateConstants.maxFrameBytes else {
                throw LDPProtocolError.payloadTooLarge(payloadLen)
            }

            return LDPFrameHeader(
                version: version,
                msgType: msgType,
                requestID: UInt64(littleEndian: rid),
                attemptID: UInt64(littleEndian: aid),
                payloadLen: payloadLen,
                statusOrFlags: UInt32(littleEndian: sof)
            )
        }
    }
}

public struct LDPFrame: Equatable, Sendable {
    public let header: LDPFrameHeader
    public let payload: Data

    public init(header: LDPFrameHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }
}

// MARK: - JSON Payloads (matching Worker LDP1 Contract)

public struct LDPProbeModelRequest: Codable, Equatable, Sendable {
    public let modelPath: String
    public let backend: String

    public init(modelPath: String, backend: String = "cpu") {
        self.modelPath = modelPath
        self.backend = backend
    }
}

public struct LDPWarmupRequest: Codable, Equatable, Sendable {
    public let modelPath: String
    public let backend: String
    public let noMmap: Bool

    public init(modelPath: String, backend: String = "metal", noMmap: Bool = false) {
        self.modelPath = modelPath
        self.backend = backend
        self.noMmap = noMmap
    }
}

public struct LDPProbeResultPayload: Codable, Equatable, Sendable {
    public let modelPath: String
    public let roles: [String]
    public let arch: String
    public let variant: String
    public let backend: String?
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
    public let loadMs: Double
    public let physFootprintBytes: UInt64

    public init(
        modelPath: String,
        roles: [String],
        arch: String,
        variant: String,
        backend: String? = nil,
        nativeSampleRate: Int,
        maxAudioMs: Int,
        languages: [String] = [],
        supportsLanguageDetect: Bool = true,
        supportsStreaming: Bool = false,
        supportsVocabulary: Bool = false,
        supportsContextPrompt: Bool = false,
        supportsInitialPrompt: Bool = false,
        supportsPnc: Bool = false,
        supportsItn: Bool = false,
        supportsCancellation: Bool = true,
        loadMs: Double = 0,
        physFootprintBytes: UInt64 = 0
    ) {
        self.modelPath = modelPath
        self.roles = roles
        self.arch = arch
        self.variant = variant
        self.backend = backend
        self.nativeSampleRate = nativeSampleRate
        self.maxAudioMs = maxAudioMs
        self.languages = languages
        self.supportsLanguageDetect = supportsLanguageDetect
        self.supportsStreaming = supportsStreaming
        self.supportsVocabulary = supportsVocabulary
        self.supportsContextPrompt = supportsContextPrompt
        self.supportsInitialPrompt = supportsInitialPrompt
        self.supportsPnc = supportsPnc
        self.supportsItn = supportsItn
        self.supportsCancellation = supportsCancellation
        self.loadMs = loadMs
        self.physFootprintBytes = physFootprintBytes
    }

    enum CodingKeys: String, CodingKey {
        case modelPath, roles, arch, variant, backend, nativeSampleRate, maxAudioMs, languages
        case supportsLanguageDetect, supportsStreaming, supportsVocabulary, supportsContextPrompt
        case supportsInitialPrompt, supportsPnc, supportsItn, supportsCancellation
        case loadMs, physFootprintBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? "unknown"
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? ""
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        nativeSampleRate = try c.decodeIfPresent(Int.self, forKey: .nativeSampleRate) ?? LiteDictateConstants.defaultSampleRate
        maxAudioMs = try c.decodeIfPresent(Int.self, forKey: .maxAudioMs) ?? LiteDictateConstants.defaultMaxAudioMs
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        supportsLanguageDetect = try c.decodeIfPresent(Bool.self, forKey: .supportsLanguageDetect) ?? false
        supportsStreaming = try c.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? false
        supportsVocabulary = try c.decodeIfPresent(Bool.self, forKey: .supportsVocabulary) ?? false
        supportsContextPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsContextPrompt) ?? false
        supportsInitialPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsInitialPrompt) ?? false
        supportsPnc = try c.decodeIfPresent(Bool.self, forKey: .supportsPnc) ?? false
        supportsItn = try c.decodeIfPresent(Bool.self, forKey: .supportsItn) ?? false
        supportsCancellation = try c.decodeIfPresent(Bool.self, forKey: .supportsCancellation) ?? true
        loadMs = try c.decodeIfPresent(Double.self, forKey: .loadMs) ?? 0
        physFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .physFootprintBytes) ?? 0
    }

    public func toModelCapabilities() -> ModelCapabilities {
        ModelCapabilities(
            arch: arch,
            variant: variant,
            roles: roles,
            nativeSampleRate: nativeSampleRate,
            maxAudioMs: maxAudioMs,
            languages: languages,
            supportsLanguageDetect: supportsLanguageDetect,
            supportsStreaming: supportsStreaming,
            supportsVocabulary: supportsVocabulary,
            supportsContextPrompt: supportsContextPrompt,
            supportsInitialPrompt: supportsInitialPrompt,
            supportsPnc: supportsPnc,
            supportsItn: supportsItn,
            supportsCancellation: supportsCancellation
        )
    }
}

public struct LDPReadyPayload: Codable, Equatable, Sendable {
    public let modelPath: String
    public let roles: [String]
    public let arch: String
    public let variant: String
    public let backend: String?
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
    public let backendInitMs: Double
    public let loadMs: Double
    public let physFootprintBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case modelPath, roles, arch, variant, backend, nativeSampleRate, maxAudioMs, languages
        case supportsLanguageDetect, supportsStreaming, supportsVocabulary, supportsContextPrompt
        case supportsInitialPrompt, supportsPnc, supportsItn, supportsCancellation
        case backendInitMs, loadMs, physFootprintBytes
    }

    public init(
        modelPath: String,
        roles: [String] = ["asr"],
        arch: String = "unknown",
        variant: String = "",
        backend: String? = "metal",
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
        supportsCancellation: Bool = true,
        backendInitMs: Double = 0,
        loadMs: Double = 0,
        physFootprintBytes: UInt64 = 0
    ) {
        self.modelPath = modelPath
        self.roles = roles
        self.arch = arch
        self.variant = variant
        self.backend = backend
        self.nativeSampleRate = nativeSampleRate
        self.maxAudioMs = maxAudioMs
        self.languages = languages
        self.supportsLanguageDetect = supportsLanguageDetect
        self.supportsStreaming = supportsStreaming
        self.supportsVocabulary = supportsVocabulary
        self.supportsContextPrompt = supportsContextPrompt
        self.supportsInitialPrompt = supportsInitialPrompt
        self.supportsPnc = supportsPnc
        self.supportsItn = supportsItn
        self.supportsCancellation = supportsCancellation
        self.backendInitMs = backendInitMs
        self.loadMs = loadMs
        self.physFootprintBytes = physFootprintBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? ["asr"]
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? "unknown"
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? ""
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        nativeSampleRate = try c.decodeIfPresent(Int.self, forKey: .nativeSampleRate) ?? LiteDictateConstants.defaultSampleRate
        maxAudioMs = try c.decodeIfPresent(Int.self, forKey: .maxAudioMs) ?? LiteDictateConstants.defaultMaxAudioMs
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        supportsLanguageDetect = try c.decodeIfPresent(Bool.self, forKey: .supportsLanguageDetect) ?? false
        supportsStreaming = try c.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? false
        supportsVocabulary = try c.decodeIfPresent(Bool.self, forKey: .supportsVocabulary) ?? false
        supportsContextPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsContextPrompt) ?? false
        supportsInitialPrompt = try c.decodeIfPresent(Bool.self, forKey: .supportsInitialPrompt) ?? false
        supportsPnc = try c.decodeIfPresent(Bool.self, forKey: .supportsPnc) ?? false
        supportsItn = try c.decodeIfPresent(Bool.self, forKey: .supportsItn) ?? false
        supportsCancellation = try c.decodeIfPresent(Bool.self, forKey: .supportsCancellation) ?? true
        backendInitMs = try c.decodeIfPresent(Double.self, forKey: .backendInitMs) ?? 0
        loadMs = try c.decodeIfPresent(Double.self, forKey: .loadMs) ?? 0
        physFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .physFootprintBytes) ?? 0
    }

    public func toModelCapabilities() -> ModelCapabilities {
        ModelCapabilities(
            arch: arch,
            variant: variant,
            roles: roles,
            nativeSampleRate: nativeSampleRate,
            maxAudioMs: maxAudioMs,
            languages: languages,
            supportsLanguageDetect: supportsLanguageDetect,
            supportsStreaming: supportsStreaming,
            supportsVocabulary: supportsVocabulary,
            supportsContextPrompt: supportsContextPrompt,
            supportsInitialPrompt: supportsInitialPrompt,
            supportsPnc: supportsPnc,
            supportsItn: supportsItn,
            supportsCancellation: supportsCancellation
        )
    }
}

public struct LDPTranscribeMetadata: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let language: String
    public let vocabulary: [String]?
    public let contextPrompt: String?
    public let nThreads: Int
    public let nCtx: Int
    public let pnc: String
    public let itn: String

    public init(
        sampleRate: Int = LiteDictateConstants.defaultSampleRate,
        language: String = "auto",
        vocabulary: [String]? = nil,
        contextPrompt: String? = nil,
        nThreads: Int = 4,
        nCtx: Int = 2048,
        pnc: String = "default",
        itn: String = "default"
    ) {
        self.sampleRate = sampleRate
        self.language = language
        self.vocabulary = vocabulary
        self.contextPrompt = contextPrompt
        self.nThreads = nThreads
        self.nCtx = nCtx
        self.pnc = pnc
        self.itn = itn
    }
}

public struct LDPResultPayload: Codable, Equatable, Sendable {
    public let text: String
    public let rawText: String?
    public let detectedLanguage: String?
    public let wasTruncated: Bool
    public let wasAborted: Bool
    public let sessionInitMs: Double
    public let melMs: Double
    public let encodeMs: Double
    public let decodeMs: Double
    public let totalInferenceMs: Double
    public let peakFootprintBytes: UInt64
    public let postFreeFootprintBytes: UInt64

    public init(
        text: String,
        rawText: String? = nil,
        detectedLanguage: String? = nil,
        wasTruncated: Bool = false,
        wasAborted: Bool = false,
        sessionInitMs: Double = 0,
        melMs: Double = 0,
        encodeMs: Double = 0,
        decodeMs: Double = 0,
        totalInferenceMs: Double = 0,
        peakFootprintBytes: UInt64 = 0,
        postFreeFootprintBytes: UInt64 = 0
    ) {
        self.text = text
        self.rawText = rawText
        self.detectedLanguage = detectedLanguage
        self.wasTruncated = wasTruncated
        self.wasAborted = wasAborted
        self.sessionInitMs = sessionInitMs
        self.melMs = melMs
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.totalInferenceMs = totalInferenceMs
        self.peakFootprintBytes = peakFootprintBytes
        self.postFreeFootprintBytes = postFreeFootprintBytes
    }

    enum CodingKeys: String, CodingKey {
        case text, rawText, detectedLanguage, wasTruncated, wasAborted
        case sessionInitMs, melMs, encodeMs, decodeMs, totalInferenceMs
        case peakFootprintBytes, postFreeFootprintBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        detectedLanguage = try c.decodeIfPresent(String.self, forKey: .detectedLanguage)
        wasTruncated = try c.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
        wasAborted = try c.decodeIfPresent(Bool.self, forKey: .wasAborted) ?? false
        sessionInitMs = try c.decodeIfPresent(Double.self, forKey: .sessionInitMs) ?? 0
        melMs = try c.decodeIfPresent(Double.self, forKey: .melMs) ?? 0
        encodeMs = try c.decodeIfPresent(Double.self, forKey: .encodeMs) ?? 0
        decodeMs = try c.decodeIfPresent(Double.self, forKey: .decodeMs) ?? 0
        totalInferenceMs = try c.decodeIfPresent(Double.self, forKey: .totalInferenceMs) ?? 0
        peakFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .peakFootprintBytes) ?? 0
        postFreeFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .postFreeFootprintBytes) ?? 0
    }
}

public struct LDPCancelledPayload: Codable, Equatable, Sendable {
    public let stage: String
    public let postFreeFootprintBytes: UInt64

    public init(stage: String = "unknown", postFreeFootprintBytes: UInt64 = 0) {
        self.stage = stage
        self.postFreeFootprintBytes = postFreeFootprintBytes
    }

    enum CodingKeys: String, CodingKey {
        case stage, postFreeFootprintBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "unknown"
        postFreeFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .postFreeFootprintBytes) ?? 0
    }
}

public struct LDPByePayload: Codable, Equatable, Sendable {
    public let physFootprintBytes: UInt64

    public init(physFootprintBytes: UInt64 = 0) {
        self.physFootprintBytes = physFootprintBytes
    }
}

public struct LDPPongPayload: Codable, Equatable, Sendable {
    public let busy: Bool
    public let modelLoaded: Bool
    public let physFootprintBytes: UInt64

    public init(busy: Bool, modelLoaded: Bool, physFootprintBytes: UInt64) {
        self.busy = busy
        self.modelLoaded = modelLoaded
        self.physFootprintBytes = physFootprintBytes
    }
}

public struct LDPErrorPayload: Codable, Equatable, Sendable {
    public let code: UInt32
    public let codeName: String?
    public let message: String
    public let nativeStatus: Int?
    public let roles: [String]?
    public let arch: String?
    public let variant: String?

    public var errorCode: LDPErrorCode? {
        LDPErrorCode(rawValue: code)
    }

    public init(
        code: UInt32,
        codeName: String? = nil,
        message: String,
        nativeStatus: Int? = nil,
        roles: [String]? = nil,
        arch: String? = nil,
        variant: String? = nil
    ) {
        self.code = code
        self.codeName = codeName
        self.message = message
        self.nativeStatus = nativeStatus
        self.roles = roles
        self.arch = arch
        self.variant = variant
    }

    enum CodingKeys: String, CodingKey {
        case code, codeName, message, nativeStatus, roles, arch, variant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(UInt32.self, forKey: .code) ?? LDPErrorCode.internalError.rawValue
        codeName = try c.decodeIfPresent(String.self, forKey: .codeName)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? "Worker error"
        nativeStatus = try c.decodeIfPresent(Int.self, forKey: .nativeStatus)
        roles = try c.decodeIfPresent([String].self, forKey: .roles)
        arch = try c.decodeIfPresent(String.self, forKey: .arch)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
    }
}

// MARK: - Frame Codec & FD I/O

public enum LDPProtocolClient {
    private static let ignoreSIGPIPEOnce: Void = {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
    }()

    public static func ensureSIGPIPEIgnored() {
        _ = ignoreSIGPIPEOnce
    }

    public static func makeJSONFrame<T: Encodable>(
        msgType: LDPMessageType,
        requestID: UInt64 = 0,
        attemptID: UInt64 = 0,
        statusOrFlags: UInt32 = 0,
        body: T
    ) throws -> LDPFrame {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(body)
        guard payload.count <= LiteDictateConstants.maxFrameBytes else {
            throw LDPProtocolError.payloadTooLarge(UInt32(payload.count))
        }
        let header = LDPFrameHeader(
            msgType: msgType,
            requestID: requestID,
            attemptID: attemptID,
            payloadLen: UInt32(payload.count),
            statusOrFlags: statusOrFlags
        )
        return LDPFrame(header: header, payload: payload)
    }

    public static func makeEmptyFrame(
        msgType: LDPMessageType,
        requestID: UInt64 = 0,
        attemptID: UInt64 = 0,
        statusOrFlags: UInt32 = 0
    ) -> LDPFrame {
        LDPFrame(
            header: LDPFrameHeader(
                msgType: msgType,
                requestID: requestID,
                attemptID: attemptID,
                payloadLen: 0,
                statusOrFlags: statusOrFlags
            ),
            payload: Data()
        )
    }

    /// Encodes `0x02 TRANSCRIBE` payload:
    /// `[0..3] uint32 meta_json_len (LE)`
    /// `[4..7] uint32 sample_count (LE)`
    /// `[8..8+meta_json_len-1] UTF-8 JSON`
    /// `0..3 zero padding bytes to 4-byte boundary`
    /// `[pcm_offset..] raw LE IEEE-754 float32 mono PCM`
    public static func makeTranscribeFrame(
        requestID: UInt64,
        attemptID: UInt64,
        metadata: LDPTranscribeMetadata,
        pcm: PCMStore,
        maxSamples: Int? = nil
    ) throws -> LDPFrame {
        if let vocab = metadata.vocabulary, vocab.count > LiteDictateConstants.maxVocabEntries {
            throw LDPProtocolError.tooManyVocabularyEntries(vocab.count)
        }
        let sampleCount = maxSamples.map { min(max(0, $0), pcm.totalSampleCount) } ?? pcm.totalSampleCount
        guard sampleCount > 0 else {
            throw LDPProtocolError.emptyAudioPayload
        }

        // Reject NaN/Inf strictly per Section 7.2
        var checked = 0
        for chunk in pcm.chunks {
            if checked >= sampleCount { break }
            let take = min(chunk.count, sampleCount - checked)
            for i in 0..<take {
                if !chunk[i].isFinite {
                    throw LDPProtocolError.nonFiniteAudioSamples
                }
            }
            checked += take
        }

        let metaData = try JSONEncoder().encode(metadata)
        let metaLen = metaData.count
        let paddedHeaderPlusMeta = (8 + metaLen + 3) & ~3
        let paddingLen = paddedHeaderPlusMeta - (8 + metaLen)
        let pcmByteCount = sampleCount * MemoryLayout<Float>.size
        let totalPayloadLen = paddedHeaderPlusMeta + pcmByteCount

        guard totalPayloadLen <= LiteDictateConstants.maxFrameBytes else {
            throw LDPProtocolError.payloadTooLarge(UInt32(min(totalPayloadLen, Int(UInt32.max))))
        }

        var payload = Data(capacity: totalPayloadLen)
        var metaLenLE = UInt32(metaLen).littleEndian
        var sampleCountLE = UInt32(sampleCount).littleEndian
        withUnsafeBytes(of: &metaLenLE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &sampleCountLE) { payload.append(contentsOf: $0) }
        payload.append(metaData)
        if paddingLen > 0 {
            payload.append(Data(count: paddingLen))
        }
        payload.append(pcm.contiguousFloatData(maxSamples: sampleCount))

        let header = LDPFrameHeader(
            msgType: .transcribe,
            requestID: requestID,
            attemptID: attemptID,
            payloadLen: UInt32(payload.count),
            statusOrFlags: 0
        )
        return LDPFrame(header: header, payload: payload)
    }

    /// Decodes a `0x02 TRANSCRIBE` payload (primarily for tests & protocol verification).
    public static func decodeTranscribePayload(_ payload: Data) throws -> (metadata: LDPTranscribeMetadata, samples: [Float]) {
        guard payload.count >= 8 else {
            throw LDPProtocolError.invalidJSONPayload("Payload shorter than 8 bytes")
        }
        var metaLenRaw: UInt32 = 0
        var sampleCountRaw: UInt32 = 0
        payload.withUnsafeBytes { raw in
            memcpy(&metaLenRaw, raw.baseAddress!, 4)
            memcpy(&sampleCountRaw, raw.baseAddress!.advanced(by: 4), 4)
        }
        let metaLen = Int(UInt32(littleEndian: metaLenRaw))
        let sampleCount = Int(UInt32(littleEndian: sampleCountRaw))
        let pcmOffset = (8 + metaLen + 3) & ~3
        let expectedLen = pcmOffset + sampleCount * MemoryLayout<Float>.size
        guard payload.count == expectedLen else {
            throw LDPProtocolError.invalidJSONPayload("Payload length mismatch: got \(payload.count), expected \(expectedLen)")
        }

        let metaSlice = payload.subdata(in: 8..<(8 + metaLen))
        let metadata = try JSONDecoder().decode(LDPTranscribeMetadata.self, from: metaSlice)

        var samples = [Float](repeating: 0, count: sampleCount)
        payload.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: pcmOffset)
            for i in 0..<sampleCount {
                var bits: UInt32 = 0
                memcpy(&bits, base.advanced(by: i * 4), 4)
                samples[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return (metadata, samples)
    }

    public static func decodeJSONPayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LDPProtocolError.invalidJSONPayload(error.localizedDescription)
        }
    }

    /// Writes `frame` to `fd`, handling `EINTR` and short writes safely (with `SIGPIPE` ignored).
    public static func writeFrame(_ frame: LDPFrame, to fd: Int32) throws {
        ensureSIGPIPEIgnored()
        let headerData = frame.header.encode()
        try writeAll(headerData, to: fd)
        if !frame.payload.isEmpty {
            try writeAll(frame.payload, to: fd)
        }
    }

    /// Reads one full `LDPFrame` from `fd`, handling `EINTR` and short reads safely.
    public static func readFrame(from fd: Int32) throws -> LDPFrame {
        ensureSIGPIPEIgnored()
        let headerBytes = try readExact(count: LDPFrameHeader.byteSize, from: fd)
        let header = try LDPFrameHeader.decode(headerBytes)
        let payloadLen = Int(header.payloadLen)
        let payload = payloadLen > 0 ? try readExact(count: payloadLen, from: fd) : Data()
        return LDPFrame(header: header, payload: payload)
    }

    public static func writeAll(_ data: Data, to fd: Int32) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = data.count
            while offset < total {
                let written = Darwin.write(fd, base.advanced(by: offset), total - offset)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    throw LDPProtocolError.eof
                } else {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    throw LDPProtocolError.ioFailure(errno: err)
                }
            }
        }
    }

    public static func readExact(count: Int, from fd: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n > 0 {
                    offset += n
                } else if n == 0 {
                    throw LDPProtocolError.eof
                } else {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    throw LDPProtocolError.ioFailure(errno: err)
                }
            }
        }
        return data
    }
}
