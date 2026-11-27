import Darwin
import Foundation

// MARK: - Supervisor Events & Protocols

public struct WorkerTranscriptionRequest: Sendable {
    public let requestID: RequestID
    public let model: ModelDescriptor
    public let pcm: PCMStore
    public let language: String
    public let vocabulary: [String]?
    public let contextPrompt: String?

    public init(
        requestID: RequestID,
        model: ModelDescriptor,
        pcm: PCMStore,
        language: String = "auto",
        vocabulary: [String]? = nil,
        contextPrompt: String? = nil
    ) {
        self.requestID = requestID
        self.model = model
        self.pcm = pcm
        self.language = language
        self.vocabulary = vocabulary
        self.contextPrompt = contextPrompt
    }
}

public enum WorkerSupervisorEvent: Sendable {
    case stateChanged(WorkerLifecycleState, footprintBytes: UInt64)
    case memoryPressureChanged(MemoryPressureLevel)
    case metalShaderCompilationLikely(Bool)
    case transcriptionStarted(InferenceIdentity)
    case transcriptionSucceeded(InferenceIdentity, LDPResultPayload)
    case transcriptionCancelled(InferenceIdentity, stage: String)
    case transcriptionFailed(InferenceIdentity?, message: String, isCriticalMemoryAbort: Bool)
    case criticalMemoryInterruptedActiveJob(RequestID)
}

public protocol ModelProbing: AnyObject, Sendable {
    func probeModel(at path: String, completion: @escaping @Sendable (Result<LDPProbeResultPayload, ModelProbeError>) -> Void)
}

public enum ModelProbeError: Error, Equatable, Sendable {
    case workerBinaryMissing
    case memoryPressureCritical
    case modelTooLarge(bytes: UInt64, limitBytes: UInt64)
    case unsupportedRole(roles: [String], arch: String, variant: String)
    case modelLoadFailed(String)
    case protocolError(String)
    case timeout

    public var userMessage: String {
        switch self {
        case .workerBinaryMissing:
            return "未找到本地语音识别引擎组件"
        case .memoryPressureCritical:
            return "系统内存当前较紧张，暂不校验新模型，请稍后再试"
        case let .modelTooLarge(bytes, limitBytes):
            let sizeGB = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
            let limitGB = Double(limitBytes) / (1024.0 * 1024.0 * 1024.0)
            return String(format: "模型文件过大（%.2f GB），为保护电脑内存暂不支持超过 %.0f GB 的模型", sizeGB, limitGB)
        case let .unsupportedRole(roles, _, _):
            let roleDesc = roles.isEmpty ? "未知" : roles.joined(separator: ", ")
            return "此文件非语音识别模型（检测到角色: \(roleDesc)），无法作为语音模型加载"
        case let .modelLoadFailed(msg):
            return "模型加载校验失败：\(msg)"
        case let .protocolError(msg):
            return "模型校验通信失败：\(msg)"
        case .timeout:
            return "模型校验超时，请检查文件是否损坏"
        }
    }
}

public protocol WorkerSupervising: AnyObject, Sendable {
    var currentState: WorkerLifecycleState { get }
    var currentMemoryPressure: MemoryPressureLevel { get }
    var currentFootprintBytes: UInt64 { get }

    func setEventHandler(_ handler: @escaping @Sendable (WorkerSupervisorEvent) -> Void)
    func prepareWarmupIfAllowed(model: ModelDescriptor)
    func submitTranscription(_ request: WorkerTranscriptionRequest)
    func cancelTranscription(requestID: RequestID)
    func requestModelSwitch(to model: ModelDescriptor?)
    func updateWarmTTLSeconds(_ seconds: TimeInterval?)
    func shutdownGracefully(reason: String)
    func forceShutdownImmediately()
}

public extension WorkerSupervising {
    func updateWarmTTLSeconds(_ seconds: TimeInterval?) {}
}

// MARK: - Warm Leak Self-Heal Tracker (Section 9.1)

/// Tracks runs 3-5 median post-free `phys_footprint` & `sessionInitMs` baseline for one Worker instance.
/// Triggers graceful idle restart after 3 consecutive runs exceeding `baseline + 50 MB` with `sessionInitMs` drift.
public struct WarmLeakDetector: Sendable {
    public static let leakThresholdBytes: UInt64 = 50 * 1024 * 1024
    public static let requiredConsecutiveStrikes: Int = 3

    private var runCount: Int = 0
    private var baselineFootprintSamples: [UInt64] = []
    private var baselineInitMsSamples: [Double] = []
    public private(set) var baselineFootprintBytes: UInt64?
    public private(set) var baselineSessionInitMs: Double?
    public private(set) var consecutiveStrikes: Int = 0

    public init() {}

    /// Records a completed inference run and returns `true` when graceful self-heal restart is required.
    @discardableResult
    public mutating func recordRun(postFreeFootprintBytes: UInt64, sessionInitMs: Double) -> Bool {
        runCount += 1
        if runCount >= 3 && runCount <= 5 {
            baselineFootprintSamples.append(postFreeFootprintBytes)
            baselineInitMsSamples.append(sessionInitMs)
            if runCount == 5 {
                let sortedFP = baselineFootprintSamples.sorted()
                let sortedInit = baselineInitMsSamples.sorted()
                baselineFootprintBytes = sortedFP[sortedFP.count / 2]
                baselineSessionInitMs = sortedInit[sortedInit.count / 2]
            }
            return false
        }

        guard let baseFP = baselineFootprintBytes, let baseInit = baselineSessionInitMs else {
            return false
        }

        let footprintDrifted = postFreeFootprintBytes > baseFP &+ Self.leakThresholdBytes
        let initDrifted = sessionInitMs > max(baseInit * 1.25, baseInit + 15.0)

        if footprintDrifted && initDrifted {
            consecutiveStrikes += 1
        } else {
            consecutiveStrikes = 0
        }
        return consecutiveStrikes >= Self.requiredConsecutiveStrikes
    }
}

// MARK: - WorkerSupervisor Implementation

public final class WorkerSupervisor: WorkerSupervising, ModelProbing, @unchecked Sendable {
    public static let defaultMaxModelBytes: UInt64 = 4 * 1024 * 1024 * 1024 // 4 GiB cap for 8 GB Mac safety

    private let supervisorQueue = DispatchQueue(label: "io.github.litedictate.worker.supervisor", qos: .userInitiated)
    private let explicitWorkerPath: String?
    private var warmTTLSeconds: TimeInterval?
    private let maxModelBytes: UInt64
    private let enableSystemMemoryPressureSource: Bool

    private var eventHandler: (@Sendable (WorkerSupervisorEvent) -> Void)?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // Track active short-lived probe workers so `.critical` memory pressure & shutdown terminate them too.
    private let probeLock = NSLock()
    private var activeProbeInstances: [WorkerGeneration: WorkerProcessInstance] = [:]

    // All mutable state strictly owned by `supervisorQueue`.
    private var state: WorkerLifecycleState = .stopped
    private var memoryPressure: MemoryPressureLevel = .normal
    private var footprintBytes: UInt64 = 0
    private var nextWorkerGeneration: WorkerGeneration = 0
    private var nextAttemptID: AttemptID = 0

    private var activeInstance: WorkerProcessInstance?
    private var loadedModelID: String?
    private var loadedModelPath: String?
    private var activeInference: (identity: InferenceIdentity, request: WorkerTranscriptionRequest)?
    private var pendingRequest: WorkerTranscriptionRequest?
    private var pendingModelSwitch: ModelDescriptor?
    private var pendingSelfHealRestart: Bool = false
    private var shutdownAfterCurrentJob: Bool = false
    private var allowRespawnPendingAfterStop: Bool = false
    private var leakDetector = WarmLeakDetector()

    private var warmTTLTimer: DispatchWorkItem?
    private var killTimer: DispatchWorkItem?
    private var warningGraceTimer: DispatchWorkItem?
    private var shaderNoticeTimer: DispatchWorkItem?
    private var shaderNoticeVisible: Bool = false

    // Mirror atomics for lock-free snapshot queries
    private let stateLock = NSLock()
    private var mirroredState: WorkerLifecycleState = .stopped
    private var mirroredPressure: MemoryPressureLevel = .normal
    private var mirroredFootprint: UInt64 = 0

    public var currentState: WorkerLifecycleState {
        stateLock.lock(); defer { stateLock.unlock() }
        return mirroredState
    }

    public var currentMemoryPressure: MemoryPressureLevel {
        stateLock.lock(); defer { stateLock.unlock() }
        return mirroredPressure
    }

    public var currentFootprintBytes: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return mirroredFootprint
    }

    public init(
        workerExecutablePath: String? = nil,
        warmTTLSeconds: TimeInterval? = ModelIdleUnloadPolicy.twoMinutes.ttlSeconds,
        maxModelBytes: UInt64? = nil,
        enableSystemMemoryPressureSource: Bool = true
    ) {
        self.explicitWorkerPath = workerExecutablePath
        self.warmTTLSeconds = warmTTLSeconds
        if let maxModelBytes {
            self.maxModelBytes = maxModelBytes
        } else if let envRaw = ProcessInfo.processInfo.environment["LITEDICTATE_MAX_MODEL_BYTES"],
                  let parsed = UInt64(envRaw), parsed > 0 {
            self.maxModelBytes = parsed
        } else {
            self.maxModelBytes = Self.defaultMaxModelBytes
        }
        self.enableSystemMemoryPressureSource = enableSystemMemoryPressureSource

        if enableSystemMemoryPressureSource {
            installMemoryPressureSource()
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    public static func resolveDefaultWorkerPath(explicit: String? = nil) -> String? {
        if let explicit, FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        if let env = ProcessInfo.processInfo.environment["LITEDICTATE_WORKER_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = execDir.appendingPathComponent("litedictate-worker").path
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        let cwd = FileManager.default.currentDirectoryPath
        let devCandidates = [
            "\(cwd)/Build/Worker/litedictate-worker",
            "\(cwd)/Build/LiteDictate.app/Contents/MacOS/litedictate-worker",
        ]
        for path in devCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func setEventHandler(_ handler: @escaping @Sendable (WorkerSupervisorEvent) -> Void) {
        stateLock.lock()
        eventHandler = handler
        stateLock.unlock()
    }

    // MARK: - Public API

    public func prepareWarmupIfAllowed(model: ModelDescriptor) {
        supervisorQueue.async {
            // Section 9.1: Stopped + .warning/.critical -> NEVER predictive warmup!
            guard self.memoryPressure == .normal else { return }
            guard self.state == .stopped else { return }
            guard self.activeInstance == nil else { return }
            self.startWorkerLocked(for: model)
        }
    }

    public func submitTranscription(_ request: WorkerTranscriptionRequest) {
        supervisorQueue.async {
            // Section 9.1: .critical forbids starting inference
            if self.memoryPressure == .critical {
                self.emit(.transcriptionFailed(nil, message: "系统内存严重不足，已暂停推理并保留语音", isCriticalMemoryAbort: true))
                return
            }

            switch self.state {
            case .stopped:
                self.pendingRequest = request
                self.startWorkerLocked(for: request.model)

            case .starting:
                if self.loadedModelID == request.model.id {
                    self.pendingRequest = request
                } else {
                    // Zero dual-model residency: shut down old model first, then start new.
                    self.pendingRequest = request
                    self.pendingModelSwitch = request.model
                    self.allowRespawnPendingAfterStop = true
                    self.beginGracefulShutdownLocked(killGraceMs: 1500)
                }

            case .warmModel:
                if self.loadedModelID == request.model.id && !self.pendingSelfHealRestart {
                    self.dispatchTranscriptionLocked(request)
                } else {
                    // Zero dual-model residency: tear down old worker before starting new one.
                    self.pendingRequest = request
                    self.pendingModelSwitch = request.model
                    self.allowRespawnPendingAfterStop = true
                    self.beginGracefulShutdownLocked(killGraceMs: 1500)
                }

            case .busy, .cancelling, .stopping:
                // Single-worker red line: NEVER spawn a 2nd Metal worker. Queue until current instance resolves.
                self.pendingRequest = request
                if self.state == .stopping {
                    self.allowRespawnPendingAfterStop = true
                }
            }
        }
    }

    public func cancelTranscription(requestID: RequestID) {
        supervisorQueue.async {
            if self.pendingRequest?.requestID == requestID {
                self.pendingRequest = nil
            }
            guard let active = self.activeInference, active.identity.requestID == requestID else {
                return
            }
            guard self.state == .busy, let instance = self.activeInstance else {
                return
            }

            self.transitionStateLocked(.cancelling)
            let frame = LDPProtocolClient.makeEmptyFrame(
                msgType: .cancel,
                requestID: active.identity.requestID,
                attemptID: active.identity.attemptID
            )
            self.sendFrameAsync(frame, to: instance)

            let graceMs: Int = (self.memoryPressure == .warning) ? 500 : 2500
            if self.memoryPressure == .critical {
                instance.forceKill()
            } else {
                self.armKillTimerLocked(for: instance, delayMs: graceMs)
            }
        }
    }

    public func requestModelSwitch(to model: ModelDescriptor?) {
        supervisorQueue.async {
            guard self.loadedModelID != model?.id else { return }
            self.pendingModelSwitch = model
            switch self.state {
            case .stopped, .stopping:
                break
            case .starting, .warmModel:
                // Immediately shut down old model — zero dual-model residency!
                self.beginGracefulShutdownLocked(killGraceMs: 1500)
            case .busy, .cancelling:
                // Mark shutdown right after current job finishes.
                self.shutdownAfterCurrentJob = true
            }
        }
    }

    public func shutdownGracefully(reason: String) {
        supervisorQueue.async {
            self.pendingRequest = nil
            self.pendingModelSwitch = nil
            guard self.activeInstance != nil else { return }
            self.beginGracefulShutdownLocked(killGraceMs: 1500)
        }
    }

    public func forceShutdownImmediately() {
        killAllActiveProbeWorkers()
        supervisorQueue.async {
            self.pendingRequest = nil
            self.pendingModelSwitch = nil
            self.cancelAllTimersLocked()
            if let instance = self.activeInstance {
                self.transitionStateLocked(.stopping)
                instance.forceKill()
            }
        }
    }

    private func killAllActiveProbeWorkers() {
        probeLock.lock()
        let probes = Array(activeProbeInstances.values)
        activeProbeInstances.removeAll()
        probeLock.unlock()
        for p in probes {
            p.forceKill()
        }
    }

    /// Exposed for deterministic unit testing of the Section 9.1 memory pressure matrix.
    public func handleMemoryPressure(_ level: MemoryPressureLevel) {
        supervisorQueue.async {
            self.applyMemoryPressureLocked(level)
        }
    }

    // MARK: - ModelProbing (`0x06 PROBE_MODEL` over CPU-only short-lived worker)

    public func probeModel(
        at path: String,
        completion: @escaping @Sendable (Result<LDPProbeResultPayload, ModelProbeError>) -> Void
    ) {
        // P1-18: Reject cleanly under critical memory pressure without spawning a worker.
        if currentMemoryPressure == .critical {
            completion(.failure(.memoryPressureCritical))
            return
        }

        // P1-18: Pre-stat and enforce model size cap (default 4 GiB) before spawning.
        guard let fp = ModelRegistry.statFingerprint(forPath: path) else {
            completion(.failure(.modelLoadFailed("找不到模型文件")))
            return
        }
        if fp.fileSizeBytes > maxModelBytes {
            completion(.failure(.modelTooLarge(bytes: fp.fileSizeBytes, limitBytes: maxModelBytes)))
            return
        }

        guard let execPath = Self.resolveDefaultWorkerPath(explicit: explicitWorkerPath) else {
            completion(.failure(.workerBinaryMissing))
            return
        }

        let probeQueue = DispatchQueue(label: "io.github.litedictate.worker.probe.\(UUID().uuidString)", qos: .userInitiated)
        probeQueue.async { [weak self] in
            guard let self else { return }
            if self.currentMemoryPressure == .critical {
                completion(.failure(.memoryPressureCritical))
                return
            }

            let gen = UInt64.random(in: 1_000_000...UInt64.max)
            let instance: WorkerProcessInstance
            do {
                instance = try WorkerProcessInstance.spawn(
                    executablePath: execPath,
                    workerGeneration: gen,
                    onExit: { [weak self] exitedGen, _ in
                        guard let self else { return }
                        self.probeLock.lock()
                        self.activeProbeInstances.removeValue(forKey: exitedGen)
                        self.probeLock.unlock()
                    }
                )
            } catch {
                completion(.failure(.protocolError("启动探测进程失败: \(error)")))
                return
            }

            self.probeLock.lock()
            let becameCritical = (self.currentMemoryPressure == .critical)
            if !becameCritical {
                self.activeProbeInstances[gen] = instance
            }
            self.probeLock.unlock()

            if becameCritical {
                instance.forceKill()
                completion(.failure(.memoryPressureCritical))
                return
            }

            let finished = AtomicBool(false)
            let timeoutItem = DispatchWorkItem { [weak self] in
                if finished.compareExchange(expected: false, desired: true) {
                    instance.forceKill()
                    self?.probeLock.lock()
                    self?.activeProbeInstances.removeValue(forKey: gen)
                    self?.probeLock.unlock()
                    completion(.failure(.timeout))
                }
            }
            probeQueue.asyncAfter(deadline: .now() + 20.0, execute: timeoutItem)

            do {
                let req = LDPProbeModelRequest(modelPath: path, backend: "cpu")
                let frame = try LDPProtocolClient.makeJSONFrame(msgType: .probeModel, requestID: 1, attemptID: 1, body: req)
                try instance.writeFrame(frame)
                let reply = try instance.readFrame()

                // Gracefully shut down probe process immediately so zero memory stays resident.
                let byeReq = LDPProtocolClient.makeEmptyFrame(msgType: .shutdown)
                instance.writeFrameAsync(byeReq)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    instance.forceKill()
                }

                timeoutItem.cancel()
                guard finished.compareExchange(expected: false, desired: true) else { return }

                switch reply.header.msgType {
                case .probeResult:
                    let payload = try LDPProtocolClient.decodeJSONPayload(LDPProbeResultPayload.self, from: reply.payload)
                    let caps = payload.toModelCapabilities()
                    if !caps.isASRModel {
                        completion(.failure(.unsupportedRole(roles: payload.roles, arch: payload.arch, variant: payload.variant)))
                    } else {
                        completion(.success(payload))
                    }
                case .error:
                    let errPayload = (try? LDPProtocolClient.decodeJSONPayload(LDPErrorPayload.self, from: reply.payload))
                        ?? LDPErrorPayload(code: reply.header.statusOrFlags, message: "Probe error")
                    if errPayload.errorCode == .unsupportedRole {
                        completion(.failure(.unsupportedRole(
                            roles: errPayload.roles ?? [],
                            arch: errPayload.arch ?? "unknown",
                            variant: errPayload.variant ?? ""
                        )))
                    } else {
                        completion(.failure(.modelLoadFailed(errPayload.message)))
                    }
                default:
                    completion(.failure(.protocolError("意外的探测响应类型: \(reply.header.msgType.rawValue)")))
                }
            } catch {
                timeoutItem.cancel()
                instance.forceKill()
                if finished.compareExchange(expected: false, desired: true) {
                    if self.currentMemoryPressure == .critical {
                        completion(.failure(.memoryPressureCritical))
                    } else {
                        completion(.failure(.protocolError("\(error)")))
                    }
                }
            }
        }
    }

    // MARK: - Internal State Machine (`supervisorQueue` only)

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: supervisorQueue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let data = source.data
            let level: MemoryPressureLevel
            if data.contains(.critical) {
                level = .critical
            } else if data.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.applyMemoryPressureLocked(level)
        }
        self.memoryPressureSource = source
        source.resume()
    }

    private func applyMemoryPressureLocked(_ level: MemoryPressureLevel) {
        let changed = (memoryPressure != level)
        memoryPressure = level
        syncMirrorsLocked()
        if changed {
            emit(.memoryPressureChanged(level))
        }
        if level == .critical {
            // P1-18: Terminate any active probe worker under critical memory pressure too!
            killAllActiveProbeWorkers()
        }

        switch (state, level) {
        case (_, .normal):
            break

        // STOPPED
        case (.stopped, .warning):
            // Predictive warmup paused (enforced in prepareWarmupIfAllowed).
            break
        case (.stopped, .critical):
            // Forbid new inference; fail any queued pending request so Coordinator retains PCM.
            if let pending = pendingRequest {
                pendingRequest = nil
                emit(.criticalMemoryInterruptedActiveJob(pending.requestID))
            }

        // STARTING
        case (.starting, .warning):
            if pendingRequest == nil {
                allowRespawnPendingAfterStop = false
                beginGracefulShutdownLocked(killGraceMs: 1000)
            } else {
                // Allow up to 2s to finish warmup, else fail pending request & shutdown (NO respawn loop).
                armWarningGraceTimerLocked(delaySeconds: 2.0) { [weak self] in
                    guard let self, self.state == .starting else { return }
                    self.failStartupTimeoutLocked(message: "系统内存紧张，引擎预热超过 2 秒已取消并保留语音")
                }
            }
        case (.starting, .critical):
            allowRespawnPendingAfterStop = false
            if let pending = pendingRequest {
                pendingRequest = nil
                emit(.criticalMemoryInterruptedActiveJob(pending.requestID))
            }
            beginGracefulShutdownLocked(killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs)

        // WARM MODEL
        case (.warmModel, .warning):
            beginGracefulShutdownLocked(killGraceMs: 1500)
        case (.warmModel, .critical):
            beginGracefulShutdownLocked(killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs)

        // BUSY
        case (.busy, .warning):
            // Allow current short utterance up to 3s, then immediately unload.
            shutdownAfterCurrentJob = true
            armWarningGraceTimerLocked(delaySeconds: 3.0) { [weak self] in
                guard let self, self.state == .busy, let active = self.activeInference else { return }
                self.cancelAndShutdownForMemoryLocked(active: active, killGraceMs: 500, isCritical: false)
            }
        case (.busy, .critical):
            // Immediately logically pause & retain PCM -> CANCEL + SHUTDOWN (<=500ms SIGKILL).
            if let active = activeInference {
                cancelAndShutdownForMemoryLocked(
                    active: active,
                    killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs,
                    isCritical: true
                )
            } else {
                beginGracefulShutdownLocked(killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs)
            }

        // CANCELLING
        case (.cancelling, .warning):
            if let instance = activeInstance {
                armKillTimerLocked(for: instance, delayMs: 500)
            }
        case (.cancelling, .critical):
            if let instance = activeInstance {
                instance.forceKill()
            }

        // STOPPING
        case (.stopping, .warning):
            // Never launch a 2nd worker while stopping (already enforced by single-worker invariant).
            break
        case (.stopping, .critical):
            if let instance = activeInstance {
                armKillTimerLocked(for: instance, delayMs: LiteDictateConstants.workerCriticalKillDeadlineMs)
            }
        }
    }

    private func cancelAndShutdownForMemoryLocked(
        active: (identity: InferenceIdentity, request: WorkerTranscriptionRequest),
        killGraceMs: Int,
        isCritical: Bool
    ) {
        let reqID = active.identity.requestID
        let identity = active.identity
        // P0-3: ALWAYS notify coordinator before clearing activeInference so `.transcribing` is NEVER stranded!
        if isCritical {
            emit(.criticalMemoryInterruptedActiveJob(reqID))
        } else {
            emit(.transcriptionFailed(
                identity,
                message: "系统内存较紧张，已暂停识别并保留这段语音",
                isCriticalMemoryAbort: false
            ))
        }
        activeInference = nil
        pendingRequest = nil
        shutdownAfterCurrentJob = true
        guard let instance = activeInstance else { return }
        transitionStateLocked(.stopping)
        let cancelFrame = LDPProtocolClient.makeEmptyFrame(
            msgType: .cancel,
            requestID: active.identity.requestID,
            attemptID: active.identity.attemptID
        )
        let shutdownFrame = LDPProtocolClient.makeEmptyFrame(msgType: .shutdown)
        sendFrameAsync(cancelFrame, to: instance)
        sendFrameAsync(shutdownFrame, to: instance)
        armKillTimerLocked(for: instance, delayMs: killGraceMs)
    }

    private func startWorkerLocked(for model: ModelDescriptor) {
        // Single-worker red line: NEVER spawn when activeInstance != nil.
        guard activeInstance == nil else { return }
        guard memoryPressure != .critical else {
            if let pending = pendingRequest {
                pendingRequest = nil
                emit(.criticalMemoryInterruptedActiveJob(pending.requestID))
            }
            return
        }
        guard let execPath = Self.resolveDefaultWorkerPath(explicit: explicitWorkerPath) else {
            if pendingRequest != nil {
                pendingRequest = nil
                emit(.transcriptionFailed(nil, message: "未找到推理引擎 litedictate-worker", isCriticalMemoryAbort: false))
            }
            return
        }

        nextWorkerGeneration &+= 1
        let gen = nextWorkerGeneration
        leakDetector = WarmLeakDetector()
        pendingSelfHealRestart = false
        shutdownAfterCurrentJob = false

        do {
            let instance = try WorkerProcessInstance.spawn(
                executablePath: execPath,
                workerGeneration: gen,
                onExit: { [weak self] exitedGen, status in
                    guard let self else { return }
                    self.supervisorQueue.async {
                        self.handleProcessExitLocked(generation: exitedGen, status: status)
                    }
                }
            )
            activeInstance = instance
            loadedModelID = model.id
            loadedModelPath = model.filePath
            transitionStateLocked(.starting)

            // Transparent first-time Metal shader compilation hint if warmup takes > 1.5s.
            armShaderNoticeTimerLocked(for: gen)

            // Start blocking FD 4 reader loop on dedicated IO thread.
            startReaderLoop(for: instance)

            // Send 0x01 WARMUP
            let warmup = LDPWarmupRequest(modelPath: model.filePath, backend: "metal", noMmap: false)
            let frame = try LDPProtocolClient.makeJSONFrame(msgType: .warmup, body: warmup)
            sendFrameAsync(frame, to: instance)

            // If we launched under .warning with a pending request, enforce 2s startup cap without respawning.
            if memoryPressure == .warning {
                armWarningGraceTimerLocked(delaySeconds: 2.0) { [weak self] in
                    guard let self, self.state == .starting else { return }
                    self.failStartupTimeoutLocked(message: "系统内存紧张，引擎预热超过 2 秒已取消并保留语音")
                }
            }
        } catch {
            activeInstance = nil
            loadedModelID = nil
            loadedModelPath = nil
            transitionStateLocked(.stopped)
            if pendingRequest != nil {
                pendingRequest = nil
                emit(.transcriptionFailed(nil, message: "启动推理子进程失败：\(error)", isCriticalMemoryAbort: false))
            }
        }
    }

    private func startReaderLoop(for instance: WorkerProcessInstance) {
        let gen = instance.workerGeneration
        let ioQueue = DispatchQueue(label: "io.github.litedictate.worker.read.\(gen)", qos: .userInitiated)
        ioQueue.async { [weak self, weak instance] in
            while let instance {
                do {
                    let frame = try instance.readFrame()
                    guard let owner = self else { break }
                    owner.supervisorQueue.async {
                        owner.handleIncomingFrameLocked(frame, fromGeneration: gen)
                    }
                } catch {
                    // EOF or read failure -> process exiting or closed.
                    if let owner = self {
                        owner.supervisorQueue.async {
                            owner.handleReadLoopEndedLocked(generation: gen, error: error)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingFrameLocked(_ frame: LDPFrame, fromGeneration gen: WorkerGeneration) {
        guard let instance = activeInstance, instance.workerGeneration == gen else {
            return
        }

        switch frame.header.msgType {
        case .ready:
            clearShaderNoticeLocked()
            warningGraceTimer?.cancel()
            warningGraceTimer = nil

            let ready = try? LDPProtocolClient.decodeJSONPayload(LDPReadyPayload.self, from: frame.payload)
            footprintBytes = ready?.physFootprintBytes ?? footprintBytes

            guard state == .starting else { return }
            transitionStateLocked(.warmModel)

            if memoryPressure == .critical {
                beginGracefulShutdownLocked(killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs)
                return
            }
            if let pending = pendingRequest {
                if pending.model.id == loadedModelID {
                    pendingRequest = nil
                    dispatchTranscriptionLocked(pending)
                } else {
                    allowRespawnPendingAfterStop = true
                    beginGracefulShutdownLocked(killGraceMs: 1500)
                }
            } else if memoryPressure == .warning || pendingModelSwitch != nil {
                allowRespawnPendingAfterStop = false
                beginGracefulShutdownLocked(killGraceMs: 1500)
            } else {
                // Warmup finished while recording may still be in progress: never unload immediately
                // even when policy is `.immediately` (ttl == 0); unload happens right after job finishes.
                armWarmTTLTimerLocked(for: gen, allowImmediateUnload: false)
            }

        case .result:
            warningGraceTimer?.cancel()
            warningGraceTimer = nil

            guard let active = activeInference,
                  active.identity.requestID == frame.header.requestID,
                  active.identity.attemptID == frame.header.attemptID,
                  active.identity.workerGeneration == gen
            else {
                return
            }
            activeInference = nil

            do {
                let result = try LDPProtocolClient.decodeJSONPayload(LDPResultPayload.self, from: frame.payload)
                footprintBytes = result.postFreeFootprintBytes

                // Warm leak self-heal detection (Section 9.1)
                if leakDetector.recordRun(
                    postFreeFootprintBytes: result.postFreeFootprintBytes,
                    sessionInitMs: result.sessionInitMs
                ) {
                    pendingSelfHealRestart = true
                }

                if state == .busy {
                    transitionStateLocked(.warmModel)
                }
                emit(.transcriptionSucceeded(active.identity, result))
                afterJobSettledLocked(generation: gen)
            } catch {
                if state == .busy {
                    transitionStateLocked(.warmModel)
                }
                emit(.transcriptionFailed(active.identity, message: "解析转写结果失败", isCriticalMemoryAbort: false))
                afterJobSettledLocked(generation: gen)
            }

        case .cancelled:
            killTimer?.cancel()
            killTimer = nil
            warningGraceTimer?.cancel()
            warningGraceTimer = nil

            let payload = try? LDPProtocolClient.decodeJSONPayload(LDPCancelledPayload.self, from: frame.payload)
            if let fp = payload?.postFreeFootprintBytes, fp > 0 {
                footprintBytes = fp
            }
            if let active = activeInference,
               active.identity.requestID == frame.header.requestID,
               active.identity.attemptID == frame.header.attemptID {
                activeInference = nil
                emit(.transcriptionCancelled(active.identity, stage: payload?.stage ?? "cancelled"))
            }
            if state == .cancelling || state == .busy {
                transitionStateLocked(.warmModel)
                afterJobSettledLocked(generation: gen)
            }

        case .bye:
            // Graceful shutdown acknowledged; worker will call `_exit(0)`.
            // Keep kill timer armed until `waitpid` confirms exit.
            break

        case .pong:
            if let pong = try? LDPProtocolClient.decodeJSONPayload(LDPPongPayload.self, from: frame.payload) {
                footprintBytes = pong.physFootprintBytes
                syncMirrorsLocked()
            }

        case .error:
            clearShaderNoticeLocked()
            let errPayload = (try? LDPProtocolClient.decodeJSONPayload(LDPErrorPayload.self, from: frame.payload))
                ?? LDPErrorPayload(code: frame.header.statusOrFlags, message: "推理子进程报错")
            let errCode = errPayload.errorCode

            if errCode == .protocolError {
                // Fatal protocol desync -> tear down instance.
                instance.forceKill()
                return
            }

            if state == .starting {
                if pendingRequest != nil {
                    pendingRequest = nil
                    emit(.transcriptionFailed(nil, message: errPayload.message, isCriticalMemoryAbort: false))
                }
                beginGracefulShutdownLocked(killGraceMs: 1000)
                return
            }

            if let active = activeInference,
               active.identity.requestID == frame.header.requestID,
               active.identity.attemptID == frame.header.attemptID {
                activeInference = nil
                if state == .busy || state == .cancelling {
                    transitionStateLocked(.warmModel)
                }
                emit(.transcriptionFailed(active.identity, message: errPayload.message, isCriticalMemoryAbort: false))
                afterJobSettledLocked(generation: gen)
            }

        default:
            break
        }
    }

    private func afterJobSettledLocked(generation gen: WorkerGeneration) {
        if memoryPressure == .critical {
            allowRespawnPendingAfterStop = false
            beginGracefulShutdownLocked(killGraceMs: LiteDictateConstants.workerCriticalKillDeadlineMs)
            return
        }
        if memoryPressure == .warning || shutdownAfterCurrentJob || pendingSelfHealRestart {
            // If a pending request is waiting across self-heal or model switch (and not under warning), respawn after exit.
            allowRespawnPendingAfterStop = (pendingRequest != nil && memoryPressure == .normal)
            beginGracefulShutdownLocked(killGraceMs: 1500)
            return
        }
        if let pending = pendingRequest {
            if pending.model.id == loadedModelID && pendingModelSwitch == nil {
                pendingRequest = nil
                dispatchTranscriptionLocked(pending)
            } else {
                allowRespawnPendingAfterStop = true
                beginGracefulShutdownLocked(killGraceMs: 1500)
            }
            return
        }
        if pendingModelSwitch != nil {
            allowRespawnPendingAfterStop = false
            beginGracefulShutdownLocked(killGraceMs: 1500)
            return
        }
        armWarmTTLTimerLocked(for: gen)
    }

    private func dispatchTranscriptionLocked(_ request: WorkerTranscriptionRequest) {
        guard let instance = activeInstance, state == .warmModel else {
            pendingRequest = request
            return
        }
        warmTTLTimer?.cancel()
        warmTTLTimer = nil

        nextAttemptID &+= 1
        let identity = InferenceIdentity(
            requestID: request.requestID,
            workerGeneration: instance.workerGeneration,
            attemptID: nextAttemptID
        )

        let caps = request.model.capabilities
        let effectiveMaxSamples = caps.effectiveMaxSamples
        let clampedPCM = request.pcm.clamped(maxSamples: effectiveMaxSamples)
        let metadata = LDPTranscribeMetadata(
            sampleRate: clampedPCM.sampleRate,
            language: request.language,
            vocabulary: caps.supportsVocabulary ? request.vocabulary.map { Array($0.prefix(LiteDictateConstants.maxVocabEntries)) } : nil,
            contextPrompt: (!caps.supportsVocabulary && (caps.supportsContextPrompt || caps.supportsInitialPrompt)) ? request.contextPrompt : nil
        )

        do {
            let frame = try LDPProtocolClient.makeTranscribeFrame(
                requestID: identity.requestID,
                attemptID: identity.attemptID,
                metadata: metadata,
                pcm: clampedPCM,
                maxSamples: effectiveMaxSamples
            )
            activeInference = (identity, request)
            transitionStateLocked(.busy)
            emit(.transcriptionStarted(identity))
            sendFrameAsync(frame, to: instance)

            if memoryPressure == .warning {
                shutdownAfterCurrentJob = true
                armWarningGraceTimerLocked(delaySeconds: 3.0) { [weak self] in
                    guard let self, self.state == .busy, let active = self.activeInference else { return }
                    self.cancelAndShutdownForMemoryLocked(active: active, killGraceMs: 500, isCritical: false)
                }
            }
        } catch {
            emit(.transcriptionFailed(identity, message: "构建音频帧失败：\(error)", isCriticalMemoryAbort: false))
            armWarmTTLTimerLocked(for: instance.workerGeneration)
        }
    }

    private func beginGracefulShutdownLocked(killGraceMs: Int) {
        guard let instance = activeInstance else {
            transitionStateLocked(.stopped)
            return
        }
        warmTTLTimer?.cancel()
        warmTTLTimer = nil
        warningGraceTimer?.cancel()
        warningGraceTimer = nil
        clearShaderNoticeLocked()

        if state != .stopping {
            transitionStateLocked(.stopping)
            let frame = LDPProtocolClient.makeEmptyFrame(msgType: .shutdown)
            sendFrameAsync(frame, to: instance)
        }
        armKillTimerLocked(for: instance, delayMs: killGraceMs)
    }

    private func handleReadLoopEndedLocked(generation gen: WorkerGeneration, error: Error) {
        guard let instance = activeInstance, instance.workerGeneration == gen else { return }
        if state != .stopping {
            armKillTimerLocked(for: instance, delayMs: 500)
        }
    }

    private func failStartupTimeoutLocked(message: String) {
        allowRespawnPendingAfterStop = false
        if pendingRequest != nil {
            pendingRequest = nil
            emit(.transcriptionFailed(nil, message: message, isCriticalMemoryAbort: false))
        }
        beginGracefulShutdownLocked(killGraceMs: 500)
    }

    private func handleProcessExitLocked(generation gen: WorkerGeneration, status: Int32) {
        guard let instance = activeInstance, instance.workerGeneration == gen else { return }

        instance.closePipes()
        cancelAllTimersLocked()
        clearShaderNoticeLocked()

        let previousState = state
        let shouldRespawnPending = allowRespawnPendingAfterStop
        allowRespawnPendingAfterStop = false

        let inFlight = activeInference
        activeInference = nil
        activeInstance = nil
        loadedModelID = nil
        loadedModelPath = nil
        footprintBytes = 0
        shutdownAfterCurrentJob = false
        pendingSelfHealRestart = false

        transitionStateLocked(.stopped)

        if let inFlight {
            let isCritical = (memoryPressure == .critical)
            emit(.transcriptionFailed(
                inFlight.identity,
                message: isCritical ? "系统内存不足，推理进程已释放" : "推理子进程意外退出 (status=\(status))",
                isCriticalMemoryAbort: isCritical
            ))
        }

        // Prevent crash/timeout respawn loops:
        // Only respawn `pendingRequest` after an intentional teardown (model switch / self-heal / queued after busy).
        // If the worker crashed unexpectedly during `.starting` or timed out under `.warning`, fail once and stop.
        if let pending = pendingRequest {
            pendingModelSwitch = nil
            if memoryPressure == .critical {
                pendingRequest = nil
                emit(.criticalMemoryInterruptedActiveJob(pending.requestID))
            } else if previousState == .starting || (previousState == .stopping && !shouldRespawnPending) {
                pendingRequest = nil
                emit(.transcriptionFailed(
                    nil,
                    message: "推理子进程启动失败 (status=\(status))",
                    isCriticalMemoryAbort: false
                ))
            } else {
                startWorkerLocked(for: pending.model)
            }
        } else {
            pendingModelSwitch = nil
        }
    }

    private func sendFrameAsync(_ frame: LDPFrame, to instance: WorkerProcessInstance) {
        instance.writeFrameAsync(frame)
    }

    public func updateWarmTTLSeconds(_ seconds: TimeInterval?) {
        supervisorQueue.async {
            self.warmTTLSeconds = seconds
            if self.state == .warmModel, let instance = self.activeInstance {
                self.armWarmTTLTimerLocked(for: instance.workerGeneration, allowImmediateUnload: true)
            }
        }
    }

    private func armWarmTTLTimerLocked(for gen: WorkerGeneration, allowImmediateUnload: Bool = true) {
        warmTTLTimer?.cancel()
        warmTTLTimer = nil
        guard let ttl = warmTTLSeconds else {
            // Keep resident until memory pressure / sleep / lock / quit (0 idle timers).
            return
        }
        let effectiveTTL: TimeInterval
        if ttl <= 0 {
            if allowImmediateUnload {
                beginGracefulShutdownLocked(killGraceMs: 1500)
                return
            }
            // Wait up to 45s while user finishes speaking; afterJobSettledLocked will unload immediately.
            effectiveTTL = 45.0
        } else {
            effectiveTTL = ttl
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  let instance = self.activeInstance,
                  instance.workerGeneration == gen,
                  self.state == .warmModel
            else { return }
            self.beginGracefulShutdownLocked(killGraceMs: 1500)
        }
        warmTTLTimer = item
        supervisorQueue.asyncAfter(deadline: .now() + effectiveTTL, execute: item)
    }

    private func armKillTimerLocked(for instance: WorkerProcessInstance, delayMs: Int) {
        killTimer?.cancel()
        let gen = instance.workerGeneration
        let item = DispatchWorkItem { [weak self, weak instance] in
            guard let self, let instance,
                  self.activeInstance?.workerGeneration == gen
            else { return }
            instance.forceKill()
        }
        killTimer = item
        supervisorQueue.asyncAfter(deadline: .now() + .milliseconds(max(50, delayMs)), execute: item)
    }

    private func armWarningGraceTimerLocked(delaySeconds: TimeInterval, action: @escaping () -> Void) {
        warningGraceTimer?.cancel()
        let item = DispatchWorkItem(block: action)
        warningGraceTimer = item
        supervisorQueue.asyncAfter(deadline: .now() + delaySeconds, execute: item)
    }

    private func armShaderNoticeTimerLocked(for gen: WorkerGeneration) {
        shaderNoticeTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeInstance?.workerGeneration == gen,
                  self.state == .starting
            else { return }
            self.shaderNoticeVisible = true
            self.emit(.metalShaderCompilationLikely(true))
        }
        shaderNoticeTimer = item
        supervisorQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func clearShaderNoticeLocked() {
        shaderNoticeTimer?.cancel()
        shaderNoticeTimer = nil
        if shaderNoticeVisible {
            shaderNoticeVisible = false
            emit(.metalShaderCompilationLikely(false))
        }
    }

    private func cancelAllTimersLocked() {
        warmTTLTimer?.cancel(); warmTTLTimer = nil
        killTimer?.cancel(); killTimer = nil
        warningGraceTimer?.cancel(); warningGraceTimer = nil
        shaderNoticeTimer?.cancel(); shaderNoticeTimer = nil
    }

    private func transitionStateLocked(_ newState: WorkerLifecycleState) {
        state = newState
        syncMirrorsLocked()
        emit(.stateChanged(newState, footprintBytes: footprintBytes))
    }

    private func syncMirrorsLocked() {
        stateLock.lock()
        mirroredState = state
        mirroredPressure = memoryPressure
        mirroredFootprint = footprintBytes
        stateLock.unlock()
    }

    private func emit(_ event: WorkerSupervisorEvent) {
        stateLock.lock()
        let handler = eventHandler
        stateLock.unlock()
        handler?(event)
    }
}
