import Foundation
import Testing
@testable import LiteDictateCore

private final class MockModelProber: ModelProbing, @unchecked Sendable {
    var handler: @Sendable (String) -> Result<LDPProbeResultPayload, ModelProbeError>

    init(handler: @escaping @Sendable (String) -> Result<LDPProbeResultPayload, ModelProbeError>) {
        self.handler = handler
    }

    func probeModel(at path: String, completion: @escaping @Sendable (Result<LDPProbeResultPayload, ModelProbeError>) -> Void) {
        completion(handler(path))
    }
}

@Suite("ModelRegistry & TextPostProcessor")
struct ModelRegistryTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ld-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Import rejects non-ASR model (e.g. silero_vad) and accepts ASR model in reference & copy modes")
    func testImportProbeAndStorageModes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let externalDir = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)

        let vadFile = externalDir.appendingPathComponent("silero-vad-v6.2-F32.gguf")
        let asrFile = externalDir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
        let whisperFile = externalDir.appendingPathComponent("whisper-small.gguf")
        try Data("vad-bytes".utf8).write(to: vadFile)
        try Data("asr-bytes-payload".utf8).write(to: asrFile)
        try Data("whisper-bytes".utf8).write(to: whisperFile)

        let prober = MockModelProber { path in
            if path.contains("silero-vad") {
                return .failure(.unsupportedRole(roles: ["vad"], arch: "silero_vad", variant: "v6.2"))
            }
            if path.contains("whisper") {
                return .success(LDPProbeResultPayload(
                    modelPath: path,
                    roles: ["asr"],
                    arch: "whisper",
                    variant: "small",
                    nativeSampleRate: 16_000,
                    maxAudioMs: 30_000,
                    supportsVocabulary: false,
                    supportsContextPrompt: false,
                    supportsInitialPrompt: true
                ))
            }
            return .success(LDPProbeResultPayload(
                modelPath: path,
                roles: ["asr"],
                arch: "qwen3_asr",
                variant: "0.6b",
                nativeSampleRate: 16_000,
                maxAudioMs: 30_000,
                supportsVocabulary: true,
                supportsContextPrompt: true
            ))
        }

        let registry = ModelRegistry(appSupportDirectory: appSupport, discoveryDirectories: [externalDir])

        // Discovery finds all 3 unregistered .gguf files
        let discovered = registry.discoverLocalModels()
        #expect(discovered.count == 3)

        // 1. VAD file MUST be rejected
        let vadResult: Result<ModelDescriptor, ModelRegistryError> = await withCheckedContinuation { cont in
            registry.importModel(from: vadFile, storageMode: .reference, prober: prober) { cont.resume(returning: $0) }
        }
        guard case let .failure(.probeFailed(.unsupportedRole(roles, _, _))) = vadResult else {
            Issue.record("Expected unsupportedRole failure for VAD model, got \(vadResult)")
            return
        }
        #expect(roles == ["vad"])
        #expect(registry.models.isEmpty)

        // 2. Reference mode stores original path + stat fingerprint (zero copy)
        let refResult: Result<ModelDescriptor, ModelRegistryError> = await withCheckedContinuation { cont in
            registry.importModel(from: asrFile, storageMode: .reference, prober: prober) { cont.resume(returning: $0) }
        }
        let qwen = try refResult.get()
        #expect(qwen.storageMode == .reference)
        #expect(qwen.filePath == asrFile.standardizedFileURL.path)
        #expect(qwen.statFingerprint != nil)
        #expect(qwen.statFingerprint?.fileSizeBytes == UInt64("asr-bytes-payload".utf8.count))
        #expect(qwen.capabilities.effectiveCaptureLimitMs == 29_500)
        #expect(registry.activeModelID == qwen.id)

        // 3. Copy mode atomically copies into AppSupport/models/
        let copyResult: Result<ModelDescriptor, ModelRegistryError> = await withCheckedContinuation { cont in
            registry.importModel(from: whisperFile, storageMode: .copied, prober: prober) { cont.resume(returning: $0) }
        }
        let whisper = try copyResult.get()
        #expect(whisper.storageMode == .copied)
        #expect(whisper.filePath.hasPrefix(registry.modelsDirectory.standardizedFileURL.path))
        #expect(FileManager.default.fileExists(atPath: whisper.filePath))

        // 4. Reload persistence from models.json
        let reloaded = ModelRegistry(appSupportDirectory: appSupport, discoveryDirectories: [externalDir])
        #expect(reloaded.models.count == 2)
        #expect(reloaded.activeModelID == qwen.id)

        // 5. Missing-file stat detection + relink
        try FileManager.default.removeItem(at: asrFile)
        let verifyMissing = reloaded.verifyActiveModelForLaunch()
        guard case .failure(.fileNotFound) = verifyMissing else {
            Issue.record("Expected fileNotFound when referenced file was deleted")
            return
        }
        #expect(reloaded.activeModel?.isFileMissing == true)

        let movedFile = externalDir.appendingPathComponent("Qwen3-ASR-Moved.gguf")
        try Data("asr-moved".utf8).write(to: movedFile)
        let relinkResult: Result<ModelDescriptor, ModelRegistryError> = await withCheckedContinuation { cont in
            reloaded.relinkModel(id: qwen.id, newURL: movedFile, prober: prober) { cont.resume(returning: $0) }
        }
        let relinked = try relinkResult.get()
        #expect(relinked.filePath == movedFile.standardizedFileURL.path)
        #expect(relinked.isFileMissing == false)
        #expect((try? reloaded.verifyActiveModelForLaunch().get().id) == qwen.id)
    }

    @Test("Dynamic capture limit clamps to min(29500, max(5000, maxAudioMs - 500))")
    func testCaptureLimitFormula() {
        let shortCap = ModelCapabilities(maxAudioMs: 4_000)
        #expect(shortCap.effectiveCaptureLimitMs == 5_000)

        let midCap = ModelCapabilities(maxAudioMs: 15_000)
        #expect(midCap.effectiveCaptureLimitMs == 14_500)

        let standardCap = ModelCapabilities(maxAudioMs: 30_000)
        #expect(standardCap.effectiveCaptureLimitMs == 29_500)

        let hugeCap = ModelCapabilities(maxAudioMs: 120_000)
        #expect(hugeCap.effectiveCaptureLimitMs == 29_500)
    }

    @Test("TextPostProcessor caps vocab.txt at 50 entries, maps capabilities, and applies aliases.json longest-first")
    func testVocabAndAliases() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let vocabURL = root.appendingPathComponent("vocab.txt")
        let aliasesURL = root.appendingPathComponent("aliases.json")

        var lines = ["# comment", "", "  SwiftUI  ", "SwiftUI"]
        for i in 1...60 {
            lines.append("Term\(i)")
        }
        try lines.joined(separator: "\n").write(to: vocabURL, atomically: true, encoding: .utf8)

        let aliasJSON = """
        {
          "Swift UI": "SwiftUI",
          "Swift UI Kit": "SwiftUIKit"
        }
        """
        try aliasJSON.write(to: aliasesURL, atomically: true, encoding: .utf8)

        let processor = TextPostProcessor.load(vocabPath: vocabURL.path, aliasesPath: aliasesURL.path)
        #expect(processor.vocabulary.count == 50)
        #expect(processor.vocabulary.first == "SwiftUI")

        // Model supporting vocabulary gets vocabulary array
        let qwenCaps = ModelCapabilities(supportsVocabulary: true, supportsContextPrompt: true)
        let qwenParams = processor.inferencePromptParameters(for: qwenCaps)
        #expect(qwenParams.vocabulary?.count == 50)
        #expect(qwenParams.contextPrompt == nil)

        // Whisper model supporting initialPrompt gets contextPrompt string, NOT vocabulary
        let whisperCaps = ModelCapabilities(supportsVocabulary: false, supportsContextPrompt: false, supportsInitialPrompt: true)
        let whisperParams = processor.inferencePromptParameters(for: whisperCaps)
        #expect(whisperParams.vocabulary == nil)
        #expect(whisperParams.contextPrompt?.contains("SwiftUI") == true)

        // Model supporting neither gets nil for both
        let bareCaps = ModelCapabilities(supportsVocabulary: false, supportsContextPrompt: false, supportsInitialPrompt: false)
        let bareParams = processor.inferencePromptParameters(for: bareCaps)
        #expect(bareParams.vocabulary == nil)
        #expect(bareParams.contextPrompt == nil)

        // Longest-first alias replacement avoids partial clobber
        let replaced = processor.applyAliases(to: "Using Swift UI Kit and Swift UI today")
        #expect(replaced == "Using SwiftUIKit and SwiftUI today")
    }

    @Test("ModelRegistry deduplicates symlinks & shared POSIX inodes across modelsDirectory and external discovery dirs")
    func testSymlinkAndInodeDeduplication() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let appModelsDir = appSupport.appendingPathComponent("models", isDirectory: true)
        let t3Dir = root.appendingPathComponent("T3Models", isDirectory: true)
        try FileManager.default.createDirectory(at: appModelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: t3Dir, withIntermediateDirectories: true)

        let realFile = appModelsDir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
        let symlinkInT3 = t3Dir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
        try Data("qwen3-asr-weights".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(at: symlinkInT3, withDestinationURL: realFile)

        let prober = MockModelProber { path in
            .success(LDPProbeResultPayload(
                modelPath: path,
                roles: ["asr"],
                arch: "qwen3_asr",
                variant: "0.6b",
                nativeSampleRate: 16_000,
                maxAudioMs: 30_000,
                supportsVocabulary: true
            ))
        }

        let registry = ModelRegistry(
            appSupportDirectory: appSupport,
            discoveryDirectories: [appModelsDir, t3Dir]
        )

        // Real file in modelsDirectory + symlink in T3Models MUST appear only ONCE (pointing to real file).
        let beforeImport = registry.discoverLocalModels()
        #expect(beforeImport.count == 1)
        #expect(beforeImport.first?.filePath == realFile.resolvingSymlinksInPath().standardizedFileURL.path)

        // Importing with .copied when ALREADY inside modelsDirectory must keep exact path in-place without duplicating.
        let imported: ModelDescriptor = await withCheckedContinuation { cont in
            registry.importModel(from: realFile, storageMode: .copied, prober: prober) { result in
                cont.resume(returning: try! result.get())
            }
        }
        #expect(imported.filePath == realFile.resolvingSymlinksInPath().standardizedFileURL.path)
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: appModelsDir.path)
        #expect(dirContents == ["Qwen3-ASR-0.6B-Q8_0.gguf"])

        // After registering real file, discoverLocalModels() MUST return [] (T3 symlink is deduplicated!).
        #expect(registry.discoverLocalModels().isEmpty)

        // Importing again via the T3 symlink MUST deduplicate against existing model (count remains 1).
        let viaSymlink: ModelDescriptor = await withCheckedContinuation { cont in
            registry.importModel(from: symlinkInT3, storageMode: .reference, prober: prober) { result in
                cont.resume(returning: try! result.get())
            }
        }
        #expect(viaSymlink.id == imported.id)
        #expect(registry.models.count == 1)
    }

    @Test("P1-10: ModelCapabilities clamps out-of-range nativeSampleRate and maxAudioMs on init and decode")
    func testModelCapabilitiesSanitization() throws {
        let lowRate = ModelCapabilities(nativeSampleRate: 4_000, maxAudioMs: 200)
        #expect(lowRate.nativeSampleRate == 16_000)
        #expect(lowRate.maxAudioMs == 1_000)
        #expect(lowRate.effectiveCaptureLimitMs == 5_000)

        let hugeRate = ModelCapabilities(nativeSampleRate: 192_000, maxAudioMs: 9_999_999)
        #expect(hugeRate.nativeSampleRate == 16_000)
        #expect(hugeRate.maxAudioMs == 600_000)
        #expect(hugeRate.effectiveCaptureLimitMs == 29_500)

        let craftedJSON = """
        {"arch":"crafted","nativeSampleRate":999999,"maxAudioMs":999999999,"roles":["asr"]}
        """
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: Data(craftedJSON.utf8))
        #expect(decoded.nativeSampleRate == 16_000)
        #expect(decoded.maxAudioMs == 600_000)
        #expect(decoded.effectiveCaptureLimitMs == 29_500)
    }

    @Test("P1-7, P1-8, P1-9: removeModel rejects prefix/symlink escape, concurrent copy never overwrites, relink unlocks before completion")
    func testRemoveContainmentConcurrentCopyAndRelinkNoDeadlock() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let evilSiblingDir = appSupport.appendingPathComponent("models_evil", isDirectory: true)
        let outsideDir = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: evilSiblingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let registry = ModelRegistry(appSupportDirectory: appSupport, discoveryDirectories: [])

        // P1-7a: Sibling prefix dir (`models_evil/secret.gguf`) MUST NOT be deleted by removeModel!
        let evilFile = evilSiblingDir.appendingPathComponent("secret.gguf")
        try Data("keep-me".utf8).write(to: evilFile)
        registry.registerPreprobedModel(ModelDescriptor(
            id: "evil-prefix",
            displayName: "Evil",
            filePath: evilFile.path,
            storageMode: .copied,
            fileSizeBytes: 7,
            statFingerprint: ModelRegistry.statFingerprint(forPath: evilFile.path),
            capabilities: ModelCapabilities()
        ))
        #expect(registry.removeModel(id: "evil-prefix") == true)
        #expect(FileManager.default.fileExists(atPath: evilFile.path) == true)

        // P1-7b: Symlink inside modelsDirectory pointing outside MUST NOT delete outside target!
        try FileManager.default.createDirectory(at: registry.modelsDirectory, withIntermediateDirectories: true)
        let outsideTarget = outsideDir.appendingPathComponent("outside.gguf")
        try Data("precious".utf8).write(to: outsideTarget)
        let escapeLink = registry.modelsDirectory.appendingPathComponent("escape.gguf")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outsideTarget)
        registry.registerPreprobedModel(ModelDescriptor(
            id: "escape-link",
            displayName: "Escape",
            filePath: escapeLink.path,
            storageMode: .copied,
            fileSizeBytes: 8,
            statFingerprint: ModelRegistry.statFingerprint(forPath: outsideTarget.path),
            capabilities: ModelCapabilities()
        ))
        #expect(registry.removeModel(id: "escape-link") == true)
        #expect(FileManager.default.fileExists(atPath: outsideTarget.path) == true)

        // P1-8: Parallel atomic copies of identical filename never overwrite each other
        let srcA = outsideDir.appendingPathComponent("dirA", isDirectory: true)
        let srcB = outsideDir.appendingPathComponent("dirB", isDirectory: true)
        try FileManager.default.createDirectory(at: srcA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcB, withIntermediateDirectories: true)
        let fileA = srcA.appendingPathComponent("same.gguf")
        let fileB = srcB.appendingPathComponent("same.gguf")
        try Data("payload-A".utf8).write(to: fileA)
        try Data("payload-B".utf8).write(to: fileB)

        let prober = MockModelProber { path in
            .success(LDPProbeResultPayload(modelPath: path, roles: ["asr"], arch: "qwen3_asr", variant: "0.6b", nativeSampleRate: 16_000, maxAudioMs: 30_000))
        }
        async let importA: ModelDescriptor = withCheckedContinuation { cont in
            registry.importModel(from: fileA, storageMode: .copied, prober: prober) { cont.resume(returning: try! $0.get()) }
        }
        async let importB: ModelDescriptor = withCheckedContinuation { cont in
            registry.importModel(from: fileB, storageMode: .copied, prober: prober) { cont.resume(returning: try! $0.get()) }
        }
        let (descA, descB) = await (importA, importB)
        #expect(descA.filePath != descB.filePath)
        #expect(try String(contentsOfFile: descA.filePath, encoding: .utf8) == "payload-A")
        #expect(try String(contentsOfFile: descB.filePath, encoding: .utf8) == "payload-B")

        // P1-9: relinkModel releases lock BEFORE invoking completion (re-entrant registry query never deadlocks!)
        let relinkTarget = outsideDir.appendingPathComponent("relinked.gguf")
        try Data("relinked".utf8).write(to: relinkTarget)
        let queriedCount: Int = await withCheckedContinuation { cont in
            registry.relinkModel(id: descA.id, newURL: relinkTarget, prober: prober) { _ in
                // Synchronously re-entering ModelRegistry inside completion MUST NOT deadlock!
                cont.resume(returning: registry.models.count)
            }
        }
        #expect(queriedCount == 2)
    }

    @Test("P2-4: TextPostProcessor refuses vocab.txt and aliases.json files exceeding 256 KiB before reading")
    func testTextPostProcessor256KiBSizeCap() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let hugeVocab = root.appendingPathComponent("vocab.txt")
        let hugeAliases = root.appendingPathComponent("aliases.json")
        try Data(repeating: 0x41, count: Int(TextPostProcessor.maxConfigFileBytes) + 1024).write(to: hugeVocab)
        try Data(repeating: 0x20, count: Int(TextPostProcessor.maxConfigFileBytes) + 1024).write(to: hugeAliases)

        let processor = TextPostProcessor.load(vocabPath: hugeVocab.path, aliasesPath: hugeAliases.path)
        #expect(processor.vocabulary.isEmpty)
        #expect(processor.aliases.isEmpty)
    }
}
