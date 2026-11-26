import Foundation

public struct FocusContext: Equatable, Sendable {
    public let pid: pid_t
    public let launchDate: Date?
    public let bundleIdentifier: String?
    public let focusGeneration: UInt64
    public var axInitialized: Bool
    public var isSecureTextField: Bool

    public init(
        pid: pid_t,
        launchDate: Date?,
        bundleIdentifier: String?,
        focusGeneration: UInt64,
        axInitialized: Bool = false,
        isSecureTextField: Bool = false
    ) {
        self.pid = pid
        self.launchDate = launchDate
        self.bundleIdentifier = bundleIdentifier
        self.focusGeneration = focusGeneration
        self.axInitialized = axInitialized
        self.isSecureTextField = isSecureTextField
    }
}

public enum FocusEvent: Equatable, Sendable {
    case axInitialized(requestID: RequestID, focusGeneration: UInt64, success: Bool, isSecureTextField: Bool)
    case focusInvalidated(newGeneration: UInt64, reason: String)
}

public protocol FocusMonitoring: AnyObject, Sendable {
    var focusGenerationCounter: AtomicUInt64 { get }
    var currentFocusGeneration: UInt64 { get }

    /// Zero-IPC press-time snapshot of frontmost application and current `focusGeneration`.
    func captureInitialFocus() -> FocusContext

    /// Asynchronously attaches AXObservers strictly onto `CFRunLoopGetMain()` with 0.15s AX timeout.
    func beginMonitoring(
        requestID: RequestID,
        initialContext: FocusContext,
        onEvent: @escaping @Sendable (FocusEvent) -> Void
    )

    func stopMonitoring(requestID: RequestID)
    func isFrontmostMatching(pid: pid_t, launchDate: Date?) -> Bool
    func isCurrentFocusedElementSecureTextField() -> Bool
    func frontmostPID() -> pid_t?
    func frontmostBundleIdentifier() -> String?
}
