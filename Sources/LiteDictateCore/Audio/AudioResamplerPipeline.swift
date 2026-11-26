import AudioToolbox
import CLiteDictateAudio
import Foundation

/// Consumer-thread DSP pipeline:
/// 1. Multi-channel pre-downmix (`Nch hwSampleRate -> 1ch hwSampleRate`) via Accelerate `vDSP`
///    active-channel RMS energy tracking (eliminates >2ch converter errors & -6 dB unused-channel drop).
/// 2. `AudioConverter` resampling (`1ch hwSampleRate -> 1ch targetSampleRate`), distinguishing
///    temporary ring starvation (`kLiteDictateAudioNoDataNow`, preserves FIR filter state) from
///    true EOS (`0` packets + `noErr`, flushes filter tail frames).
/// 3. Chunked `PCMStore` accumulation with hard sample clamping to `min(maxSamplesForModel, captureLimitSamples)`.
public final class AudioResamplerPipeline {
    public static let minTargetSampleRate: Int = 8_000
    public static let maxTargetSampleRate: Int = 48_000
    public static let minCaptureLimitMs: Int = LiteDictateConstants.minCaptureLimitMs // 5_000
    public static let maxCaptureLimitMs: Int = LiteDictateConstants.defaultCaptureLimitMs // 29_500
    public static let maxAllowedSamples: Int = 29_500 * 48 // 1_416_000 (29.5s @ 48 kHz)

    public let hardwareChannels: Int
    public let hardwareSampleRate: Double
    public let targetSampleRate: Int
    public let maxOutputSamples: Int

    public private(set) var pcmStore: PCMStore
    public private(set) var truncatedByLimit: Bool = false
    public private(set) var peakLinear: Float = 0.0
    public private(set) var starvationReturnCount: Int = 0
    public private(set) var eosFlushedSampleCount: Int = 0

    private let downmixer: OpaquePointer
    private var converter: AudioConverterRef?
    private let requiresResampling: Bool

    private var monoWorkBuffer: [Float]
    private var stagedMono: [Float]
    private var outputWorkBuffer: [Float]

    public var totalOutputSamples: Int {
        pcmStore.totalSampleCount
    }

    public var lastDownmixWeights: [Float] {
        var weights = [Float](repeating: 0, count: hardwareChannels)
        _ = weights.withUnsafeMutableBufferPointer { buf in
            ld_predownmixer_get_last_weights(downmixer, buf.baseAddress!, UInt32(hardwareChannels))
        }
        return weights
    }

    /// Validates `targetSampleRate` into `8_000...48_000`, falling back to `16_000` if invalid/out-of-range.
    public static func sanitizeTargetSampleRate(_ sampleRate: Int) -> Int {
        guard (minTargetSampleRate...maxTargetSampleRate).contains(sampleRate) else {
            return LiteDictateConstants.defaultSampleRate
        }
        return sampleRate
    }

    /// Clamps `captureLimitMs` strictly into `5_000...29_500`.
    public static func sanitizeCaptureLimitMs(_ limitMs: Int) -> Int {
        min(maxCaptureLimitMs, max(minCaptureLimitMs, limitMs))
    }

    /// Clamps `maxSamplesForModel` strictly into `1...(29_500 * 48)`.
    public static func sanitizeMaxSamples(_ maxSamples: Int) -> Int {
        min(maxAllowedSamples, max(1, maxSamples))
    }

    /// Returns a validated & bounded copy of `AudioCaptureParameters` safe against untrusted GGUF metadata.
    public static func sanitizedParameters(_ parameters: AudioCaptureParameters) -> AudioCaptureParameters {
        let safeRate = sanitizeTargetSampleRate(parameters.targetSampleRate)
        let safeLimitMs = sanitizeCaptureLimitMs(parameters.captureLimitMs)
        let safeMaxSamples = sanitizeMaxSamples(parameters.maxSamplesForModel)
        return AudioCaptureParameters(
            targetSampleRate: safeRate,
            captureLimitMs: safeLimitMs,
            maxSamplesForModel: safeMaxSamples,
            selectionMode: parameters.selectionMode
        )
    }

    public init(
        hardwareChannels: Int,
        hardwareSampleRate: Double,
        targetSampleRate: Int = LiteDictateConstants.defaultSampleRate,
        maxOutputSamples: Int
    ) throws {
        let clampedChannels = max(1, min(hardwareChannels, Int(LD_AUDIO_MAX_CHANNELS)))
        guard hardwareSampleRate.isFinite, hardwareSampleRate > 0 else {
            throw AudioPipelineError.invalidFormat("Invalid hardware sample rate \(hardwareSampleRate)")
        }
        let safeTargetSampleRate = Self.sanitizeTargetSampleRate(targetSampleRate)
        let safeMaxOutputSamples = Self.sanitizeMaxSamples(maxOutputSamples)

        guard let mixer = ld_predownmixer_create(UInt32(clampedChannels)) else {
            throw AudioPipelineError.allocationFailed("Failed to allocate LDPreDownmixer")
        }

        self.hardwareChannels = clampedChannels
        self.hardwareSampleRate = hardwareSampleRate
        self.targetSampleRate = safeTargetSampleRate
        self.maxOutputSamples = safeMaxOutputSamples
        self.pcmStore = PCMStore(sampleRate: safeTargetSampleRate)
        self.downmixer = mixer
        self.requiresResampling = abs(hardwareSampleRate - Double(safeTargetSampleRate)) >= 0.5
        self.monoWorkBuffer = [Float](repeating: 0, count: 4096)
        self.stagedMono = []
        self.stagedMono.reserveCapacity(8192)
        self.outputWorkBuffer = [Float](repeating: 0, count: 4096)

        if self.requiresResampling {
            var inASBD = Self.makeMonoFloat32ASBD(sampleRate: hardwareSampleRate)
            var outASBD = Self.makeMonoFloat32ASBD(sampleRate: Double(safeTargetSampleRate))
            var createdConverter: AudioConverterRef?
            let status = AudioConverterNew(&inASBD, &outASBD, &createdConverter)
            guard status == noErr, let createdConverter else {
                ld_predownmixer_destroy(mixer)
                throw AudioPipelineError.converterCreationFailed(status)
            }
            var quality = UInt32(kAudioConverterQuality_High)
            AudioConverterSetProperty(
                createdConverter,
                kAudioConverterSampleRateConverterQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &quality
            )
            self.converter = createdConverter
        }
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        ld_predownmixer_destroy(downmixer)
    }

    /// Processes interleaved hardware frames (`frameCount * hardwareChannels` floats).
    /// Returns `true` if `maxOutputSamples` has been reached (caller should trigger stop/truncation).
    @discardableResult
    public func appendInterleaved(
        _ interleaved: UnsafePointer<Float>,
        frameCount: Int
    ) -> Bool {
        guard frameCount > 0 else { return truncatedByLimit }
        if truncatedByLimit { return true }

        if monoWorkBuffer.count < frameCount {
            monoWorkBuffer = [Float](repeating: 0, count: frameCount)
        }

        monoWorkBuffer.withUnsafeMutableBufferPointer { monoBuf in
            _ = ld_predownmixer_process(
                downmixer,
                interleaved,
                monoBuf.baseAddress!,
                UInt32(frameCount)
            )
            if requiresResampling {
                stagedMono.append(contentsOf: UnsafeBufferPointer(start: monoBuf.baseAddress!, count: frameCount))
            } else {
                appendOutputSamples(UnsafeBufferPointer(start: monoBuf.baseAddress!, count: frameCount))
            }
        }

        if requiresResampling {
            drainConverter(isEOS: false)
        }

        return truncatedByLimit
    }

    /// Convenience array overload for deterministic unit tests.
    @discardableResult
    public func appendInterleaved(_ interleaved: [Float]) -> Bool {
        let frames = interleaved.count / hardwareChannels
        guard frames > 0 else { return truncatedByLimit }
        return interleaved.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return truncatedByLimit }
            return appendInterleaved(base, frameCount: frames)
        }
    }

    /// Flushes true EOS tail frames (`0` packets + `noErr`), hard-clamps to `maxOutputSamples`,
    /// and returns the frozen chunked `PCMStore`.
    public func finishEOS() -> PCMStore {
        if requiresResampling && !truncatedByLimit {
            let beforeFlush = pcmStore.totalSampleCount
            drainConverter(isEOS: true)
            eosFlushedSampleCount = max(0, pcmStore.totalSampleCount - beforeFlush)
        }

        if pcmStore.totalSampleCount > maxOutputSamples {
            pcmStore.clamp(maxSamples: maxOutputSamples)
            truncatedByLimit = true
        }
        return pcmStore
    }

    /// Computes final peak in dBFS from the frozen mono `PCMStore`.
    public func finalPeakDBFS() -> Float {
        pcmStore.peakDBFS()
    }

    /// Recall-oriented short-utterance gate (Section 5.2):
    /// Drops ONLY if duration `< 120 ms` OR whole-utterance peak `< -62 dBFS`.
    public static func shouldDropByShortUtteranceGate(
        durationMs: Int,
        peakDBFS: Float
    ) -> Bool {
        durationMs < LiteDictateConstants.shortUtteranceMinDurationMs
            || peakDBFS < LiteDictateConstants.shortUtteranceMinPeakDBFS
    }

    /// Computes effective hard sample limit: `min(maxSamplesForModel, captureLimitSamples)`,
    /// strictly bounded after sanitizing `targetSampleRate`, `captureLimitMs`, and `maxSamplesForModel`.
    public static func effectiveMaxSamples(for parameters: AudioCaptureParameters) -> Int {
        let safe = sanitizedParameters(parameters)
        let captureLimitSamples = Int(
            (Int64(safe.captureLimitMs) * Int64(safe.targetSampleRate)) / 1000
        )
        return max(1, min(safe.maxSamplesForModel, min(maxAllowedSamples, captureLimitSamples)))
    }

    // MARK: - AudioConverter Pull Loop

    private struct ConverterInputState {
        var basePointer: UnsafePointer<Float>?
        var totalFrames: Int
        var consumedFrames: Int
        var isEOS: Bool
    }

    private static let converterInputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData else {
            ioNumberDataPackets.pointee = 0
            return kLiteDictateAudioNoDataNow
        }

        let state = inUserData.assumingMemoryBound(to: ConverterInputState.self)
        let available = state.pointee.totalFrames - state.pointee.consumedFrames
        if available > 0, let base = state.pointee.basePointer {
            let requested = Int(ioNumberDataPackets.pointee)
            let toProvide = min(requested, available)
            let offset = state.pointee.consumedFrames

            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 1
            ioData.pointee.mBuffers.mDataByteSize = UInt32(toProvide * MemoryLayout<Float>.size)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: base.advanced(by: offset))
            ioNumberDataPackets.pointee = UInt32(toProvide)
            state.pointee.consumedFrames += toProvide
            return noErr
        }

        ioNumberDataPackets.pointee = 0
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mDataByteSize = 0
        ioData.pointee.mBuffers.mData = nil

        if state.pointee.isEOS {
            // True end-of-stream: return 0 packets + noErr so AudioConverter flushes FIR tail frames.
            return noErr
        } else {
            // Temporary ring starvation: return custom status to preserve filter state.
            return kLiteDictateAudioNoDataNow
        }
    }

    private func drainConverter(isEOS: Bool) {
        guard let converter else { return }

        var state = ConverterInputState(
            basePointer: nil,
            totalFrames: stagedMono.count,
            consumedFrames: 0,
            isEOS: isEOS
        )

        stagedMono.withUnsafeBufferPointer { stagedBuf in
            state.basePointer = stagedBuf.baseAddress

            while !truncatedByLimit {
                var outPacketCount = UInt32(outputWorkBuffer.count)
                var status: OSStatus = noErr

                outputWorkBuffer.withUnsafeMutableBufferPointer { outBuf in
                    var outABL = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(outBuf.count * MemoryLayout<Float>.size),
                            mData: outBuf.baseAddress
                        )
                    )
                    withUnsafeMutablePointer(to: &state) { statePtr in
                        status = AudioConverterFillComplexBuffer(
                            converter,
                            Self.converterInputProc,
                            statePtr,
                            &outPacketCount,
                            &outABL,
                            nil
                        )
                    }
                }

                let produced = Int(outPacketCount)
                if produced > 0 {
                    outputWorkBuffer.withUnsafeBufferPointer { outBuf in
                        let slice = UnsafeBufferPointer(start: outBuf.baseAddress!, count: produced)
                        appendOutputSamples(slice)
                    }
                }

                if status == kLiteDictateAudioNoDataNow {
                    starvationReturnCount += 1
                    break
                }

                if status != noErr {
                    break
                }

                if produced == 0 {
                    // For isEOS == true, 0 output packets + noErr signals tail flush is complete.
                    break
                }
            }
        }

        if state.consumedFrames > 0 {
            if state.consumedFrames >= stagedMono.count {
                stagedMono.removeAll(keepingCapacity: true)
            } else {
                stagedMono.removeFirst(state.consumedFrames)
            }
        }
    }

    private func appendOutputSamples(_ buffer: UnsafeBufferPointer<Float>) {
        guard !buffer.isEmpty, let base = buffer.baseAddress else { return }
        let remaining = maxOutputSamples - pcmStore.totalSampleCount
        if remaining <= 0 {
            truncatedByLimit = true
            return
        }

        let toTake = min(remaining, buffer.count)
        var chunkPeak: Float = 0.0
        ld_audio_measure_mono(base, UInt32(toTake), &chunkPeak, nil)
        if chunkPeak > peakLinear {
            peakLinear = chunkPeak
        }

        pcmStore.append(UnsafeBufferPointer(start: base, count: toTake))
        if pcmStore.totalSampleCount >= maxOutputSamples {
            truncatedByLimit = true
        }
    }

    private static func makeMonoFloat32ASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

public enum AudioPipelineError: Error, LocalizedError, CustomDebugStringConvertible, Sendable {
    case invalidFormat(String)
    case allocationFailed(String)
    case converterCreationFailed(OSStatus)
    case audioUnitFailed(String, OSStatus)

    /// Consumer-friendly Chinese error message (never exposes raw `OSStatus` or internal CoreAudio jargon).
    public var userFacingMessage: String {
        switch self {
        case .invalidFormat:
            return "当前麦克风音频参数异常，请重新连接设备或更换麦克风。"
        case .allocationFailed:
            return "录音初始化失败，请稍后重试。"
        case .converterCreationFailed:
            return "音频格式初始化失败，请切换麦克风或稍后重试。"
        case .audioUnitFailed:
            return "无法启动麦克风，请检查系统麦克风权限或设备连接。"
        }
    }

    public var errorDescription: String? {
        userFacingMessage
    }

    /// Internal diagnostic description containing step name and raw `OSStatus` (never shown directly to users).
    public var debugDescription: String {
        switch self {
        case .invalidFormat(let msg): return "InvalidFormat(\(msg))"
        case .allocationFailed(let msg): return "AllocationFailed(\(msg))"
        case .converterCreationFailed(let status): return "AudioConverterNew failed with OSStatus \(status)"
        case .audioUnitFailed(let step, let status): return "AUHAL \(step) failed with OSStatus \(status)"
        }
    }
}
