import CoreGraphics
import Foundation
import XCTest
@testable import LiteDictateCore

private final class LockedEventsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FocusEvent] = []

    func append(_ event: FocusEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func snapshot() -> [FocusEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MockFocusBackend: FocusMonitorBackend, @unchecked Sendable {
    private let lock = NSLock()
    var currentApp: FrontmostAppSnapshot?
    var attachResult = AXObserverRegistrationResult(success: true, isSecureTextField: false)
    var secureFieldQueryResult = false

    private(set) var frontmostQueryCount = 0
    private(set) var attachCallCount = 0
    private(set) var detachCallCount = 0
    private(set) var lastAttachWasOnMainThread = false
    private(set) var lastDetachWasOnMainThread = false
    private(set) var lastTimeoutSeconds: Float = 0
    private(set) var lastAttachPID: pid_t = 0
    private var invalidationCallback: (@Sendable (String) -> Void)?

    func frontmostApplication() -> FrontmostAppSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        frontmostQueryCount += 1
        return currentApp
    }

    func attachAXObserverOnMainThread(
        pid: pid_t,
        timeoutSeconds: Float,
        onInvalidated: @escaping @Sendable (String) -> Void
    ) -> AXObserverRegistrationResult {
        lock.lock()
        attachCallCount += 1
        lastAttachWasOnMainThread = Thread.isMainThread
        lastTimeoutSeconds = timeoutSeconds
        lastAttachPID = pid
        invalidationCallback = onInvalidated
        let res = attachResult
        lock.unlock()
        return res
    }

    func detachAXObserverOnMainThread() {
        lock.lock()
        detachCallCount += 1
        lastDetachWasOnMainThread = Thread.isMainThread
        invalidationCallback = nil
        lock.unlock()
    }

    func isCurrentFocusedElementSecureTextField(timeoutSeconds: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastTimeoutSeconds = timeoutSeconds
        return secureFieldQueryResult
    }

    func simulateAXNotification(_ reason: String) {
        lock.lock()
        let cb = invalidationCallback
        lock.unlock()
        cb?(reason)
    }
}

final class PermissionAndFocusProbeTests: XCTestCase {
    // MARK: - Probe 3: Live HID Modifier & Synthetic Event Self-Loop Verification

    func testLiveHIDModifierProbeExcludesCapsLock() {
        // Pure mask check: CapsLock alone is clear; Command/Shift/Option/Control are reported
        XCTAssertTrue(HotkeyDebtMachine.extractModifierMask(from: 0).isEmpty)
        XCTAssertTrue(HotkeyDebtMachine.extractModifierMask(from: CGEventFlags.maskAlphaShift.rawValue).isEmpty)
        XCTAssertEqual(
            HotkeyDebtMachine.extractModifierMask(
                from: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlphaShift.rawValue
            ),
            [.command]
        )

        // Live macOS HID system state query must execute cleanly without crashing
        let controller = HotkeyController()
        let liveMask = controller.currentHIDModifierMask()
        XCTAssertEqual(controller.areHIDModifiersClear(), liveMask.isEmpty)
        XCTAssertEqual(HotkeyController.liveHIDModifierMask(), liveMask)
    }

    func testSyntheticPrivateStateCmdVEventCarriesLDICUserDataAndBypassesMachine() {
        let source = CGEventSource(stateID: .privateState)
        XCTAssertNotNil(source, "CGEventSource(.privateState) must succeed on macOS")

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(HotkeyVirtualKeyCode.ansiV),
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(HotkeyVirtualKeyCode.ansiV),
            keyDown: false
        )
        XCTAssertNotNil(keyDown)
        XCTAssertNotNil(keyUp)

        keyDown?.flags = .maskCommand
        keyDown?.setIntegerValueField(.eventSourceUserData, value: LiteDictateConstants.syntheticEventUserData)
        keyUp?.flags = .maskCommand
        keyUp?.setIntegerValueField(.eventSourceUserData, value: LiteDictateConstants.syntheticEventUserData)

        XCTAssertEqual(keyDown?.getIntegerValueField(.eventSourceUserData), 0x4C444943)
        XCTAssertEqual(keyUp?.getIntegerValueField(.eventSourceUserData), 0x4C444943)
        XCTAssertEqual(keyDown?.flags, .maskCommand)
        XCTAssertEqual(keyUp?.flags, .maskCommand)

        // Verify the state machine passes through the exact generated event fields untouched
        let machine = HotkeyDebtMachine(
            binding: HotkeyBinding(keyCode: HotkeyVirtualKeyCode.ansiV, modifiers: [.command], triggerMode: .toggle),
            shouldInterceptCancelEscape: AtomicBool(true),
            triggerKeyDebtActive: AtomicBool(false)
        )
        let decision = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: UInt16(keyDown!.getIntegerValueField(.keyboardEventKeycode)),
            rawFlags: keyDown!.flags.rawValue,
            eventSourceUserData: keyDown!.getIntegerValueField(.eventSourceUserData)
        ))
        XCTAssertEqual(decision.action, .passThrough)
        XCTAssertTrue(decision.emittedEvents.isEmpty)
    }

    // MARK: - PermissionManager Tests

    func testPermissionManagerLiveProbeAndSettingsURLs() {
        let manager = PermissionManager()
        let snap = manager.snapshot(eventTapAlive: false)

        // Verify live pasteboard access state is a valid macOS 15.4+ or macOS 14.x fallback enum case
        let validStates: Set<PasteboardAccessState> = [.standard, .alwaysAllow, .alwaysDeny, .ask, .default]
        XCTAssertTrue(validStates.contains(snap.pasteboardAccess))
        XCTAssertFalse(snap.eventTapAlive)
        XCTAssertEqual(manager.isSecureEventInputEnabled(), snap.secureInputEnabled)

        // Verify exact System Settings pane deep links
        XCTAssertEqual(
            manager.settingsURL(for: .microphone).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        XCTAssertEqual(
            manager.settingsURL(for: .inputMonitoring).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            manager.settingsURL(for: .accessibility).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            manager.settingsURL(for: .privacy).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        )
    }

    func testPermissionManagerIndependentCapabilitiesNeverInferEachOther() {
        let probes = PermissionProbes(
            microphoneStatus: { .granted },
            listenEventAccess: { true },
            postEventAccess: { false }, // Independently false despite AX & Listen being true
            accessibilityTrusted: { true },
            pasteboardAccess: { .alwaysDeny },
            secureInputEnabled: { false },
            requestMicrophone: { $0(true) },
            requestAccessibility: {},
            requestListenEvent: { true },
            requestPostEvent: { false }
        )
        let manager = PermissionManager(probes: probes)
        let snap = manager.snapshot(eventTapAlive: true)

        XCTAssertEqual(snap.microphone, .granted)
        XCTAssertTrue(snap.listenEventAccess)
        XCTAssertFalse(snap.postEventAccess)
        XCTAssertTrue(snap.accessibilityTrusted)
        XCTAssertEqual(snap.pasteboardAccess, .alwaysDeny)
        XCTAssertTrue(snap.canCaptureAudio)
        XCTAssertTrue(snap.canMonitorGlobalHotkey)
        XCTAssertFalse(snap.canAutoPaste) // Blocked by both postEventAccess=false and pasteboard=.alwaysDeny
        XCTAssertFalse(snap.allCorePermissionsGranted)

        // Secure Input alone blocks canAutoPaste even when all 4 permissions are granted
        let secureProbes = PermissionProbes(
            microphoneStatus: { .granted },
            listenEventAccess: { true },
            postEventAccess: { true },
            accessibilityTrusted: { true },
            pasteboardAccess: { .standard },
            secureInputEnabled: { true },
            requestMicrophone: { $0(true) },
            requestAccessibility: {},
            requestListenEvent: { true },
            requestPostEvent: { true }
        )
        let secureSnap = PermissionManager(probes: secureProbes).snapshot(eventTapAlive: true)
        XCTAssertTrue(secureSnap.allCorePermissionsGranted)
        XCTAssertFalse(secureSnap.canAutoPaste)
    }

    func testPermissionManagerActiveRequestMethodsInvokeProbesAndReturnValues() {
        let micCount = AtomicUInt64(0)
        let axCount = AtomicUInt64(0)
        let listenCount = AtomicUInt64(0)
        let postCount = AtomicUInt64(0)
        let listenReturn = AtomicBool(true)
        let postReturn = AtomicBool(false)
        let micReturn = AtomicBool(true)

        let probes = PermissionProbes(
            microphoneStatus: { .notDetermined },
            listenEventAccess: { false },
            postEventAccess: { false },
            accessibilityTrusted: { false },
            pasteboardAccess: { .default },
            secureInputEnabled: { false },
            requestMicrophone: { completion in
                micCount.increment(ordering: .acqRel)
                completion(micReturn.load(ordering: .acquire))
            },
            requestAccessibility: {
                axCount.increment(ordering: .acqRel)
            },
            requestListenEvent: {
                listenCount.increment(ordering: .acqRel)
                return listenReturn.load(ordering: .acquire)
            },
            requestPostEvent: {
                postCount.increment(ordering: .acqRel)
                return postReturn.load(ordering: .acquire)
            }
        )
        let manager = PermissionManager(probes: probes)

        // 1. Microphone request invokes only requestMicrophone probe
        let micExp = expectation(description: "requestMicrophoneAccess completion")
        let micGranted = AtomicBool(false)
        manager.requestMicrophoneAccess { granted in
            micGranted.store(granted, ordering: .release)
            micExp.fulfill()
        }
        wait(for: [micExp], timeout: 2.0)
        XCTAssertTrue(micGranted.load(ordering: .acquire))
        XCTAssertEqual(micCount.load(ordering: .acquire), 1)
        XCTAssertEqual(axCount.load(ordering: .acquire), 0)
        XCTAssertEqual(listenCount.load(ordering: .acquire), 0)
        XCTAssertEqual(postCount.load(ordering: .acquire), 0)

        // 2. Accessibility request invokes only requestAccessibility probe
        manager.requestAccessibilityPrompt()
        XCTAssertEqual(axCount.load(ordering: .acquire), 1)
        XCTAssertEqual(listenCount.load(ordering: .acquire), 0)
        XCTAssertEqual(postCount.load(ordering: .acquire), 0)

        // 3. Input Monitoring (ListenEvent) request invokes only requestListenEvent probe and propagates return value
        XCTAssertTrue(manager.requestListenEventAccess())
        listenReturn.store(false, ordering: .release)
        XCTAssertFalse(manager.requestListenEventAccess())
        XCTAssertEqual(listenCount.load(ordering: .acquire), 2)
        XCTAssertEqual(postCount.load(ordering: .acquire), 0)

        // 4. Synthetic PostEvent request invokes only requestPostEvent probe and propagates return value
        XCTAssertFalse(manager.requestPostEventAccess())
        postReturn.store(true, ordering: .release)
        XCTAssertTrue(manager.requestPostEventAccess())
        XCTAssertEqual(postCount.load(ordering: .acquire), 2)

        // 5. Verify main-thread dispatch helper works without deadlock both on main thread and from background thread
        XCTAssertEqual(PermissionManager.runOnMainThreadSync { Thread.isMainThread }, true)
        let bgExp = expectation(description: "background runOnMainThreadSync")
        let ranOnMain = AtomicBool(false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PermissionManager.runOnMainThreadSync { Thread.isMainThread }
            ranOnMain.store(result, ordering: .release)
            bgExp.fulfill()
        }
        wait(for: [bgExp], timeout: 2.0)
        XCTAssertTrue(ranOnMain.load(ordering: .acquire))

        // 6. Verify settingsURL(for:) covers every SystemSettingsPane case
        let panes: [SystemSettingsPane] = [.microphone, .inputMonitoring, .accessibility, .privacy]
        for pane in panes {
            let url = manager.settingsURL(for: pane)
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            XCTAssertTrue(url.absoluteString.contains("com.apple.preference.security?Privacy"))
        }
    }

    // MARK: - FocusMonitor Tests

    func testFocusMonitorZeroIPCCaptureMainThreadAttachmentAndMonotonicInvalidation() {
        let backend = MockFocusBackend()
        let launchA = Date(timeIntervalSince1970: 1_700_000_000)
        let launchB = Date(timeIntervalSince1970: 1_700_000_500)
        backend.currentApp = FrontmostAppSnapshot(pid: 1001, launchDate: launchA, bundleIdentifier: "com.apple.Notes")

        let monitor = FocusMonitor(backend: backend, observeWorkspaceNotifications: false)

        // 1. Zero-IPC press-time capture MUST NOT attach AXObserver
        let initial = monitor.captureInitialFocus()
        XCTAssertEqual(initial.pid, 1001)
        XCTAssertEqual(initial.launchDate, launchA)
        XCTAssertEqual(initial.bundleIdentifier, "com.apple.Notes")
        XCTAssertFalse(initial.axInitialized)
        XCTAssertEqual(backend.attachCallCount, 0)

        let initExp = expectation(description: "AX initialized on main thread")
        let invalidatedExp = expectation(description: "Focus invalidated 4 times")
        invalidatedExp.expectedFulfillmentCount = 4

        let eventsBox = LockedEventsBox()

        // 2. Call beginMonitoring from a BACKGROUND queue — backend attach MUST still happen on main thread!
        DispatchQueue.global(qos: .userInitiated).async {
            monitor.beginMonitoring(requestID: 42, initialContext: initial) { event in
                eventsBox.append(event)

                switch event {
                case .axInitialized:
                    initExp.fulfill()
                case .focusInvalidated:
                    invalidatedExp.fulfill()
                }
            }
        }

        wait(for: [initExp], timeout: 2.0)
        XCTAssertEqual(backend.attachCallCount, 1)
        XCTAssertTrue(backend.lastAttachWasOnMainThread, "AXObserver MUST attach strictly on CFRunLoopGetMain()")
        XCTAssertEqual(backend.lastAttachPID, 1001)
        XCTAssertEqual(backend.lastTimeoutSeconds, 0.15, accuracy: 0.001)

        // 3. Focus changes permanently increment focusGeneration — switching back NEVER revives initial.focusGeneration!
        backend.simulateAXNotification("AXFocusedUIElementChanged")
        let genAfterElementChange = monitor.currentFocusGeneration
        XCTAssertGreaterThan(genAfterElementChange, initial.focusGeneration)

        backend.simulateAXNotification("AXFocusedWindowChanged")
        let genAfterWindowChange = monitor.currentFocusGeneration
        XCTAssertGreaterThan(genAfterWindowChange, genAfterElementChange)

        // Switch away to App B
        backend.currentApp = FrontmostAppSnapshot(pid: 2002, launchDate: launchB, bundleIdentifier: "com.apple.Safari")
        monitor.notifyFocusChanged(reason: "NSWorkspace.didActivateApplicationNotification")
        let genAfterSwitchToB = monitor.currentFocusGeneration
        XCTAssertGreaterThan(genAfterSwitchToB, genAfterWindowChange)

        // Switch BACK to App A -> generation MUST increase again (never equals initial.focusGeneration!)
        backend.currentApp = FrontmostAppSnapshot(pid: 1001, launchDate: launchA, bundleIdentifier: "com.apple.Notes")
        monitor.notifyFocusChanged(reason: "NSWorkspace.didActivateApplicationNotification")
        let genAfterSwitchBackToA = monitor.currentFocusGeneration
        XCTAssertGreaterThan(genAfterSwitchBackToA, genAfterSwitchToB)
        XCTAssertNotEqual(genAfterSwitchBackToA, initial.focusGeneration)

        wait(for: [invalidatedExp], timeout: 2.0)

        // 4. stopMonitoring detaches strictly on main thread
        monitor.stopMonitoring(requestID: 42)
        let detachExp = expectation(description: "Detach runs on main thread")
        DispatchQueue.main.async {
            detachExp.fulfill()
        }
        wait(for: [detachExp], timeout: 2.0)
        XCTAssertEqual(backend.detachCallCount, 1)
        XCTAssertTrue(backend.lastDetachWasOnMainThread)

        let eventsSnapshot = eventsBox.snapshot()
        XCTAssertEqual(
            eventsSnapshot.first,
            .axInitialized(requestID: 42, focusGeneration: initial.focusGeneration, success: true, isSecureTextField: false)
        )
    }

    func testFocusMonitorDetectsPreSetupDriftAndSecureTextField() {
        let backend = MockFocusBackend()
        let launchA = Date(timeIntervalSince1970: 1_700_000_000)
        let launchB = Date(timeIntervalSince1970: 1_700_000_100)
        backend.currentApp = FrontmostAppSnapshot(pid: 1001, launchDate: launchA, bundleIdentifier: "com.apple.Notes")
        backend.secureFieldQueryResult = true

        let monitor = FocusMonitor(backend: backend, observeWorkspaceNotifications: false)
        XCTAssertTrue(monitor.isCurrentFocusedElementSecureTextField())

        let initial = monitor.captureInitialFocus()
        // Frontmost app changes BEFORE main-thread AX setup runs
        backend.currentApp = FrontmostAppSnapshot(pid: 2002, launchDate: launchB, bundleIdentifier: "com.apple.Terminal")

        let exp = expectation(description: "axInitialized reports failure after pre-setup drift")
        let resultBox = AtomicBool(true)
        monitor.beginMonitoring(requestID: 99, initialContext: initial) { event in
            if case let .axInitialized(reqID, _, success, _) = event, reqID == 99 {
                resultBox.store(success, ordering: .release)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertFalse(resultBox.load(ordering: .acquire))
        XCTAssertGreaterThan(monitor.currentFocusGeneration, initial.focusGeneration)
    }

    func testLiveFocusMonitorProbeZeroIPCLatency() {
        let monitor = FocusMonitor()
        let start = CFAbsoluteTimeGetCurrent()
        let initial = monitor.captureInitialFocus()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        // Zero-IPC press-time capture must be well below the 100 ms cold-mic SLO
        XCTAssertLessThan(elapsedMs, 50.0, "captureInitialFocus() should be zero-IPC and < 50 ms")
        XCTAssertEqual(initial.focusGeneration, monitor.currentFocusGeneration)

        // Probe main-thread begin/stop monitoring lifecycle cleanly (succeeds if AX granted, fails gracefully if not)
        let exp = expectation(description: "Live AX initialization completes")
        monitor.beginMonitoring(requestID: 1, initialContext: initial) { event in
            if case let .axInitialized(reqID, _, _, _) = event, reqID == 1 {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
        monitor.stopMonitoring(requestID: 1)
    }

    func testLiveFocusMonitorBackendWindowComparisonIgnoresSpuriousSameWindowNotifications() {
        let winA = "window-A" as CFString
        let winASame = "window-A" as CFString
        let winB = "window-B" as CFString

        // Exact same window (spurious WeType / Safari / Electron notification) -> must NOT invalidate!
        XCTAssertFalse(LiveFocusMonitorBackend.didFocusedWindowChange(initial: winA, current: winASame))
        XCTAssertFalse(LiveFocusMonitorBackend.didFocusedWindowChange(initial: nil, current: nil))

        // Different window or window closed/appeared -> MUST invalidate!
        XCTAssertTrue(LiveFocusMonitorBackend.didFocusedWindowChange(initial: winA, current: winB))
        XCTAssertTrue(LiveFocusMonitorBackend.didFocusedWindowChange(initial: winA, current: nil))
        XCTAssertTrue(LiveFocusMonitorBackend.didFocusedWindowChange(initial: nil, current: winB))
    }
}
