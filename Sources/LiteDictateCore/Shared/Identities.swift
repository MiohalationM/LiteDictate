import Foundation

public typealias RequestID = UInt64
public typealias CaptureGeneration = UInt64
public typealias WorkerGeneration = UInt64
public typealias AttemptID = UInt64
public typealias GestureGeneration = UInt64

/// Identifies a specific audio capture session bound to a request.
public struct CaptureIdentity: Hashable, Codable, Sendable {
    public let requestID: RequestID
    public let captureGeneration: CaptureGeneration

    public init(requestID: RequestID, captureGeneration: CaptureGeneration) {
        self.requestID = requestID
        self.captureGeneration = captureGeneration
    }
}

/// Three-key inference generation token preventing stale worker results from ever committing.
public struct InferenceIdentity: Hashable, Codable, Sendable {
    public let requestID: RequestID
    public let workerGeneration: WorkerGeneration
    public let attemptID: AttemptID

    public init(requestID: RequestID, workerGeneration: WorkerGeneration, attemptID: AttemptID) {
        self.requestID = requestID
        self.workerGeneration = workerGeneration
        self.attemptID = attemptID
    }
}

public enum LiteDictateConstants {
    /// Synthetic Cmd+V CGEventSource userData marker ("LDIC").
    public static let syntheticEventUserData: Int64 = 0x4C444943
    public static let ldpMagicBytes: [UInt8] = [0x4C, 0x44, 0x50, 0x31] // "LDP1"
    public static let ldpVersion: UInt16 = 1
    public static let ldpHeaderSize: Int = 32
    public static let maxFrameBytes: Int = 8 * 1024 * 1024

    public static let defaultSampleRate: Int = 16_000
    public static let defaultMaxAudioMs: Int = 30_000
    public static let defaultCaptureLimitMs: Int = 29_500
    public static let minCaptureLimitMs: Int = 5_000
    public static let shortUtteranceMinDurationMs: Int = 120
    public static let shortUtteranceMinPeakDBFS: Float = -62.0

    public static let maxVocabEntries: Int = 50
    public static let toggleCooldownMs: Int = 600
    public static let preCommitHIDWaitMaxMs: Int = 2_000
    public static let defaultPasteRestoreDelayMs: Int = 550
    public static let minPasteRestoreDelayMs: Int = 200
    public static let maxPasteRestoreDelayMs: Int = 700
    public static let clipboardSnapshotBudgetBytes: Int = 8 * 1024 * 1024

    public static let warmTTLSeconds: TimeInterval = 60.0
    public static let failedPCMRetentionSeconds: TimeInterval = 60.0
    public static let recoveryTextRetentionSeconds: TimeInterval = 300.0
    public static let axMessagingTimeoutSeconds: Float = 0.15
    public static let workerCriticalKillDeadlineMs: Int = 500
    public static let workerLogRingBufferBytes: Int = 256 * 1024
}
