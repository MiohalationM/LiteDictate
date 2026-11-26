import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Snapshot of the frontmost application captured with ZERO AX IPC.
public struct FrontmostAppSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let launchDate: Date?
    public let bundleIdentifier: String?

    public init(pid: pid_t, launchDate: Date?, bundleIdentifier: String?) {
        self.pid = pid
        self.launchDate = launchDate
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Result of attaching main-thread AXObservers for an active dictation request.
public struct AXObserverRegistrationResult: Equatable, Sendable {
    public let success: Bool
    public let isSecureTextField: Bool

    public init(success: Bool, isSecureTextField: Bool) {
        self.success = success
        self.isSecureTextField = isSecureTextField
    }
}

/// Abstract backend allowing `FocusMonitor` to be tested deterministically without relying on TCC Accessibility grants.
public protocol FocusMonitorBackend: AnyObject, Sendable {
    /// Zero-IPC snapshot of frontmost application.
    func frontmostApplication() -> FrontmostAppSnapshot?

    /// Must be invoked strictly on the main thread (`CFRunLoopGetMain()`).
    /// Sets `0.15s` AX messaging timeout on both systemWide and appElement and registers focus notifications.
    func attachAXObserverOnMainThread(
        pid: pid_t,
        timeoutSeconds: Float,
        onInvalidated: @escaping @Sendable (String) -> Void
    ) -> AXObserverRegistrationResult

    /// Must be invoked strictly on the main thread (`CFRunLoopGetMain()`).
    func detachAXObserverOnMainThread()

    /// Checks `IsSecureEventInputEnabled()` and current AX focused element role/subrole.
    /// NEVER queries `kAXMarkedTextRangeAttribute` (WeType red line).
    func isCurrentFocusedElementSecureTextField(timeoutSeconds: Float) -> Bool

    /// Returns `true` ONLY when Accessibility positively confirms the focused element is a non-editable
    /// native AppKit control (e.g. Finder Desktop / ScrollArea / Outline / Button / Window) rather than a text box.
    func isCurrentFocusedElementKnownNonEditable(bundleIdentifier: String?, timeoutSeconds: Float) -> Bool
}

public extension FocusMonitorBackend {
    func isCurrentFocusedElementKnownNonEditable(bundleIdentifier: String?, timeoutSeconds: Float) -> Bool {
        false
    }
}

/// Production macOS backend attaching `AXObserver` strictly to `CFRunLoopGetMain()`.
public final class LiveFocusMonitorBackend: FocusMonitorBackend, @unchecked Sendable {
    private final class CallbackContext: @unchecked Sendable {
        let appElement: AXUIElement
        let initialFocusedWindow: AXUIElement?
        let onInvalidated: @Sendable (String) -> Void

        init(
            appElement: AXUIElement,
            initialFocusedWindow: AXUIElement?,
            onInvalidated: @escaping @Sendable (String) -> Void
        ) {
            self.appElement = appElement
            self.initialFocusedWindow = initialFocusedWindow
            self.onInvalidated = onInvalidated
        }
    }

    // Main-thread exclusively owned AX resources.
    private var activeObserver: AXObserver?
    private var activeAppElement: AXUIElement?
    private var activeCallbackContext: CallbackContext?

    public init() {}

    deinit {
        if Thread.isMainThread {
            detachAXObserverOnMainThread()
        }
    }

    public func frontmostApplication() -> FrontmostAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return FrontmostAppSnapshot(
            pid: app.processIdentifier,
            launchDate: app.launchDate,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    public func attachAXObserverOnMainThread(
        pid: pid_t,
        timeoutSeconds: Float,
        onInvalidated: @escaping @Sendable (String) -> Void
    ) -> AXObserverRegistrationResult {
        precondition(Thread.isMainThread, "AXObserver MUST be attached on the main thread (CFRunLoopGetMain())")

        detachAXObserverOnMainThread()

        guard pid > 0, AXIsProcessTrusted() else {
            let secure = IsSecureEventInputEnabled()
            return AXObserverRegistrationResult(success: false, isSecureTextField: secure)
        }

        // Apply 0.15s messaging timeout to BOTH systemWide and target application AXUIElements.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeoutSeconds)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeoutSeconds)

        var observerRef: AXObserver?
        let createError = AXObserverCreate(pid, Self.axObserverCallback, &observerRef)
        guard createError == .success, let observer = observerRef else {
            let secure = isCurrentFocusedElementSecureTextField(timeoutSeconds: timeoutSeconds)
            return AXObserverRegistrationResult(success: false, isSecureTextField: secure)
        }

        // Capture initial focused window so spurious same-window IME/DOM notifications are ignored.
        let initialFocusedWindow = Self.copyFocusedWindow(from: appElement)

        let callbackCtx = CallbackContext(
            appElement: appElement,
            initialFocusedWindow: initialFocusedWindow,
            onInvalidated: onInvalidated
        )
        let refcon = Unmanaged.passUnretained(callbackCtx).toOpaque()

        // Subscribe ONLY to kAXFocusedWindowChangedNotification (not kAXFocusedUIElementChangedNotification
        // or kAXUIElementDestroyedNotification, which fire spuriously inside the same window in Electron/Safari/WeType).
        let windowChangedErr = AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )

        let windowOK = (windowChangedErr == .success || windowChangedErr == .notificationAlreadyRegistered)

        guard windowOK else {
            _ = AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            let secure = isCurrentFocusedElementSecureTextField(timeoutSeconds: timeoutSeconds)
            return AXObserverRegistrationResult(success: false, isSecureTextField: secure)
        }

        var isSecure = IsSecureEventInputEnabled()
        if !isSecure {
            var focusedValue: CFTypeRef?
            let focusedQueryErr = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
            if focusedQueryErr == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
                let element = (focusedValue as! AXUIElement)
                AXUIElementSetMessagingTimeout(element, timeoutSeconds)
                isSecure = Self.isElementSecureTextField(element)
            }
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        activeObserver = observer
        activeAppElement = appElement
        activeCallbackContext = callbackCtx

        return AXObserverRegistrationResult(success: true, isSecureTextField: isSecure)
    }

    public func detachAXObserverOnMainThread() {
        precondition(Thread.isMainThread, "AXObserver MUST be detached on the main thread (CFRunLoopGetMain())")

        if let observer = activeObserver {
            if let appElement = activeAppElement {
                _ = AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            }
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        activeObserver = nil
        activeAppElement = nil
        activeCallbackContext = nil
    }

    public func isCurrentFocusedElementSecureTextField(timeoutSeconds: Float) -> Bool {
        if IsSecureEventInputEnabled() {
            return true
        }
        guard AXIsProcessTrusted() else {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeoutSeconds)

        var focusedValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard err == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let element = (focusedValue as! AXUIElement)
        AXUIElementSetMessagingTimeout(element, timeoutSeconds)
        return Self.isElementSecureTextField(element)
    }

    /// Leaf controls that are unambiguously non-editable across native macOS apps.
    private static let knownNonEditableLeafRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXImage",
        "AXToolbar",
        "AXMenuBar",
        "AXMenu",
    ]

    /// Container roles that are non-editable ONLY in known native non-editor Apple apps
    /// (never applied to arbitrary 3rd-party Electron/CEF/Tauri/custom-drawn apps where
    /// focused editors frequently report AXWindow/AXScrollArea).
    private static let knownNonEditableContainerRoles: Set<String> = [
        "AXWindow",
        "AXApplication",
        "AXScrollArea",
        "AXOutline",
        "AXTable",
        "AXList",
        "AXBrowser",
        "AXIconGroup",
        "AXTabGroup",
        "AXSplitGroup",
    ]

    private static let knownNativeNonEditorBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.preview",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.activitymonitor",
        "com.apple.music",
        "com.apple.photos",
        "com.apple.books",
        "com.apple.appstore",
        "com.apple.podcasts",
        "com.apple.tv",
        "com.apple.maps",
        "com.apple.weather",
        "com.apple.stocks",
        "com.apple.home",
    ]

    public func isCurrentFocusedElementKnownNonEditable(bundleIdentifier: String?, timeoutSeconds: Float) -> Bool {
        // Never assume non-editable for browsers, Electron, Qt, JetBrains, or Terminals where AX roles
        // frequently report AXWebArea/AXGroup/AXUnknown even when an input box IS actively focused.
        let normalizedBundleID = bundleIdentifier?.lowercased()
        if let bundleID = normalizedBundleID, !bundleID.isEmpty {
            if DirectTextInjector.axUnreliableBundleIDs.contains(bundleID)
                || ClipboardInjector.defaultTerminalBundleIDs.contains(bundleID)
                || bundleID.hasPrefix("com.jetbrains.")
                || bundleID.contains("electron")
                || bundleID.contains("t3code")
                || bundleID.contains("t3.code")
                || bundleID.contains("t3-code")
            {
                return false
            }
        }
        guard AXIsProcessTrusted() else {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeoutSeconds)

        var focusedValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard err == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let element = (focusedValue as! AXUIElement)
        AXUIElementSetMessagingTimeout(element, timeoutSeconds)

        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable) == .success,
           isSettable.boolValue
        {
            return false
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String
        else {
            return false
        }
        if LiveAXDirectInserter.allowedNativeTextRoles.contains(role) || role == "AXWebArea" {
            return false
        }
        if Self.knownNonEditableLeafRoles.contains(role) {
            return true
        }
        if let bundleID = normalizedBundleID,
           Self.knownNativeNonEditorBundleIDs.contains(bundleID),
           Self.knownNonEditableContainerRoles.contains(role)
        {
            return true
        }
        return false
    }

    /// Compares initial and current focused window references using `CFEqual`.
    /// Returns `false` when the focused window is unchanged (spurious IME/popover/DOM notification).
    public static func didFocusedWindowChange(initial: CFTypeRef?, current: CFTypeRef?) -> Bool {
        switch (initial, current) {
        case (nil, nil):
            return false
        case let (lhs?, rhs?):
            return !CFEqual(lhs, rhs)
        default:
            return true
        }
    }

    private static func copyFocusedWindow(from appElement: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (windowValue as! AXUIElement)
    }

    /// Checks ONLY `kAXRoleAttribute` and `kAXSubroleAttribute` for `"AXSecureTextField"`.
    /// Strictly respects WeType 5 red lines: NEVER queries `kAXMarkedTextRangeAttribute`.
    private static func isElementSecureTextField(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == "AXSecureTextField"
        {
            return true
        }

        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           subrole == "AXSecureTextField"
        {
            return true
        }

        return false
    }

    private static let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let ctx = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
        let currentWindow = LiveFocusMonitorBackend.copyFocusedWindow(from: ctx.appElement)
        guard LiveFocusMonitorBackend.didFocusedWindowChange(
            initial: ctx.initialFocusedWindow,
            current: currentWindow
        ) else {
            // Spurious notification while still inside the exact same window — ignore.
            return
        }
        let reason = notification as String
        ctx.onInvalidated(reason)
    }
}

/// Focus generation & main-thread `AXObserver` monitor.
///
/// Key invariants:
/// - `captureInitialFocus()` performs ZERO AX IPC so cold-mic startup stays `<= 100 ms`.
/// - `AXObserver` setup & teardown run strictly on `CFRunLoopGetMain()`.
/// - `focusGenerationCounter` is monotonically incremented on ANY focus/window/element/app change;
///   switching back NEVER restores an older generation (permanently invalidates auto-paste for the in-flight request).
public final class FocusMonitor: FocusMonitoring, @unchecked Sendable {
    public let focusGenerationCounter: AtomicUInt64

    public var currentFocusGeneration: UInt64 {
        focusGenerationCounter.load(ordering: .acquire)
    }

    private let backend: FocusMonitorBackend
    private let timeoutSeconds: Float
    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(
        label: "io.github.litedictate.focus.delivery",
        qos: .userInteractive
    )

    private var activeRequestID: RequestID?
    private var activeEventHandler: (@Sendable (FocusEvent) -> Void)?
    private var workspaceObserver: NSObjectProtocol?

    public init(
        backend: FocusMonitorBackend = LiveFocusMonitorBackend(),
        timeoutSeconds: Float = LiteDictateConstants.axMessagingTimeoutSeconds,
        observeWorkspaceNotifications: Bool = true
    ) {
        self.focusGenerationCounter = AtomicUInt64(1)
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds

        if observeWorkspaceNotifications {
            installWorkspaceObserver()
        }
    }

    deinit {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        let backendRef = backend
        if Thread.isMainThread {
            backendRef.detachAXObserverOnMainThread()
        } else {
            DispatchQueue.main.async {
                backendRef.detachAXObserverOnMainThread()
            }
        }
    }

    /// Zero-IPC press-time capture of frontmost app identity + current `focusGeneration`.
    public func captureInitialFocus() -> FocusContext {
        let generation = focusGenerationCounter.load(ordering: .acquire)
        let app = backend.frontmostApplication()
        return FocusContext(
            pid: app?.pid ?? -1,
            launchDate: app?.launchDate,
            bundleIdentifier: app?.bundleIdentifier,
            focusGeneration: generation,
            axInitialized: false,
            isSecureTextField: false
        )
    }

    /// Asynchronously attaches AXObservers strictly onto `CFRunLoopGetMain()` with `0.15s` timeout.
    public func beginMonitoring(
        requestID: RequestID,
        initialContext: FocusContext,
        onEvent: @escaping @Sendable (FocusEvent) -> Void
    ) {
        stateLock.lock()
        activeRequestID = requestID
        activeEventHandler = onEvent
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.setupMonitoringOnMainThread(
                requestID: requestID,
                initialContext: initialContext,
                onEvent: onEvent
            )
        }
    }

    public func stopMonitoring(requestID: RequestID) {
        stateLock.lock()
        let shouldDetach = (activeRequestID == requestID)
        if shouldDetach {
            activeRequestID = nil
            activeEventHandler = nil
        }
        stateLock.unlock()

        guard shouldDetach else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillStopped = (self.activeRequestID == nil)
            self.stateLock.unlock()
            if stillStopped {
                self.backend.detachAXObserverOnMainThread()
            }
        }
    }

    public func isFrontmostMatching(pid: pid_t, launchDate: Date?) -> Bool {
        guard pid > 0, let current = backend.frontmostApplication() else {
            return false
        }
        return current.pid == pid && current.launchDate == launchDate
    }

    public func isCurrentFocusedElementSecureTextField() -> Bool {
        backend.isCurrentFocusedElementSecureTextField(timeoutSeconds: timeoutSeconds)
    }

    public func frontmostPID() -> pid_t? {
        backend.frontmostApplication()?.pid
    }

    public func frontmostBundleIdentifier() -> String? {
        backend.frontmostApplication()?.bundleIdentifier
    }

    public func isCurrentFocusedElementKnownNonEditable(bundleIdentifier: String?) -> Bool {
        backend.isCurrentFocusedElementKnownNonEditable(
            bundleIdentifier: bundleIdentifier,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Triggers a monotonic `focusGeneration` increment and notifies any active request asynchronously.
    /// Exposed as internal/public for workspace notification delivery and deterministic unit tests.
    public func notifyFocusChanged(reason: String) {
        let newGeneration = focusGenerationCounter.increment(ordering: .acqRel)
        stateLock.lock()
        let handler = activeEventHandler
        stateLock.unlock()

        if let handler {
            deliveryQueue.async {
                handler(.focusInvalidated(newGeneration: newGeneration, reason: reason))
            }
        }
    }

    // MARK: - Private

    private func installWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyFocusChanged(reason: "NSWorkspace.didActivateApplicationNotification")
        }
    }

    private func setupMonitoringOnMainThread(
        requestID: RequestID,
        initialContext: FocusContext,
        onEvent: @escaping @Sendable (FocusEvent) -> Void
    ) {
        precondition(Thread.isMainThread, "FocusMonitor AX setup must execute on main thread")

        stateLock.lock()
        let isStillActive = (activeRequestID == requestID)
        stateLock.unlock()
        guard isStillActive else { return }

        // Check if focus already changed between zero-IPC press capture and main-thread AX setup.
        let generationBeforeAX = focusGenerationCounter.load(ordering: .acquire)
        let appStillMatches = isFrontmostMatching(pid: initialContext.pid, launchDate: initialContext.launchDate)
        if generationBeforeAX != initialContext.focusGeneration || !appStillMatches {
            if generationBeforeAX == initialContext.focusGeneration {
                notifyFocusChanged(reason: "frontmostApplicationChangedBeforeAXSetup")
            }
            deliveryQueue.async {
                onEvent(
                    .axInitialized(
                        requestID: requestID,
                        focusGeneration: initialContext.focusGeneration,
                        success: false,
                        isSecureTextField: false
                    )
                )
            }
            return
        }

        let result = backend.attachAXObserverOnMainThread(
            pid: initialContext.pid,
            timeoutSeconds: timeoutSeconds
        ) { [weak self] reason in
            self?.notifyFocusChanged(reason: reason)
        }

        // Re-check that this request is still active and focus did not shift during AX setup.
        stateLock.lock()
        let stillActiveAfterAX = (activeRequestID == requestID)
        stateLock.unlock()
        guard stillActiveAfterAX else {
            backend.detachAXObserverOnMainThread()
            return
        }

        let generationAfterAX = focusGenerationCounter.load(ordering: .acquire)
        let matchesAfterAX = isFrontmostMatching(pid: initialContext.pid, launchDate: initialContext.launchDate)
        let effectiveSuccess = result.success && generationAfterAX == initialContext.focusGeneration && matchesAfterAX

        if !effectiveSuccess && generationAfterAX == initialContext.focusGeneration && !matchesAfterAX {
            notifyFocusChanged(reason: "frontmostApplicationChangedDuringAXSetup")
        }

        deliveryQueue.async {
            onEvent(
                .axInitialized(
                    requestID: requestID,
                    focusGeneration: initialContext.focusGeneration,
                    success: effectiveSuccess,
                    isSecureTextField: result.isSecureTextField
                )
            )
        }
    }
}
