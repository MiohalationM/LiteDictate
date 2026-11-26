import Darwin
import Foundation

/// Bounded 256 KB ring buffer draining Worker FD 1/2 diagnostics asynchronously without heap growth.
public final class DiagnosticLogRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var totalWritten: Int = 0

    public init(capacity: Int = LiteDictateConstants.workerLogRingBufferBytes) {
        self.capacity = max(1024, capacity)
        self.storage = [UInt8](repeating: 0, count: self.capacity)
    }

    public func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty, let base = bytes.baseAddress else { return }
        lock.lock()
        defer { lock.unlock() }

        var offset = 0
        var remaining = bytes.count
        if remaining >= capacity {
            offset = remaining - capacity
            remaining = capacity
            writeIndex = 0
            totalWritten = capacity
        }
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            storage.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress!.advanced(by: writeIndex), base.advanced(by: offset), chunk)
            }
            writeIndex = (writeIndex + chunk) % capacity
            offset += chunk
            remaining -= chunk
            totalWritten = min(capacity, totalWritten + chunk)
        }
    }

    public func snapshotText() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard totalWritten > 0 else { return "" }
        if totalWritten < capacity {
            return String(decoding: storage[0..<totalWritten], as: UTF8.self)
        }
        var ordered = [UInt8]()
        ordered.reserveCapacity(capacity)
        ordered.append(contentsOf: storage[writeIndex..<capacity])
        ordered.append(contentsOf: storage[0..<writeIndex])
        return String(decoding: ordered, as: UTF8.self)
    }
}

public enum WorkerSpawnError: Error, Sendable, Equatable {
    case executableNotFound(String)
    case pipeFailed(errno: Int32)
    case fdRelocationFailed(errno: Int32)
    case spawnFailed(errno: Int32)
}

/// Manages a single `litedictate-worker` child process spawned via `posix_spawn` with:
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`
/// - FD 0 -> `/dev/null`
/// - FD 1, 2 -> diagnostic pipe drained into 256 KB ring buffer
/// - FD 3 -> Host->Worker protocol pipe (relocating any source FD in 0...4 via `F_DUPFD_CLOEXEC >= 5`)
/// - FD 4 -> Worker->Host protocol pipe
/// - Single `waitid(WNOWAIT)` + `waitpid` reaper eliminating PID reuse races on `SIGKILL`.
public final class WorkerProcessInstance: @unchecked Sendable {
    private final class LogReadBufferBox: @unchecked Sendable {
        var bytes = [UInt8](repeating: 0, count: 4096)
    }

    public let workerGeneration: WorkerGeneration
    public let pid: pid_t
    public let diagnosticLogs: DiagnosticLogRingBuffer

    private let stateLock = NSLock()
    private let writeQueue: DispatchQueue
    private var reaped: Bool = false
    /// Exclusively owned by `writeQueue` (eliminates write-vs-close FD reuse races).
    private var writeFD: Int32
    private var readFD: Int32
    private var logSource: DispatchSourceRead?
    private let exitedAtomic = AtomicBool(false)

    public var hasExited: Bool {
        exitedAtomic.load(ordering: .acquire)
    }

    private init(
        workerGeneration: WorkerGeneration,
        pid: pid_t,
        writeFD: Int32,
        readFD: Int32,
        logReadFD: Int32,
        diagnosticLogs: DiagnosticLogRingBuffer,
        onExit: @escaping @Sendable (WorkerGeneration, Int32) -> Void
    ) {
        self.workerGeneration = workerGeneration
        self.pid = pid
        self.writeQueue = DispatchQueue(
            label: "io.github.litedictate.worker.write.\(workerGeneration)",
            qos: .userInitiated
        )
        self.writeFD = writeFD
        self.readFD = readFD
        self.diagnosticLogs = diagnosticLogs

        // Asynchronously drain FD 1/2 diagnostic log pipe into 256 KB ring buffer using a single reused 4 KiB buffer.
        let logQueue = DispatchQueue(label: "io.github.litedictate.worker.log.\(workerGeneration)", qos: .utility)
        let source = DispatchSource.makeReadSource(fileDescriptor: logReadFD, queue: logQueue)
        let ring = diagnosticLogs
        let reusableBuffer = LogReadBufferBox()
        source.setEventHandler {
            while true {
                let n = reusableBuffer.bytes.withUnsafeMutableBytes { raw -> Int in
                    Darwin.read(logReadFD, raw.baseAddress!, raw.count)
                }
                if n > 0 {
                    reusableBuffer.bytes.withUnsafeBufferPointer { ptr in
                        ring.append(UnsafeBufferPointer(start: ptr.baseAddress, count: n))
                    }
                } else if n == 0 {
                    source.cancel()
                    break
                } else {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK { break }
                    source.cancel()
                    break
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(logReadFD)
        }
        self.logSource = source
        source.resume()

        // Single owner reaper using waitid(WNOWAIT) before flipping `reaped` under lock,
        // then waitpid() to reap — guarantees zero PID-reuse race when sending SIGKILL.
        let reaperQueue = DispatchQueue(label: "io.github.litedictate.worker.reaper.\(workerGeneration)", qos: .utility)
        reaperQueue.async { [weak self] in
            var info = siginfo_t()
            while true {
                let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                if rc == 0 { break }
                if errno == EINTR { continue }
                break
            }

            if let self {
                self.stateLock.lock()
                self.reaped = true
                self.exitedAtomic.store(true, ordering: .release)
                self.stateLock.unlock()
            }

            var status: Int32 = 0
            while true {
                let w = waitpid(pid, &status, 0)
                if w >= 0 { break }
                if errno == EINTR { continue }
                break
            }

            onExit(workerGeneration, status)
        }
    }

    deinit {
        if writeFD >= 0 {
            Darwin.close(writeFD)
            writeFD = -1
        }
        stateLock.lock()
        let r = readFD
        let src = logSource
        readFD = -1
        logSource = nil
        stateLock.unlock()
        if r >= 0 { Darwin.close(r) }
        src?.cancel()
    }

    /// Spawns `litedictate-worker` using `posix_spawn` with strict FD 0/1/2/3/4 wiring and CLOEXEC.
    public static func spawn(
        executablePath: String,
        workerGeneration: WorkerGeneration,
        environmentOverrides: [String: String] = [:],
        onExit: @escaping @Sendable (WorkerGeneration, Int32) -> Void
    ) throws -> WorkerProcessInstance {
        LDPProtocolClient.ensureSIGPIPEIgnored()
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw WorkerSpawnError.executableNotFound(executablePath)
        }

        // Create pipes: [0] = read, [1] = write
        var logPipe: [Int32] = [-1, -1]
        var h2wPipe: [Int32] = [-1, -1]
        var w2hPipe: [Int32] = [-1, -1]

        func closeIfValid(_ fd: inout Int32) {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }

        func cleanupAll() {
            closeIfValid(&logPipe[0]); closeIfValid(&logPipe[1])
            closeIfValid(&h2wPipe[0]); closeIfValid(&h2wPipe[1])
            closeIfValid(&w2hPipe[0]); closeIfValid(&w2hPipe[1])
        }

        guard pipe(&logPipe) == 0 else {
            throw WorkerSpawnError.pipeFailed(errno: errno)
        }
        guard pipe(&h2wPipe) == 0 else {
            let err = errno
            cleanupAll()
            throw WorkerSpawnError.pipeFailed(errno: err)
        }
        guard pipe(&w2hPipe) == 0 else {
            let err = errno
            cleanupAll()
            throw WorkerSpawnError.pipeFailed(errno: err)
        }

        // Mark all pipe ends CLOEXEC in parent immediately.
        for fd in [logPipe[0], logPipe[1], h2wPipe[0], h2wPipe[1], w2hPipe[0], w2hPipe[1]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        // Non-blocking read for diagnostic log pipe so DispatchSource drains cleanly without blocking.
        let logFlags = fcntl(logPipe[0], F_GETFL, 0)
        if logFlags >= 0 {
            _ = fcntl(logPipe[0], F_SETFL, logFlags | O_NONBLOCK)
        }

        // Relocate any child source FD falling in 0...4 to >= 5 via F_DUPFD_CLOEXEC (Section 7.1).
        func relocateIfInReservedRange(_ fd: inout Int32) throws {
            if fd >= 0 && fd <= 4 {
                let relocated = fcntl(fd, F_DUPFD_CLOEXEC, 5)
                guard relocated >= 5 else {
                    throw WorkerSpawnError.fdRelocationFailed(errno: errno)
                }
                Darwin.close(fd)
                fd = relocated
            }
        }

        do {
            try relocateIfInReservedRange(&logPipe[1])
            try relocateIfInReservedRange(&h2wPipe[0])
            try relocateIfInReservedRange(&w2hPipe[1])
        } catch {
            cleanupAll()
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // FD 0 -> /dev/null
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // FD 1, 2 -> diagnostic log pipe write end
        posix_spawn_file_actions_adddup2(&fileActions, logPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, logPipe[1], STDERR_FILENO)
        // FD 3 -> Host->Worker read end
        posix_spawn_file_actions_adddup2(&fileActions, h2wPipe[0], 3)
        // FD 4 -> Worker->Host write end
        posix_spawn_file_actions_adddup2(&fileActions, w2hPipe[1], 4)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        defer { posix_spawnattr_destroy(&spawnAttr) }

        let flags: Int16 = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&spawnAttr, flags)

        // Build argv and envp
        var envDict = ProcessInfo.processInfo.environment
        for (k, v) in environmentOverrides {
            envDict[k] = v
        }
        let argvStrings = [executablePath]
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }

        var argvC: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        var envpC: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in argvC where ptr != nil { free(ptr) }
            for ptr in envpC where ptr != nil { free(ptr) }
        }

        var childPID: pid_t = 0
        let rc = executablePath.withCString { cPath in
            posix_spawn(&childPID, cPath, &fileActions, &spawnAttr, &argvC, &envpC)
        }

        // Close child-side ends in parent regardless of spawn outcome.
        closeIfValid(&logPipe[1])
        closeIfValid(&h2wPipe[0])
        closeIfValid(&w2hPipe[1])

        guard rc == 0 else {
            closeIfValid(&logPipe[0])
            closeIfValid(&h2wPipe[1])
            closeIfValid(&w2hPipe[0])
            throw WorkerSpawnError.spawnFailed(errno: rc)
        }

        return WorkerProcessInstance(
            workerGeneration: workerGeneration,
            pid: childPID,
            writeFD: h2wPipe[1],
            readFD: w2hPipe[0],
            logReadFD: logPipe[0],
            diagnosticLogs: DiagnosticLogRingBuffer(),
            onExit: onExit
        )
    }

    /// Serializes writes onto `writeQueue` (same serial queue that closes `writeFD`), eliminating FD-reuse races.
    public func writeFrame(_ frame: LDPFrame) throws {
        try writeQueue.sync {
            guard writeFD >= 0 else {
                throw LDPProtocolError.eof
            }
            try LDPProtocolClient.writeFrame(frame, to: writeFD)
        }
    }

    /// Asynchronously enqueues a frame write onto the instance's serial `writeQueue`.
    public func writeFrameAsync(_ frame: LDPFrame) {
        writeQueue.async {
            guard self.writeFD >= 0 else { return }
            try? LDPProtocolClient.writeFrame(frame, to: self.writeFD)
        }
    }

    public func readFrame() throws -> LDPFrame {
        stateLock.lock()
        let fd = readFD
        stateLock.unlock()
        guard fd >= 0 else {
            throw LDPProtocolError.eof
        }
        return try LDPProtocolClient.readFrame(from: fd)
    }

    public func closePipes() {
        writeQueue.async {
            if self.writeFD >= 0 {
                Darwin.close(self.writeFD)
                self.writeFD = -1
            }
        }

        stateLock.lock()
        let r = readFD
        let src = logSource
        readFD = -1
        logSource = nil
        stateLock.unlock()

        if r >= 0 { Darwin.close(r) }
        src?.cancel()
    }

    /// Generation-bound signal delivery: impossible to signal a reaped/recycled PID.
    public func sendSignalIfAlive(_ sig: Int32) {
        stateLock.lock()
        let alreadyReaped = reaped
        if !alreadyReaped {
            _ = Darwin.kill(pid, sig)
        }
        stateLock.unlock()
    }

    public func forceKill() {
        sendSignalIfAlive(SIGKILL)
        closePipes()
    }
}
