import Darwin
import Foundation
import Testing
@testable import LiteDictateCore

@Suite("LDP1 Protocol, Atomics & Diagnostic Ring Buffer")
struct LDPProtocolClientTests {
    @Test("AtomicBool and AtomicUInt64 lock-free C11 operations")
    func testAtomics() {
        let flag = AtomicBool(false)
        #expect(flag.load(ordering: .acquire) == false)
        flag.store(true, ordering: .release)
        #expect(flag.load(ordering: .acquire) == true)
        #expect(flag.exchange(false) == true)
        #expect(flag.compareExchange(expected: false, desired: true) == true)
        #expect(flag.compareExchange(expected: false, desired: false) == false)

        let counter = AtomicUInt64(10)
        #expect(counter.load() == 10)
        #expect(counter.fetchAdd(5) == 10)
        #expect(counter.load() == 15)
        #expect(counter.increment() == 16)
        #expect(counter.exchange(100) == 16)
        #expect(counter.compareExchange(expected: 100, desired: 200) == true)
        #expect(counter.load() == 200)
    }

    @Test("LDPFrameHeader exact 32-byte little-endian layout matches C++ contract")
    func testFrameHeaderLayout() throws {
        let header = LDPFrameHeader(
            msgType: .transcribe,
            requestID: 0x0102_0304_0506_0708,
            attemptID: 0x1112_1314_1516_1718,
            payloadLen: 4096,
            statusOrFlags: 0x0000_0003
        )
        let bytes = header.encode()
        #expect(bytes.count == 32)
        #expect(Array(bytes[0..<4]) == [0x4C, 0x44, 0x50, 0x31]) // "LDP1"
        #expect(bytes[4] == 1 && bytes[5] == 0)                 // version = 1 LE
        #expect(bytes[6] == 0x02 && bytes[7] == 0x00)           // msgType = 0x02 LE

        let decoded = try LDPFrameHeader.decode(bytes)
        #expect(decoded == header)
    }

    @Test("LDPFrameHeader rejects bad magic, bad version, and oversized payload")
    func testFrameHeaderValidation() {
        var badMagic = LDPFrameHeader(msgType: .ping).encode()
        badMagic[0] = 0x58
        #expect(throws: LDPProtocolError.invalidMagic) {
            _ = try LDPFrameHeader.decode(badMagic)
        }

        var badVersion = LDPFrameHeader(msgType: .ping).encode()
        badVersion[4] = 2
        #expect(throws: LDPProtocolError.unsupportedVersion(2)) {
            _ = try LDPFrameHeader.decode(badVersion)
        }

        let oversized = LDPFrameHeader(msgType: .transcribe, payloadLen: UInt32(LiteDictateConstants.maxFrameBytes + 1)).encode()
        #expect(throws: LDPProtocolError.payloadTooLarge(UInt32(LiteDictateConstants.maxFrameBytes + 1))) {
            _ = try LDPFrameHeader.decode(oversized)
        }
    }

    @Test("0x02 TRANSCRIBE framing encodes 4-byte aligned PCM and validates NaN/Inf and >50 vocab")
    func testTranscribeFrameRoundTrip() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 0.75, -1.0]
        let pcm = PCMStore(sampleRate: 16_000, samples: samples)
        let meta = LDPTranscribeMetadata(
            sampleRate: 16_000,
            language: "zh",
            vocabulary: ["SwiftUI", "LiteDictate"],
            contextPrompt: nil
        )
        let frame = try LDPProtocolClient.makeTranscribeFrame(
            requestID: 42,
            attemptID: 7,
            metadata: meta,
            pcm: pcm
        )
        #expect(frame.header.msgType == .transcribe)
        #expect(frame.header.requestID == 42)
        #expect(frame.header.attemptID == 7)
        #expect(frame.payload.count == Int(frame.header.payloadLen))

        let decoded = try LDPProtocolClient.decodeTranscribePayload(frame.payload)
        #expect(decoded.metadata == meta)
        #expect(decoded.samples == samples)

        // NaN rejection
        let nanPCM = PCMStore(sampleRate: 16_000, samples: [0.1, .nan, 0.2])
        #expect(throws: LDPProtocolError.nonFiniteAudioSamples) {
            _ = try LDPProtocolClient.makeTranscribeFrame(requestID: 1, attemptID: 1, metadata: meta, pcm: nanPCM)
        }

        // Inf rejection
        let infPCM = PCMStore(sampleRate: 16_000, samples: [0.1, .infinity])
        #expect(throws: LDPProtocolError.nonFiniteAudioSamples) {
            _ = try LDPProtocolClient.makeTranscribeFrame(requestID: 1, attemptID: 1, metadata: meta, pcm: infPCM)
        }

        // > 50 vocabulary entries rejection
        let hugeVocab = (0..<51).map { "word\($0)" }
        let hugeMeta = LDPTranscribeMetadata(vocabulary: hugeVocab)
        #expect(throws: LDPProtocolError.tooManyVocabularyEntries(51)) {
            _ = try LDPProtocolClient.makeTranscribeFrame(requestID: 1, attemptID: 1, metadata: hugeMeta, pcm: pcm)
        }
    }

    @Test("FD pipe writeFrame and readFrame roundtrip")
    func testPipeRoundTrip() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }

        let req = LDPWarmupRequest(modelPath: "/tmp/model.gguf", backend: "metal", noMmap: false)
        let frame = try LDPProtocolClient.makeJSONFrame(msgType: .warmup, requestID: 9, attemptID: 2, body: req)
        try LDPProtocolClient.writeFrame(frame, to: fds[1])
        let received = try LDPProtocolClient.readFrame(from: fds[0])
        #expect(received == frame)

        let decoded = try LDPProtocolClient.decodeJSONPayload(LDPWarmupRequest.self, from: received.payload)
        #expect(decoded == req)
    }

    @Test("DiagnosticLogRingBuffer caps capacity and preserves latest tail")
    func testDiagnosticRingBuffer() {
        let ring = DiagnosticLogRingBuffer(capacity: 1024)
        let chunkA = Array(String(repeating: "A", count: 800).utf8)
        let chunkB = Array(String(repeating: "B", count: 600).utf8)
        chunkA.withUnsafeBufferPointer { ring.append($0) }
        chunkB.withUnsafeBufferPointer { ring.append($0) }

        let text = ring.snapshotText()
        #expect(text.utf8.count == 1024)
        #expect(text.hasSuffix(String(repeating: "B", count: 600)))
        #expect(text.hasPrefix(String(repeating: "A", count: 424)))
    }

    @Test("PCMStore chunks into 1s slices and hard-clamps accurately")
    func testPCMStoreChunkingAndClamp() {
        var store = PCMStore(sampleRate: 16_000)
        store.append([Float](repeating: 0.5, count: 20_000))
        store.append([Float](repeating: -0.25, count: 15_000))
        #expect(store.totalSampleCount == 35_000)
        #expect(store.chunks.count == 3) // 16k + 16k + 3k
        #expect(store.chunks[0].count == 16_000)
        #expect(store.chunks[1].count == 16_000)
        #expect(store.chunks[2].count == 3_000)

        let clamped = store.clamped(maxSamples: 18_000)
        #expect(clamped.totalSampleCount == 18_000)
        #expect(clamped.chunks.count == 2)
        #expect(clamped.chunks[1].count == 2_000)
    }
}
