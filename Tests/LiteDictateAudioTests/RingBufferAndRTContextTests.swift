import CLiteDictateAudio
import Foundation
import LiteDictateCore
import XCTest

final class RingBufferAndRTContextTests: XCTestCase {
    func testRingBuffer2SecondSizingAndMemoryBounds() {
        // 48 kHz mono -> exact 2.0s = 96,000 frames = 384,000 bytes (<= 512 KiB).
        guard let monoRB = ld_ring_create(1, 48_000.0, 2.0, Int(LD_AUDIO_DEFAULT_RING_MAX_BYTES)) else {
            XCTFail("Failed to allocate mono ring buffer")
            return
        }
        defer { ld_ring_destroy(monoRB) }
        XCTAssertEqual(ld_ring_capacity_frames(monoRB), 96_000)
        XCTAssertEqual(ld_ring_byte_capacity(monoRB), 384_000)

        // High-rate multi-channel external interface (8ch @ 192 kHz):
        // ring + scratch + 29.5s 16 kHz mono PCMStore (1.888 MB) MUST stay strictly <= 2.5 MB!
        guard let extremeCtx = ld_capture_context_create(
            8,
            192_000.0,
            2048,
            false,
            2.0,
            Int(LD_AUDIO_DEFAULT_RING_MAX_BYTES)
        ) else {
            XCTFail("Failed to allocate extreme capture context")
            return
        }
        defer { ld_capture_context_destroy(extremeCtx) }

        let contextBytes = ld_capture_context_memory_bytes(extremeCtx)
        let pcmStore29_5sBytes = 472_000 * MemoryLayout<Float>.size // 1,888,000 bytes
        let totalStreamingBytes = contextBytes + pcmStore29_5sBytes
        XCTAssertLessThanOrEqual(
            totalStreamingBytes,
            2_500_000,
            "Total streaming RAM (\(totalStreamingBytes) bytes) must remain <= 2.5 MB even at 8ch 192 kHz"
        )
    }

    func testRingBufferOverflowPreservesUnreadOldFramesAndMarksInterrupted() {
        guard let ctx = ld_capture_context_create(
            2,
            48_000.0,
            512,
            false,
            0.001, // 48 frames capacity
            1024
        ) else {
            XCTFail("Failed to create capture context")
            return
        }
        defer { ld_capture_context_destroy(ctx) }

        let ring = ld_capture_context_ring_buffer(ctx)
        let cap = Int(ld_ring_capacity_frames(ring))
        XCTAssertEqual(cap, 48)

        ld_capture_context_set_accept_audio(ctx, true)

        // Write `cap` frames with recognizable sentinel values (1.0 ..< cap+1).
        var oldFrames = [Float](repeating: 0, count: cap * 2)
        for f in 0..<cap {
            oldFrames[f * 2] = Float(f + 1) / 1000.0
            oldFrames[f * 2 + 1] = -Float(f + 1) / 1000.0
        }
        oldFrames.withUnsafeBufferPointer { buf in
            ld_capture_context_ingest_interleaved_for_testing(ctx, buf.baseAddress!, UInt32(cap), 100)
        }

        var telemetry = ld_capture_context_read_telemetry(ctx)
        XCTAssertTrue(telemetry.capture_started)
        XCTAssertTrue(telemetry.first_frame_received)
        XCTAssertFalse(telemetry.audio_interrupted)
        XCTAssertEqual(telemetry.dropped_frames, 0)

        // Attempt to write 20 NEW frames while buffer is completely full.
        let newFrames = [Float](repeating: 0.999, count: 20 * 2)
        newFrames.withUnsafeBufferPointer { buf in
            ld_capture_context_ingest_interleaved_for_testing(ctx, buf.baseAddress!, 20, 200)
        }

        telemetry = ld_capture_context_read_telemetry(ctx)
        XCTAssertTrue(telemetry.audio_interrupted, "Overflow MUST set audio_interrupted = true")
        XCTAssertEqual(telemetry.dropped_frames, 20, "All 20 excess frames must be counted as dropped")

        // Drain buffer and verify ALL unread OLD frames were preserved completely intact!
        var drained = [Float](repeating: 0, count: cap * 2)
        let readCount = drained.withUnsafeMutableBufferPointer { buf in
            Int(ld_ring_read_interleaved(ring, buf.baseAddress!, UInt32(cap)))
        }
        XCTAssertEqual(readCount, cap)
        for i in 0..<(cap * 2) {
            XCTAssertEqual(drained[i], oldFrames[i], accuracy: 1e-6, "Old frame sample \(i) corrupted on overflow")
        }
    }

    func testRingBufferPartialOverflowPreservesOldAndAcceptsAvailableHeadroom() {
        guard let rb = ld_ring_create_exact(1, 10) else {
            XCTFail("Failed to allocate ring buffer")
            return
        }
        defer { ld_ring_destroy(rb) }

        let batch1: [Float] = [1, 2, 3, 4, 5, 6]
        var dropped: UInt32 = 0
        let w1 = batch1.withUnsafeBufferPointer { ld_ring_write_interleaved(rb, $0.baseAddress!, 6, &dropped) }
        XCTAssertEqual(w1, 6)
        XCTAssertEqual(dropped, 0)

        // Only 4 frames of headroom left; attempt to write 7 -> accepts first 4, drops last 3.
        let batch2: [Float] = [7, 8, 9, 10, 11, 12, 13]
        let w2 = batch2.withUnsafeBufferPointer { ld_ring_write_interleaved(rb, $0.baseAddress!, 7, &dropped) }
        XCTAssertEqual(w2, 4)
        XCTAssertEqual(dropped, 3)

        var out = [Float](repeating: 0, count: 10)
        let r = out.withUnsafeMutableBufferPointer { ld_ring_read_interleaved(rb, $0.baseAddress!, 10) }
        XCTAssertEqual(r, 10)
        XCTAssertEqual(out, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    func testRingBufferNonInterleavedWriteAndWraparound() {
        guard let rb = ld_ring_create_exact(2, 8) else {
            XCTFail("Failed to create ring buffer")
            return
        }
        defer { ld_ring_destroy(rb) }

        // Advance read/write offset to force wraparound across boundary.
        let prime: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4, 0.5, -0.5]
        _ = prime.withUnsafeBufferPointer { ld_ring_write_interleaved(rb, $0.baseAddress!, 5, nil) }
        var discard = [Float](repeating: 0, count: 10)
        _ = discard.withUnsafeMutableBufferPointer { ld_ring_read_interleaved(rb, $0.baseAddress!, 5) }

        let ch0: [Float] = [10, 20, 30, 40, 50, 60]
        let ch1: [Float] = [-10, -20, -30, -40, -50, -60]
        var dropped: UInt32 = 99
        let written: UInt32 = ch0.withUnsafeBufferPointer { b0 in
            ch1.withUnsafeBufferPointer { b1 in
                var ptrs: [UnsafePointer<Float>] = [b0.baseAddress!, b1.baseAddress!]
                return ptrs.withUnsafeMutableBufferPointer { ptrBuf in
                    ld_ring_write_noninterleaved(rb, ptrBuf.baseAddress!, 2, 6, &dropped)
                }
            }
        }
        XCTAssertEqual(written, 6)
        XCTAssertEqual(dropped, 0)

        var out = [Float](repeating: 0, count: 12)
        let readCount = out.withUnsafeMutableBufferPointer { ld_ring_read_interleaved(rb, $0.baseAddress!, 6) }
        XCTAssertEqual(readCount, 6)
        XCTAssertEqual(out, [10, -10, 20, -20, 30, -30, 40, -40, 50, -50, 60, -60])
    }

    func testSPSCConcurrentProducerConsumerStress() {
        guard let rb = ld_ring_create_exact(2, 4096) else {
            XCTFail("Failed to create ring buffer")
            return
        }
        defer { ld_ring_destroy(rb) }

        final class RingBox: @unchecked Sendable {
            let rb: OpaquePointer
            init(_ rb: OpaquePointer) { self.rb = rb }
        }
        let box = RingBox(rb)

        let totalFrames = 100_000
        let producerDone = expectation(description: "Producer finished")
        let consumerDone = expectation(description: "Consumer finished")

        let producerQueue = DispatchQueue(label: "test.spsc.producer", qos: .userInteractive)
        let consumerQueue = DispatchQueue(label: "test.spsc.consumer", qos: .userInitiated)

        producerQueue.async {
            var produced = 0
            var chunk = [Float](repeating: 0, count: 256 * 2)
            while produced < totalFrames {
                let n = min(256, totalFrames - produced)
                for i in 0..<n {
                    let seq = Float(produced + i)
                    chunk[i * 2] = seq
                    chunk[i * 2 + 1] = -seq
                }
                var offset = 0
                while offset < n {
                    let written: Int = chunk.withUnsafeBufferPointer { buf in
                        Int(ld_ring_write_interleaved(
                            box.rb,
                            buf.baseAddress!.advanced(by: offset * 2),
                            UInt32(n - offset),
                            nil
                        ))
                    }
                    if written == 0 {
                        sched_yield()
                    } else {
                        offset += written
                    }
                }
                produced += n
            }
            producerDone.fulfill()
        }

        final class VerificationResult: @unchecked Sendable {
            var mismatchCount = 0
            var framesRead = 0
        }
        let verify = VerificationResult()

        consumerQueue.async {
            var expected = 0
            var buf = [Float](repeating: 0, count: 311 * 2)
            while expected < totalFrames {
                let read: Int = buf.withUnsafeMutableBufferPointer { ptr in
                    Int(ld_ring_read_interleaved(box.rb, ptr.baseAddress!, 311))
                }
                if read == 0 {
                    sched_yield()
                    continue
                }
                for i in 0..<read {
                    let seq = Float(expected + i)
                    if buf[i * 2] != seq || buf[i * 2 + 1] != -seq {
                        verify.mismatchCount += 1
                    }
                }
                expected += read
            }
            verify.framesRead = expected
            consumerDone.fulfill()
        }

        wait(for: [producerDone, consumerDone], timeout: 10.0)
        XCTAssertEqual(verify.framesRead, totalFrames)
        XCTAssertEqual(verify.mismatchCount, 0)
        XCTAssertEqual(ld_ring_available_read(rb), 0)
    }

    func testMonotonicConsumerWaiterTimeoutAndImmediateSignalWake() {
        guard let waiter = ld_waiter_create() else {
            XCTFail("Failed to create waiter")
            return
        }
        defer { ld_waiter_destroy(waiter) }

        // 1. Timed wait returns false on 10ms timeout.
        let t0 = DispatchTime.now().uptimeNanoseconds
        let signalled1 = ld_waiter_wait_ms(waiter, 10)
        let elapsedMs1 = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        XCTAssertFalse(signalled1)
        XCTAssertGreaterThanOrEqual(elapsedMs1, 7.0)

        // 2. Explicit signal wakes waiter immediately even with 500ms timeout.
        final class WaiterBox: @unchecked Sendable {
            let w: OpaquePointer
            init(_ w: OpaquePointer) { self.w = w }
        }
        let wBox = WaiterBox(waiter)

        let wakeStart = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(15)) {
            ld_waiter_signal(wBox.w)
        }
        let signalled2 = ld_waiter_wait_ms(waiter, 500)
        let elapsedMs2 = Double(DispatchTime.now().uptimeNanoseconds - wakeStart) / 1_000_000.0
        XCTAssertTrue(signalled2)
        XCTAssertLessThan(elapsedMs2, 150.0, "Signal must wake consumer immediately instead of waiting 500ms")
    }
}
