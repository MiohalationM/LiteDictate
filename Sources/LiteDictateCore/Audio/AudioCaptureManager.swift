import AudioToolbox
import CLiteDictateAudio
import CoreAudio
import Darwin
import Foundation

/// Hardware lifecycle state of the Input-only AUHAL instance (owned by `audioControlQueue`).
public enum AudioHardwareState: String, Sendable, Equatable {
    case stopped
    case prepared
    case starting
    case running
    case stopping
    case disposed
}

/// Recording pipeline state (strictly separated from `AudioHardwareState`, owned by `audioControlQueue`).
public enum AudioRecordingState: String, Sendable, Equatable {
    case idle
    case capturing
    case quiescing
    case draining
}

/// Prepared Input-only AUHAL handle returned by `AudioUnitBackend`.
internal struct PreparedAudioUnit: @unchecked Sendable {
    let audioUnit: AudioUnit?
    let hardwareChannels: Int
    let hardwareSampleRate: Double
    let maxFramesPerSlice: Int
    let isNonInterleaved: Bool
    let captureContext: OpaquePointer
}

/// Backend abstraction separating real TN2091 Input-only AUHAL calls from deterministic unit tests.
internal protocol AudioUnitBackend: AnyObject, Sendable {
    func prepareInputOnlyAUHAL(deviceID: AudioDeviceID, deviceInfo: AudioDeviceInfo) throws -> PreparedAudioUnit
    func startAUHAL(_ prepared: PreparedAudioUnit) -> OSStatus
    func stopAndDisposeAUHAL(_ prepared: PreparedAudioUnit)
}

/// Production TN2091 Input-only AUHAL backend:
/// - `kAudioUnitSubType_HALOutput`
/// - `EnableIO(input, bus 1) = 1`, `EnableIO(output, bus 0) = 0`
/// - `CurrentDevice = resolvedDeviceID` (NEVER touches output bus or system default input!)
internal final class CoreAudioAUHALBackend: AudioUnitBackend, @unchecked Sendable {
    func prepareInputOnlyAUHAL(deviceID: AudioDeviceID, deviceInfo: AudioDeviceInfo) throws -> PreparedAudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioPipelineError.audioUnitFailed("AudioComponentFindNext(HALOutput)", kAudioUnitErr_InvalidElement)
        }

        var rawAU: AudioUnit?
        var status = AudioComponentInstanceNew(component, &rawAU)
        guard status == noErr, let au = rawAU else {
            throw AudioPipelineError.audioUnitFailed("AudioComponentInstanceNew", status)
        }

        var succeeded = false
        defer {
            if !succeeded {
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
            }
        }

        // Apple TN2091: Enable Input (bus 1) and explicitly disable Output (bus 0) BEFORE CurrentDevice.
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioPipelineError.audioUnitFailed("EnableIO(input, bus 1)", status)
        }

        var enableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioPipelineError.audioUnitFailed("EnableIO(output, bus 0)", status)
        }

        var devID = deviceID
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioPipelineError.audioUnitFailed("SetCurrentDevice", status)
        }

        // Query hardware input stream format (Bus 1, Input Scope).
        var hwFormat = AudioStreamBasicDescription()
        var hwFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hwFormat,
            &hwFormatSize
        )
        guard status == noErr else {
            throw AudioPipelineError.audioUnitFailed("GetStreamFormat(Input, bus 1)", status)
        }

        let rawRate = hwFormat.mSampleRate > 0 ? hwFormat.mSampleRate : deviceInfo.nominalSampleRate
        let hwSampleRate: Double = (rawRate.isFinite && rawRate >= 8_000.0 && rawRate <= 384_000.0) ? rawRate : 48_000.0
        let rawChannels = hwFormat.mChannelsPerFrame > 0 ? Int(hwFormat.mChannelsPerFrame) : max(1, deviceInfo.inputChannelCount)
        let effectiveChannels = max(1, min(rawChannels, Int(LD_AUDIO_MAX_CHANNELS)))

        // If hardware exposes > LD_AUDIO_MAX_CHANNELS (e.g. 64ch virtual bus), map first N channels cleanly.
        if rawChannels > effectiveChannels {
            var channelMap = (0..<effectiveChannels).map { Int32($0) }
            _ = channelMap.withUnsafeMutableBytes { rawBuf in
                AudioUnitSetProperty(
                    au,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    rawBuf.baseAddress!,
                    UInt32(rawBuf.count)
                )
            }
        }

        // Configure client format on Bus 1 Output Scope: native hardware sample rate, Float32.
        // Prefer interleaved (single memcpy into SPSC ring), fall back to non-interleaved if AUHAL requires it.
        var isNonInterleaved = false
        var interleavedASBD = AudioStreamBasicDescription(
            mSampleRate: hwSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(effectiveChannels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(effectiveChannels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(effectiveChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &interleavedASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        if status != noErr {
            isNonInterleaved = true
            var nonInterleavedASBD = AudioStreamBasicDescription(
                mSampleRate: hwSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(effectiveChannels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &nonInterleavedASBD,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else {
                throw AudioPipelineError.audioUnitFailed("SetStreamFormat(Output, bus 1)", status)
            }
        }

        // Determine max frames per slice while capping scratch storage so total RAM remains <= 2.5 MB.
        var maxFrames: UInt32 = 4096
        var maxFramesSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            &maxFramesSize
        )
        let maxScratchBytes = 128 * 1024 // 128 KiB ceiling for scratch ABL
        let maxFramesByBudget = max(512, maxScratchBytes / (effectiveChannels * MemoryLayout<Float>.size))
        let clampedMaxFrames = max(512, min(max(Int(maxFrames), 1024), maxFramesByBudget))

        // Allocate independent C heap LDCaptureContext (ZERO Swift ARC on RT thread).
        guard let ctx = ld_capture_context_create(
            UInt32(effectiveChannels),
            hwSampleRate,
            UInt32(clampedMaxFrames),
            isNonInterleaved,
            2.0,
            Int(LD_AUDIO_DEFAULT_RING_MAX_BYTES)
        ) else {
            throw AudioPipelineError.allocationFailed("ld_capture_context_create returned NULL")
        }

        ld_capture_context_set_audio_unit(ctx, au)

        // Register pure C @convention(c) input callback with C LDCaptureContext* refCon.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: ld_auhal_input_callback,
            inputProcRefCon: UnsafeMutableRawPointer(ctx)
        )
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            ld_capture_context_set_audio_unit(ctx, nil)
            ld_capture_context_destroy(ctx)
            throw AudioPipelineError.audioUnitFailed("SetInputCallback", status)
        }

        status = AudioUnitInitialize(au)
        guard status == noErr else {
            var nullCB = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &nullCB,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            ld_capture_context_set_audio_unit(ctx, nil)
            ld_capture_context_destroy(ctx)
            throw AudioPipelineError.audioUnitFailed("AudioUnitInitialize", status)
        }

        succeeded = true
        return PreparedAudioUnit(
            audioUnit: au,
            hardwareChannels: effectiveChannels,
            hardwareSampleRate: hwSampleRate,
            maxFramesPerSlice: clampedMaxFrames,
            isNonInterleaved: isNonInterleaved,
            captureContext: ctx
        )
    }

    func startAUHAL(_ prepared: PreparedAudioUnit) -> OSStatus {
        guard let au = prepared.audioUnit else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStart(au)
    }

    func stopAndDisposeAUHAL(_ prepared: PreparedAudioUnit) {
        // 1. Stop RT audio ingestion first (quiesce).
        ld_capture_context_set_accept_audio(prepared.captureContext, false)

        guard let au = prepared.audioUnit else { return }

        // 2. Stop AUHAL (waits for any in-progress HAL IO callback to return).
        _ = AudioOutputUnitStop(au)

        // 3. Clear input callback so HAL holds no reference to LDCaptureContext.
        var nullCB = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        _ = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &nullCB,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        // 4. Uninitialize & Dispose AUHAL.
        _ = AudioUnitUninitialize(au)
        _ = AudioComponentInstanceDispose(au)
        ld_capture_context_set_audio_unit(prepared.captureContext, nil)
    }
}

/// Real-time Input-only AUHAL capture manager with:
/// - Strict separation of `AudioHardwareState` and `AudioRecordingState`
/// - Safe `pendingStopAfterStart` handling for in-flight `AudioOutputUnitStart()` cancellation
/// - Dedicated `QOS_CLASS_USER_INITIATED` Consumer pthread with 10 ms monotonic timed wait
/// - Multi-channel `vDSP` pre-downmix + `AudioConverter` resampling + EOS tail flush
/// - Hard sample clamp (`min(maxSamplesForModel, captureLimitSamples)`) & `<120ms`/`<-62dBFS` gate
/// - Independent C `LDCaptureContext` freed ONLY after AUHAL stop + callback clear + Dispose + consumer exit
public final class AudioCaptureManager: AudioCapturing, @unchecked Sendable {
    private enum ConsumerMode: UInt64 {
        case capturing = 0
        case draining = 1
        case cancelled = 2
    }

    private final class ConsumerRunner: @unchecked Sendable {
        let identity: CaptureIdentity
        let captureContext: OpaquePointer
        let waiter: OpaquePointer
        let resampler: AudioResamplerPipeline
        let modeAtom: AtomicUInt64
        let firstFrameEmitted: AtomicBool
        let onFirstFrame: @Sendable () -> Void
        let onLimitReached: @Sendable () -> Void

        // Written exclusively by consumer thread prior to pthread_join; read after pthread_join.
        var frozenPCM: PCMStore
        var peakDBFS: Float = -120.0
        var hitCaptureLimit: Bool = false

        init(
            identity: CaptureIdentity,
            captureContext: OpaquePointer,
            waiter: OpaquePointer,
            resampler: AudioResamplerPipeline,
            firstFrameEmitted: AtomicBool,
            onFirstFrame: @escaping @Sendable () -> Void,
            onLimitReached: @escaping @Sendable () -> Void
        ) {
            self.identity = identity
            self.captureContext = captureContext
            self.waiter = waiter
            self.resampler = resampler
            self.modeAtom = AtomicUInt64(ConsumerMode.capturing.rawValue)
            self.firstFrameEmitted = firstFrameEmitted
            self.onFirstFrame = onFirstFrame
            self.onLimitReached = onLimitReached
            self.frozenPCM = PCMStore(sampleRate: resampler.targetSampleRate)
        }

        func run() {
            let ring = ld_capture_context_ring_buffer(captureContext)
            let channels = Int(ld_capture_context_channels(captureContext))
            let chunkFrames = 2048
            var interleavedBuffer = [Float](repeating: 0, count: chunkFrames * channels)
            var notifiedLimit = false

            while true {
                // Drain all currently buffered ring frames.
                while true {
                    let readFrames: Int = interleavedBuffer.withUnsafeMutableBufferPointer { buf in
                        Int(ld_ring_read_interleaved(ring, buf.baseAddress!, UInt32(chunkFrames)))
                    }
                    if readFrames == 0 {
                        break
                    }

                    // Emit firstFrameReceived with minimal latency as soon as valid PCM arrives.
                    let telemetry = ld_capture_context_read_telemetry(captureContext)
                    if telemetry.first_frame_received {
                        if firstFrameEmitted.compareExchange(expected: false, desired: true) {
                            onFirstFrame()
                        }
                    }

                    let reachedLimit: Bool = interleavedBuffer.withUnsafeBufferPointer { buf in
                        resampler.appendInterleaved(buf.baseAddress!, frameCount: readFrames)
                    }

                    if reachedLimit && !notifiedLimit {
                        notifiedLimit = true
                        hitCaptureLimit = true
                        onLimitReached()
                    }
                }

                let mode = ConsumerMode(rawValue: modeAtom.load(ordering: .acquire)) ?? .capturing
                switch mode {
                case .cancelled:
                    return

                case .draining:
                    // AUHAL is already stopped & disposed prior to entering Draining, so no new
                    // frames can arrive. Perform one final drain check then flush AudioConverter EOS tail.
                    while true {
                        let readFrames: Int = interleavedBuffer.withUnsafeMutableBufferPointer { buf in
                            Int(ld_ring_read_interleaved(ring, buf.baseAddress!, UInt32(chunkFrames)))
                        }
                        if readFrames == 0 { break }
                        _ = interleavedBuffer.withUnsafeBufferPointer { buf in
                            resampler.appendInterleaved(buf.baseAddress!, frameCount: readFrames)
                        }
                    }

                    frozenPCM = resampler.finishEOS()
                    peakDBFS = resampler.finalPeakDBFS()
                    if resampler.truncatedByLimit {
                        hitCaptureLimit = true
                    }
                    return

                case .capturing:
                    // Monotonic 10 ms timed wait; woken immediately by control thread on Draining/Cancel.
                    _ = ld_waiter_wait_ms(waiter, 10)
                }
            }
        }
    }

    private struct PendingStartRequest {
        let identity: CaptureIdentity
        let parameters: AudioCaptureParameters
        let onEvent: @Sendable (AudioCaptureEvent) -> Void
    }

    private final class ActiveSession: @unchecked Sendable {
        let identity: CaptureIdentity
        let parameters: AudioCaptureParameters
        let deviceInfo: AudioDeviceInfo
        let fallbackNotice: String?
        let onEvent: @Sendable (AudioCaptureEvent) -> Void
        let prepared: PreparedAudioUnit
        let waiter: OpaquePointer
        let consumerRunner: ConsumerRunner
        var consumerThread: pthread_t?
        var telemetryTimer: DispatchSourceTimer?
        var safetyTimeoutTimer: DispatchSourceTimer?

        let firstFrameEmitted: AtomicBool
        var speechDetectedEmitted: Bool = false
        var pendingStopAfterStart: Bool = false
        var pendingCancelAfterStart: Bool = false
        var truncatedByLimit: Bool = false

        init(
            identity: CaptureIdentity,
            parameters: AudioCaptureParameters,
            deviceInfo: AudioDeviceInfo,
            fallbackNotice: String?,
            onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void,
            prepared: PreparedAudioUnit,
            waiter: OpaquePointer,
            consumerRunner: ConsumerRunner,
            firstFrameEmitted: AtomicBool
        ) {
            self.identity = identity
            self.parameters = parameters
            self.deviceInfo = deviceInfo
            self.fallbackNotice = fallbackNotice
            self.onEvent = onEvent
            self.prepared = prepared
            self.waiter = waiter
            self.consumerRunner = consumerRunner
            self.firstFrameEmitted = firstFrameEmitted
        }
    }

    private static let consumerThreadEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { raw in
        let runner = Unmanaged<ConsumerRunner>.fromOpaque(raw).takeRetainedValue()
        runner.run()
        return nil
    }

    public let deviceManager: AudioDeviceManager
    public let controlQueue: DispatchQueue
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private let hardwareStartQueue: DispatchQueue
    private let backend: AudioUnitBackend

    // Owned exclusively by `controlQueue`; mirrored to lock-protected snapshots for thread-safe inspection.
    private var _hardwareState: AudioHardwareState = .stopped
    private var _recordingState: AudioRecordingState = .idle
    private var activeSession: ActiveSession?
    private var pendingStart: PendingStartRequest?
    private var deviceObserverID: UUID?

    private let stateMirrorLock = NSLock()
    private var mirroredHardwareState: AudioHardwareState = .stopped
    private var mirroredRecordingState: AudioRecordingState = .idle
    private var mirroredLastStartStatus: OSStatus = noErr
    private let meterLevelBits = AtomicUInt64(0)

    public var hardwareState: AudioHardwareState {
        stateMirrorLock.lock()
        defer { stateMirrorLock.unlock() }
        return mirroredHardwareState
    }

    public var recordingState: AudioRecordingState {
        stateMirrorLock.lock()
        defer { stateMirrorLock.unlock() }
        return mirroredRecordingState
    }

    /// Last internal CoreAudio `OSStatus` from `AudioOutputUnitStart` (for internal debug diagnostics only).
    public var lastInternalStartStatus: OSStatus {
        stateMirrorLock.lock()
        defer { stateMirrorLock.unlock() }
        return mirroredLastStartStatus
    }

    public convenience init(deviceManager: AudioDeviceManager = AudioDeviceManager()) {
        self.init(deviceManager: deviceManager, backend: CoreAudioAUHALBackend())
    }

    internal init(deviceManager: AudioDeviceManager, backend: AudioUnitBackend) {
        self.deviceManager = deviceManager
        self.controlQueue = deviceManager.controlQueue
        self.controlQueue.setSpecific(key: controlQueueKey, value: 1)
        self.hardwareStartQueue = DispatchQueue(
            label: "io.github.litedictate.audio.hwstart",
            qos: .userInitiated
        )
        self.backend = backend

        self.deviceObserverID = deviceManager.addInternalObserver { [weak self] devices in
            self?.handleDevicesChangedOnControlQueue(devices)
        }
    }

    deinit {
        if let observerID = deviceObserverID {
            deviceManager.removeInternalObserver(id: observerID)
        }
        let cleanup: () -> Void = {
            if let session = self.activeSession {
                session.pendingCancelAfterStart = true
                session.pendingStopAfterStart = true
                session.telemetryTimer?.cancel()
                session.telemetryTimer = nil
                session.safetyTimeoutTimer?.cancel()
                session.safetyTimeoutTimer = nil
                if self._hardwareState != .starting {
                    self.finalizeSessionOnControlQueue(session, cancel: true, truncatedByLimit: false)
                } else {
                    self.activeSession = nil
                }
            }
            self.pendingStart = nil
        }
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            cleanup()
        } else {
            controlQueue.sync(execute: cleanup)
        }
    }

    // MARK: - AudioCapturing Protocol

    public func startCapture(
        identity: CaptureIdentity,
        parameters: AudioCaptureParameters,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) {
        controlQueue.async { [weak self] in
            self?.startCaptureOnControlQueue(identity: identity, parameters: parameters, onEvent: onEvent)
        }
    }

    public func stopCapture(identity: CaptureIdentity) {
        controlQueue.async { [weak self] in
            self?.stopCaptureOnControlQueue(identity: identity, cancel: false)
        }
    }

    public func cancelCapture(identity: CaptureIdentity) {
        controlQueue.async { [weak self] in
            self?.stopCaptureOnControlQueue(identity: identity, cancel: true)
        }
    }

    public func currentMeterLevel() -> Float {
        let bits = UInt32(truncatingIfNeeded: meterLevelBits.load(ordering: .relaxed))
        return Float(bitPattern: bits)
    }

    // MARK: - Control Queue State Machine

    private func setStates(hardware: AudioHardwareState, recording: AudioRecordingState) {
        _hardwareState = hardware
        _recordingState = recording
        stateMirrorLock.lock()
        mirroredHardwareState = hardware
        mirroredRecordingState = recording
        stateMirrorLock.unlock()
    }

    private func setMeterLevel(_ value: Float) {
        let clamped = value.isFinite ? max(0.0, value) : 0.0
        meterLevelBits.store(UInt64(clamped.bitPattern), ordering: .relaxed)
    }

    private func startCaptureOnControlQueue(
        identity: CaptureIdentity,
        parameters: AudioCaptureParameters,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) {
        // Sanitize parameters against untrusted/crafted model metadata BEFORE touching converter or PCMStore.
        let safeParameters = AudioResamplerPipeline.sanitizedParameters(parameters)

        // If another capture is currently in flight, stop/cancel it safely first.
        if let existing = activeSession {
            if _hardwareState == .starting {
                // AudioOutputUnitStart is currently executing on hardwareStartQueue;
                // queue this new start so it runs immediately once teardown finishes.
                existing.pendingStopAfterStart = true
                existing.pendingCancelAfterStart = true
                ld_capture_context_set_accept_audio(existing.prepared.captureContext, false)
                pendingStart = PendingStartRequest(identity: identity, parameters: safeParameters, onEvent: onEvent)
                return
            } else {
                finalizeSessionOnControlQueue(existing, cancel: true, truncatedByLimit: false)
            }
        }

        let resolution = deviceManager.resolveDevice(for: safeParameters.selectionMode)
        guard let device = resolution.device else {
            setStates(hardware: .stopped, recording: .idle)
            onEvent(.captureFailed(
                identity: identity,
                reason: resolution.fallbackNotice ?? "未找到可用的麦克风设备。"
            ))
            return
        }

        guard let deviceID = deviceManager.deviceID(forUID: device.uid) else {
            setStates(hardware: .stopped, recording: .idle)
            onEvent(.captureFailed(
                identity: identity,
                reason: "麦克风「\(device.name)」当前不可用。"
            ))
            return
        }

        let prepared: PreparedAudioUnit
        do {
            prepared = try backend.prepareInputOnlyAUHAL(deviceID: deviceID, deviceInfo: device)
        } catch let pipelineError as AudioPipelineError {
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: pipelineError.userFacingMessage))
            return
        } catch {
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: "无法启动麦克风，请检查系统麦克风权限或设备连接。"))
            return
        }

        let effectiveMax = AudioResamplerPipeline.effectiveMaxSamples(for: safeParameters)
        let resampler: AudioResamplerPipeline
        do {
            resampler = try AudioResamplerPipeline(
                hardwareChannels: prepared.hardwareChannels,
                hardwareSampleRate: prepared.hardwareSampleRate,
                targetSampleRate: safeParameters.targetSampleRate,
                maxOutputSamples: effectiveMax
            )
        } catch let pipelineError as AudioPipelineError {
            backend.stopAndDisposeAUHAL(prepared)
            ld_capture_context_destroy(prepared.captureContext)
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: pipelineError.userFacingMessage))
            return
        } catch {
            backend.stopAndDisposeAUHAL(prepared)
            ld_capture_context_destroy(prepared.captureContext)
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: "音频格式初始化失败，请切换麦克风或稍后重试。"))
            return
        }

        guard let waiter = ld_waiter_create() else {
            backend.stopAndDisposeAUHAL(prepared)
            ld_capture_context_destroy(prepared.captureContext)
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: "录音初始化失败，请稍后重试。"))
            return
        }

        setStates(hardware: .prepared, recording: .idle)

        let firstFrameEmitted = AtomicBool(false)
        let runner = ConsumerRunner(
            identity: identity,
            captureContext: prepared.captureContext,
            waiter: waiter,
            resampler: resampler,
            firstFrameEmitted: firstFrameEmitted,
            onFirstFrame: {
                onEvent(.firstFrameReceived(identity: identity))
            },
            onLimitReached: { [weak self] in
                guard let self else { return }
                self.controlQueue.async {
                    self.handleCaptureLimitReachedOnControlQueue(identity: identity)
                }
            }
        )

        let session = ActiveSession(
            identity: identity,
            parameters: safeParameters,
            deviceInfo: device,
            fallbackNotice: resolution.fallbackNotice,
            onEvent: onEvent,
            prepared: prepared,
            waiter: waiter,
            consumerRunner: runner,
            firstFrameEmitted: firstFrameEmitted
        )

        // Reset C capture context BEFORE spawning consumer thread so ring reset is strictly synchronized.
        ld_capture_context_reset_session(prepared.captureContext)
        ld_waiter_reset(waiter)

        guard let consumerThread = spawnConsumerThread(runner: runner) else {
            ld_waiter_destroy(waiter)
            backend.stopAndDisposeAUHAL(prepared)
            ld_capture_context_destroy(prepared.captureContext)
            setStates(hardware: .disposed, recording: .idle)
            onEvent(.captureFailed(identity: identity, reason: "无法启动录音处理，请稍后重试。"))
            return
        }
        session.consumerThread = consumerThread

        // Prepared -> Starting / Capturing
        activeSession = session
        setMeterLevel(0.0)
        ld_capture_context_set_accept_audio(prepared.captureContext, true)
        setStates(hardware: .starting, recording: .capturing)

        startSessionTimers(for: session)
        onEvent(.captureStarted(
            identity: identity,
            deviceName: device.name,
            fallbackNotice: resolution.fallbackNotice
        ))

        // Execute potentially blocking AudioOutputUnitStart() on hardwareStartQueue so
        // audioControlQueue remains immediately responsive to in-flight cancel/stop!
        let backendRef = self.backend
        hardwareStartQueue.async { [weak self] in
            let startStatus = backendRef.startAUHAL(prepared)
            if let self {
                self.controlQueue.async {
                    self.handleAudioUnitStartCompleted(session: session, status: startStatus)
                }
            } else {
                // Manager was deallocated while AudioOutputUnitStart was in-flight: stop & clean up!
                backendRef.stopAndDisposeAUHAL(prepared)
                session.consumerRunner.modeAtom.store(ConsumerMode.cancelled.rawValue, ordering: .release)
                ld_waiter_signal(session.waiter)
                if let thread = session.consumerThread {
                    _ = pthread_join(thread, nil)
                    session.consumerThread = nil
                }
                ld_capture_context_destroy(prepared.captureContext)
                ld_waiter_destroy(session.waiter)
            }
        }
    }

    private func handleAudioUnitStartCompleted(session: ActiveSession, status: OSStatus) {
        guard activeSession === session else {
            return
        }

        stateMirrorLock.lock()
        mirroredLastStartStatus = status
        stateMirrorLock.unlock()

        if status != noErr {
            let wasCancelled = session.pendingCancelAfterStart
            finalizeSessionOnControlQueue(session, cancel: true, truncatedByLimit: false)
            if !wasCancelled {
                session.onEvent(.captureFailed(
                    identity: session.identity,
                    reason: "无法启动麦克风，请检查系统麦克风权限或设备连接。"
                ))
            }
            drainPendingStartIfAny()
            return
        }

        setStates(hardware: .running, recording: _recordingState)

        // In-flight cancellation/stop arrived while AudioOutputUnitStart was running:
        // immediately stop & dispose AUHAL so the microphone is NEVER left open!
        if session.pendingStopAfterStart {
            let cancel = session.pendingCancelAfterStart
            let truncated = session.truncatedByLimit
            finalizeSessionOnControlQueue(session, cancel: cancel, truncatedByLimit: truncated)
            drainPendingStartIfAny()
        }
    }

    private func stopCaptureOnControlQueue(identity: CaptureIdentity, cancel: Bool) {
        if let pending = pendingStart, pending.identity == identity {
            pendingStart = nil
            if !cancel {
                let safeRate = AudioResamplerPipeline.sanitizeTargetSampleRate(pending.parameters.targetSampleRate)
                let emptyPCM = PCMStore(sampleRate: safeRate)
                let result = AudioCaptureResult(
                    identity: identity,
                    pcm: emptyPCM,
                    durationMs: 0,
                    peakDBFS: -120.0,
                    audioInterrupted: false,
                    droppedFrames: 0,
                    truncatedByLimit: false,
                    droppedByShortUtteranceGate: true,
                    resolvedDeviceName: nil,
                    fallbackNotice: nil
                )
                pending.onEvent(.captureCompleted(result))
            }
            return
        }

        guard let session = activeSession, session.identity == identity else {
            return
        }

        if _hardwareState == .starting {
            session.pendingStopAfterStart = true
            if cancel {
                session.pendingCancelAfterStart = true
            }
            // Quiesce RT ingestion immediately while awaiting AudioOutputUnitStart return.
            ld_capture_context_set_accept_audio(session.prepared.captureContext, false)
            setStates(hardware: .starting, recording: .quiescing)
            return
        }

        finalizeSessionOnControlQueue(session, cancel: cancel, truncatedByLimit: session.truncatedByLimit)
        drainPendingStartIfAny()
    }

    private func handleCaptureLimitReachedOnControlQueue(identity: CaptureIdentity) {
        guard let session = activeSession, session.identity == identity else { return }
        session.truncatedByLimit = true
        if _hardwareState == .starting {
            session.pendingStopAfterStart = true
            ld_capture_context_set_accept_audio(session.prepared.captureContext, false)
            setStates(hardware: .starting, recording: .quiescing)
            return
        }
        finalizeSessionOnControlQueue(session, cancel: false, truncatedByLimit: true)
        drainPendingStartIfAny()
    }

    private func handleDevicesChangedOnControlQueue(_ devices: [AudioDeviceInfo]) {
        guard let session = activeSession else { return }
        let stillPresent = devices.contains(where: { $0.uid == session.deviceInfo.uid })
        guard !stillPresent else { return }

        // Pinned or active microphone was unplugged mid-recording:
        // retain already-captured PCM and mark audioInterrupted = true.
        ld_capture_context_mark_interrupted(session.prepared.captureContext)
        if _hardwareState == .starting {
            session.pendingStopAfterStart = true
            ld_capture_context_set_accept_audio(session.prepared.captureContext, false)
            setStates(hardware: .starting, recording: .quiescing)
            return
        }
        finalizeSessionOnControlQueue(session, cancel: false, truncatedByLimit: session.truncatedByLimit)
        drainPendingStartIfAny()
    }

    /// Executes full safe stop transition:
    /// `Capturing -> Stopping -> Quiescing -> Draining -> Disposed/Idle`
    /// Guarantees `LDCaptureContext` is NEVER freed until AUHAL is stopped, input callback cleared,
    /// `AudioComponentInstanceDispose` completes, AND consumer thread exits via `pthread_join`.
    private func finalizeSessionOnControlQueue(
        _ session: ActiveSession,
        cancel: Bool,
        truncatedByLimit: Bool
    ) {
        guard activeSession === session else { return }
        activeSession = nil

        // Stop timers first.
        session.telemetryTimer?.cancel()
        session.telemetryTimer = nil
        session.safetyTimeoutTimer?.cancel()
        session.safetyTimeoutTimer = nil

        // 1. Stopping & Quiescing: halt RT callback ingestion, stop AUHAL, clear callback, dispose AUHAL.
        setStates(hardware: .stopping, recording: .quiescing)
        backend.stopAndDisposeAUHAL(session.prepared)
        setStates(hardware: .disposed, recording: .draining)

        // 2. Draining: signal consumer thread (monotonic condvar wake) and join until completely exited.
        let targetMode: ConsumerMode = cancel ? .cancelled : .draining
        session.consumerRunner.modeAtom.store(targetMode.rawValue, ordering: .release)
        ld_waiter_signal(session.waiter)

        if let thread = session.consumerThread {
            _ = pthread_join(thread, nil)
            session.consumerThread = nil
        }

        // 3. Snapshot final atomic telemetry before freeing C context.
        let finalTelemetry = ld_capture_context_read_telemetry(session.prepared.captureContext)

        // 4. Safe to destroy C CaptureContext and Waiter ONLY AFTER AUHAL disposed AND consumer exited.
        ld_capture_context_destroy(session.prepared.captureContext)
        ld_waiter_destroy(session.waiter)

        setMeterLevel(0.0)
        setStates(hardware: .disposed, recording: .idle)

        if cancel {
            return
        }

        let frozenPCM = session.consumerRunner.frozenPCM
        let durationMs = frozenPCM.durationMs
        let peakDBFS = session.consumerRunner.peakDBFS
        let wasTruncated = truncatedByLimit || session.consumerRunner.hitCaptureLimit
        let droppedByGate = AudioResamplerPipeline.shouldDropByShortUtteranceGate(
            durationMs: durationMs,
            peakDBFS: peakDBFS
        )

        let result = AudioCaptureResult(
            identity: session.identity,
            pcm: frozenPCM,
            durationMs: durationMs,
            peakDBFS: peakDBFS,
            audioInterrupted: finalTelemetry.audio_interrupted,
            droppedFrames: finalTelemetry.dropped_frames,
            truncatedByLimit: wasTruncated,
            droppedByShortUtteranceGate: droppedByGate,
            resolvedDeviceName: session.deviceInfo.name,
            fallbackNotice: session.fallbackNotice
        )

        session.onEvent(.captureCompleted(result))
    }

    private func drainPendingStartIfAny() {
        guard let next = pendingStart else { return }
        pendingStart = nil
        startCaptureOnControlQueue(
            identity: next.identity,
            parameters: next.parameters,
            onEvent: next.onEvent
        )
    }

    // MARK: - Timers & Consumer Thread Spawning

    private func startSessionTimers(for session: ActiveSession) {
        // 30 Hz (~33 ms) lock-free telemetry & UI meter readout timer (active ONLY while recording).
        let meterTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        meterTimer.schedule(deadline: .now() + .milliseconds(15), repeating: .milliseconds(33), leeway: .milliseconds(4))
        meterTimer.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else { return }
            self.pollTelemetryOnControlQueue(session: session)
        }
        meterTimer.resume()
        session.telemetryTimer = meterTimer

        // Wall-clock safety backup slightly past captureLimitMs in case hardware audio stream stalls.
        let safetyTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        let safetyDelayMs = session.parameters.captureLimitMs + 1500
        safetyTimer.schedule(deadline: .now() + .milliseconds(safetyDelayMs))
        safetyTimer.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else { return }
            self.handleCaptureLimitReachedOnControlQueue(identity: session.identity)
        }
        safetyTimer.resume()
        session.safetyTimeoutTimer = safetyTimer
    }

    private func pollTelemetryOnControlQueue(session: ActiveSession) {
        let telemetry = ld_capture_context_read_telemetry(session.prepared.captureContext)
        let rms = telemetry.meter_rms_linear
        let peak = telemetry.meter_peak_linear
        let peakDBFS: Float = peak > 1e-9 ? 20.0 * log10f(peak) : -120.0

        setMeterLevel(rms)

        if telemetry.first_frame_received {
            if session.firstFrameEmitted.compareExchange(expected: false, desired: true) {
                session.onEvent(.firstFrameReceived(identity: session.identity))
            }
        }

        if telemetry.speech_detected && !session.speechDetectedEmitted {
            session.speechDetectedEmitted = true
            session.onEvent(.speechDetected(identity: session.identity))
        }

        session.onEvent(.levelUpdate(
            identity: session.identity,
            rmsLevel: rms,
            peakDBFS: peakDBFS
        ))

        // If AUHAL render continuously fails (e.g. hardware stalled/removed), stop & preserve PCM.
        if telemetry.render_error_count >= 5, _hardwareState == .running {
            ld_capture_context_mark_interrupted(session.prepared.captureContext)
            finalizeSessionOnControlQueue(session, cancel: false, truncatedByLimit: session.truncatedByLimit)
            drainPendingStartIfAny()
        }
    }

    private func spawnConsumerThread(runner: ConsumerRunner) -> pthread_t? {
        var attr = pthread_attr_t()
        guard pthread_attr_init(&attr) == 0 else { return nil }
        defer { pthread_attr_destroy(&attr) }

        _ = pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0)

        let retainedBox = Unmanaged.passRetained(runner).toOpaque()
        var thread: pthread_t?
        let rc = pthread_create(&thread, &attr, Self.consumerThreadEntry, retainedBox)
        if rc != 0 {
            Unmanaged<ConsumerRunner>.fromOpaque(retainedBox).release()
            return nil
        }
        return thread
    }
}
