import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

/// Global hotkey controller running a `CGEventTap` on a dedicated high-priority `pthread` + `CFRunLoop`.
///
/// Strict EventTap thread invariants:
/// 1. Line 1 of tap callback immediately passes through synthetic events (`0x4C444943` "LDIC").
/// 2. Never calls coordinator synchronously, never starts/stops audio, never performs AX IPC or pasteboard reads.
/// 3. Reads `shouldInterceptCancelEscape` lock-free (`acquire`), mirrors trigger key debt lock-free (`release`).
/// 4. Dispatches semantic `HotkeyEvent`s asynchronously onto `eventDeliveryQueue`.
public final class HotkeyController: HotkeyControlling, @unchecked Sendable {
    private final class TapThreadContext: @unchecked Sendable {
        let machine: HotkeyDebtMachine
        let deliveryQueue: DispatchQueue
        let onEvent: @Sendable (HotkeyEvent) -> Void
        let tapAliveAtomic: AtomicBool
        let temporarilySuspendedAtomic: AtomicBool
        let startupSemaphore = DispatchSemaphore(value: 0)
        let lifecycleLock = NSLock()

        var frontmostBundleID: String?
        var secureInputWasActive: Bool = false
        var secureInputPollTimer: CFRunLoopTimer?
        var tapPort: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var startupSucceeded: Bool = false

        init(
            machine: HotkeyDebtMachine,
            initialFrontmostBundleID: String?,
            deliveryQueue: DispatchQueue,
            onEvent: @escaping @Sendable (HotkeyEvent) -> Void,
            tapAliveAtomic: AtomicBool,
            temporarilySuspendedAtomic: AtomicBool
        ) {
            self.machine = machine
            self.frontmostBundleID = initialFrontmostBundleID
            self.deliveryQueue = deliveryQueue
            self.onEvent = onEvent
            self.tapAliveAtomic = tapAliveAtomic
            self.temporarilySuspendedAtomic = temporarilySuspendedAtomic
        }

        func setRunLoop(_ rl: CFRunLoop?) {
            lifecycleLock.lock()
            runLoop = rl
            lifecycleLock.unlock()
        }

        func getRunLoop() -> CFRunLoop? {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return runLoop
        }

        func setTapPort(_ port: CFMachPort?) {
            lifecycleLock.lock()
            tapPort = port
            lifecycleLock.unlock()
        }

        func getTapPort() -> CFMachPort? {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return tapPort
        }
    }

    private let stateLock = NSLock()
    private let eventDeliveryQueue = DispatchQueue(
        label: "io.github.litedictate.hotkey.delivery",
        qos: .userInteractive
    )
    private let tapAliveAtomic = AtomicBool(false)
    private let temporarilySuspendedAtomic = AtomicBool(false)

    private var thread: pthread_t?
    private var context: TapThreadContext?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init() {}

    deinit {
        stop()
    }

    public var isTemporarilySuspended: Bool {
        temporarilySuspendedAtomic.load(ordering: .acquire)
    }

    public var isTapAlive: Bool {
        guard tapAliveAtomic.load(ordering: .acquire) else {
            return false
        }
        stateLock.lock()
        let ctx = context
        stateLock.unlock()
        guard let port = ctx?.getTapPort() else { return false }
        return CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    @discardableResult
    public func start(
        binding: HotkeyBinding,
        disabledBundleIDs: Set<String>,
        shouldInterceptCancelEscape: AtomicBool,
        triggerKeyDebtActive: AtomicBool,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void
    ) -> Bool {
        stop()

        let initialFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let machine = HotkeyDebtMachine(
            binding: binding,
            disabledBundleIDs: disabledBundleIDs,
            shouldInterceptCancelEscape: shouldInterceptCancelEscape,
            triggerKeyDebtActive: triggerKeyDebtActive,
            temporarilySuspended: temporarilySuspendedAtomic
        )
        let ctx = TapThreadContext(
            machine: machine,
            initialFrontmostBundleID: initialFrontmost,
            deliveryQueue: eventDeliveryQueue,
            onEvent: onEvent,
            tapAliveAtomic: tapAliveAtomic,
            temporarilySuspendedAtomic: temporarilySuspendedAtomic
        )

        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0)

        let rawCtx = Unmanaged.passRetained(ctx).toOpaque()
        var createdThread: pthread_t?
        let rc = pthread_create(&createdThread, &attr, Self.tapThreadEntry, rawCtx)
        pthread_attr_destroy(&attr)

        guard rc == 0, let createdThread else {
            Unmanaged<TapThreadContext>.fromOpaque(rawCtx).release()
            tapAliveAtomic.store(false, ordering: .release)
            return false
        }

        // Wait briefly for the dedicated pthread to create and enable its CGEventTap.
        let waitResult = ctx.startupSemaphore.wait(timeout: .now() + .seconds(2))

        if waitResult == .timedOut || !ctx.startupSucceeded {
            if let rl = ctx.getRunLoop() {
                CFRunLoopStop(rl)
            }
            pthread_join(createdThread, nil)
            tapAliveAtomic.store(false, ordering: .release)
            return false
        }

        stateLock.lock()
        self.thread = createdThread
        self.context = ctx
        stateLock.unlock()

        installSystemObservers(for: ctx)
        return true
    }

    public func stop() {
        removeSystemObservers()

        stateLock.lock()
        let currentThread = thread
        let currentContext = context
        thread = nil
        context = nil
        stateLock.unlock()

        tapAliveAtomic.store(false, ordering: .release)

        if let currentContext, let rl = currentContext.getRunLoop() {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                HotkeyController.teardownTapResourcesOnTapThread(for: currentContext, runLoop: rl)
                CFRunLoopStop(rl)
            }
            CFRunLoopWakeUp(rl)
        }

        if let currentThread {
            pthread_join(currentThread, nil)
        }
    }

    public func updateBinding(_ binding: HotkeyBinding) {
        performOnTapThread { ctx in
            ctx.machine.updateBinding(binding)
        }
    }

    public func updateDisabledBundleIDs(_ bundleIDs: Set<String>) {
        performOnTapThread { ctx in
            ctx.machine.updateDisabledBundleIDs(bundleIDs)
        }
    }

    public func setTemporarilySuspended(_ suspended: Bool) {
        temporarilySuspendedAtomic.store(suspended, ordering: .release)
        performOnTapThread { ctx in
            ctx.machine.resetDebtForSuspendOrResume()
            if !suspended,
               !IsSecureEventInputEnabled(),
               let tapPort = ctx.getTapPort(),
               CFMachPortIsValid(tapPort),
               !CGEvent.tapIsEnabled(tap: tapPort)
            {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                ctx.tapAliveAtomic.store(CGEvent.tapIsEnabled(tap: tapPort), ordering: .release)
            }
        }
    }

    public func areHIDModifiersClear() -> Bool {
        currentHIDModifierMask().isEmpty
    }

    public func currentHIDModifierMask() -> HotkeyModifierMask {
        Self.liveHIDModifierMask()
    }

    /// Real-time HID modifier probe using `CGEventSource.flagsState(.hidSystemState)`.
    /// Checks `[.maskCommand, .maskShift, .maskAlternate, .maskControl]` ONLY — explicitly excludes CapsLock.
    public static func liveHIDModifierMask() -> HotkeyModifierMask {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return HotkeyDebtMachine.extractModifierMask(from: flags.rawValue)
    }

    public static func areLiveHIDModifiersClear() -> Bool {
        liveHIDModifierMask().isEmpty
    }

    // MARK: - Private Helpers

    private func performOnTapThread(_ block: @escaping @Sendable (TapThreadContext) -> Void) {
        stateLock.lock()
        let ctx = context
        stateLock.unlock()

        guard let ctx, let rl = ctx.getRunLoop() else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
            block(ctx)
        }
        CFRunLoopWakeUp(rl)
    }

    private func installSystemObservers(for ctx: TapThreadContext) {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let activateObs = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            self?.performOnTapThread { tapCtx in
                tapCtx.frontmostBundleID = bundleID
            }
        }

        let sleepObs = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.dispatchSyntheticSystemReset(.systemSleepOrLock)
        }

        let screenSleepObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.dispatchSyntheticSystemReset(.systemSleepOrLock)
        }

        let wakeObs = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconcileSuppressionIfHIDClear()
        }

        let screenWakeObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconcileSuppressionIfHIDClear()
        }

        let lockObs = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.dispatchSyntheticSystemReset(.systemSleepOrLock)
        }

        let unlockObs = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconcileSuppressionIfHIDClear()
        }

        stateLock.lock()
        // Only retain observers if this context is still the active one.
        if self.context === ctx {
            workspaceObservers = [activateObs, sleepObs, screenSleepObs, wakeObs, screenWakeObs]
            distributedObservers = [lockObs, unlockObs]
        } else {
            wsCenter.removeObserver(activateObs)
            wsCenter.removeObserver(sleepObs)
            wsCenter.removeObserver(screenSleepObs)
            wsCenter.removeObserver(wakeObs)
            wsCenter.removeObserver(screenWakeObs)
            DistributedNotificationCenter.default().removeObserver(lockObs)
            DistributedNotificationCenter.default().removeObserver(unlockObs)
        }
        stateLock.unlock()
    }

    private func removeSystemObservers() {
        stateLock.lock()
        let wsObs = workspaceObservers
        let distObs = distributedObservers
        workspaceObservers = []
        distributedObservers = []
        stateLock.unlock()

        let wsCenter = NSWorkspace.shared.notificationCenter
        for obs in wsObs {
            wsCenter.removeObserver(obs)
        }
        let distCenter = DistributedNotificationCenter.default()
        for obs in distObs {
            distCenter.removeObserver(obs)
        }
    }

    private func dispatchSyntheticSystemReset(_ kind: RawKeyEventKind) {
        performOnTapThread { ctx in
            let decision = ctx.machine.process(RawKeyEvent(kind: kind))
            for evt in decision.emittedEvents {
                ctx.deliveryQueue.async {
                    ctx.onEvent(evt)
                }
            }
        }
    }

    private func reconcileSuppressionIfHIDClear() {
        performOnTapThread { ctx in
            let liveFlags = CGEventSource.flagsState(.hidSystemState).rawValue
            ctx.machine.clearSuppressionIfKeysReleased(currentRawFlags: liveFlags)
        }
    }

    private static func startSecureInputPollTimerOnTapThread(for ctx: TapThreadContext) {
        guard ctx.secureInputPollTimer == nil, let rl = ctx.getRunLoop() else { return }
        var timerContext = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(ctx).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.5,
            0.5,
            0,
            0,
            { timer, info in
                guard let info else { return }
                let tapCtx = Unmanaged<TapThreadContext>.fromOpaque(info).takeUnretainedValue()
                if !IsSecureEventInputEnabled() {
                    tapCtx.secureInputWasActive = false
                    let liveFlags = CGEventSource.flagsState(.hidSystemState).rawValue
                    tapCtx.machine.clearSuppressionIfKeysReleased(currentRawFlags: liveFlags)
                    if let timer {
                        CFRunLoopTimerInvalidate(timer)
                    }
                    tapCtx.secureInputPollTimer = nil
                }
            },
            &timerContext
        )
        if let timer {
            ctx.secureInputPollTimer = timer
            CFRunLoopAddTimer(rl, timer, .commonModes)
        }
    }

    private static func stopSecureInputPollTimerOnTapThread(for ctx: TapThreadContext) {
        if let timer = ctx.secureInputPollTimer {
            CFRunLoopTimerInvalidate(timer)
            ctx.secureInputPollTimer = nil
        }
    }

    /// Idempotent tap-thread cleanup ensuring `CFRunLoopTimer`, `CFRunLoopSource`, and `CFMachPort`
    /// are cleanly disabled, removed, invalidated, and released with zero CF retain leaks (P1-14).
    private static func teardownTapResourcesOnTapThread(for ctx: TapThreadContext, runLoop: CFRunLoop) {
        ctx.tapAliveAtomic.store(false, ordering: .release)
        stopSecureInputPollTimerOnTapThread(for: ctx)

        if let source = ctx.runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            ctx.runLoopSource = nil
        }

        if let port = ctx.getTapPort() {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            ctx.setTapPort(nil)
        }
    }

    // MARK: - Dedicated EventTap pthread & CGEventTap callback

    private static let tapThreadEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { rawPtr in
        pthread_setname_np("io.github.litedictate.eventtap")
        let ctx = Unmanaged<TapThreadContext>.fromOpaque(rawPtr).takeRetainedValue()
        let rl = CFRunLoopGetCurrent()
        ctx.setRunLoop(rl)

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let unretainedPtr = Unmanaged.passUnretained(ctx).toOpaque()
        guard let tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: HotkeyController.eventTapCallback,
            userInfo: unretainedPtr
        ) else {
            ctx.startupSucceeded = false
            ctx.tapAliveAtomic.store(false, ordering: .release)
            ctx.setRunLoop(nil)
            ctx.startupSemaphore.signal()
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0) else {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            ctx.startupSucceeded = false
            ctx.tapAliveAtomic.store(false, ordering: .release)
            ctx.setRunLoop(nil)
            ctx.startupSemaphore.signal()
            return nil
        }

        ctx.setTapPort(tapPort)
        ctx.runLoopSource = source
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tapPort, enable: true)

        let enabled = CGEvent.tapIsEnabled(tap: tapPort)
        ctx.startupSucceeded = enabled
        ctx.tapAliveAtomic.store(enabled, ordering: .release)
        ctx.startupSemaphore.signal()

        if enabled {
            CFRunLoopRun()
        }

        if let rl {
            HotkeyController.teardownTapResourcesOnTapThread(for: ctx, runLoop: rl)
        }
        ctx.setRunLoop(nil)
        return nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // LINE 1: Immediately pass through our own synthetic Cmd+V ("LDIC" = 0x4C444943).
        if event.getIntegerValueField(.eventSourceUserData) == LiteDictateConstants.syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let ctx = Unmanaged<TapThreadContext>.fromOpaque(userInfo).takeUnretainedValue()

        // LINE 2 (P1-13): Immediately pass all keystrokes through untouched while temporarily suspended
        // (e.g., while Settings is recording a new global shortcut).
        if ctx.temporarilySuspendedAtomic.load(ordering: .acquire) {
            return Unmanaged.passUnretained(event)
        }

        // Handle tap disabled notifications by resetting state and re-enabling if not in Secure Input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let kind: RawKeyEventKind = (type == .tapDisabledByTimeout)
                ? .tapDisabledByTimeout
                : .tapDisabledByUserInput
            let decision = ctx.machine.process(RawKeyEvent(kind: kind))
            for emitted in decision.emittedEvents {
                ctx.deliveryQueue.async {
                    ctx.onEvent(emitted)
                }
            }

            let secureInput = IsSecureEventInputEnabled()
            if !secureInput, let tapPort = ctx.getTapPort() {
                CGEvent.tapEnable(tap: tapPort, enable: true)
                ctx.tapAliveAtomic.store(CGEvent.tapIsEnabled(tap: tapPort), ordering: .release)
                let liveFlags = CGEventSource.flagsState(.hidSystemState).rawValue
                ctx.machine.clearSuppressionIfKeysReleased(currentRawFlags: liveFlags)
            } else {
                ctx.tapAliveAtomic.store(false, ordering: .release)
            }
            return Unmanaged.passUnretained(event)
        }

        // Secure Input active (e.g., password fields): never intercept keystrokes.
        if IsSecureEventInputEnabled() {
            if !ctx.secureInputWasActive {
                ctx.secureInputWasActive = true
                let decision = ctx.machine.process(RawKeyEvent(kind: .secureInputActivated))
                for emitted in decision.emittedEvents {
                    ctx.deliveryQueue.async {
                        ctx.onEvent(emitted)
                    }
                }
                HotkeyController.startSecureInputPollTimerOnTapThread(for: ctx)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKind: RawKeyEventKind
        switch type {
        case .keyDown:
            eventKind = .keyDown
        case .keyUp:
            eventKind = .keyUp
        case .flagsChanged:
            eventKind = .flagsChanged
        default:
            return Unmanaged.passUnretained(event)
        }

        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if ctx.secureInputWasActive {
            ctx.secureInputWasActive = false
            HotkeyController.stopSecureInputPollTimerOnTapThread(for: ctx)
            ctx.machine.reconcileSuppressionAfterSecureInputEnded(
                incomingKind: eventKind,
                incomingIsAutorepeat: isAutorepeat,
                currentRawFlags: event.flags.rawValue
            )
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let rawEvent = RawKeyEvent(
            kind: eventKind,
            keyCode: keyCode,
            isAutorepeat: isAutorepeat,
            rawFlags: event.flags.rawValue,
            eventSourceUserData: event.getIntegerValueField(.eventSourceUserData),
            frontmostBundleID: ctx.frontmostBundleID
        )

        let decision = ctx.machine.process(rawEvent)
        if !decision.emittedEvents.isEmpty {
            let events = decision.emittedEvents
            ctx.deliveryQueue.async {
                for emitted in events {
                    ctx.onEvent(emitted)
                }
            }
        }

        switch decision.action {
        case .swallow:
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        }
    }
}
