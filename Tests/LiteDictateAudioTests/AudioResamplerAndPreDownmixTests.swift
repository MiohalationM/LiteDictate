import CLiteDictateAudio
import Foundation
import LiteDictateCore
import XCTest

final class AudioResamplerAndPreDownmixTests: XCTestCase {
    private func makeSineWave(
        frequency: Double,
        sampleRate: Double,
        frameCount: Int,
        amplitude: Float
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount)
        let twoPiF = 2.0 * Double.pi * frequency / sampleRate
        for i in 0..<frameCount {
            samples[i] = amplitude * Float(sin(twoPiF * Double(i)))
        }
        return samples
    }

    func testMono48kHzTo16kHzResamplingStarvationAndEOSTailFlush() throws {
        let hwRate = 48_000.0
        let targetRate = 16_000
        let durationSec = 0.5
        let hwFrames = Int(hwRate * durationSec) // 24,000 frames
        let expectedOutSamples = Int(Double(targetRate) * durationSec) // 8,000 samples

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 1,
            hardwareSampleRate: hwRate,
            targetSampleRate: targetRate,
            maxOutputSamples: 472_000
        )

        let sine = makeSineWave(frequency: 1_000.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: 0.5)

        // Feed in realistic 10 ms chunks (480 frames @ 48 kHz) to exercise kLiteDictateAudioNoDataNow starvation.
        let chunkFrames = 480
        var offset = 0
        while offset < hwFrames {
            let count = min(chunkFrames, hwFrames - offset)
            let chunk = Array(sine[offset..<(offset + count)])
            pipeline.appendInterleaved(chunk)
            offset += count
        }

        XCTAssertGreaterThan(
            pipeline.starvationReturnCount,
            0,
            "Converter should encounter kLiteDictateAudioNoDataNow across 10ms streaming chunks"
        )

        let pcm = pipeline.finishEOS()
        XCTAssertGreaterThan(
            pipeline.eosFlushedSampleCount,
            0,
            "True EOS (0 packets + noErr) should flush converter FIR filter tail frames"
        )
        XCTAssertEqual(pcm.sampleRate, targetRate)
        // Output count should match 8,000 samples closely (within small FIR latency tolerance).
        XCTAssertLessThanOrEqual(abs(pcm.totalSampleCount - expectedOutSamples), 64)

        let peakDBFS = pcm.peakDBFS()
        let expectedDBFS = 20.0 * log10f(0.5) // -6.02 dBFS
        XCTAssertEqual(peakDBFS, expectedDBFS, accuracy: 0.5, "Resampling should preserve signal amplitude")
    }

    func testTwoChannelSingleMicPreDownmixHasNoMinus6dBDrop() throws {
        // Simulates a Scarlett 2i2 USB interface with mic plugged ONLY into Input 1 (ch0),
        // while Input 2 (ch1) is silent (0.0). Naive (L+R)/2 would attenuate by -6.02 dB!
        let hwRate = 48_000.0
        let hwFrames = 24_000
        let amplitude: Float = 0.5 // -6.02 dBFS

        let sine = makeSineWave(frequency: 440.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: amplitude)
        var interleaved = [Float](repeating: 0, count: hwFrames * 2)
        for i in 0..<hwFrames {
            interleaved[i * 2] = sine[i]
            interleaved[i * 2 + 1] = 0.0 // unused XLR input
        }

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 2,
            hardwareSampleRate: hwRate,
            targetSampleRate: 16_000,
            maxOutputSamples: 472_000
        )

        let chunkFrames = 480
        var offset = 0
        while offset < hwFrames {
            let count = min(chunkFrames, hwFrames - offset)
            let slice = Array(interleaved[(offset * 2)..<((offset + count) * 2)])
            pipeline.appendInterleaved(slice)
            offset += count
        }

        let weights = pipeline.lastDownmixWeights
        XCTAssertEqual(weights.count, 2)
        XCTAssertEqual(weights[0], 1.0, accuracy: 0.01, "Active channel 0 must receive full 1.0 weight")
        XCTAssertEqual(weights[1], 0.0, accuracy: 0.01, "Silent channel 1 must receive 0.0 weight")

        let pcm = pipeline.finishEOS()
        let peakDBFS = pcm.peakDBFS()
        let expectedDBFS = 20.0 * log10f(amplitude) // -6.02 dBFS (NOT -12.04 dBFS!)
        XCTAssertEqual(
            peakDBFS,
            expectedDBFS,
            accuracy: 0.5,
            "2ch single-mic pre-downmix MUST NOT suffer -6 dB attenuation (got \(peakDBFS) dBFS vs \(expectedDBFS) dBFS)"
        )
    }

    func testTwoChannelSingleMicRejectsUnusedPreampNoiseFloor() throws {
        // Channel 0 has -14 dBFS speech (~0.2), Channel 1 has -72 dBFS idle preamp hum (~0.00025).
        let hwRate = 48_000.0
        let hwFrames = 4_800
        let active = makeSineWave(frequency: 500.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: 0.2)
        let noise = makeSineWave(frequency: 60.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: 0.00025)

        var interleaved = [Float](repeating: 0, count: hwFrames * 2)
        for i in 0..<hwFrames {
            interleaved[i * 2] = active[i]
            interleaved[i * 2 + 1] = noise[i]
        }

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 2,
            hardwareSampleRate: hwRate,
            targetSampleRate: 16_000,
            maxOutputSamples: 472_000
        )
        pipeline.appendInterleaved(interleaved)

        let weights = pipeline.lastDownmixWeights
        XCTAssertEqual(weights[0], 1.0, accuracy: 0.01)
        XCTAssertEqual(weights[1], 0.0, accuracy: 0.01)
    }

    func testTwoChannelBalancedStereoPreservesLevelWithoutClipping() throws {
        let hwRate = 48_000.0
        let hwFrames = 12_000
        let amplitude: Float = 0.4
        let sine = makeSineWave(frequency: 600.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: amplitude)

        var interleaved = [Float](repeating: 0, count: hwFrames * 2)
        for i in 0..<hwFrames {
            interleaved[i * 2] = sine[i]
            interleaved[i * 2 + 1] = sine[i]
        }

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 2,
            hardwareSampleRate: hwRate,
            targetSampleRate: 16_000,
            maxOutputSamples: 472_000
        )
        pipeline.appendInterleaved(interleaved)
        let weights = pipeline.lastDownmixWeights
        XCTAssertEqual(weights[0], 0.5, accuracy: 0.02)
        XCTAssertEqual(weights[1], 0.5, accuracy: 0.02)

        let pcm = pipeline.finishEOS()
        let expectedDBFS = 20.0 * log10f(amplitude)
        XCTAssertEqual(pcm.peakDBFS(), expectedDBFS, accuracy: 0.5)
    }

    func testFourChannelInterfacePreDownmixAndResampleNoMinus12dBDrop() throws {
        // 4ch USB audio interface with mic plugged into Input 3 (index 2).
        // Naive 4ch AudioConverter often fails or drops -12 dB!
        let hwRate = 48_000.0
        let hwFrames = 24_000
        let amplitude: Float = 0.5
        let sine = makeSineWave(frequency: 800.0, sampleRate: hwRate, frameCount: hwFrames, amplitude: amplitude)

        var interleaved = [Float](repeating: 0, count: hwFrames * 4)
        for i in 0..<hwFrames {
            interleaved[i * 4 + 2] = sine[i]
        }

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 4,
            hardwareSampleRate: hwRate,
            targetSampleRate: 16_000,
            maxOutputSamples: 472_000
        )

        let chunkFrames = 480
        var offset = 0
        while offset < hwFrames {
            let count = min(chunkFrames, hwFrames - offset)
            let slice = Array(interleaved[(offset * 4)..<((offset + count) * 4)])
            pipeline.appendInterleaved(slice)
            offset += count
        }

        let weights = pipeline.lastDownmixWeights
        XCTAssertEqual(weights.count, 4)
        XCTAssertEqual(weights[0], 0.0, accuracy: 0.01)
        XCTAssertEqual(weights[1], 0.0, accuracy: 0.01)
        XCTAssertEqual(weights[2], 1.0, accuracy: 0.01)
        XCTAssertEqual(weights[3], 0.0, accuracy: 0.01)

        let pcm = pipeline.finishEOS()
        let expectedDBFS = 20.0 * log10f(amplitude)
        XCTAssertEqual(pcm.peakDBFS(), expectedDBFS, accuracy: 0.5)
        XCTAssertLessThanOrEqual(abs(pcm.totalSampleCount - 8_000), 64)
    }

    func testHardSampleClampAndPCMStoreChunkedBudget() throws {
        // Effective max = min(maxSamplesForModel = 4_000, captureLimitSamples = 80_000) -> 4,000 samples.
        let params = AudioCaptureParameters(
            targetSampleRate: 16_000,
            captureLimitMs: 5_000,
            maxSamplesForModel: 4_000,
            selectionMode: .smartAuto
        )
        let effectiveMax = AudioResamplerPipeline.effectiveMaxSamples(for: params)
        XCTAssertEqual(effectiveMax, 4_000)

        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 1,
            hardwareSampleRate: 48_000.0,
            targetSampleRate: 16_000,
            maxOutputSamples: effectiveMax
        )

        // Feed 1.0 second (48,000 hw frames -> 16,000 target samples >> 4,000 clamp).
        let sine = makeSineWave(frequency: 440.0, sampleRate: 48_000.0, frameCount: 48_000, amplitude: 0.3)
        let reachedLimit = pipeline.appendInterleaved(sine)
        XCTAssertTrue(reachedLimit)
        XCTAssertTrue(pipeline.truncatedByLimit)

        let pcm = pipeline.finishEOS()
        XCTAssertEqual(pcm.totalSampleCount, 4_000, "Output must be hard-clamped to effectiveMaxSamples even after EOS")

        // Verify 29.5s chunked PCMStore memory stays <= 1.888 MB (1s chunks = 64 KB each).
        var store = PCMStore(sampleRate: 16_000)
        let oneSec = [Float](repeating: 0.1, count: 16_000)
        for _ in 0..<29 {
            store.append(oneSec)
        }
        store.append([Float](repeating: 0.1, count: 8_000)) // +0.5s = 29.5s total
        XCTAssertEqual(store.totalSampleCount, 472_000)
        XCTAssertEqual(store.chunks.count, 30)
        XCTAssertEqual(store.estimatedMemoryBytes, 1_888_000)
    }

    func testRecallOrientedShortUtteranceGate() {
        // Drops ONLY if duration < 120 ms OR peak < -62 dBFS.
        XCTAssertTrue(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 0, peakDBFS: -10.0))
        XCTAssertTrue(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 119, peakDBFS: -6.0))
        XCTAssertTrue(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 500, peakDBFS: -62.1))
        XCTAssertTrue(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 2_000, peakDBFS: -120.0))

        // Boundary & short commands ("git", "diff", "对") MUST NOT be dropped!
        XCTAssertFalse(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 120, peakDBFS: -62.0))
        XCTAssertFalse(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 120, peakDBFS: -25.0))
        XCTAssertFalse(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 180, peakDBFS: -40.0))
        XCTAssertFalse(AudioResamplerPipeline.shouldDropByShortUtteranceGate(durationMs: 1_500, peakDBFS: -61.9))
    }

    func testParameterBoundsSanitizationAndConsumerFriendlyPipelineErrors() throws {
        // P1-10: targetSampleRate outside 8_000...48_000 falls back to 16_000; valid values preserved.
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(0), 16_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(7_999), 16_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(8_000), 8_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(16_000), 16_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(48_000), 48_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(48_001), 16_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeTargetSampleRate(192_000), 16_000)

        // P1-10: captureLimitMs clamped strictly to 5_000...29_500.
        XCTAssertEqual(AudioResamplerPipeline.sanitizeCaptureLimitMs(0), 5_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeCaptureLimitMs(10_000), 10_000)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeCaptureLimitMs(600_000), 29_500)

        // P1-10: maxSamplesForModel clamped strictly to 1...(29_500 * 48).
        XCTAssertEqual(AudioResamplerPipeline.sanitizeMaxSamples(0), 1)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeMaxSamples(-100), 1)
        XCTAssertEqual(AudioResamplerPipeline.sanitizeMaxSamples(Int.max), 29_500 * 48)

        let hostileParams = AudioCaptureParameters(
            targetSampleRate: 384_000,
            captureLimitMs: 999_999,
            maxSamplesForModel: Int.max,
            selectionMode: .smartAuto
        )
        let sanitized = AudioResamplerPipeline.sanitizedParameters(hostileParams)
        XCTAssertEqual(sanitized.targetSampleRate, 16_000)
        XCTAssertEqual(sanitized.captureLimitMs, 29_500)
        XCTAssertEqual(sanitized.maxSamplesForModel, 29_500 * 48)
        XCTAssertEqual(AudioResamplerPipeline.effectiveMaxSamples(for: hostileParams), 29_500 * 16)

        // Pipeline init enforces the same bounds directly against bogus target rate / huge max samples.
        let pipeline = try AudioResamplerPipeline(
            hardwareChannels: 1,
            hardwareSampleRate: 48_000.0,
            targetSampleRate: 500_000,
            maxOutputSamples: Int.max
        )
        XCTAssertEqual(pipeline.targetSampleRate, 16_000)
        XCTAssertEqual(pipeline.pcmStore.sampleRate, 16_000)
        XCTAssertEqual(pipeline.maxOutputSamples, 29_500 * 48)

        // P2-2: user-facing errors hide raw OSStatus/CoreAudio jargon while debugDescription keeps diagnostics.
        let auError = AudioPipelineError.audioUnitFailed("AudioUnitInitialize", OSStatus(-10863))
        XCTAssertFalse(auError.userFacingMessage.contains("OSStatus"))
        XCTAssertFalse(auError.userFacingMessage.contains("-10863"))
        XCTAssertFalse(auError.userFacingMessage.contains("AUHAL"))
        XCTAssertTrue(auError.debugDescription.contains("OSStatus -10863"))

        let convError = AudioPipelineError.converterCreationFailed(OSStatus(-50))
        XCTAssertFalse(convError.userFacingMessage.contains("OSStatus"))
        XCTAssertTrue(convError.debugDescription.contains("OSStatus -50"))
    }
}
