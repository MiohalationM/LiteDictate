import Darwin
import Foundation

public struct ModelRegistryPersistence: Codable, Equatable, Sendable {
    public var activeModelId: String?
    public var models: [ModelDescriptor]

    public init(activeModelId: String? = nil, models: [ModelDescriptor] = []) {
        self.activeModelId = activeModelId
        self.models = models
    }
}

public enum ModelRegistryError: Error, Equatable, Sendable {
    case fileNotFound(String)
    case copyFailed(String)
    case probeFailed(ModelProbeError)
    case modelNotRegistered(String)

    public var userMessage: String {
        switch self {
        case let .fileNotFound(path):
            return "找不到模型文件：\(URL(fileURLWithPath: path).lastPathComponent)"
        case let .copyFailed(msg):
            return "复制模型文件失败：\(msg)"
        case let .probeFailed(err):
            return err.userMessage
        case let .modelNotRegistered(id):
            return "未找到已注册模型：\(id)"
        }
    }
}

/// Manages BYO `.gguf` models: reference vs atomic temp+rename copy, `0x06 PROBE_MODEL` ASR validation,
/// `models.json` persistence, startup auto-discovery, pre-launch `stat` missing-file detection & relink,
/// and dynamic capture limit computation (`min(29_500, max(5_000, maxAudioMs - 500))`).
public final class ModelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    public let appSupportDirectory: URL
    public let modelsDirectory: URL
    public let registryFileURL: URL
    private let discoveryDirectories: [URL]

    private var activeModelIDStorage: String?
    private var modelsStorage: [ModelDescriptor] = []

    private struct FileInodeKey: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    public init(
        appSupportDirectory: URL = AppConfig.defaultAppSupportDirectory(),
        discoveryDirectories: [URL]? = nil
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.modelsDirectory = appSupportDirectory.appendingPathComponent("models", isDirectory: true)
        self.registryFileURL = appSupportDirectory.appendingPathComponent("models.json")

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // Always scan LiteDictate's own modelsDirectory FIRST so real files take precedence over symlinks in T3 Code.
        self.discoveryDirectories = discoveryDirectories ?? [
            self.modelsDirectory,
            home.appendingPathComponent(".t3/userdata/speech/models", isDirectory: true),
        ]

        loadFromDiskLocked()
        refreshFileStatuses()
    }

    public static func canonicalResolvedPath(forPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func isInsideModelsDirectory(_ path: String) -> Bool {
        let resolvedFile = Self.canonicalResolvedPath(forPath: path)
        let resolvedModelsDir = modelsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedModelsDir.hasSuffix("/") ? resolvedModelsDir : (resolvedModelsDir + "/")
        return resolvedFile.hasPrefix(prefix)
    }

    public var activeModelID: String? {
        lock.lock(); defer { lock.unlock() }
        return activeModelIDStorage
    }

    public var models: [ModelDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return modelsStorage
    }

    public var activeModel: ModelDescriptor? {
        lock.lock(); defer { lock.unlock() }
        guard let id = activeModelIDStorage else { return nil }
        return modelsStorage.first { $0.id == id }
    }

    /// Pre-launch `stat()` fast check: marks missing external files cleanly without crashing.
    @discardableResult
    public func refreshFileStatuses() -> [ModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        for i in modelsStorage.indices {
            modelsStorage[i].isFileMissing = (Self.statFingerprint(forPath: modelsStorage[i].filePath) == nil)
        }
        return modelsStorage
    }

    /// Verifies active model exists via `stat()`; returns `.success(model)` or marks missing and returns error.
    public func verifyActiveModelForLaunch() -> Result<ModelDescriptor, ModelRegistryError> {
        lock.lock()
        defer { lock.unlock() }
        guard let id = activeModelIDStorage,
              let idx = modelsStorage.firstIndex(where: { $0.id == id })
        else {
            return .failure(.modelNotRegistered("active"))
        }
        let path = modelsStorage[idx].filePath
        if Self.statFingerprint(forPath: path) == nil {
            modelsStorage[idx].isFileMissing = true
            return .failure(.fileNotFound(path))
        }
        modelsStorage[idx].isFileMissing = false
        return .success(modelsStorage[idx])
    }

    public func effectiveCaptureLimitMs(for model: ModelDescriptor? = nil) -> Int {
        let target = model ?? activeModel
        guard let target else {
            return LiteDictateConstants.defaultCaptureLimitMs
        }
        return target.capabilities.effectiveCaptureLimitMs
    }

    /// Scans discovery directories for unregistered `.gguf` files for first-launch guided onboarding.
    /// Deduplicates by BOTH symlink-resolved canonical path AND POSIX `(dev, ino)` so a symlink pointing to
    /// an already-registered or already-discovered model never appears as a duplicate candidate.
    public func discoverLocalModels() -> [DiscoveredModelCandidate] {
        lock.lock()
        var registeredPaths = Set<String>()
        var registeredInodes = Set<FileInodeKey>()
        for model in modelsStorage {
            let resolved = Self.canonicalResolvedPath(forPath: model.filePath)
            registeredPaths.insert(resolved)
            if let liveFP = Self.statFingerprint(forPath: resolved) ?? model.statFingerprint {
                registeredInodes.insert(FileInodeKey(dev: liveFP.dev, ino: liveFP.ino))
            }
        }
        lock.unlock()

        var seenPaths = Set<String>()
        var seenInodes = Set<FileInodeKey>()
        var candidates: [DiscoveredModelCandidate] = []
        let fm = FileManager.default

        for dir in discoveryDirectories {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in items {
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard let fp = Self.statFingerprint(forPath: resolved) else { continue }
                let inodeKey = FileInodeKey(dev: fp.dev, ino: fp.ino)

                guard !registeredPaths.contains(resolved),
                      !registeredInodes.contains(inodeKey),
                      !seenPaths.contains(resolved),
                      !seenInodes.contains(inodeKey)
                else { continue }

                seenPaths.insert(resolved)
                seenInodes.insert(inodeKey)
                candidates.append(DiscoveredModelCandidate(
                    filePath: resolved,
                    fileName: URL(fileURLWithPath: resolved).lastPathComponent,
                    fileSizeBytes: fp.fileSizeBytes
                ))
            }
        }
        return candidates.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    /// Scans ONLY LiteDictate's own `modelsDirectory` for unregistered `.gguf` files (for automatic startup registration).
    public func discoverModelsInAppModelsDirectory() -> [DiscoveredModelCandidate] {
        discoverLocalModels().filter { isInsideModelsDirectory($0.filePath) }
    }

    /// Imports a `.gguf` file after verifying `"asr"` role and capabilities via `0x06 PROBE_MODEL`.
    /// Deduplicates against existing models by BOTH symlink-resolved canonical path AND POSIX `(dev, ino)`.
    /// If `sourceURL` is ALREADY inside `modelsDirectory`, never duplicate-copies the file.
    public func importModel(
        from sourceURL: URL,
        storageMode: ModelStorageMode,
        prober: ModelProbing,
        completion: @escaping @Sendable (Result<ModelDescriptor, ModelRegistryError>) -> Void
    ) {
        let resolvedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.statFingerprint(forPath: resolvedSource.path) != nil else {
            completion(.failure(.fileNotFound(resolvedSource.path)))
            return
        }

        // Probe BEFORE copying/registering so invalid or non-ASR models (like Silero VAD) are rejected cleanly.
        prober.probeModel(at: resolvedSource.path) { [weak self] probeResult in
            guard let self else { return }
            switch probeResult {
            case let .failure(probeError):
                completion(.failure(.probeFailed(probeError)))

            case let .success(payload):
                let capabilities = payload.toModelCapabilities()
                guard capabilities.isASRModel else {
                    completion(.failure(.probeFailed(.unsupportedRole(
                        roles: payload.roles,
                        arch: payload.arch,
                        variant: payload.variant
                    ))))
                    return
                }

                let alreadyInModelsDir = self.isInsideModelsDirectory(resolvedSource.path)
                let finalPath: String
                let effectiveStorageMode: ModelStorageMode
                switch storageMode {
                case .reference:
                    finalPath = resolvedSource.path
                    effectiveStorageMode = .reference
                case .copied:
                    if alreadyInModelsDir {
                        // Already located in modelsDirectory: keep exact path in-place without re-copying.
                        finalPath = resolvedSource.path
                        effectiveStorageMode = .copied
                    } else {
                        do {
                            finalPath = try self.atomicCopyIntoModelsDirectory(from: resolvedSource)
                            effectiveStorageMode = .copied
                        } catch {
                            completion(.failure(.copyFailed(error.localizedDescription)))
                            return
                        }
                    }
                }

                guard let fingerprint = Self.statFingerprint(forPath: finalPath) else {
                    completion(.failure(.fileNotFound(finalPath)))
                    return
                }

                let displayName = Self.deriveDisplayName(
                    fileURL: URL(fileURLWithPath: finalPath),
                    arch: capabilities.arch,
                    variant: capabilities.variant
                )

                let resolvedFinalPath = Self.canonicalResolvedPath(forPath: finalPath)
                let finalInode = FileInodeKey(dev: fingerprint.dev, ino: fingerprint.ino)

                self.lock.lock()
                // Replace existing entry if pointing to same resolved path OR same POSIX (dev, ino); otherwise append.
                let descriptor: ModelDescriptor
                if let existingIdx = self.modelsStorage.firstIndex(where: { existing in
                    let existingResolved = Self.canonicalResolvedPath(forPath: existing.filePath)
                    if existingResolved == resolvedFinalPath {
                        return true
                    }
                    if let existingFP = Self.statFingerprint(forPath: existingResolved) ?? existing.statFingerprint {
                        return FileInodeKey(dev: existingFP.dev, ino: existingFP.ino) == finalInode
                    }
                    return false
                }) {
                    let existingID = self.modelsStorage[existingIdx].id
                    descriptor = ModelDescriptor(
                        id: existingID,
                        displayName: displayName,
                        filePath: resolvedFinalPath,
                        storageMode: effectiveStorageMode,
                        fileSizeBytes: fingerprint.fileSizeBytes,
                        statFingerprint: fingerprint,
                        capabilities: capabilities,
                        preferredLanguage: self.modelsStorage[existingIdx].preferredLanguage,
                        isFileMissing: false
                    )
                    self.modelsStorage[existingIdx] = descriptor
                } else {
                    descriptor = ModelDescriptor(
                        displayName: displayName,
                        filePath: resolvedFinalPath,
                        storageMode: effectiveStorageMode,
                        fileSizeBytes: fingerprint.fileSizeBytes,
                        statFingerprint: fingerprint,
                        capabilities: capabilities,
                        preferredLanguage: "auto",
                        isFileMissing: false
                    )
                    self.modelsStorage.append(descriptor)
                }

                if self.activeModelIDStorage == nil {
                    self.activeModelIDStorage = descriptor.id
                }
                self.saveToDiskLocked()
                self.lock.unlock()

                completion(.success(descriptor))
            }
        }
    }

    /// Relinks a missing referenced model after re-validating with `0x06 PROBE_MODEL`.
    public func relinkModel(
        id: String,
        newURL: URL,
        prober: ModelProbing,
        completion: @escaping @Sendable (Result<ModelDescriptor, ModelRegistryError>) -> Void
    ) {
        let canonical = newURL.standardizedFileURL
        guard Self.statFingerprint(forPath: canonical.path) != nil else {
            completion(.failure(.fileNotFound(canonical.path)))
            return
        }

        prober.probeModel(at: canonical.path) { [weak self] probeResult in
            guard let self else { return }
            switch probeResult {
            case let .failure(err):
                completion(.failure(.probeFailed(err)))
            case let .success(payload):
                let caps = payload.toModelCapabilities()
                guard caps.isASRModel else {
                    completion(.failure(.probeFailed(.unsupportedRole(roles: payload.roles, arch: payload.arch, variant: payload.variant))))
                    return
                }
                guard let fp = Self.statFingerprint(forPath: canonical.path) else {
                    completion(.failure(.fileNotFound(canonical.path)))
                    return
                }

                // P1-9: Construct result under lock, UNLOCK FIRST, then invoke completion to prevent re-entrant deadlock!
                self.lock.lock()
                let outcome: Result<ModelDescriptor, ModelRegistryError>
                if let idx = self.modelsStorage.firstIndex(where: { $0.id == id }) {
                    var updated = self.modelsStorage[idx]
                    updated.filePath = canonical.path
                    updated.fileSizeBytes = fp.fileSizeBytes
                    updated.statFingerprint = fp
                    updated.isFileMissing = false
                    updated.displayName = Self.deriveDisplayName(fileURL: canonical, arch: caps.arch, variant: caps.variant)
                    let replaced = ModelDescriptor(
                        id: updated.id,
                        displayName: updated.displayName,
                        filePath: updated.filePath,
                        storageMode: updated.storageMode,
                        fileSizeBytes: updated.fileSizeBytes,
                        statFingerprint: updated.statFingerprint,
                        capabilities: caps,
                        preferredLanguage: updated.preferredLanguage,
                        isFileMissing: false
                    )
                    self.modelsStorage[idx] = replaced
                    self.saveToDiskLocked()
                    outcome = .success(replaced)
                } else {
                    outcome = .failure(.modelNotRegistered(id))
                }
                self.lock.unlock()
                completion(outcome)
            }
        }
    }

    @discardableResult
    public func selectActiveModel(id: String) -> ModelDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        guard let found = modelsStorage.first(where: { $0.id == id }) else {
            return nil
        }
        activeModelIDStorage = id
        saveToDiskLocked()
        return found
    }

    @discardableResult
    public func removeModel(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = modelsStorage.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let removed = modelsStorage.remove(at: idx)
        if removed.storageMode == .copied {
            // P1-7: Slash-aware canonical containment check AND reject symlink escapes before unlinking!
            var lst = Darwin.stat()
            let lstatOK = removed.filePath.withCString { fstatat(AT_FDCWD, $0, &lst, AT_SYMLINK_NOFOLLOW) } == 0
            let isNotSymlink = lstatOK && ((lst.st_mode & S_IFMT) == S_IFREG)
            if isNotSymlink && isInsideModelsDirectory(removed.filePath) {
                let resolvedURL = URL(fileURLWithPath: Self.canonicalResolvedPath(forPath: removed.filePath))
                try? FileManager.default.removeItem(at: resolvedURL)
            }
        }
        if activeModelIDStorage == id {
            activeModelIDStorage = modelsStorage.first?.id
        }
        saveToDiskLocked()
        return true
    }

    /// Direct registration helper for deterministic tests.
    public func registerPreprobedModel(_ descriptor: ModelDescriptor, setActive: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = modelsStorage.firstIndex(where: { $0.id == descriptor.id }) {
            modelsStorage[idx] = descriptor
        } else {
            modelsStorage.append(descriptor)
        }
        if setActive || activeModelIDStorage == nil {
            activeModelIDStorage = descriptor.id
        }
        saveToDiskLocked()
    }

    // MARK: - Helpers

    public static func statFingerprint(forPath path: String) -> FileStatFingerprint? {
        var st = Darwin.stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &st, 0) }) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStatFingerprint(
            dev: UInt64(st.st_dev),
            ino: UInt64(st.st_ino),
            fileSizeBytes: UInt64(max(0, st.st_size)),
            mtimeSec: Int64(st.st_mtimespec.tv_sec),
            mtimeNsec: Int64(st.st_mtimespec.tv_nsec)
        )
    }

    /// P1-8: Concurrent-safe atomic copy using POSIX `link()` (fails atomically with `EEXIST` rather than
    /// overwriting an existing file), retrying with a unique UUID-qualified destination on collision.
    private func atomicCopyIntoModelsDirectory(from sourceURL: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let baseName = sourceURL.lastPathComponent
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        let tempURL = modelsDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)-\(baseName)")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        try fm.copyItem(at: sourceURL, to: tempURL)

        var candidate = modelsDirectory.appendingPathComponent(baseName)
        for _ in 0..<16 {
            let rc = tempURL.path.withCString { srcC in
                candidate.path.withCString { dstC in
                    Darwin.link(srcC, dstC)
                }
            }
            if rc == 0 {
                return candidate.resolvingSymlinksInPath().standardizedFileURL.path
            }
            let err = errno
            if err == EEXIST {
                let uniqueName = ext.isEmpty
                    ? "\(stem)-\(UUID().uuidString.prefix(8))"
                    : "\(stem)-\(UUID().uuidString.prefix(8)).\(ext)"
                candidate = modelsDirectory.appendingPathComponent(uniqueName)
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
    }

    private static func deriveDisplayName(fileURL: URL, arch: String, variant: String) -> String {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        if !stem.isEmpty {
            return stem
        }
        return variant.isEmpty ? arch : "\(arch) (\(variant))"
    }

    private func loadFromDiskLocked() {
        guard let data = try? Data(contentsOf: registryFileURL),
              let persisted = try? JSONDecoder().decode(ModelRegistryPersistence.self, from: data)
        else {
            return
        }
        modelsStorage = persisted.models
        activeModelIDStorage = persisted.activeModelId ?? persisted.models.first?.id
    }

    private func saveToDiskLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let snapshot = ModelRegistryPersistence(activeModelId: activeModelIDStorage, models: modelsStorage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }

        let tempURL = appSupportDirectory.appendingPathComponent(".models.json.tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            _ = tempURL.path.withCString { src in
                registryFileURL.path.withCString { dst in
                    Darwin.rename(src, dst)
                }
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }
}
