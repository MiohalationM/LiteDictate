import AppKit
import LiteDictateCore

/// Animated 5-bar acoustic waveform matching the `LiteDictate` (`言落`) brand mark geometry.
@MainActor
private final class WaveformPillView: NSView {
    private var targetLevel: CGFloat = 0.0
    private var smoothedLevel: CGFloat = 0.0
    private var barTrail: [CGFloat] = [0.0, 0.0, 0.0, 0.0, 0.0]
    private var phaseTick: CGFloat = 0.0
    private var barColor: NSColor = .systemCyan
    private var isAnimatingPulse: Bool = false

    override var isFlipped: Bool { true }

    func reset() {
        targetLevel = 0.0
        smoothedLevel = 0.0
        barTrail = [0.0, 0.0, 0.0, 0.0, 0.0]
        phaseTick = 0.0
        needsDisplay = true
    }

    func update(level: Float, color: NSColor, animatingPulse: Bool, tick: CGFloat, advanceEnvelope: Bool) {
        let clamped = CGFloat(level.isFinite ? max(0.0, min(1.0, level)) : 0.0)
        self.targetLevel = clamped
        self.barColor = color
        self.isAnimatingPulse = animatingPulse
        self.phaseTick = tick

        if advanceEnvelope {
            // Fast attack for snappy speech syllables, smooth release for natural fluid decay.
            let alpha: CGFloat = clamped > smoothedLevel ? 0.58 : 0.24
            smoothedLevel += (clamped - smoothedLevel) * alpha

            // Propagate energy outward from center bar with subtle asymmetric organic variance.
            let centerEnergy = smoothedLevel
            let innerLeft = barTrail[1] + (centerEnergy * 0.92 - barTrail[1]) * 0.48
            let innerRight = barTrail[3] + (centerEnergy * 0.95 - barTrail[3]) * 0.42
            let outerLeft = barTrail[0] + (innerLeft * 0.84 - barTrail[0]) * 0.38
            let outerRight = barTrail[4] + (innerRight * 0.86 - barTrail[4]) * 0.34
            barTrail = [outerLeft, innerLeft, centerEnergy, innerRight, outerRight]
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barCount = 5
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 4.0
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (bounds.width - totalWidth) * 0.5
        let midY = bounds.height * 0.5
        let minBarHeight: CGFloat = 4.0
        let maxBarHeight = max(minBarHeight, bounds.height - 4.0)

        // Brand-signature silhouette weights tuned for dramatic, readable vertical travel across all 5 bars.
        let restFractions: [CGFloat] = [0.12, 0.15, 0.18, 0.15, 0.12]
        let peakWeights: [CGFloat] = [0.68, 0.88, 1.0, 0.88, 0.68]
        let alphas: [CGFloat] = [0.78, 0.94, 1.0, 0.94, 0.78]

        for i in 0..<barCount {
            let phaseOffset = CGFloat(i) * 0.85
            let heightFraction: CGFloat
            if isAnimatingPulse {
                // Smooth traveling wave during engine startup / transcription
                let wave = 0.5 + 0.5 * sin(phaseTick * 0.28 - phaseOffset)
                heightFraction = restFractions[i] + (peakWeights[i] * 0.62 - restFractions[i]) * wave
            } else {
                // Live responsive acoustic waveform during recording:
                // stays calm near `restFractions` in silence and spans up to full height during normal speech.
                let energy = barTrail[i]
                let ripple = 0.82 + 0.18 * sin(phaseTick * 0.46 + phaseOffset)
                let speechExcursion = min(1.0, energy * ripple)
                heightFraction = restFractions[i] + (peakWeights[i] - restFractions[i]) * speechExcursion
            }

            let h = max(minBarHeight, min(maxBarHeight, maxBarHeight * heightFraction))
            let rect = NSRect(
                x: startX + CGFloat(i) * (barWidth + gap),
                y: midY - h * 0.5,
                width: barWidth,
                height: h
            )
            barColor.withAlphaComponent(alphas[i]).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5).fill()
        }
    }
}

/// 100% lazy, zero-retention pure-AppKit floating frosted-glass recording pill & non-intrusive toast.
/// Strictly `.borderless`, `.nonactivatingPanel`, `ignoresMouseEvents = true`, `level = .floating`,
/// `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`.
/// Tears down `NSPanel` and all backing views completely when hidden so idle RAM stays `<= 20 MB`.
@MainActor
final class RecordingOverlay {
    private var panel: NSPanel?
    private var visualEffectView: NSVisualEffectView?
    private var waveformView: WaveformPillView?
    private var toastIconView: NSImageView?
    private var statusLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var timerLabel: NSTextField?
    private var animationTimer: Timer?
    private var animationTick: CGFloat = 0
    private var latestState: RecordingOverlayState = .hidden
    private var currentPanelSize: NSSize = NSSize(width: 244, height: 46)

    private let recordingPanelWidth: CGFloat = 244
    private let recordingPanelHeight: CGFloat = 46
    private let toastPanelHeight: CGFloat = 44

    init() {
        // Strictly lazy: zero AppKit windows or IOSurface backing stores allocated at init!
    }

    func render(_ state: RecordingOverlayState) {
        let wasToast = latestState.isToast
        latestState = state
        guard state.isVisible else {
            tearDownPanel()
            return
        }

        ensurePanelCreated()
        if wasToast && !state.isToast {
            waveformView?.reset()
        }
        applyStateToViews(state, advanceEnvelope: false)
        updatePanelGeometry(for: state)

        if let panel, !panel.isVisible {
            positionBottomCenterOnActiveScreen(panel, size: currentPanelSize)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1.0
            }
        }

        if state.isToast {
            stopAnimationTimer()
        } else {
            ensureAnimationTimerRunning()
        }
    }

    private func ensurePanelCreated() {
        guard panel == nil else { return }

        let initialSize = NSSize(width: recordingPanelWidth, height: recordingPanelHeight)
        currentPanelSize = initialSize
        let rect = NSRect(origin: .zero, size: initialSize)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = initialSize.height * 0.5
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let wave = WaveformPillView(frame: .zero)
        wave.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wave.widthAnchor.constraint(equalToConstant: 40),
            wave.heightAnchor.constraint(equalToConstant: 30),
        ])

        let toastIcon = NSImageView(frame: .zero)
        toastIcon.translatesAutoresizingMaskIntoConstraints = false
        toastIcon.imageScaling = .scaleProportionallyDown
        toastIcon.contentTintColor = .systemTeal
        toastIcon.isHidden = true
        NSLayoutConstraint.activate([
            toastIcon.widthAnchor.constraint(equalToConstant: 18),
            toastIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let status = NSTextField(labelWithString: "")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let hint = NSTextField(labelWithString: "")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.isHidden = true

        let textStack = NSStackView(views: [status, hint])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let timer = NSTextField(labelWithString: "")
        timer.translatesAutoresizingMaskIntoConstraints = false
        timer.font = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .medium)
        timer.textColor = .secondaryLabelColor
        timer.alignment = .right
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)
        timer.setContentHuggingPriority(.required, for: .horizontal)

        let rowStack = NSStackView(views: [wave, toastIcon, textStack, timer])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 10
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        visualEffect.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
            rowStack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
        ])

        p.contentView = visualEffect

        self.panel = p
        self.visualEffectView = visualEffect
        self.waveformView = wave
        self.toastIconView = toastIcon
        self.statusLabel = status
        self.hintLabel = hint
        self.timerLabel = timer
    }

    private func updatePanelGeometry(for state: RecordingOverlayState) {
        guard let panel, let visualEffectView else { return }

        let targetSize: NSSize
        if state.isToast {
            let textWidth = statusLabel?.attributedStringValue.size().width ?? 160
            // 16 (left) + 18 (icon) + 10 (gap) + textWidth + 16 (right) + small breathing room
            let computedWidth = ceil(textWidth) + 68
            let clampedWidth = min(360, max(216, computedWidth))
            targetSize = NSSize(width: clampedWidth, height: toastPanelHeight)
        } else {
            let height: CGFloat = state.isCompilingMetalShaders ? 52 : recordingPanelHeight
            let width: CGFloat = state.isCompilingMetalShaders ? 276 : recordingPanelWidth
            targetSize = NSSize(width: width, height: height)
        }

        if abs(targetSize.width - currentPanelSize.width) > 0.5 || abs(targetSize.height - currentPanelSize.height) > 0.5 {
            currentPanelSize = targetSize
            visualEffectView.layer?.cornerRadius = targetSize.height * 0.5
            let origin = bottomCenterOriginOnActiveScreen(for: targetSize)
            panel.setFrame(NSRect(origin: origin, size: targetSize), display: true)
        }
    }

    private func applyStateToViews(_ state: RecordingOverlayState, advanceEnvelope: Bool) {
        if state.isToast {
            let message = state.toastMessage ?? state.statusText
            statusLabel?.stringValue = message
            statusLabel?.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
            hintLabel?.stringValue = ""
            hintLabel?.isHidden = true
            timerLabel?.stringValue = ""
            timerLabel?.isHidden = true
            waveformView?.isHidden = true

            let symbolName = message.contains("剪贴板") ? "doc.on.clipboard.fill" : "checkmark.circle.fill"
            let cfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
            toastIconView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            toastIconView?.isHidden = false
            return
        }

        toastIconView?.isHidden = true
        waveformView?.isHidden = false
        statusLabel?.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        statusLabel?.stringValue = state.statusText

        let waveColor: NSColor
        let pulseMode: Bool

        if state.isCompilingMetalShaders {
            waveColor = .systemBlue
            pulseMode = true
            hintLabel?.stringValue = "仅首次需要，完成后永久加速"
            hintLabel?.isHidden = false
            timerLabel?.stringValue = ""
            timerLabel?.isHidden = true
        } else if state.phase == .recording {
            waveColor = state.isReadyForSpeech ? .systemTeal : .systemOrange
            pulseMode = !state.isReadyForSpeech
            hintLabel?.stringValue = ""
            hintLabel?.isHidden = true
            let sec = Double(state.elapsedMs) / 1000.0
            timerLabel?.stringValue = String(format: "%.1fs", sec)
            timerLabel?.isHidden = false
        } else if state.phase == .arming {
            waveColor = .systemOrange
            pulseMode = true
            hintLabel?.stringValue = ""
            hintLabel?.isHidden = true
            timerLabel?.stringValue = ""
            timerLabel?.isHidden = true
        } else {
            waveColor = .systemIndigo
            pulseMode = true
            hintLabel?.stringValue = ""
            hintLabel?.isHidden = true
            timerLabel?.stringValue = ""
            timerLabel?.isHidden = true
        }

        waveformView?.update(
            level: state.audioLevel,
            color: waveColor,
            animatingPulse: pulseMode,
            tick: animationTick,
            advanceEnvelope: advanceEnvelope
        )
    }

    private func ensureAnimationTimerRunning() {
        guard animationTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil, self.latestState.isVisible, !self.latestState.isToast else { return }
                self.animationTick += 1.0
                self.applyStateToViews(self.latestState, advanceEnvelope: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationTick = 0
    }

    private func tearDownPanel() {
        stopAnimationTimer()

        guard let existing = panel else { return }
        existing.orderOut(nil)
        existing.contentView = nil
        existing.close()
        panel = nil
        visualEffectView = nil
        waveformView = nil
        toastIconView = nil
        statusLabel = nil
        hintLabel = nil
        timerLabel = nil
    }

    private func bottomCenterOriginOnActiveScreen(for size: NSSize) -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return .zero }
        let x = visibleFrame.midX - (size.width * 0.5)
        let y = visibleFrame.minY + 72.0
        return NSPoint(x: round(x), y: round(y))
    }

    private func positionBottomCenterOnActiveScreen(_ panel: NSPanel, size: NSSize) {
        panel.setFrameOrigin(bottomCenterOriginOnActiveScreen(for: size))
    }
}
