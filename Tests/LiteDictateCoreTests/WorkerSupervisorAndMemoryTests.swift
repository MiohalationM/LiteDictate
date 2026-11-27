import Foundation
import Testing
@testable import LiteDictateCore

@Suite("WorkerSupervisor, WarmLeakDetector & Memory Pressure Matrix")
struct WorkerSupervisorAndMemoryTests {
    private func waitUntil(_ condition: () -> Bool, timeoutMs: Int = 5_000) async {
        let attempts = max(1, timeoutMs / 15)
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    @Test("WarmLeakDetector computes runs 3-5 median baseline and triggers after 3 consecutive +50MB & init drift strikes")
    func testWarmLeakDetector() {
        var detector = WarmLeakDetector()
        let mb: UInt64 = 1024 * 1024

        // Runs 1-2 ignored (warm-up noise)
        #expect(detector.recordRun(postFreeFootprintBytes: 200 * mb, sessionInitMs: 100) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 180 * mb, sessionInitMs: 80) == false)

        // Runs 3-5 establish median baseline: 110 MB, 54 ms
        #expect(detector.recordRun(postFreeFootprintBytes: 112 * mb, sessionInitMs: 56) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 108 * mb, sessionInitMs: 52) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 110 * mb, sessionInitMs: 54) == false)
        #expect(detector.baselineFootprintBytes == 110 * mb)
        #expect(detector.baselineSessionInitMs == 54.0)

        // Strike 1 & 2 -> not yet 3
        #expect(detector.recordRun(postFreeFootprintBytes: 165 * mb, sessionInitMs: 75) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 170 * mb, sessionInitMs: 80) == false)
        #expect(detector.consecutiveStrikes == 2)

        // Normal run resets consecutive streak
        #expect(detector.recordRun(postFreeFootprintBytes: 115 * mb, sessionInitMs: 55) == false)
        #expect(detector.consecutiveStrikes == 0)

        // Footprint drift WITHOUT sessionInitMs drift does NOT trigger
        #expect(detector.recordRun(postFreeFootprintBytes: 170 * mb, sessionInitMs: 55) == false)
        #expect(detector.consecutiveStrikes == 0)

        // 3 consecutive strikes with BOTH > baseline+50MB AND sessionInitMs drift triggers self-heal!
        #expect(detector.recordRun(postFreeFootprintBytes: 165 * mb, sessionInitMs: 75) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 170 * mb, sessionInitMs: 80) == false)
        #expect(detector.recordRun(postFreeFootprintBytes: 175 * mb, sessionInitMs: 85) == true)
    }

    @Test("WorkerSupervisor memory pressure matrix blocks warmup on .warning and blocks inference on .critical")
    func testMemoryPressureStoppedState() async {
        let supervisor = WorkerSupervisor(
            workerExecutablePath: "/nonexistent/worker",
            warmTTLSeconds: 60,
            enableSystemMemoryPressureSource: false
        )

        let criticalAbortReceived = AtomicBool(false)

        supervisor.setEventHandler { event in
            if case let .transcriptionFailed(_, _, isCritical) = event, isCritical {
                criticalAbortReceived.store(true, ordering: .release)
            }
        }

        let model = ModelDescriptor(
            id: "m1",
            displayName: "TestModel",
            filePath: "/tmp/test.gguf",
            storageMode: .reference,
            fileSizeBytes: 100,
            statFingerprint: nil,
            capabilities: ModelCapabilities()
        )

        // Under .warning, predictive warmup is paused (never tries to start)
        supervisor.handleMemoryPressure(.warning)
        supervisor.prepareWarmupIfAllowed(model: model)
        await waitUntil { supervisor.currentMemoryPressure == .warning }
        #expect(supervisor.currentMemoryPressure == .warning)
        #expect(supervisor.currentState == .stopped)

        // Under .critical, submitting transcription immediately emits critical abort without spawning worker
        supervisor.handleMemoryPressure(.critical)
        let req = WorkerTranscriptionRequest(
            requestID: 1,
            model: model,
            pcm: PCMStore(sampleRate: 16_000, samples: [Float](repeating: 0.2, count: 3200))
        )
        supervisor.submitTranscription(req)
        await waitUntil { criticalAbortReceived.load(ordering: .acquire) }

        #expect(criticalAbortReceived.load(ordering: .acquire) == true)
        #expect(supervisor.currentState == .stopped)
    }

    @Test("WorkerProcessInstance posix_spawn wires FD 0=/dev/null, FD 1/2=log ring, FD 3/4=LDP1 protocol pipes")
    func testPosixSpawnFD34Wiring() async throws {
        // Create a tiny executable python3 script simulating LDP1 over FD 3 & FD 4 and logging to stderr.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockWorker = tmpDir.appendingPathComponent("mock-worker")
        let script = """
        #!/usr/bin/env python3
        import os, struct, sys

        sys.stderr.write("worker-diag-hello\\n")
        sys.stderr.flush()

        def read_exact(fd, n):
            buf = bytearray()
            while len(buf) < n:
                chunk = os.read(fd, n - len(buf))
                if not chunk:
                    raise EOFError()
                buf.extend(chunk)
            return bytes(buf)

        hdr = read_exact(3, 32)
        magic, ver, mtype, req_id, att_id, plen, flags = struct.unpack("<4sHHQQII", hdr)
        if plen > 0:
            _ = read_exact(3, plen)
        if magic == b"LDP1" and mtype == 0x05:
            payload = b'{"busy":false,"modelLoaded":false,"physFootprintBytes":12345}'
            reply = struct.pack("<4sHHQQII", b"LDP1", 1, 0x85, req_id, att_id, len(payload), 0) + payload
            os.write(4, reply)
        """
        try script.write(to: mockWorker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockWorker.path)

        let exitExp = AtomicBool(false)
        let instance = try WorkerProcessInstance.spawn(
            executablePath: mockWorker.path,
            workerGeneration: 1,
            onExit: { _, _ in
                exitExp.store(true, ordering: .release)
            }
        )

        let ping = LDPProtocolClient.makeEmptyFrame(msgType: .ping, requestID: 77, attemptID: 3)
        try instance.writeFrame(ping)
        let pongFrame = try instance.readFrame()
        #expect(pongFrame.header.msgType == .pong)
        #expect(pongFrame.header.requestID == 77)
        let pong = try LDPProtocolClient.decodeJSONPayload(LDPPongPayload.self, from: pongFrame.payload)
        #expect(pong.physFootprintBytes == 12345)

        // Wait briefly for reaper + diagnostic log drain
        for _ in 0..<40 {
            if exitExp.load() && instance.diagnosticLogs.snapshotText().contains("worker-diag-hello") {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(exitExp.load() == true)
        #expect(instance.hasExited == true)
        #expect(instance.diagnosticLogs.snapshotText().contains("worker-diag-hello"))
    }

    @Test("WorkerSupervisor fails once without infinite respawn loop if worker crashes during .starting")
    func testStartingCrashDoesNotRespawnLoop() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let countFile = tmpDir.appendingPathComponent("spawns.txt")
        let crashWorker = tmpDir.appendingPathComponent("crash-worker")
        let script = """
        #!/bin/sh
        echo x >> "\(countFile.path)"
        exit 1
        """
        try script.write(to: crashWorker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crashWorker.path)

        let supervisor = WorkerSupervisor(
            workerExecutablePath: crashWorker.path,
            warmTTLSeconds: 60,
            enableSystemMemoryPressureSource: false
        )

        let failureCount = AtomicUInt64(0)
        supervisor.setEventHandler { event in
            if case .transcriptionFailed = event {
                failureCount.increment()
            }
        }

        let model = ModelDescriptor(
            id: "m1",
            displayName: "CrashTest",
            filePath: "/tmp/test.gguf",
            storageMode: .reference,
            fileSizeBytes: 100,
            statFingerprint: nil,
            capabilities: ModelCapabilities()
        )
        let req = WorkerTranscriptionRequest(
            requestID: 1,
            model: model,
            pcm: PCMStore(sampleRate: 16_000, samples: [Float](repeating: 0.2, count: 3200))
        )
        supervisor.submitTranscription(req)

        await waitUntil({ failureCount.load() >= 1 && supervisor.currentState == .stopped }, timeoutMs: 5_000)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(failureCount.load() == 1)
        #expect(supervisor.currentState == .stopped)
        let spawns = (try? String(contentsOf: countFile, encoding: .utf8))?.split(separator: "\n").count ?? 0
        #expect(spawns == 1)
    }

    @Test("P1-18: probeModel rejects under .critical memory pressure and rejects files exceeding maxModelBytes before spawning")
    func testProbeModelCriticalAndSizeCap() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-probe-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bigFile = tmpDir.appendingPathComponent("too-big.gguf")
        try Data(repeating: 0x55, count: 2048).write(to: bigFile)

        // Cap set to 1024 bytes for deterministic test
        let supervisor = WorkerSupervisor(
            workerExecutablePath: "/bin/echo",
            warmTTLSeconds: 60,
            maxModelBytes: 1024,
            enableSystemMemoryPressureSource: false
        )

        let sizeResult: Result<LDPProbeResultPayload, ModelProbeError> = await withCheckedContinuation { cont in
            supervisor.probeModel(at: bigFile.path) { cont.resume(returning: $0) }
        }
        guard case let .failure(.modelTooLarge(bytes, limit)) = sizeResult else {
            Issue.record("Expected modelTooLarge error, got \(sizeResult)")
            return
        }
        #expect(bytes == 2048)
        #expect(limit == 1024)

        // Under .critical pressure, probeModel rejects immediately even for small files
        let smallFile = tmpDir.appendingPathComponent("small.gguf")
        try Data("ok".utf8).write(to: smallFile)
        supervisor.handleMemoryPressure(.critical)
        await waitUntil { supervisor.currentMemoryPressure == .critical }

        let critResult: Result<LDPProbeResultPayload, ModelProbeError> = await withCheckedContinuation { cont in
            supervisor.probeModel(at: smallFile.path) { cont.resume(returning: $0) }
        }
        #expect(critResult == .failure(.memoryPressureCritical))
    }

    @Test("P0-3: Warning memory pressure timeout on active .busy inference emits transcriptionFailed instead of stranding")
    func testWarningMemoryAbortEmitsTranscriptionFailed() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ld-warn-busy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let slowWorker = tmpDir.appendingPathComponent("slow-worker")
        // Responds READY to WARMUP, then hangs on TRANSCRIBE until killed/shutdown so .warning 3s abort triggers.
        let script = """
        #!/usr/bin/env python3
        import os, struct, time

        def read_exact(fd, n):
            buf = bytearray()
            while len(buf) < n:
                chunk = os.read(fd, n - len(buf))
                if not chunk:
                    raise EOFError()
                buf.extend(chunk)
            return bytes(buf)

        while True:
            try:
                hdr = read_exact(3, 32)
            except EOFError:
                break
            magic, ver, mtype, req_id, att_id, plen, flags = struct.unpack("<4sHHQQII", hdr)
            if plen > 0:
                _ = read_exact(3, plen)
            if mtype == 0x01:
                payload = b'{"modelPath":"/tmp/m.gguf","roles":["asr"],"arch":"qwen3_asr","variant":"0.6b","nativeSampleRate":16000,"maxAudioMs":30000,"physFootprintBytes":1000}'
                os.write(4, struct.pack("<4sHHQQII", b"LDP1", 1, 0x81, req_id, att_id, len(payload), 0) + payload)
            elif mtype == 0x02:
                time.sleep(10)
            elif mtype == 0x04:
                break
        """
        try script.write(to: slowWorker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowWorker.path)

        let supervisor = WorkerSupervisor(
            workerExecutablePath: slowWorker.path,
            warmTTLSeconds: 60,
            enableSystemMemoryPressureSource: false
        )
        defer { supervisor.forceShutdownImmediately() }

        let gotWarningFailure = AtomicBool(false)
        let startedBusy = AtomicBool(false)
        supervisor.setEventHandler { event in
            switch event {
            case .transcriptionStarted:
                startedBusy.store(true, ordering: .release)
            case let .transcriptionFailed(id, _, isCritical):
                if id != nil && !isCritical {
                    gotWarningFailure.store(true, ordering: .release)
                }
            default:
                break
            }
        }

        let model = ModelDescriptor(
            id: "m1",
            displayName: "SlowModel",
            filePath: "/tmp/m.gguf",
            storageMode: .reference,
            fileSizeBytes: 100,
            statFingerprint: nil,
            capabilities: ModelCapabilities()
        )
        supervisor.submitTranscription(WorkerTranscriptionRequest(
            requestID: 42,
            model: model,
            pcm: PCMStore(sampleRate: 16_000, samples: [Float](repeating: 0.1, count: 1600))
        ))

        await waitUntil({ startedBusy.load() }, timeoutMs: 6_000)
        #expect(startedBusy.load() == true)

        // Trigger .warning while worker is .busy -> after 3s grace, emits transcriptionFailed (non-critical)!
        supervisor.handleMemoryPressure(.warning)

        await waitUntil({ gotWarningFailure.load() }, timeoutMs: 8_000)
        #expect(gotWarningFailure.load() == true)
    }
}
