import CoreGraphics
import XCTest
@testable import LiteDictateCore

final class HotkeyDebtMachineTests: XCTestCase {
    private let cmdShiftFlags: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
    private let leftCmdLeftShiftFlags: UInt64 =
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskShift.rawValue |
        DeviceModifierFlags.leftCommand |
        DeviceModifierFlags.leftShift
    private let rightCmdLeftShiftFlags: UInt64 =
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskShift.rawValue |
        DeviceModifierFlags.rightCommand |
        DeviceModifierFlags.leftShift

    private func makeMachine(
        binding: HotkeyBinding = .cmdShiftD,
        disabledBundleIDs: Set<String> = []
    ) -> (HotkeyDebtMachine, AtomicBool, AtomicBool) {
        let shouldCancelEsc = AtomicBool(false)
        let triggerDebt = AtomicBool(false)
        let machine = HotkeyDebtMachine(
            binding: binding,
            disabledBundleIDs: disabledBundleIDs,
            shouldInterceptCancelEscape: shouldCancelEsc,
            triggerKeyDebtActive: triggerDebt
        )
        return (machine, shouldCancelEsc, triggerDebt)
    }

    func testToggleDefaultCmdShiftDAndMonotonicGeneration() {
        let (machine, _, triggerDebt) = makeMachine()

        let d1 = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(d1.action, .swallow)
        XCTAssertEqual(d1.emittedEvents, [.triggerToggle(gestureGeneration: 1)])
        XCTAssertTrue(machine.swallowedTriggerKeyDown)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        let d1Up = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(d1Up.action, .swallow)
        XCTAssertTrue(d1Up.emittedEvents.isEmpty)
        XCTAssertFalse(machine.swallowedTriggerKeyDown)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        let d2 = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(d2.action, .swallow)
        XCTAssertEqual(d2.emittedEvents, [.triggerToggle(gestureGeneration: 2)])
    }

    func testToggleModifiersReleasedBeforeDZeroLeakedLetters() {
        let (machine, _, triggerDebt) = makeMachine()

        // Press Cmd+Shift+D
        let down = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(down.action, .swallow)
        XCTAssertEqual(down.emittedEvents, [.triggerToggle(gestureGeneration: 1)])
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        // User releases Cmd and Shift BEFORE releasing D
        let flagsUp = machine.process(RawKeyEvent(kind: .flagsChanged, rawFlags: 0))
        XCTAssertEqual(flagsUp.action, .passThrough)
        XCTAssertTrue(flagsUp.emittedEvents.isEmpty)
        XCTAssertTrue(machine.swallowedTriggerKeyDown)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        // Autorepeats of D with ZERO modifiers MUST still be swallowed (0 leaked 'd')
        for _ in 0..<5 {
            let rep = machine.process(RawKeyEvent(
                kind: .keyDown,
                keyCode: HotkeyVirtualKeyCode.ansiD,
                isAutorepeat: true,
                rawFlags: 0
            ))
            XCTAssertEqual(rep.action, .swallow)
            XCTAssertTrue(rep.emittedEvents.isEmpty)
            XCTAssertTrue(triggerDebt.load(ordering: .acquire))
        }

        // KeyUp of D with ZERO modifiers MUST be swallowed and clear debt
        let up = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))
        XCTAssertEqual(up.action, .swallow)
        XCTAssertTrue(up.emittedEvents.isEmpty)
        XCTAssertFalse(machine.swallowedTriggerKeyDown)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        // Subsequent plain 'd' typing passes through normally
        let normalD = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))
        XCTAssertEqual(normalD.action, .passThrough)
        XCTAssertTrue(normalD.emittedEvents.isEmpty)
    }

    func testPushToTalkKeyUpStopsAndModifierReleaseFirstStillSwallowsD() {
        let pttBinding = HotkeyBinding(
            keyCode: HotkeyVirtualKeyCode.ansiD,
            modifiers: [.command, .shift],
            triggerMode: .pushToTalk
        )
        let (machine, _, triggerDebt) = makeMachine(binding: pttBinding)

        // Gesture 1: Release D first
        let start1 = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(start1.action, .swallow)
        XCTAssertEqual(start1.emittedEvents, [.triggerStart(gestureGeneration: 1)])
        XCTAssertTrue(machine.pttActive)

        let repeat1 = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            isAutorepeat: true,
            rawFlags: cmdShiftFlags
        ))
        XCTAssertEqual(repeat1.action, .swallow)
        XCTAssertTrue(repeat1.emittedEvents.isEmpty)

        let stop1 = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(stop1.action, .swallow)
        XCTAssertEqual(stop1.emittedEvents, [.triggerStop(gestureGeneration: 1)])
        XCTAssertFalse(machine.pttActive)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        // Gesture 2: Release Shift BEFORE D -> stops PTT, keeps D debt until keyUp(D), no duplicate stop
        let start2 = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(start2.action, .swallow)
        XCTAssertEqual(start2.emittedEvents, [.triggerStart(gestureGeneration: 2)])

        let shiftReleased = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            rawFlags: CGEventFlags.maskCommand.rawValue
        ))
        XCTAssertEqual(shiftReleased.action, .passThrough)
        XCTAssertEqual(shiftReleased.emittedEvents, [.triggerStop(gestureGeneration: 2)])
        XCTAssertFalse(machine.pttActive)
        XCTAssertTrue(machine.swallowedTriggerKeyDown)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        let leakedRepeat = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            isAutorepeat: true,
            rawFlags: 0
        ))
        XCTAssertEqual(leakedRepeat.action, .swallow)
        XCTAssertTrue(leakedRepeat.emittedEvents.isEmpty)

        let lateUp = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))
        XCTAssertEqual(lateUp.action, .swallow)
        XCTAssertTrue(lateUp.emittedEvents.isEmpty) // Idempotent: no duplicate triggerStop
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))
    }

    func testEscapeInterceptedOnlyWhenAtomicFlagTrueAndPairedDebtCleared() {
        let (machine, shouldCancelEsc, _) = makeMachine()

        // Idle / RecoveryPanel: shouldInterceptCancelEscape == false -> Esc MUST pass through
        shouldCancelEsc.store(false, ordering: .release)
        let idleEscDown = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.escape))
        XCTAssertEqual(idleEscDown.action, .passThrough)
        XCTAssertTrue(idleEscDown.emittedEvents.isEmpty)
        let idleEscUp = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.escape))
        XCTAssertEqual(idleEscUp.action, .passThrough)

        // Recording/Transcribing: shouldInterceptCancelEscape == true -> Esc swallowed & emits cancelEscape
        shouldCancelEsc.store(true, ordering: .release)
        let activeEscDown = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.escape,
            rawFlags: CGEventFlags.maskAlphaShift.rawValue // CapsLock on must NOT block Esc cancel
        ))
        XCTAssertEqual(activeEscDown.action, .swallow)
        XCTAssertEqual(activeEscDown.emittedEvents, [.cancelEscape])
        XCTAssertTrue(machine.swallowedEscapeKeyDown)

        // Coordinator immediately resets flag to false upon receiving cancelEscape,
        // yet autorepeat + keyUp of Esc MUST still be swallowed via paired debt!
        shouldCancelEsc.store(false, ordering: .release)
        let escRepeat = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.escape,
            isAutorepeat: true
        ))
        XCTAssertEqual(escRepeat.action, .swallow)
        XCTAssertTrue(escRepeat.emittedEvents.isEmpty)

        let escUp = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.escape))
        XCTAssertEqual(escUp.action, .swallow)
        XCTAssertFalse(machine.swallowedEscapeKeyDown)

        // Next Esc in Idle passes through cleanly
        let nextEsc = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.escape))
        XCTAssertEqual(nextEsc.action, .passThrough)

        // Modified Esc (e.g. Cmd+Opt+Esc Force Quit) is never intercepted even when flag is true
        shouldCancelEsc.store(true, ordering: .release)
        let forceQuitEsc = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.escape,
            rawFlags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        ))
        XCTAssertEqual(forceQuitEsc.action, .passThrough)
        XCTAssertTrue(forceQuitEsc.emittedEvents.isEmpty)
    }

    func testCapsLockIgnoredAndExtraModifiersRejected() {
        let (machine, _, _) = makeMachine()

        // CapsLock (.maskAlphaShift) MUST be ignored by modifier extraction & matching
        XCTAssertEqual(
            HotkeyDebtMachine.extractModifierMask(from: CGEventFlags.maskAlphaShift.rawValue),
            []
        )
        let withCapsLock = cmdShiftFlags | CGEventFlags.maskAlphaShift.rawValue
        let capsDecision = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: withCapsLock
        ))
        XCTAssertEqual(capsDecision.action, .swallow)
        XCTAssertEqual(capsDecision.emittedEvents, [.triggerToggle(gestureGeneration: 1)])
        _ = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: withCapsLock))

        // Extra Option rejected
        let extraOpt = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags | CGEventFlags.maskAlternate.rawValue
        ))
        XCTAssertEqual(extraOpt.action, .passThrough)
        XCTAssertTrue(extraOpt.emittedEvents.isEmpty)

        // Extra Control rejected
        let extraCtrl = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags | CGEventFlags.maskControl.rawValue
        ))
        XCTAssertEqual(extraCtrl.action, .passThrough)
        XCTAssertTrue(extraCtrl.emittedEvents.isEmpty)
    }

    func testStrictLeftSideOnlyModifierMatching() {
        let strictBinding = HotkeyBinding(
            keyCode: HotkeyVirtualKeyCode.ansiD,
            modifiers: [.command, .shift],
            triggerMode: .toggle,
            strictLeftSideOnly: true
        )
        let (machine, _, _) = makeMachine(binding: strictBinding)

        // Right Command + Left Shift rejected
        let rightCmd = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: rightCmdLeftShiftFlags
        ))
        XCTAssertEqual(rightCmd.action, .passThrough)
        XCTAssertTrue(rightCmd.emittedEvents.isEmpty)

        // Left Command + Left Shift accepted
        let leftBoth = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: leftCmdLeftShiftFlags
        ))
        XCTAssertEqual(leftBoth.action, .swallow)
        XCTAssertEqual(leftBoth.emittedEvents, [.triggerToggle(gestureGeneration: 1)])
    }

    func testSyntheticLDICEventAlwaysBypasses() {
        let (machine, shouldCancelEsc, triggerDebt) = makeMachine()
        shouldCancelEsc.store(true, ordering: .release)

        // Synthetic Cmd+V with 0x4C444943 ("LDIC")
        let synthV = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiV,
            rawFlags: CGEventFlags.maskCommand.rawValue,
            eventSourceUserData: LiteDictateConstants.syntheticEventUserData
        ))
        XCTAssertEqual(synthV.action, .passThrough)
        XCTAssertTrue(synthV.emittedEvents.isEmpty)

        // Even a synthetic event matching the trigger chord or Esc passes straight through untouched
        let synthTrigger = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags,
            eventSourceUserData: LiteDictateConstants.syntheticEventUserData
        ))
        XCTAssertEqual(synthTrigger.action, .passThrough)
        XCTAssertTrue(synthTrigger.emittedEvents.isEmpty)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        let synthEsc = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.escape,
            eventSourceUserData: LiteDictateConstants.syntheticEventUserData
        ))
        XCTAssertEqual(synthEsc.action, .passThrough)
        XCTAssertTrue(synthEsc.emittedEvents.isEmpty)
    }

    func testDisabledBundleIDsPassThroughWithoutBreakingExistingDebt() {
        let (machine, _, triggerDebt) = makeMachine(disabledBundleIDs: ["com.example.disabled"])

        // New trigger in disabled bundle passes through
        let blocked = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags,
            frontmostBundleID: "com.example.disabled"
        ))
        XCTAssertEqual(blocked.action, .passThrough)
        XCTAssertTrue(blocked.emittedEvents.isEmpty)

        // Trigger started in enabled app, then focus shifts to disabled app before keyUp:
        // paired debt MUST still swallow keyUp and clear `triggerKeyDebtActive`!
        let started = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags,
            frontmostBundleID: "com.apple.Notes"
        ))
        XCTAssertEqual(started.action, .swallow)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        let keyUpInDisabled = machine.process(RawKeyEvent(
            kind: .keyUp,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: 0,
            frontmostBundleID: "com.example.disabled"
        ))
        XCTAssertEqual(keyUpInDisabled.action, .swallow)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))
    }

    func testSuppressUntilReleaseRecoveryAcrossSystemResets() {
        let (machine, _, triggerDebt) = makeMachine()

        // Press Cmd+Shift+D, then hit tapDisabledByTimeout while keys are still held
        _ = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        let reset = machine.process(RawKeyEvent(kind: .tapDisabledByTimeout))
        XCTAssertEqual(reset.emittedEvents, [.systemReset(reason: "tapDisabledByTimeout")])
        XCTAssertTrue(machine.suppressUntilRelease)
        XCTAssertFalse(machine.swallowedTriggerKeyDown)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        // While suppressed, D repeat is swallowed and does NOT re-trigger
        let suppressedRepeat = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            isAutorepeat: true,
            rawFlags: cmdShiftFlags
        ))
        XCTAssertEqual(suppressedRepeat.action, .swallow)
        XCTAssertTrue(suppressedRepeat.emittedEvents.isEmpty)
        XCTAssertTrue(machine.suppressUntilRelease)

        // Release modifiers first -> still waiting for D keyUp
        _ = machine.process(RawKeyEvent(kind: .flagsChanged, rawFlags: 0))
        XCTAssertTrue(machine.suppressUntilRelease)

        // Release D -> all relevant keys released, suppression lifts
        let dUp = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))
        XCTAssertEqual(dUp.action, .swallow)
        XCTAssertFalse(machine.suppressUntilRelease)

        // Fresh Cmd+Shift+D now triggers normally!
        let fresh = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(fresh.action, .swallow)
        XCTAssertEqual(fresh.emittedEvents, [.triggerToggle(gestureGeneration: 2)])
        _ = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))

        // Also test sleep/lock & Secure Input resets with reverse release order (keyUp then flagsChanged)
        for kind in [RawKeyEventKind.systemSleepOrLock, .secureInputActivated, .tapDisabledByUserInput] {
            let r = machine.process(RawKeyEvent(kind: kind))
            XCTAssertEqual(r.emittedEvents.count, 1)
            XCTAssertTrue(machine.suppressUntilRelease)

            // Suppressed fresh press while modifiers held must not fire
            let blocked = machine.process(RawKeyEvent(
                kind: .keyDown,
                keyCode: HotkeyVirtualKeyCode.ansiD,
                rawFlags: cmdShiftFlags
            ))
            XCTAssertTrue(blocked.emittedEvents.isEmpty)

            _ = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
            XCTAssertTrue(machine.suppressUntilRelease) // Modifiers still held!
            _ = machine.process(RawKeyEvent(kind: .flagsChanged, rawFlags: 0))
            XCTAssertFalse(machine.suppressUntilRelease)
        }
    }

    func testDynamicBindingChangePreservesInFlightKeyDebt() {
        let (machine, _, triggerDebt) = makeMachine()

        // Press Cmd+Shift+D
        let d1 = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(d1.action, .swallow)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        // Change binding to Opt+Space while D is still held
        machine.updateBinding(HotkeyBinding(keyCode: 0x31, modifiers: [.option], triggerMode: .toggle))

        // Releasing old key D MUST still be swallowed and clear debt
        let dUp = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))
        XCTAssertEqual(dUp.action, .swallow)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))

        // New binding Opt+Space triggers properly
        let optSpace = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: 0x31,
            rawFlags: CGEventFlags.maskAlternate.rawValue
        ))
        XCTAssertEqual(optSpace.action, .swallow)
        XCTAssertEqual(optSpace.emittedEvents, [.triggerToggle(gestureGeneration: 2)])
    }

    func testSuppressionReconcilesAfterSecureInputAndUnlockWithoutBreakingHeldKeyGuard() {
        let (machine, _, _) = makeMachine()

        // Case 1: Idle Secure Input activation -> ends -> user immediately presses Cmd, then Shift, then D
        let secReset = machine.process(RawKeyEvent(kind: .secureInputActivated))
        XCTAssertEqual(secReset.emittedEvents, [.systemReset(reason: "secureInputActivated")])
        XCTAssertTrue(machine.suppressUntilRelease)
        XCTAssertFalse(machine.waitingForTriggerReleaseAfterReset)

        // Secure Input ends right as user presses Cmd (first key of a fresh Cmd+Shift+D)
        machine.reconcileSuppressionAfterSecureInputEnded(
            incomingKind: .flagsChanged,
            incomingIsAutorepeat: false,
            currentRawFlags: CGEventFlags.maskCommand.rawValue
        )
        XCTAssertFalse(machine.suppressUntilRelease)

        let firstAfterSecure = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags
        ))
        XCTAssertEqual(firstAfterSecure.action, .swallow)
        XCTAssertEqual(firstAfterSecure.emittedEvents, [.triggerToggle(gestureGeneration: 1)])
        _ = machine.process(RawKeyEvent(kind: .keyUp, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: 0))

        // Case 2: Screen lock while idle -> unlock with live HID clear -> first Cmd+Shift+D works immediately
        _ = machine.process(RawKeyEvent(kind: .systemSleepOrLock))
        XCTAssertTrue(machine.suppressUntilRelease)
        machine.clearSuppressionIfKeysReleased(currentRawFlags: 0)
        XCTAssertFalse(machine.suppressUntilRelease)

        // Case 3: Reset while D was actively held -> clearSuppressionIfKeysReleased MUST NOT lift suppression prematurely
        _ = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        _ = machine.process(RawKeyEvent(kind: .secureInputActivated))
        XCTAssertTrue(machine.suppressUntilRelease)
        XCTAssertTrue(machine.waitingForTriggerReleaseAfterReset)

        machine.clearSuppressionIfKeysReleased(currentRawFlags: 0)
        XCTAssertTrue(machine.suppressUntilRelease, "Must stay suppressed while waiting for held trigger key release")

        machine.reconcileSuppressionAfterSecureInputEnded(
            incomingKind: .flagsChanged,
            incomingIsAutorepeat: false,
            currentRawFlags: CGEventFlags.maskCommand.rawValue
        )
        XCTAssertTrue(machine.suppressUntilRelease)
    }

    func testTemporarySuspendPassesAllKeystrokesThroughAndResetsDebtOnResume() {
        let shouldCancelEsc = AtomicBool(true)
        let triggerDebt = AtomicBool(false)
        let suspended = AtomicBool(false)
        let machine = HotkeyDebtMachine(
            binding: .cmdShiftD,
            shouldInterceptCancelEscape: shouldCancelEsc,
            triggerKeyDebtActive: triggerDebt,
            temporarilySuspended: suspended
        )

        // Start a chord so trigger debt is active, then suspend (e.g. user opens Settings shortcut recorder)
        let start = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(start.action, .swallow)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        suspended.store(true, ordering: .release)
        machine.resetDebtForSuspendOrResume()
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))
        XCTAssertFalse(machine.swallowedTriggerKeyDown)

        // While suspended, Cmd+Shift+D and Esc (even with shouldInterceptCancelEscape == true) pass through untouched!
        let duringSuspendTrigger = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags
        ))
        XCTAssertEqual(duringSuspendTrigger.action, .passThrough)
        XCTAssertTrue(duringSuspendTrigger.emittedEvents.isEmpty)

        let duringSuspendEsc = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.escape))
        XCTAssertEqual(duringSuspendEsc.action, .passThrough)
        XCTAssertTrue(duringSuspendEsc.emittedEvents.isEmpty)

        // Resume and reset debt -> fresh Cmd+Shift+D triggers cleanly again
        suspended.store(false, ordering: .release)
        machine.resetDebtForSuspendOrResume()
        let afterResume = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.ansiD,
            rawFlags: cmdShiftFlags
        ))
        XCTAssertEqual(afterResume.action, .swallow)
        XCTAssertEqual(afterResume.emittedEvents, [.triggerToggle(gestureGeneration: 2)])

        // Verify HotkeyController.setTemporarilySuspended toggles cleanly even when tap is stopped
        let controller = HotkeyController()
        XCTAssertFalse(controller.isTemporarilySuspended)
        controller.setTemporarilySuspended(true)
        XCTAssertTrue(controller.isTemporarilySuspended)
        controller.setTemporarilySuspended(false)
        XCTAssertFalse(controller.isTemporarilySuspended)
    }

    func testReconcileStaleTriggerKeyDebtClearsStuckDebtWhenLiveHIDShowsKeyReleased() {
        let pttBinding = HotkeyBinding(
            keyCode: HotkeyVirtualKeyCode.ansiD,
            modifiers: [.command, .shift],
            triggerMode: .pushToTalk
        )
        let (machine, _, triggerDebt) = makeMachine(binding: pttBinding)

        // Start PTT chord -> debt is active
        let start = machine.process(RawKeyEvent(kind: .keyDown, keyCode: HotkeyVirtualKeyCode.ansiD, rawFlags: cmdShiftFlags))
        XCTAssertEqual(start.action, .swallow)
        XCTAssertTrue(machine.swallowedTriggerKeyDown)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        // While live HID still reports D physically down, reconciliation MUST NOT clear debt
        let stillDown = machine.reconcileStaleTriggerKeyDebt { _ in true }
        XCTAssertTrue(stillDown.isEmpty)
        XCTAssertTrue(machine.swallowedTriggerKeyDown)
        XCTAssertTrue(triggerDebt.load(ordering: .acquire))

        // Simulate dropped D keyUp: live HID reports D is NOT pressed -> debt clears & PTT stops cleanly!
        let cleared = machine.reconcileStaleTriggerKeyDebt { _ in false }
        XCTAssertEqual(cleared, [.triggerStop(gestureGeneration: 1)])
        XCTAssertFalse(machine.swallowedTriggerKeyDown)
        XCTAssertFalse(machine.pttActive)
        XCTAssertFalse(triggerDebt.load(ordering: .acquire))
    }

    func testDefaultBindingIsRightCommandPTT() {
        let def = HotkeyBinding.defaultBinding
        XCTAssertEqual(def.kind, .singleModifier)
        XCTAssertEqual(def.keyCode, HotkeyVirtualKeyCode.rightCommand)
        XCTAssertEqual(def.triggerMode, .pushToTalk)
        XCTAssertEqual(def.displayString, "右 ⌘")
    }

    func testSingleModifierRightCommandPTTChordGuardAndRelease() {
        let (machine, _, _) = makeMachine(binding: .rightCommandPTT)
        let rightCmdDownFlags: UInt64 = CGEventFlags.maskCommand.rawValue | DeviceModifierFlags.rightCommand
        let leftCmdDownFlags: UInt64 = CGEventFlags.maskCommand.rawValue | DeviceModifierFlags.leftCommand

        // 1. Left Command MUST be completely ignored when bound to Right Command
        let leftDown = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.leftCommand,
            rawFlags: leftCmdDownFlags,
            timestampNs: 1_000_000_000
        ))
        XCTAssertEqual(leftDown.action, .passThrough)
        XCTAssertTrue(leftDown.emittedEvents.isEmpty)
        XCTAssertFalse(machine.pendingSingleModifierHold)

        // 2. Right Command + C chord within 130ms MUST cancel pending hold and never misfire
        let rCmdDown1 = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_000_000_000
        ))
        XCTAssertTrue(rCmdDown1.emittedEvents.isEmpty)
        XCTAssertTrue(machine.pendingSingleModifierHold)

        let cKeyDown = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: 0x08, // ANSI C
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_040_000_000
        ))
        XCTAssertEqual(cKeyDown.action, .passThrough)
        XCTAssertTrue(cKeyDown.emittedEvents.isEmpty)
        XCTAssertFalse(machine.pendingSingleModifierHold)
        XCTAssertTrue(machine.firePendingSingleModifierHoldIfValid().emittedEvents.isEmpty)

        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 2_100_000_000
        ))
        XCTAssertFalse(machine.pttActive)

        // 3. Quick brush (<130ms) without firing hold timer MUST NOT start dictation
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 3_000_000_000
        ))
        XCTAssertTrue(machine.pendingSingleModifierHold)
        let quickUp = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 3_060_000_000
        ))
        XCTAssertTrue(quickUp.emittedEvents.isEmpty)
        XCTAssertFalse(machine.pendingSingleModifierHold)
        XCTAssertFalse(machine.pttActive)

        // 4. Proper Right Command PTT hold (>= 130ms) starts on timer and stops on release
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 4_000_000_000
        ))
        XCTAssertTrue(machine.pendingSingleModifierHold)
        let started = machine.firePendingSingleModifierHoldIfValid()
        XCTAssertEqual(started.emittedEvents, [.triggerStart(gestureGeneration: 1)])
        XCTAssertTrue(machine.pttActive)

        let stopped = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 5_000_000_000
        ))
        XCTAssertEqual(stopped.emittedEvents, [.triggerStop(gestureGeneration: 1)])
        XCTAssertFalse(machine.pttActive)
    }

    func testSingleModifierToggleTapVsChordAndLongHold() {
        var toggleRightCmd = HotkeyBinding.rightCommandPTT
        toggleRightCmd.triggerMode = .toggle
        let (machine, _, _) = makeMachine(binding: toggleRightCmd)
        let rightCmdDownFlags: UInt64 = CGEventFlags.maskCommand.rawValue | DeviceModifierFlags.rightCommand

        // 1. Clean quick tap (120ms <= 450ms) emits triggerToggle
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 1_000_000_000
        ))
        let tapUp = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 1_120_000_000
        ))
        XCTAssertEqual(tapUp.emittedEvents, [.triggerToggle(gestureGeneration: 1)])

        // 2. Right Command + C chord does NOT emit toggle
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_000_000_000
        ))
        _ = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: 0x08,
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_050_000_000
        ))
        let chordUp = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 2_120_000_000
        ))
        XCTAssertTrue(chordUp.emittedEvents.isEmpty)

        // 3. Long hold (>450ms) does NOT emit toggle
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 3_000_000_000
        ))
        let longUp = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 3_600_000_000
        ))
        XCTAssertTrue(longUp.emittedEvents.isEmpty)
    }

    func testSingleModifierPTTEscapeCancelWhileHoldingRightCommandAndSecureInputReconcile() {
        let (machine, shouldCancelEsc, _) = makeMachine(binding: .rightCommandPTT)
        let rightCmdDownFlags: UInt64 = CGEventFlags.maskCommand.rawValue | DeviceModifierFlags.rightCommand
        let bothCmdFlags: UInt64 = rightCmdDownFlags | DeviceModifierFlags.leftCommand

        // 1. Holding Left Cmd + Right Cmd simultaneously MUST NOT start Right Cmd PTT
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: bothCmdFlags,
            timestampNs: 1_000_000_000
        ))
        XCTAssertFalse(machine.pendingSingleModifierHold)

        // 2. Start Right Cmd PTT, then press Esc while still holding Right Cmd -> MUST cancel!
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_000_000_000
        ))
        let started = machine.firePendingSingleModifierHoldIfValid()
        XCTAssertEqual(started.emittedEvents, [.triggerStart(gestureGeneration: 1)])
        XCTAssertTrue(machine.pttActive)
        shouldCancelEsc.store(true, ordering: .release)

        let escWhileHoldingRightCmd = machine.process(RawKeyEvent(
            kind: .keyDown,
            keyCode: HotkeyVirtualKeyCode.escape,
            rawFlags: rightCmdDownFlags,
            timestampNs: 2_500_000_000
        ))
        XCTAssertEqual(escWhileHoldingRightCmd.action, .swallow)
        XCTAssertEqual(escWhileHoldingRightCmd.emittedEvents, [.cancelEscape])
        XCTAssertFalse(machine.pttActive)

        // Releasing Right Cmd after Esc cancel emits nothing
        let releaseAfterCancel = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: 0,
            timestampNs: 2_600_000_000
        ))
        XCTAssertTrue(releaseAfterCancel.emittedEvents.isEmpty)

        // 3. After Secure Input ends, immediate Right Cmd press reconciles suppression on first try
        _ = machine.process(RawKeyEvent(kind: .secureInputActivated))
        XCTAssertTrue(machine.suppressUntilRelease)
        machine.reconcileSuppressionAfterSecureInputEnded(
            incomingKind: .flagsChanged,
            incomingIsAutorepeat: false,
            currentRawFlags: rightCmdDownFlags
        )
        XCTAssertFalse(machine.suppressUntilRelease)
        _ = machine.process(RawKeyEvent(
            kind: .flagsChanged,
            keyCode: HotkeyVirtualKeyCode.rightCommand,
            rawFlags: rightCmdDownFlags,
            timestampNs: 3_000_000_000
        ))
        XCTAssertTrue(machine.pendingSingleModifierHold)
    }
}
