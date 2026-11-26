import AVFoundation
import CLiteDictateAudio
import CoreAudio
import Foundation
@testable import LiteDictateCore
import XCTest

// MARK: - Deterministic Mock Providers & Backends

private final class MockDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AudioDeviceEntry]
    private var listeners: [UUID: (DispatchQueue, @Sendable () -> Void)] = [:]

    init(entries: [AudioDeviceEntry]) {
        self.entries = entries
    }

    func updateEntries(_ newEntries: [AudioDeviceEntry], notify: Bool = true) {
        lock.lock()
        entries = newEntries
        let snapshot = Array(listeners.values)
        lock.unlock()

        if notify {
            for (queue, handler) in snapshot {
                queue.async { handler() }
            }
        }
    }

    func enumerateInputDevices() -> [AudioDeviceEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first(where: { $0.info.uid == uid })?.deviceID
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains(where: { $0.deviceID == deviceID })
    }

    func installDevicesChangedListener(
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        let id = UUID()
        lock.lock()
        listeners[id] = (queue, handler)
        lock.unlock()
        return id as NSUUID
    }

    func removeDevicesChangedListener(_ token: AnyObject) {
        guard let uuid = token as? UUID else { return }
        lock.lock()
        listeners.removeValue(forKey: uuid)
        lock.unlock()
    }
}

private final class MockAUHALBackend: AudioUnitBackend, @unchecked Sendable {
    private let lock = NSLock()
    var prepareCount = 0
    var startCount = 0
    var stopAndDisposeCount = 0
    var startStatusToReturn: OSStatus = noErr
    var startGateSemaphore: DispatchSemaphore?
    var onStartEntered: (@Sendable () -> Void)?
    var lastPreparedContext: OpaquePointer?

    func prepareInputOnlyAUHAL(deviceID: AudioDeviceID, deviceInfo: AudioDeviceInfo) throws -> PreparedAudioUnit {
        lock.lock()
        prepareCount += 1
        lock.unlock()

        let channels = max(1, min(deviceInfo.inputChannelCount, Int(LD_AUDIO_MAX_CHANNELS)))
        let rate = max(8_000.0, deviceInfo.nominalSampleRate)
        guard let ctx = ld_capture_context_create(
            UInt32(channels),
            rate,
            1024,
            false,
            2.0,
            Int(LD_AUDIO_DEFAULT_RING_MAX_BYTES)
        ) else {
            throw AudioPipelineError.allocationFailed("Mock context alloc failed")
        }

        lock.lock()
        lastPreparedContext = ctx
        lock.unlock()

        return PreparedAudioUnit(
            audioUnit: nil,
            hardwareChannels: channels,
            hardwareSampleRate: rate,
            maxFramesPerSlice: 1024,
            isNonInterleaved: false,
            captureContext: ctx
        )
    }

    func startAUHAL(_ prepared: PreparedAudioUnit) -> OSStatus {
        lock.lock()
        startCount += 1
        let gate = startGateSemaphore
        let entered = onStartEntered
        let status = startStatusToReturn
        lock.unlock()

        entered?()
        gate?.wait()
        return status
    }

    func stopAndDisposeAUHAL(_ prepared: PreparedAudioUnit) {
        ld_capture_context_set_accept_audio(prepared.captureContext, false)
        lock.lock()
        stopAndDisposeCount += 1
        lastPreparedContext = nil
        lock.unlock()
    }
}

// MARK: - Device Selection, Capture State Machine & Live Probe 2 Tests

final class AudioDeviceAndCaptureManagerTests: XCTestCase {
    private let usbMic = AudioDeviceEntry(
        deviceID: 101,
        info: AudioDeviceInfo(
            uid: "USB-Scarlett-2i2",
            name: "Scarlett 2i2 USB",
            transportKind: .usb,
            inputChannelCount: 2,
            nominalSampleRate: 48_000
        )
    )
    private let builtInMic = AudioDeviceEntry(
        deviceID: 102,
        info: AudioDeviceInfo(
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Air Microphone",
            transportKind: .builtIn,
            inputChannelCount: 1,
            nominalSampleRate: 48_000
        )
    )
    private let airPodsMic = AudioDeviceEntry(
        deviceID: 103,
        info: AudioDeviceInfo(
            uid: "BT-AirPods-Pro-AA:BB",
            name: "AirPods Pro",
            transportKind: .bluetooth,
            inputChannelCount: 1,
            nominalSampleRate: 16_000
        )
    )
    private let iphoneMic = AudioDeviceEntry(
        deviceID: 104,
        info: AudioDeviceInfo(
            uid: "Continuity-iPhone-15",
            name: "iPhone Microphone",
            transportKind: .continuity,
            inputChannelCount: 1,
            nominalSampleRate: 48_000
        )
    )
    private let virtualMic = AudioDeviceEntry(
        deviceID: 105,
        info: AudioDeviceInfo(
            uid: "BlackHole2ch_UID",
            name: "BlackHole 2ch",
            transportKind: .virtual,
            inputChannelCount: 2,
            nominalSampleRate: 48_000
        )
    )

    func testTransportClassificationCoversAllRequiredKinds() {
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeUSB, name: "USB Mic", uid: "u1"
            ),
            .usb
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeThunderbolt, name: "TB Dock", uid: "u2"
            ),
            .usb
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeDisplayPort, name: "Studio Display", uid: "u3"
            ),
            .usb
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeBuiltIn, name: "MacBook Air Mic", uid: "u4"
            ),
            .builtIn
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeBluetooth, name: "AirPods", uid: "u5"
            ),
            .bluetooth
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeBluetoothLE, name: "LE Headset", uid: "u6"
            ),
            .bluetooth
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeContinuityCaptureWireless, name: "iPhone", uid: "u7"
            ),
            .continuity
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeUnknown, name: "Mio's iPhone Microphone", uid: "u8"
            ),
            .continuity
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeVirtual, name: "BlackHole", uid: "u9"
            ),
            .virtual
        )
        XCTAssertEqual(
            CoreAudioDeviceProvider.classifyTransport(
                transportType: kAudioDeviceTransportTypeAggregate, name: "Multi-Input", uid: "u10"
            ),
            .virtual
        )
    }

    func testSmartAutoPriorityAndZeroBluetoothHFPSwitch() {
        // 1. USB > BuiltIn, skipping Bluetooth / Continuity / Virtual.
        let provider = MockDeviceProvider(entries: [airPodsMic, iphoneMic, virtualMic, builtInMic, usbMic])
        let manager = AudioDeviceManager(provider: provider)

        let res1 = manager.resolveDevice(for: .smartAuto)
        XCTAssertEqual(res1.device?.uid, usbMic.info.uid)
        XCTAssertFalse(res1.isBluetoothHFPWarning)
        XCTAssertFalse(res1.didFallbackFromPinned)

        // 2. Unplug USB -> BuiltIn chosen, Bluetooth AirPods STILL skipped (0 HFP switch!).
        provider.updateEntries([airPodsMic, iphoneMic, virtualMic, builtInMic], notify: false)
        let res2 = manager.resolveDevice(for: .smartAuto)
        XCTAssertEqual(res2.device?.uid, builtInMic.info.uid)
        XCTAssertFalse(res2.isBluetoothHFPWarning)

        // 3. Only Bluetooth + Continuity + Virtual present -> smartAuto skips ALL of them.
        provider.updateEntries([airPodsMic, iphoneMic, virtualMic], notify: false)
        let res3 = manager.resolveDevice(for: .smartAuto)
        XCTAssertNil(res3.device, "smartAuto MUST skip Bluetooth, Continuity, and Virtual devices")
    }

    func testPinnedModeBluetoothWarningFallbackAndReplugAutoRestore() {
        let provider = MockDeviceProvider(entries: [usbMic, builtInMic, airPodsMic])
        let manager = AudioDeviceManager(provider: provider)

        // 1. Pinned Bluetooth mic sets isBluetoothHFPWarning = true.
        let btRes = manager.resolveDevice(for: .pinned(deviceUID: airPodsMic.info.uid))
        XCTAssertEqual(btRes.device?.uid, airPodsMic.info.uid)
        XCTAssertTrue(btRes.isBluetoothHFPWarning)
        XCTAssertFalse(btRes.didFallbackFromPinned)

        // 2. Pinned USB mic present -> resolved directly by stable UID.
        let pinnedConfig = AudioSelectionMode.pinned(deviceUID: usbMic.info.uid)
        let usbRes = manager.resolveDevice(for: pinnedConfig)
        XCTAssertEqual(usbRes.device?.uid, usbMic.info.uid)
        XCTAssertFalse(usbRes.didFallbackFromPinned)
        XCTAssertNil(usbRes.fallbackNotice)

        // 3. USB mic unplugged before start -> temporary fallback to BuiltIn + notice (pinnedConfig untouched!).
        provider.updateEntries([builtInMic, airPodsMic], notify: false)
        let fallbackRes = manager.resolveDevice(for: pinnedConfig)
        XCTAssertEqual(fallbackRes.device?.uid, builtInMic.info.uid)
        XCTAssertTrue(fallbackRes.didFallbackFromPinned)
        XCTAssertNotNil(fallbackRes.fallbackNotice)
        XCTAssertFalse(fallbackRes.isBluetoothHFPWarning)

        // 4. USB mic replugged (even with a brand new AudioDeviceID!) -> auto-restores via stable AudioDeviceUID!
        let repluggedUSB = AudioDeviceEntry(deviceID: 999, info: usbMic.info)
        provider.updateEntries([repluggedUSB, builtInMic, airPodsMic], notify: false)
        let restoredRes = manager.resolveDevice(for: pinnedConfig)
        XCTAssertEqual(restoredRes.device?.uid, usbMic.info.uid)
        XCTAssertFalse(restoredRes.didFallbackFromPinned)
        XCTAssertNil(restoredRes.fallbackNotice)
        XCTAssertEqual(manager.deviceID(forUID: usbMic.info.uid), 999)
    }

    func testInFlightAudioOutputUnitStartCancellationTriggersPendingStopAfterStart() {
        let provider = MockDeviceProvider(entries: [builtInMic])
        let deviceManager = AudioDeviceManager(provider: provider)
        let backend = MockAUHALBackend()
        let startGate = DispatchSemaphore(value: 0)
        backend.startGateSemaphore = startGate

        let startEnteredExp = expectation(description: "AudioOutputUnitStart entered")
        backend.onStartEntered = {
            startEnteredExp.fulfill()
        }

        let captureManager = AudioCaptureManager(deviceManager: deviceManager, backend: backend)
        let identity = CaptureIdentity(requestID: 42, captureGeneration: 1)

        final class EventLog: @unchecked Sendable {
            let lock = NSLock()
            var completed = false
            var failed = false
        }
        let log = EventLog()

        captureManager.startCapture(
            identity: identity,
            parameters: AudioCaptureParameters()
        ) { event in
            log.lock.lock()
            defer { log.lock.unlock() }
            switch event {
            case .captureCompleted: log.completed = true
            case .captureFailed: log.failed = true
            default: break
            }
        }

        // Wait until AudioOutputUnitStart is actively in-flight.
        wait(for: [startEnteredExp], timeout: 2.0)
        XCTAssertEqual(captureManager.hardwareState, .starting)

        // Cancel capture WHILE AudioOutputUnitStart() is blocked in-flight!
        captureManager.cancelCapture(identity: identity)

        // Synchronize controlQueue so pendingStopAfterStart is definitely recorded before unblocking start.
        deviceManager.controlQueue.sync {}
        XCTAssertEqual(captureManager.hardwareState, .starting)
        XCTAssertEqual(captureManager.recordingState, .quiescing)
        XCTAssertEqual(backend.stopAndDisposeCount, 0, "Must NOT dispose AUHAL while startAUHAL is executing")

        // Unblock AudioOutputUnitStart -> must immediately stop & dispose AUHAL!
        startGate.signal()

        let deadline = Date().addingTimeInterval(2.0)
        while captureManager.hardwareState != .disposed && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopAndDisposeCount, 1, "In-flight cancel MUST stop & dispose mic upon Start return")
        XCTAssertEqual(captureManager.hardwareState, .disposed)
        XCTAssertEqual(captureManager.recordingState, .idle)
        XCTAssertFalse(log.completed, "Cancelled capture must not emit captureCompleted")
        XCTAssertFalse(log.failed)
    }

    func testMidRecordingPinnedDeviceUnplugRetainsPCMAndMarksAudioInterrupted() {
        let provider = MockDeviceProvider(entries: [usbMic, builtInMic])
        let deviceManager = AudioDeviceManager(provider: provider)
        let backend = MockAUHALBackend()
        let captureManager = AudioCaptureManager(deviceManager: deviceManager, backend: backend)

        let identity = CaptureIdentity(requestID: 77, captureGeneration: 1)
        let startedExp = expectation(description: "Capture started")
        let completedExp = expectation(description: "Capture completed on unplug")

        final class ResultBox: @unchecked Sendable {
            var result: AudioCaptureResult?
        }
        let resultBox = ResultBox()

        captureManager.startCapture(
            identity: identity,
            parameters: AudioCaptureParameters(
                targetSampleRate: 16_000,
                captureLimitMs: 10_000,
                selectionMode: .pinned(deviceUID: usbMic.info.uid)
            )
        ) { event in
            switch event {
            case .captureStarted:
                startedExp.fulfill()
            case .captureCompleted(let result):
                resultBox.result = result
                completedExp.fulfill()
            default:
                break
            }
        }

        wait(for: [startedExp], timeout: 2.0)

        // Wait until hardwareState transitions to .running.
        let runDeadline = Date().addingTimeInterval(2.0)
        while captureManager.hardwareState != .running && Date() < runDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(captureManager.hardwareState, .running)

        // Inject 0.3s of 2ch 48 kHz single-mic speech into the active C capture context.
        guard let ctx = backend.lastPreparedContext else {
            XCTFail("Expected active capture context")
            return
        }
        let frames = 14_400 // 300 ms @ 48 kHz
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            samples[i * 2] = 0.35 * Float(sin(2.0 * Double.pi * 600.0 * Double(i) / 48_000.0))
        }
        samples.withUnsafeBufferPointer { buf in
            ld_capture_context_ingest_interleaved_for_testing(ctx, buf.baseAddress!, UInt32(frames), 12345)
        }

        // Give consumer thread a brief moment to ingest frames, then UNPLUG pinned USB mic!
        Thread.sleep(forTimeInterval: 0.04)
        provider.updateEntries([builtInMic], notify: true)

        wait(for: [completedExp], timeout: 3.0)

        guard let result = resultBox.result else {
            XCTFail("Missing AudioCaptureResult after mid-recording unplug")
            return
        }
        XCTAssertEqual(result.identity, identity)
        XCTAssertTrue(result.audioInterrupted, "Mid-recording unplug MUST mark audioInterrupted = true")
        XCTAssertFalse(result.droppedByShortUtteranceGate, "300ms captured audio must be retained")
        XCTAssertGreaterThanOrEqual(result.durationMs, 250, "Captured PCM before unplug must be retained")
        XCTAssertEqual(result.pcm.sampleRate, 16_000)
        XCTAssertEqual(captureManager.hardwareState, .disposed)
        XCTAssertEqual(captureManager.recordingState, .idle)
    }

    func testDynamicTimeoutTruncationClampsAndMarksTruncatedByLimit() {
        let provider = MockDeviceProvider(entries: [builtInMic])
        let deviceManager = AudioDeviceManager(provider: provider)
        let backend = MockAUHALBackend()
        let captureManager = AudioCaptureManager(deviceManager: deviceManager, backend: backend)

        let identity = CaptureIdentity(requestID: 88, captureGeneration: 1)
        let startedExp = expectation(description: "Capture started")
        let completedExp = expectation(description: "Capture truncated and completed")

        final class ResultBox: @unchecked Sendable {
            var result: AudioCaptureResult?
        }
        let resultBox = ResultBox()

        // Clamp model max to 4,800 samples (300 ms @ 16 kHz) to verify automatic truncation stop.
        captureManager.startCapture(
            identity: identity,
            parameters: AudioCaptureParameters(
                targetSampleRate: 16_000,
                captureLimitMs: 5_000,
                maxSamplesForModel: 4_800,
                selectionMode: .smartAuto
            )
        ) { event in
            switch event {
            case .captureStarted:
                startedExp.fulfill()
            case .captureCompleted(let result):
                resultBox.result = result
                completedExp.fulfill()
            default:
                break
            }
        }

        wait(for: [startedExp], timeout: 2.0)
        let runDeadline = Date().addingTimeInterval(2.0)
        while captureManager.hardwareState != .running && Date() < runDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        guard let ctx = backend.lastPreparedContext else {
            XCTFail("Expected active capture context")
            return
        }

        // Feed 0.5s (24,000 frames @ 48 kHz -> 8,000 samples @ 16 kHz > 4,800 limit).
        let frames = 24_000
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = 0.25 * Float(sin(2.0 * Double.pi * 500.0 * Double(i) / 48_000.0))
        }
        samples.withUnsafeBufferPointer { buf in
            ld_capture_context_ingest_interleaved_for_testing(ctx, buf.baseAddress!, UInt32(frames), 999)
        }

        wait(for: [completedExp], timeout: 3.0)
        guard let result = resultBox.result else {
            XCTFail("Expected AudioCaptureResult")
            return
        }
        XCTAssertTrue(result.truncatedByLimit, "Exceeding limit must set truncatedByLimit = true")
        XCTAssertEqual(result.pcm.totalSampleCount, 4_800)
        XCTAssertEqual(result.durationMs, 300)
        XCTAssertFalse(result.droppedByShortUtteranceGate)
    }

    func testUntrustedCaptureParametersAreClampedBeforeConverterAndPCMStore() {
        let provider = MockDeviceProvider(entries: [builtInMic])
        let deviceManager = AudioDeviceManager(provider: provider)
        let backend = MockAUHALBackend()
        let captureManager = AudioCaptureManager(deviceManager: deviceManager, backend: backend)

        let identity = CaptureIdentity(requestID: 90, captureGeneration: 1)
        let startedExp = expectation(description: "Capture started with clamped parameters")
        let completedExp = expectation(description: "Capture completed cleanly")

        final class ResultBox: @unchecked Sendable {
            var result: AudioCaptureResult?
        }
        let resultBox = ResultBox()

        // Untrusted model metadata: bogus 999 kHz rate, 1-hour limit, huge maxSamplesForModel.
        captureManager.startCapture(
            identity: identity,
            parameters: AudioCaptureParameters(
                targetSampleRate: 999_000,
                captureLimitMs: 3_600_000,
                maxSamplesForModel: Int.max / 2,
                selectionMode: .smartAuto
            )
        ) { event in
            switch event {
            case .captureStarted:
                startedExp.fulfill()
            case .captureCompleted(let result):
                resultBox.result = result
                completedExp.fulfill()
            default:
                break
            }
        }

        wait(for: [startedExp], timeout: 2.0)
        let runDeadline = Date().addingTimeInterval(2.0)
        while captureManager.hardwareState != .running && Date() < runDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        captureManager.stopCapture(identity: identity)
        wait(for: [completedExp], timeout: 3.0)

        guard let result = resultBox.result else {
            XCTFail("Expected AudioCaptureResult")
            return
        }
        XCTAssertEqual(
            result.pcm.sampleRate,
            LiteDictateConstants.defaultSampleRate,
            "Invalid targetSampleRate outside 8k..48k must fall back to 16 kHz"
        )
    }

    func testStartFailureEmitsConsumerFriendlyErrorWithoutRawOSStatus() {
        let provider = MockDeviceProvider(entries: [builtInMic])
        let deviceManager = AudioDeviceManager(provider: provider)
        let backend = MockAUHALBackend()
        backend.startStatusToReturn = OSStatus(-50)
        let captureManager = AudioCaptureManager(deviceManager: deviceManager, backend: backend)

        let identity = CaptureIdentity(requestID: 91, captureGeneration: 1)
        let failedExp = expectation(description: "Capture failed with consumer-friendly message")

        final class ErrorBox: @unchecked Sendable {
            var reason: String?
        }
        let errorBox = ErrorBox()

        captureManager.startCapture(
            identity: identity,
            parameters: AudioCaptureParameters()
        ) { event in
            if case .captureFailed(_, let reason) = event {
                errorBox.reason = reason
                failedExp.fulfill()
            }
        }

        wait(for: [failedExp], timeout: 2.0)

        guard let reason = errorBox.reason else {
            XCTFail("Expected failure reason")
            return
        }
        XCTAssertFalse(reason.contains("OSStatus"), "User-facing error must not leak raw OSStatus: \(reason)")
        XCTAssertFalse(reason.contains("-50"), "User-facing error must not leak raw error code: \(reason)")
        XCTAssertFalse(reason.contains("AUHAL"), "User-facing error must not leak internal CoreAudio jargon: \(reason)")
        XCTAssertEqual(captureManager.lastInternalStartStatus, OSStatus(-50), "Raw OSStatus should remain available for internal debug diagnostics")
    }

    // MARK: - Phase 1 Probe 2: Live Real-Machine Hardware Verification

    func testLiveProbe2_RealMachineDeviceEnumerationAndSmartAuto() {
        let manager = AudioDeviceManager()
        let devices = manager.availableInputDevices()

        print("[Probe 2] Enumerated \(devices.count) live CoreAudio input device(s):")
        for d in devices {
            print("  - \(d.name) | uid=\(d.uid) | transport=\(d.transportKind.rawValue) | ch=\(d.inputChannelCount) | sr=\(Int(d.nominalSampleRate))Hz | smartAutoEligible=\(d.isEligibleForSmartAuto)")
        }

        // Every returned device MUST have > 0 input channels and a non-empty stable UID.
        for d in devices {
            XCTAssertGreaterThan(d.inputChannelCount, 0)
            XCTAssertFalse(d.uid.isEmpty)
            XCTAssertGreaterThan(d.nominalSampleRate, 0)
        }

        let resolution = manager.resolveDevice(for: .smartAuto)
        if let selected = resolution.device {
            print("[Probe 2] smartAuto resolved: \(selected.name) (\(selected.transportKind.rawValue), \(selected.inputChannelCount)ch @ \(Int(selected.nominalSampleRate))Hz)")
            XCTAssertTrue(
                selected.transportKind == .usb || selected.transportKind == .builtIn,
                "smartAuto MUST never select Bluetooth, Continuity, or Virtual devices"
            )
            XCTAssertFalse(resolution.isBluetoothHFPWarning)
        } else {
            print("[Probe 2] smartAuto resolved nil (no USB or BuiltIn mic currently attached).")
            XCTAssertFalse(devices.contains(where: { $0.transportKind == .usb || $0.transportKind == .builtIn }))
        }
    }

    func testLiveProbe2_RealInputOnlyAUHALPrepareStartStopAndCancelSmoke() throws {
        let deviceManager = AudioDeviceManager()
        let resolution = deviceManager.resolveDevice(for: .smartAuto)
        guard let resolvedDevice = resolution.device else {
            throw XCTSkip("[Probe 2] No USB or BuiltIn microphone available on host")
        }

        // Check Microphone TCC authorization BEFORE calling startCapture so clean checkouts
        // without CLI microphone permission skip deterministically instead of timing out or hanging on TCC.
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[Probe 2] Live mic authorization status: \(micAuth.rawValue), target device: \(resolvedDevice.name)")
        guard micAuth == .authorized else {
            throw XCTSkip("[Probe 2] Skipping live AUHAL capture smoke test because Microphone TCC permission is not .authorized (status=\(micAuth.rawValue)).")
        }

        let captureManager = AudioCaptureManager(deviceManager: deviceManager)

        // 1. Live start -> capture -> stop smoke test.
        let startedOrFailedExp = expectation(description: "Live AUHAL started or failed")
        let finishedExp = expectation(description: "Live AUHAL captureCompleted or captureFailed")

        final class LiveProbeState: @unchecked Sendable {
            let lock = NSLock()
            var startNano: UInt64 = 0
            var firstFrameNano: UInt64?
            var result: AudioCaptureResult?
            var failureReason: String?
            var startedOrFailedFulfilled = false
            var finishedFulfilled = false
        }
        let state = LiveProbeState()
        state.startNano = DispatchTime.now().uptimeNanoseconds

        let id1 = CaptureIdentity(requestID: 2001, captureGeneration: 1)
        captureManager.startCapture(
            identity: id1,
            parameters: AudioCaptureParameters(
                targetSampleRate: 16_000,
                captureLimitMs: 5_000,
                selectionMode: .smartAuto
            )
        ) { event in
            state.lock.lock()
            defer { state.lock.unlock() }
            switch event {
            case .captureStarted:
                if !state.startedOrFailedFulfilled {
                    state.startedOrFailedFulfilled = true
                    startedOrFailedExp.fulfill()
                }
            case .firstFrameReceived:
                if state.firstFrameNano == nil {
                    state.firstFrameNano = DispatchTime.now().uptimeNanoseconds
                }
            case .captureCompleted(let res):
                state.result = res
                if !state.startedOrFailedFulfilled {
                    state.startedOrFailedFulfilled = true
                    startedOrFailedExp.fulfill()
                }
                if !state.finishedFulfilled {
                    state.finishedFulfilled = true
                    finishedExp.fulfill()
                }
            case .captureFailed(_, let reason):
                state.failureReason = reason
                if !state.startedOrFailedFulfilled {
                    state.startedOrFailedFulfilled = true
                    startedOrFailedExp.fulfill()
                }
                if !state.finishedFulfilled {
                    state.finishedFulfilled = true
                    finishedExp.fulfill()
                }
            default:
                break
            }
        }

        wait(for: [startedOrFailedExp], timeout: 3.0)

        if let failure = state.failureReason {
            XCTFail("Live AUHAL capture failed unexpectedly: \(failure)")
            return
        }

        // Let AUHAL run briefly (~220 ms) to receive real PCM frames.
        Thread.sleep(forTimeInterval: 0.22)
        captureManager.stopCapture(identity: id1)
        wait(for: [finishedExp], timeout: 3.0)

        if let failure = state.failureReason {
            XCTFail("Live AUHAL capture failed unexpectedly: \(failure)")
            return
        }

        guard let result = state.result else {
            XCTFail("Expected live AudioCaptureResult")
            return
        }

        if let firstNano = state.firstFrameNano {
            let coldStartMs = Double(firstNano - state.startNano) / 1_000_000.0
            print(String(format: "[Probe 2] Live AUHAL first valid PCM frame latency: %.1f ms | captured=%d ms | peak=%.1f dBFS | dropped=%llu", coldStartMs, result.durationMs, result.peakDBFS, result.droppedFrames))
        }

        XCTAssertEqual(result.pcm.sampleRate, 16_000)
        XCTAssertEqual(captureManager.hardwareState, .disposed)
        XCTAssertEqual(captureManager.recordingState, .idle)
        XCTAssertNotNil(state.firstFrameNano, "Authorized mic capture should receive valid PCM frames")
        XCTAssertGreaterThan(result.pcm.totalSampleCount, 0)

        // 2. Rapid start -> immediate in-flight cancel smoke test (must leave hardware disposed & idle).
        let id2 = CaptureIdentity(requestID: 2002, captureGeneration: 2)
        captureManager.startCapture(
            identity: id2,
            parameters: AudioCaptureParameters(targetSampleRate: 16_000, captureLimitMs: 5_000, selectionMode: .smartAuto)
        ) { _ in }
        captureManager.cancelCapture(identity: id2)

        let cancelDeadline = Date().addingTimeInterval(3.0)
        while (captureManager.recordingState != .idle || (captureManager.hardwareState != .disposed && captureManager.hardwareState != .stopped)) && Date() < cancelDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(captureManager.recordingState, .idle)
    }
}
