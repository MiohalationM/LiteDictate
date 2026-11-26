import Foundation

public enum AudioTransportKind: String, Codable, Hashable, Sendable {
    case usb
    case builtIn
    case bluetooth
    case continuity
    case virtual
    case other

    public var displayBadge: String {
        switch self {
        case .usb: return "USB"
        case .builtIn: return "内置"
        case .bluetooth: return "蓝牙"
        case .continuity: return "iPhone"
        case .virtual: return "虚拟"
        case .other: return "其他"
        }
    }
}

public struct AudioDeviceInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let transportKind: AudioTransportKind
    public let inputChannelCount: Int
    public let nominalSampleRate: Double

    public var isBluetoothHFPWarning: Bool {
        transportKind == .bluetooth
    }

    public var isEligibleForSmartAuto: Bool {
        transportKind == .usb || transportKind == .builtIn
    }

    public init(
        uid: String,
        name: String,
        transportKind: AudioTransportKind,
        inputChannelCount: Int,
        nominalSampleRate: Double
    ) {
        self.uid = uid
        self.name = name
        self.transportKind = transportKind
        self.inputChannelCount = inputChannelCount
        self.nominalSampleRate = nominalSampleRate
    }
}

public enum AudioSelectionMode: Codable, Hashable, Sendable {
    case smartAuto
    case pinned(deviceUID: String)
}

public struct AudioDeviceResolution: Equatable, Sendable {
    public let device: AudioDeviceInfo?
    public let didFallbackFromPinned: Bool
    public let fallbackNotice: String?
    public let isBluetoothHFPWarning: Bool

    public init(
        device: AudioDeviceInfo?,
        didFallbackFromPinned: Bool = false,
        fallbackNotice: String? = nil,
        isBluetoothHFPWarning: Bool = false
    ) {
        self.device = device
        self.didFallbackFromPinned = didFallbackFromPinned
        self.fallbackNotice = fallbackNotice
        self.isBluetoothHFPWarning = isBluetoothHFPWarning
    }
}

/// Chunked mono Float32 PCM buffer (1-second chunks = 64 KB at 16 kHz) bounded under 2 MB.
public struct PCMStore: Sendable, Equatable {
    public let sampleRate: Int
    public private(set) var chunks: [[Float]]
    public private(set) var totalSampleCount: Int

    public var chunkCapacitySamples: Int {
        max(1, sampleRate)
    }

    public var durationMs: Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Int64(totalSampleCount) * 1000) / Int64(sampleRate))
    }

    public var estimatedMemoryBytes: Int {
        totalSampleCount * MemoryLayout<Float>.size
    }

    public var isEmpty: Bool {
        totalSampleCount == 0
    }

    public init(sampleRate: Int = LiteDictateConstants.defaultSampleRate, chunks: [[Float]] = []) {
        self.sampleRate = max(1, sampleRate)
        self.chunks = chunks
        self.totalSampleCount = chunks.reduce(0) { $0 + $1.count }
    }

    public init(sampleRate: Int = LiteDictateConstants.defaultSampleRate, samples: [Float]) {
        self.sampleRate = max(1, sampleRate)
        self.chunks = []
        self.totalSampleCount = 0
        append(samples)
    }

    public mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    public mutating func append(_ buffer: UnsafeBufferPointer<Float>) {
        guard !buffer.isEmpty, let base = buffer.baseAddress else { return }
        let cap = chunkCapacitySamples
        var offset = 0
        let count = buffer.count

        while offset < count {
            if chunks.isEmpty || chunks[chunks.count - 1].count >= cap {
                var newChunk: [Float] = []
                newChunk.reserveCapacity(cap)
                chunks.append(newChunk)
            }
            let lastIdx = chunks.count - 1
            let remainingInChunk = cap - chunks[lastIdx].count
            let toCopy = min(remainingInChunk, count - offset)
            let slice = UnsafeBufferPointer(start: base.advanced(by: offset), count: toCopy)
            chunks[lastIdx].append(contentsOf: slice)
            offset += toCopy
            totalSampleCount += toCopy
        }
    }

    /// Hard-clamps total samples in-place to `maxSamples`.
    public mutating func clamp(maxSamples: Int) {
        let limit = max(0, maxSamples)
        guard totalSampleCount > limit else { return }
        if limit == 0 {
            chunks.removeAll(keepingCapacity: false)
            totalSampleCount = 0
            return
        }
        var kept = 0
        var newChunks: [[Float]] = []
        newChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            if kept >= limit { break }
            let need = limit - kept
            if chunk.count <= need {
                newChunks.append(chunk)
                kept += chunk.count
            } else {
                newChunks.append(Array(chunk.prefix(need)))
                kept += need
                break
            }
        }
        chunks = newChunks
        totalSampleCount = kept
    }

    /// Returns a hard-clamped copy with at most `maxSamples` samples.
    public func clamped(maxSamples: Int) -> PCMStore {
        var copy = self
        copy.clamp(maxSamples: maxSamples)
        return copy
    }

    /// Serializes samples as contiguous little-endian IEEE-754 Float32 bytes (sanitizing non-finite values).
    public func contiguousFloatData(maxSamples: Int? = nil) -> Data {
        let limit = maxSamples.map { min(max(0, $0), totalSampleCount) } ?? totalSampleCount
        guard limit > 0 else { return Data() }
        var data = Data(count: limit * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawOut in
            let outPtr = rawOut.bindMemory(to: UInt32.self)
            var written = 0
            for chunk in chunks {
                if written >= limit { break }
                let take = min(chunk.count, limit - written)
                for i in 0..<take {
                    let s = chunk[i]
                    let safe: Float = s.isFinite ? s : 0.0
                    outPtr[written + i] = safe.bitPattern.littleEndian
                }
                written += take
            }
        }
        return data
    }

    public func flattenedSamples(maxSamples: Int? = nil) -> [Float] {
        let limit = maxSamples.map { min(max(0, $0), totalSampleCount) } ?? totalSampleCount
        guard limit > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(limit)
        var remaining = limit
        for chunk in chunks {
            if remaining <= 0 { break }
            if chunk.count <= remaining {
                out.append(contentsOf: chunk)
                remaining -= chunk.count
            } else {
                out.append(contentsOf: chunk.prefix(remaining))
                remaining = 0
            }
        }
        return out
    }

    public func peakDBFS() -> Float {
        var peak: Float = 0.0
        for chunk in chunks {
            for sample in chunk {
                guard sample.isFinite else { continue }
                let absVal = abs(sample)
                if absVal > peak { peak = absVal }
            }
        }
        guard peak > 1e-9 else { return -120.0 }
        return 20.0 * log10f(peak)
    }
}

public struct AudioCaptureParameters: Equatable, Sendable {
    public let targetSampleRate: Int
    public let captureLimitMs: Int
    public let maxSamplesForModel: Int
    public let selectionMode: AudioSelectionMode

    public init(
        targetSampleRate: Int = LiteDictateConstants.defaultSampleRate,
        captureLimitMs: Int = LiteDictateConstants.defaultCaptureLimitMs,
        maxSamplesForModel: Int? = nil,
        selectionMode: AudioSelectionMode = .smartAuto
    ) {
        self.targetSampleRate = max(8_000, targetSampleRate)
        self.captureLimitMs = max(LiteDictateConstants.minCaptureLimitMs, captureLimitMs)
        let defaultSamples = (self.captureLimitMs * self.targetSampleRate) / 1000
        self.maxSamplesForModel = maxSamplesForModel ?? defaultSamples
        self.selectionMode = selectionMode
    }
}

public struct AudioCaptureResult: Equatable, Sendable {
    public let identity: CaptureIdentity
    public let pcm: PCMStore
    public let durationMs: Int
    public let peakDBFS: Float
    public let audioInterrupted: Bool
    public let droppedFrames: UInt64
    public let truncatedByLimit: Bool
    public let droppedByShortUtteranceGate: Bool
    public let resolvedDeviceName: String?
    public let fallbackNotice: String?

    public init(
        identity: CaptureIdentity,
        pcm: PCMStore,
        durationMs: Int,
        peakDBFS: Float,
        audioInterrupted: Bool,
        droppedFrames: UInt64,
        truncatedByLimit: Bool = false,
        droppedByShortUtteranceGate: Bool = false,
        resolvedDeviceName: String? = nil,
        fallbackNotice: String? = nil
    ) {
        self.identity = identity
        self.pcm = pcm
        self.durationMs = durationMs
        self.peakDBFS = peakDBFS
        self.audioInterrupted = audioInterrupted
        self.droppedFrames = droppedFrames
        self.truncatedByLimit = truncatedByLimit
        self.droppedByShortUtteranceGate = droppedByShortUtteranceGate
        self.resolvedDeviceName = resolvedDeviceName
        self.fallbackNotice = fallbackNotice
    }
}

public enum AudioCaptureEvent: Sendable {
    case captureStarted(identity: CaptureIdentity, deviceName: String, fallbackNotice: String?)
    case firstFrameReceived(identity: CaptureIdentity)
    case speechDetected(identity: CaptureIdentity)
    case levelUpdate(identity: CaptureIdentity, rmsLevel: Float, peakDBFS: Float)
    case captureCompleted(AudioCaptureResult)
    case captureFailed(identity: CaptureIdentity, reason: String)
}

public protocol AudioDeviceManaging: AnyObject, Sendable {
    func availableInputDevices() -> [AudioDeviceInfo]
    func resolveDevice(for mode: AudioSelectionMode) -> AudioDeviceResolution
    func startObservingChanges(_ onChange: @escaping @Sendable ([AudioDeviceInfo]) -> Void)
    func stopObservingChanges()
}

public protocol AudioCapturing: AnyObject, Sendable {
    func startCapture(
        identity: CaptureIdentity,
        parameters: AudioCaptureParameters,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    )
    func stopCapture(identity: CaptureIdentity)
    func cancelCapture(identity: CaptureIdentity)
    func currentMeterLevel() -> Float
}
