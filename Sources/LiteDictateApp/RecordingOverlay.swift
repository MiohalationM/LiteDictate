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
        let barWidth: CGFloat = 4.0
        let gap: CGFloat = 4.5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (bounds.width - totalWidth) * 0.5
        let midY = bounds.height * 0.5
        let minBarHeight: CGFloat = 4.5
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

/// 100% lazy, zero-retention pure-AppKit floating frosted-glass recording pill.
/// Strictly `.borderless`, `.nonactivatingPanel`, `ignoresMouseEvents = true`, `level = .floating`,
/// `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`.
/// Tears down `NSPanel` and all backing views completely when hidden so idle RAM stays `<= 20 MB`.
@MainActor
final class RecordingOverlay {
    private var panel: NSPanel?
    private var waveformView: WaveformPillView?
    private var statusLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var timerLabel: NSTextField?
    private var animationTimer: Timer?
    private var animationTick: CGFloat = 0
    private var latestState: RecordingOverlayState = .hidden

    private let panelWidth: CGFloat = 304
    private let panelHeight: CGFloat = 60

    init() {
        // Strictly lazy: zero AppKit windows or IOSurface backing stores allocated at init!
    }

    func render(_ state: RecordingOverlayState) {
        latestState = state
        guard state.isVisible else {
            tearDownPanel()
            return
        }

        ensurePanelCreated()
        applyStateToViews(state, advanceEnvelope: false)

        if let panel, !panel.isVisible {
            positionBottomCenterOnActiveScreen(panel)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1.0
            }
        }
        ensureAnimationTimerRunning()
    }

    private func ensurePanelCreated() {
        guard panel == nil else { return }

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
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
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = panelHeight * 0.5
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let wave = WaveformPillView(frame: .zero)
        wave.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(labelWithString: "按 Esc 取消")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let timer = NSTextField(labelWithString: "")
        timer.translatesAutoresizingMaskIntoConstraints = false
        timer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timer.textColor = .secondaryLabelColor
        timer.alignment = .right
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [status, hint])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        visualEffect.addSubview(wave)
        visualEffect.addSubview(textStack)
        visualEffect.addSubview(timer)

        NSLayoutConstraint.activate([
            wave.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 18),
            wave.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 46),
            wave.heightAnchor.constraint(equalToConstant: 40),

            textStack.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: timer.leadingAnchor, constant: -10),

            timer.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -18),
            timer.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
        ])

        p.contentView = visualEffect

        self.panel = p
        self.waveformView = wave
        self.statusLabel = status
        self.hintLabel = hint
        self.timerLabel = timer
    }

    private func applyStateToViews(_ state: RecordingOverlayState, advanceEnvelope: Bool) {
        statusLabel?.stringValue = state.statusText

        let waveColor: NSColor
        let pulseMode: Bool

        if state.isCompilingMetalShaders {
            waveColor = .systemBlue
            pulseMode = true
            hintLabel?.stringValue = "仅首次需要，完成后永久加速"
            timerLabel?.stringValue = ""
        } else if state.phase == .recording {
            waveColor = state.isReadyForSpeech ? .systemTeal : .systemOrange
            pulseMode = !state.isReadyForSpeech
            hintLabel?.stringValue = "按 Esc 取消"
            let sec = Double(state.elapsedMs) / 1000.0
            timerLabel?.stringValue = String(format: "%.1fs", sec)
        } else if state.phase == .arming {
            waveColor = .systemOrange
            pulseMode = true
            hintLabel?.stringValue = "按 Esc 取消"
            timerLabel?.stringValue = ""
        } else {
            waveColor = .systemIndigo
            pulseMode = true
            hintLabel?.stringValue = state.phase == .transcribing ? "离线识别中 · Esc 取消" : "马上就好"
            timerLabel?.stringValue = ""
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
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil, self.latestState.isVisible else { return }
                self.animationTick += 1.0
                self.applyStateToViews(self.latestState, advanceEnvelope: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func tearDownPanel() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationTick = 0

        guard let existing = panel else { return }
        existing.orderOut(nil)
        existing.contentView = nil
        existing.close()
        panel = nil
        waveformView = nil
        statusLabel = nil
        hintLabel = nil
        timerLabel = nil
    }

    private func positionBottomCenterOnActiveScreen(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let x = visibleFrame.midX - (panelWidth * 0.5)
        let y = visibleFrame.minY + 76.0
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }
}
