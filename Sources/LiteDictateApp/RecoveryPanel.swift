import AppKit
import LiteDictateCore

/// 100% lazy, zero-retention frosted-glass non-activating interactive recovery card.
/// Strictly `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`, `ignoresMouseEvents = false`.
/// Tears down `NSPanel` and clears all text buffers immediately when dismissed so idle RAM stays `<= 20 MB`.
@MainActor
final class RecoveryPanel {
    private let dispatchAction: (AppActionCommand) -> Void

    private var panel: NSPanel?
    private var reasonLabel: NSTextField?
    private var noticeLabel: NSTextField?
    private var textView: NSTextView?
    private var insertButton: NSButton?
    private var copyButton: NSButton?
    private var retryButton: NSButton?

    private let panelWidth: CGFloat = 436
    private let panelHeight: CGFloat = 224

    init(dispatchAction: @escaping (AppActionCommand) -> Void) {
        self.dispatchAction = dispatchAction
        // Strictly lazy: zero AppKit windows allocated at startup!
    }

    func render(_ payload: RecoveryPayload?) {
        guard let payload else {
            tearDownPanel()
            return
        }

        ensurePanelCreated()

        reasonLabel?.stringValue = payload.reason
        if let notice = payload.notice, !notice.isEmpty {
            noticeLabel?.stringValue = notice
            noticeLabel?.textColor = .systemOrange
        } else {
            let remaining = max(0, Int(payload.expiresAt.timeIntervalSinceNow))
            noticeLabel?.stringValue = payload.hasRetainedAudio
                ? "这段语音将在内存中暂存约 \(remaining) 秒（不会写入硬盘）"
                : "识别结果将在内存中暂存约 \(remaining) 秒"
            noticeLabel?.textColor = .secondaryLabelColor
        }

        if let text = payload.text, !text.isEmpty {
            textView?.string = text
            textView?.textColor = .labelColor
        } else {
            textView?.string = "语音已安全保存在内存中，点击「重试识别」即可重新转成文字。"
            textView?.textColor = .secondaryLabelColor
        }

        insertButton?.isEnabled = payload.canPaste
        copyButton?.isEnabled = payload.canCopy
        retryButton?.isEnabled = payload.canRetry
        retryButton?.isHidden = !payload.canRetry

        if let panel, !panel.isVisible {
            positionOnActiveScreen(panel)
            panel.orderFrontRegardless()
        }
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
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSVisualEffectView(frame: rect)
        root.material = .hudWindow
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1.0
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let badge = NSImageView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)
        badge.contentTintColor = .systemOrange

        let reason = NSTextField(wrappingLabelWithString: "")
        reason.translatesAutoresizingMaskIntoConstraints = false
        reason.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        reason.textColor = .labelColor
        reason.maximumNumberOfLines = 2
        reason.lineBreakMode = .byTruncatingTail

        let notice = NSTextField(wrappingLabelWithString: "")
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 2
        notice.lineBreakMode = .byTruncatingTail

        let textCard = NSView(frame: .zero)
        textCard.translatesAutoresizingMaskIntoConstraints = false
        textCard.wantsLayer = true
        textCard.layer?.cornerRadius = 10
        textCard.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.68).cgColor
        textCard.layer?.borderWidth = 0.75
        textCard.layer?.borderColor = NSColor.separatorColor.cgColor

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 390, height: 84))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 13.5)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        textCard.addSubview(scroll)

        let insertBtn = NSButton(title: "插入当前窗口", target: self, action: #selector(onPasteToCurrentWindow))
        insertBtn.bezelStyle = .rounded
        insertBtn.bezelColor = .controlAccentColor
        insertBtn.contentTintColor = .white

        let copyBtn = NSButton(title: "复制文字", target: self, action: #selector(onCopy))
        copyBtn.bezelStyle = .rounded

        let retryBtn = NSButton(title: "重试识别", target: self, action: #selector(onRetry))
        retryBtn.bezelStyle = .rounded

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(onDiscard))
        closeBtn.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [insertBtn, copyBtn, retryBtn, spacer, closeBtn])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        root.addSubview(badge)
        root.addSubview(reason)
        root.addSubview(notice)
        root.addSubview(textCard)
        root.addSubview(buttonStack)

        p.contentView = root

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),

            reason.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            reason.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            reason.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),

            notice.leadingAnchor.constraint(equalTo: reason.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            notice.topAnchor.constraint(equalTo: reason.bottomAnchor, constant: 3),

            textCard.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 10),
            textCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            textCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            textCard.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: textCard.topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: textCard.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: textCard.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: textCard.bottomAnchor, constant: -2),

            buttonStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        self.panel = p
        self.reasonLabel = reason
        self.noticeLabel = notice
        self.textView = tv
        self.insertButton = insertBtn
        self.copyButton = copyBtn
        self.retryButton = retryBtn
    }

    private func tearDownPanel() {
        textView?.string = ""
        guard let existing = panel else { return }
        existing.orderOut(nil)
        existing.contentView = nil
        existing.close()
        panel = nil
        reasonLabel = nil
        noticeLabel = nil
        textView = nil
        insertButton = nil
        copyButton = nil
        retryButton = nil
    }

    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - (panelWidth * 0.5)
        let y = frame.midY - (panelHeight * 0.5) + 40.0
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    @objc private func onCopy() {
        dispatchAction(.recoveryCopy)
    }

    @objc private func onPasteToCurrentWindow() {
        // Hide RecoveryPanel first and verify external frontmostApplication.pid != LiteDictate.pid.
        panel?.orderOut(nil)
        let myPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self else { return }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPID == nil || frontPID == myPID {
                self.panel?.orderFrontRegardless()
            }
            self.dispatchAction(.recoveryPasteToFrontmost)
        }
    }

    @objc private func onRetry() {
        dispatchAction(.recoveryRetry)
    }

    @objc private func onDiscard() {
        dispatchAction(.recoveryDiscard)
    }
}
