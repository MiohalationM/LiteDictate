import AppKit
import Carbon.HIToolbox
import LiteDictateCore
import UniformTypeIdentifiers

/// Interactive visual shortcut recorder pill (Pure AppKit).
/// Supports BOTH single-modifier keys (Right ⌘, Left ⌘, Right ⌥, Left ⌥, Fn, Right ⇧, Right ⌃)
/// AND traditional modifier+key combos (e.g. ⌘⇧D, ⌥Space). Press Esc to cancel recording.
@MainActor
private final class HotkeyRecorderButton: NSButton {
    var onRecorded: ((HotkeyBinding) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?
    private var currentBinding: HotkeyBinding = .defaultBinding
    private var isRecordingShortcut: Bool = false
    private var localMonitor: Any?
    private var pendingSingleModifierKeyCode: UInt16?
    private var chordOccurredDuringRecording: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setBinding(_ binding: HotkeyBinding) {
        currentBinding = binding
        if !isRecordingShortcut {
            updateTitle()
        }
    }

    func cancelRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        pendingSingleModifierKeyCode = nil
        chordOccurredDuringRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        onRecordingStateChanged?(false)
        updateTitle()
    }

    private func updateTitle() {
        if isRecordingShortcut {
            if let pending = pendingSingleModifierKeyCode {
                title = "松开即可设为 \(HotkeyBinding.singleModifierLabel(for: pending))…"
            } else {
                title = "按下单键（如右⌘/Fn）或组合键（Esc 取消）"
            }
            contentTintColor = .controlAccentColor
        } else {
            title = "  \(currentBinding.displayString)  （点击修改）"
            contentTintColor = nil
        }
    }

    private static func isModifierPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        HotkeyDebtMachine.isSingleModifierDown(keyCode: keyCode, rawFlags: UInt64(flags.rawValue))
    }

    private static func expectedModifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case UInt16(kVK_RightCommand), UInt16(kVK_Command):
            return .command
        case UInt16(kVK_RightOption), UInt16(kVK_Option):
            return .option
        case UInt16(kVK_RightShift), UInt16(kVK_Shift):
            return .shift
        case UInt16(kVK_RightControl), UInt16(kVK_Control):
            return .control
        case UInt16(kVK_Function):
            return .function
        default:
            return []
        }
    }

    @objc private func toggleRecording() {
        if isRecordingShortcut {
            cancelRecording()
            return
        }
        isRecordingShortcut = true
        pendingSingleModifierKeyCode = nil
        chordOccurredDuringRecording = false
        onRecordingStateChanged?(true)
        updateTitle()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecordingShortcut else { return event }

            if event.type == .flagsChanged {
                let keyCode = event.keyCode
                guard HotkeyBinding.isSingleModifierKeyCode(keyCode) else { return nil }
                let rawFlags = UInt64(event.modifierFlags.rawValue)
                let isDown = Self.isModifierPressed(keyCode: keyCode, flags: event.modifierFlags)
                let activeModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control, .function])
                let expectedFlag = Self.expectedModifierFlag(for: keyCode)

                if isDown {
                    if !self.chordOccurredDuringRecording
                        && self.pendingSingleModifierKeyCode == nil
                        && activeModifiers == expectedFlag
                        && !HotkeyDebtMachine.hasExtraModifiersBesidesSingleTarget(keyCode: keyCode, rawFlags: rawFlags)
                    {
                        self.pendingSingleModifierKeyCode = keyCode
                        self.updateTitle()
                    } else if self.pendingSingleModifierKeyCode != keyCode {
                        // Multiple modifiers held together: user is building a combo, not a single modifier.
                        self.pendingSingleModifierKeyCode = nil
                        self.chordOccurredDuringRecording = true
                        self.updateTitle()
                    }
                } else {
                    if let pending = self.pendingSingleModifierKeyCode,
                       pending == keyCode,
                       !self.chordOccurredDuringRecording {
                        let mask = HotkeyBinding.singleModifierMask(for: keyCode)
                        let updated = HotkeyBinding(
                            kind: .singleModifier,
                            keyCode: keyCode,
                            modifiers: mask,
                            triggerMode: self.currentBinding.triggerMode,
                            strictLeftSideOnly: false
                        )
                        self.currentBinding = updated
                        self.cancelRecording()
                        self.onRecorded?(updated)
                    } else if activeModifiers.isEmpty {
                        self.pendingSingleModifierKeyCode = nil
                        self.chordOccurredDuringRecording = false
                        self.updateTitle()
                    }
                }
                return nil
            }

            // `.keyDown`
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelRecording()
                return nil
            }

            var mask: HotkeyModifierMask = []
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if flags.contains(.command) { mask.insert(.command) }
            if flags.contains(.shift) { mask.insert(.shift) }
            if flags.contains(.option) { mask.insert(.option) }
            if flags.contains(.control) { mask.insert(.control) }

            // Require at least one modifier key so normal typing keys cannot be hijacked.
            guard !mask.isEmpty else {
                self.pendingSingleModifierKeyCode = nil
                NSSound.beep()
                return nil
            }

            self.pendingSingleModifierKeyCode = nil
            self.chordOccurredDuringRecording = true

            let updated = HotkeyBinding(
                kind: .keyCombo,
                keyCode: event.keyCode,
                modifiers: mask,
                triggerMode: self.currentBinding.triggerMode,
                strictLeftSideOnly: self.currentBinding.strictLeftSideOnly
            )
            self.currentBinding = updated
            self.cancelRecording()
            self.onRecorded?(updated)
            return nil
        }
    }
}

@MainActor
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// 100% lazy, zero-retention Pure AppKit Preferences Window (`偏好设置…`).
/// Created ONLY when opened; on `windowWillClose`, releases its window & backing stores completely
/// so post-close idle memory returns to `<= 20 MB`. Zero SwiftUI / WebView!
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let dispatchAction: (AppActionCommand) -> Void
    private let loadVocabAndAliases: () -> (vocabText: String, aliasesJSON: String)
    private let onDidClose: () -> Void

    private var snapshot: AppStateSnapshot
    private var selectedTab: Int = 0
    private var segmentedTabs: NSSegmentedControl?
    private var contentContainer: NSView?
    private var hotkeyRecorder: HotkeyRecorderButton?
    private var vocabTextView: NSTextView?
    private var aliasesTextView: NSTextView?
    private var statusFooterLabel: NSTextField?
    private var hasUnsavedDictEdits: Bool = false

    private let windowWidth: CGFloat = 584
    private let windowHeight: CGFloat = 468

    init(
        initialSnapshot: AppStateSnapshot,
        dispatchAction: @escaping (AppActionCommand) -> Void,
        loadVocabAndAliases: @escaping () -> (vocabText: String, aliasesJSON: String),
        onDidClose: @escaping () -> Void
    ) {
        self.snapshot = initialSnapshot
        self.dispatchAction = dispatchAction
        self.loadVocabAndAliases = loadVocabAndAliases
        self.onDidClose = onDidClose

        let rect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "言落 偏好设置"
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        win.delegate = self
        buildShell(in: win)
        renderTabContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        dispatchAction(.refreshPermissions)
    }

    func render(_ newSnapshot: AppStateSnapshot) {
        let old = snapshot
        snapshot = newSnapshot
        updateStatusFooter()

        // Avoid clobbering active text editing in Tab 3 when only unrelated fields change.
        if selectedTab == 3 && hasUnsavedDictEdits {
            return
        }
        let relevantChanged =
            old.launchAtLogin != newSnapshot.launchAtLogin ||
            old.hotkey != newSnapshot.hotkey ||
            old.inputMode != newSnapshot.inputMode ||
            old.preferredLanguage != newSnapshot.preferredLanguage ||
            old.playFeedbackSounds != newSnapshot.playFeedbackSounds ||
            old.modelIdleUnloadPolicy != newSnapshot.modelIdleUnloadPolicy ||
            old.activeModelID != newSnapshot.activeModelID ||
            old.models != newSnapshot.models ||
            old.discoveredModels != newSnapshot.discoveredModels ||
            old.isImportingModel != newSnapshot.isImportingModel ||
            old.audioSelection != newSnapshot.audioSelection ||
            old.availableDevices != newSnapshot.availableDevices ||
            old.resolvedDevice != newSnapshot.resolvedDevice ||
            old.permissions != newSnapshot.permissions
        if relevantChanged {
            renderTabContent()
        }
    }

    func textDidChange(_ notification: Notification) {
        hasUnsavedDictEdits = true
    }

    func windowDidResignKey(_ notification: Notification) {
        hotkeyRecorder?.cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        hotkeyRecorder?.cancelRecording()
        // Belt-and-suspenders: guarantee global EventTap resumes even if view was already torn down.
        dispatchAction(.setHotkeyRecordingActive(false))
        hotkeyRecorder = nil
        vocabTextView = nil
        aliasesTextView = nil
        contentContainer = nil
        segmentedTabs = nil
        statusFooterLabel = nil
        window?.contentView = nil
        window?.delegate = nil
        onDidClose()
    }

    // MARK: - Window Shell

    private func buildShell(in window: NSWindow) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))

        let tabs = NSSegmentedControl(
            labels: ["通用", "语音模型", "麦克风", "词库与权限"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onTabChanged(_:))
        )
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator

        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let footerDivider = NSBox()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.boxType = .separator

        let footer = NSTextField(labelWithString: "")
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = NSFont.systemFont(ofSize: 11.5)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        root.addSubview(tabs)
        root.addSubview(divider)
        root.addSubview(container)
        root.addSubview(footerDivider)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),

            divider.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            container.topAnchor.constraint(equalTo: divider.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        window.contentView = root
        self.segmentedTabs = tabs
        self.contentContainer = container
        self.statusFooterLabel = footer
        updateStatusFooter()
    }

    private func updateStatusFooter() {
        if let err = snapshot.lastErrorMessage, !err.isEmpty {
            statusFooterLabel?.stringValue = "⚠ \(err)"
            statusFooterLabel?.textColor = .systemOrange
        } else if let notice = snapshot.lastNoticeMessage, !notice.isEmpty {
            statusFooterLabel?.stringValue = notice
            statusFooterLabel?.textColor = .secondaryLabelColor
        } else {
            statusFooterLabel?.stringValue = "言落 LiteDictate · 完全本地离线识别，不上传任何语音与文字"
            statusFooterLabel?.textColor = .secondaryLabelColor
        }
    }

    private func renderTabContent() {
        guard let container = contentContainer else { return }
        hotkeyRecorder?.cancelRecording()
        hotkeyRecorder = nil
        vocabTextView = nil
        aliasesTextView = nil
        container.subviews.forEach { $0.removeFromSuperview() }

        let page: NSView
        switch selectedTab {
        case 0: page = buildGeneralTab()
        case 1: page = buildModelsTab()
        case 2: page = buildMicrophoneTab()
        default: page = buildDictionaryAndPermissionsTab()
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Tab 0: General

    private func buildGeneralTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        // 1. Launch at Login
        let loginRow = makeLabeledRow("开机启动") {
            switch snapshot.launchAtLogin {
            case .enabled, .notRegistered:
                let cb = NSButton(checkboxWithTitle: "开机自动启动言落", target: self, action: #selector(onToggleLaunchAtLogin(_:)))
                cb.state = (snapshot.launchAtLogin == .enabled) ? .on : .off
                return cb
            case .requiresApproval:
                let btn = NSButton(title: "前往「登录项」批准开机自启动…", target: self, action: #selector(onOpenLoginItems))
                btn.bezelStyle = .rounded
                return btn
            case .unavailable:
                let lbl = NSTextField(labelWithString: "需从应用程序目录运行以开启")
                lbl.textColor = .secondaryLabelColor
                return lbl
            }
        }
        stack.addArrangedSubview(loginRow)

        // 2. Trigger Mode
        let triggerRow = makeLabeledRow("说话方式") {
            let seg = NSSegmentedControl(
                labels: [HotkeyTriggerMode.toggle.displayTitle, HotkeyTriggerMode.pushToTalk.displayTitle],
                trackingMode: .selectOne,
                target: self,
                action: #selector(onTriggerModeChanged(_:))
            )
            seg.selectedSegment = (snapshot.hotkey.triggerMode == .toggle) ? 0 : 1
            return seg
        }
        stack.addArrangedSubview(triggerRow)

        // 3. Visual Shortcut Recorder + 1-click Presets + Reset
        let shortcutRow = makeLabeledRow("呼出快捷键") {
            let recorder = HotkeyRecorderButton(frame: .zero)
            recorder.setBinding(snapshot.hotkey)
            recorder.onRecordingStateChanged = { [weak self] active in
                self?.dispatchAction(.setHotkeyRecordingActive(active))
            }
            recorder.onRecorded = { [weak self] binding in
                self?.dispatchAction(.setHotkeyBinding(binding))
            }
            self.hotkeyRecorder = recorder

            let resetBtn = NSButton(title: "恢复默认 右 ⌘", target: self, action: #selector(onResetDefaultHotkey))
            resetBtn.bezelStyle = .rounded

            let topLine = NSStackView(views: [recorder, resetBtn])
            topLine.orientation = .horizontal
            topLine.spacing = 8

            let presetSpecs: [(title: String, binding: HotkeyBinding, action: Selector)] = [
                ("右 ⌘", .rightCommandPTT, #selector(onPresetRightCommand)),
                ("右 ⌥", .rightOptionPTT, #selector(onPresetRightOption)),
                ("Fn", .fnPTT, #selector(onPresetFn)),
                ("⌘⇧D", .cmdShiftD, #selector(onPresetCmdShiftD)),
            ]
            let presetLabel = NSTextField(labelWithString: "常用预设：")
            presetLabel.font = NSFont.systemFont(ofSize: 11.5)
            presetLabel.textColor = .secondaryLabelColor

            var presetViews: [NSView] = [presetLabel]
            for spec in presetSpecs {
                let btn = NSButton(title: spec.title, target: self, action: spec.action)
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                let isSelected = (snapshot.hotkey.kind == spec.binding.kind &&
                                  snapshot.hotkey.keyCode == spec.binding.keyCode &&
                                  snapshot.hotkey.modifiers == spec.binding.modifiers)
                if isSelected {
                    btn.bezelColor = .controlAccentColor
                    btn.contentTintColor = .white
                }
                presetViews.append(btn)
            }
            let presetLine = NSStackView(views: presetViews)
            presetLine.orientation = .horizontal
            presetLine.alignment = .centerY
            presetLine.spacing = 6

            let v = NSStackView(views: [topLine, presetLine])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 6
            return v
        }
        stack.addArrangedSubview(shortcutRow)

        // 4. Text Input Mode
        let inputModeRow = makeLabeledRow("文字输入方式") {
            let directRadio = NSButton(
                radioButtonWithTitle: TextInputMode.directTyping.displayTitle,
                target: self,
                action: #selector(onSelectDirectTypingMode)
            )
            directRadio.state = (snapshot.inputMode == .directTyping) ? .on : .off

            let clipRadio = NSButton(
                radioButtonWithTitle: TextInputMode.clipboardCompatibility.displayTitle,
                target: self,
                action: #selector(onSelectClipboardCompatMode)
            )
            clipRadio.state = (snapshot.inputMode == .clipboardCompatibility) ? .on : .off

            let v = NSStackView(views: [directRadio, clipRadio])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 6
            return v
        }
        stack.addArrangedSubview(inputModeRow)

        // 5. Recognition Language
        let langRow = makeLabeledRow("识别语言") {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["自动识别（推荐）", "中文", "English"])
            switch snapshot.preferredLanguage.lowercased() {
            case "zh": popup.selectItem(at: 1)
            case "en": popup.selectItem(at: 2)
            default: popup.selectItem(at: 0)
            }
            popup.target = self
            popup.action = #selector(onLanguagePopupChanged(_:))
            return popup
        }
        stack.addArrangedSubview(langRow)

        // 6. Feedback Sound Toggle
        let soundRow = makeLabeledRow("轻提示音") {
            let cb = NSButton(
                checkboxWithTitle: "开始与结束语音输入时播放轻提示音",
                target: self,
                action: #selector(onToggleFeedbackSounds(_:))
            )
            cb.state = snapshot.playFeedbackSounds ? .on : .off
            return cb
        }
        stack.addArrangedSubview(soundRow)

        return stack
    }

    // MARK: - Tab 1: Models

    private func buildModelsTab() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10

        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8

        let importBtn = NSButton(title: "导入本地 .gguf 模型…", target: self, action: #selector(onImportModel))
        importBtn.bezelStyle = .rounded
        importBtn.bezelColor = .controlAccentColor
        importBtn.contentTintColor = .white
        importBtn.isEnabled = !snapshot.isImportingModel

        let rescanBtn = NSButton(title: "重新扫描本机目录", target: self, action: #selector(onRescanModels))
        rescanBtn.bezelStyle = .rounded

        actionsRow.addArrangedSubview(importBtn)
        actionsRow.addArrangedSubview(rescanBtn)
        if snapshot.isImportingModel {
            let busy = NSTextField(labelWithString: "正在校验模型…")
            busy.textColor = .secondaryLabelColor
            actionsRow.addArrangedSubview(busy)
        }
        root.addArrangedSubview(actionsRow)

        // Registered models card list inside scroll view
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        if snapshot.models.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "还没有导入语音模型。点击上方「导入本地 .gguf 模型…」即可开始离线语音输入。")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
        } else {
            for model in snapshot.models {
                let row = makeModelRow(model, isActive: model.id == snapshot.activeModelID)
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }

        if !snapshot.discoveredModels.isEmpty {
            let header = NSTextField(labelWithString: "本机已发现模型（点击一键启用）：")
            header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(header)

            for cand in snapshot.discoveredModels {
                let sizeMB = Double(cand.fileSizeBytes) / (1024.0 * 1024.0)
                let btn = NSButton(
                    title: String(format: "+ 启用 %@ (%.0f MB)", cand.fileName, sizeMB),
                    target: self,
                    action: #selector(onAddDiscoveredModel(_:))
                )
                btn.bezelStyle = .rounded
                btn.identifier = NSUserInterfaceItemIdentifier(cand.filePath)
                listStack.addArrangedSubview(btn)
            }
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = FlippedClipView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35)
        scroll.documentView = listStack
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 184),
            listStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -16),
            listStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
        ])
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // Model idle auto-unload policy selector
        let unloadLabel = NSTextField(labelWithString: "空闲自动释放模型：")
        unloadLabel.font = NSFont.systemFont(ofSize: 12.5)
        let unloadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let policies = ModelIdleUnloadPolicy.allCases
        unloadPopup.addItems(withTitles: policies.map(\.displayTitle))
        if let idx = policies.firstIndex(of: snapshot.modelIdleUnloadPolicy) {
            unloadPopup.selectItem(at: idx)
        }
        unloadPopup.target = self
        unloadPopup.action = #selector(onModelIdleUnloadPolicyChanged(_:))

        let unloadRow = NSStackView(views: [unloadLabel, unloadPopup])
        unloadRow.orientation = .horizontal
        unloadRow.alignment = .centerY
        unloadRow.spacing = 6
        root.addArrangedSubview(unloadRow)

        // Concise guide on obtaining open-source models (P2-2: everyday consumer Chinese)
        let guide = NSTextField(
            wrappingLabelWithString: "去哪里获取更多开源模型？支持常见开源离线语音模型文件（.gguf 格式），如 Qwen3-ASR、Whisper、SenseVoice、Parakeet 等。下载后直接点击上方导入即可，默认原地引用不重复占空间。"
        )
        guide.font = NSFont.systemFont(ofSize: 11.5)
        guide.textColor = .secondaryLabelColor
        root.addArrangedSubview(guide)
        guide.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        return root
    }

    private func makeModelRow(_ model: ModelDescriptor, isActive: Bool) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = isActive ? 1.2 : 0.6
        card.layer?.borderColor = (isActive ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor

        let sizeMB = Double(model.fileSizeBytes) / (1024.0 * 1024.0)
        let title = NSTextField(labelWithString: model.displayName)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        let subtitleText = model.isFileMissing
            ? String(format: "⚠ 模型文件已移动或删除 · %.0f MB", sizeMB)
            : String(format: "%.0f MB · %@", sizeMB, isActive ? "当前使用中" : "已导入")
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = NSFont.systemFont(ofSize: 11.5)
        subtitle.textColor = model.isFileMissing ? .systemOrange : (isActive ? .controlAccentColor : .secondaryLabelColor)

        let infoStack = NSStackView(views: [title, subtitle])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6

        if model.isFileMissing {
            let relink = NSButton(title: "重新定位…", target: self, action: #selector(onRelinkModel(_:)))
            relink.bezelStyle = .rounded
            relink.identifier = NSUserInterfaceItemIdentifier(model.id)
            buttons.addArrangedSubview(relink)
        } else if !isActive {
            let useBtn = NSButton(title: "切换使用", target: self, action: #selector(onSelectModel(_:)))
            useBtn.bezelStyle = .rounded
            useBtn.identifier = NSUserInterfaceItemIdentifier(model.id)
            buttons.addArrangedSubview(useBtn)
        }

        let removeBtn = NSButton(title: "移除", target: self, action: #selector(onRemoveModel(_:)))
        removeBtn.bezelStyle = .rounded
        removeBtn.identifier = NSUserInterfaceItemIdentifier(model.id)
        buttons.addArrangedSubview(removeBtn)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [infoStack, spacer, buttons])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        infoStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
        return card
    }

    // MARK: - Tab 2: Microphone

    private func buildMicrophoneTab() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10

        let smartRadio = NSButton(
            radioButtonWithTitle: "智能选择（推荐：优先外接/内置麦，听歌不降音质）",
            target: self,
            action: #selector(onSelectSmartAutoMic)
        )
        if case .smartAuto = snapshot.audioSelection {
            smartRadio.state = .on
        }
        root.addArrangedSubview(smartRadio)

        let resolvedHint = NSTextField(
            labelWithString: "当前将使用：\(snapshot.resolvedDevice?.name ?? "未检测到可用麦克风")"
        )
        resolvedHint.font = NSFont.systemFont(ofSize: 12)
        resolvedHint.textColor = .secondaryLabelColor
        root.addArrangedSubview(resolvedHint)

        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let listHeader = NSTextField(labelWithString: "或手动指定一台麦克风：")
        listHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        listHeader.textColor = .secondaryLabelColor
        root.addArrangedSubview(listHeader)

        if snapshot.availableDevices.isEmpty {
            let none = NSTextField(labelWithString: "暂未检测到输入麦克风")
            none.textColor = .secondaryLabelColor
            root.addArrangedSubview(none)
        } else {
            for device in snapshot.availableDevices {
                let badge = friendlyTransportBadge(device.transportKind)
                let btNote = device.isBluetoothHFPWarning ? "（听歌时可能会切换通话音质）" : ""
                let radio = NSButton(
                    radioButtonWithTitle: "[\(badge)] \(device.name)\(btNote)",
                    target: self,
                    action: #selector(onSelectPinnedMic(_:))
                )
                radio.identifier = NSUserInterfaceItemIdentifier(device.uid)
                if case let .pinned(uid) = snapshot.audioSelection, uid == device.uid {
                    radio.state = .on
                }
                root.addArrangedSubview(radio)
            }
        }

        if snapshot.isBluetoothWarningActive {
            let warn = NSTextField(
                wrappingLabelWithString: "温馨提示：使用蓝牙耳机麦克风录音时，系统可能会临时切到通话模式，导致音乐播放变糊并稍有延迟。若戴着蓝牙耳机听歌，建议选「智能选择」。"
            )
            warn.font = NSFont.systemFont(ofSize: 11.5)
            warn.textColor = .systemOrange
            root.addArrangedSubview(warn)
            warn.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        return root
    }

    private func friendlyTransportBadge(_ kind: AudioTransportKind) -> String {
        switch kind {
        case .usb: return "外接麦克风"
        case .builtIn: return "电脑内置"
        case .bluetooth: return "蓝牙耳机"
        case .continuity: return "iPhone"
        case .virtual: return "虚拟设备"
        case .other: return "音频输入"
        }
    }

    // MARK: - Tab 3: Dictionary & Permissions

    private func buildDictionaryAndPermissionsTab() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10

        let (vocabText, aliasesJSON) = loadVocabAndAliases()
        hasUnsavedDictEdits = false

        let dictHeader = NSTextField(labelWithString: "常用词（左，每行一个，最多 50 个）与自动纠错词（右，如 {\"错别字\": \"正确词\"}）")
        dictHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(dictHeader)

        let vocabScroll = makeEditableTextBox(initialText: vocabText, monospace: false)
        let aliasesScroll = makeEditableTextBox(initialText: aliasesJSON, monospace: true)
        self.vocabTextView = vocabScroll.documentView as? NSTextView
        self.aliasesTextView = aliasesScroll.documentView as? NSTextView

        let editorsRow = NSStackView(views: [vocabScroll, aliasesScroll])
        editorsRow.orientation = .horizontal
        editorsRow.spacing = 10
        editorsRow.distribution = .fillEqually
        editorsRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editorsRow.heightAnchor.constraint(equalToConstant: 128),
        ])
        root.addArrangedSubview(editorsRow)
        editorsRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let saveBtn = NSButton(title: "保存词库并立即生效", target: self, action: #selector(onSaveDictionary))
        saveBtn.bezelStyle = .rounded
        saveBtn.bezelColor = .controlAccentColor
        saveBtn.contentTintColor = .white

        let folderBtn = NSButton(title: "打开数据文件夹", target: self, action: #selector(onOpenAppSupportFolder))
        folderBtn.bezelStyle = .rounded

        let dictBtnRow = NSStackView(views: [saveBtn, folderBtn])
        dictBtnRow.orientation = .horizontal
        dictBtnRow.spacing = 8
        root.addArrangedSubview(dictBtnRow)

        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let permHeader = NSTextField(labelWithString: "系统权限状态")
        permHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(permHeader)

        let p = snapshot.permissions
        let rows: [(String, Bool, Selector)] = [
            ("麦克风（用于收音）", p.microphone == .granted, p.microphone == .granted ? #selector(onOpenMicSettings) : #selector(onRequestMicPermission)),
            ("快捷键监听（全局呼出言落）", p.listenEventAccess, p.listenEventAccess ? #selector(onOpenInputMonitoringSettings) : #selector(onRequestInputMonitoring)),
            ("自动输入文字（把识别结果打进输入框）", p.postEventAccess, p.postEventAccess ? #selector(onOpenAccessibilitySettings) : #selector(onRequestPostEvent)),
            ("识别当前输入框（防止误输到别的窗口）", p.accessibilityTrusted, p.accessibilityTrusted ? #selector(onOpenAccessibilitySettings) : #selector(onRequestAccessibility)),
        ]

        for (title, granted, action) in rows {
            let row = makePermissionRow(title: title, granted: granted, action: action)
            root.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        let permButtons = NSStackView()
        permButtons.orientation = .horizontal
        permButtons.spacing = 8

        if !p.allCorePermissionsGranted {
            let pullAll = NSButton(title: "⚡ 一键开启缺失权限", target: self, action: #selector(onRequestAllMissingPermissions))
            pullAll.bezelStyle = .rounded
            pullAll.bezelColor = .controlAccentColor
            pullAll.contentTintColor = .white
            permButtons.addArrangedSubview(pullAll)
        }
        let refreshBtn = NSButton(title: "刷新状态", target: self, action: #selector(onRefreshPermissions))
        refreshBtn.bezelStyle = .rounded
        permButtons.addArrangedSubview(refreshBtn)

        let relaunchBtn = NSButton(title: "重启使权限生效", target: self, action: #selector(onRelaunchApp))
        relaunchBtn.bezelStyle = .rounded
        permButtons.addArrangedSubview(relaunchBtn)

        root.addArrangedSubview(permButtons)
        return root
    }

    private func makeEditableTextBox(initialText: String, monospace: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            : NSFont.systemFont(ofSize: 12.5)
        tv.string = initialText
        tv.delegate = self
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    private func makePermissionRow(title: String, granted: Bool, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12.5)

        let badge = NSTextField(labelWithString: granted ? "✓ 已开启" : "未开启")
        badge.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        badge.textColor = granted ? .systemGreen : .systemOrange

        let btn = NSButton(title: granted ? "查看设置" : "去开启", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, badge, btn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeLabeledRow(_ title: String, control: () -> NSView) -> NSView {
        let label = NSTextField(labelWithString: "\(title)：")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 102).isActive = true

        let ctrl = control()
        let row = NSStackView(views: [label, ctrl])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    // MARK: - Actions

    @objc private func onTabChanged(_ sender: NSSegmentedControl) {
        selectedTab = sender.selectedSegment
        renderTabContent()
    }

    @objc private func onToggleLaunchAtLogin(_ sender: NSButton) {
        dispatchAction(.setLaunchAtLogin(sender.state == .on))
    }

    @objc private func onOpenLoginItems() {
        dispatchAction(.openLoginItemsSettings)
    }

    @objc private func onTriggerModeChanged(_ sender: NSSegmentedControl) {
        dispatchAction(.setTriggerMode(sender.selectedSegment == 0 ? .toggle : .pushToTalk))
    }

    @objc private func onResetDefaultHotkey() {
        hotkeyRecorder?.cancelRecording()
        dispatchAction(.setHotkeyBinding(.defaultBinding))
    }

    @objc private func onPresetRightCommand() {
        hotkeyRecorder?.cancelRecording()
        dispatchAction(.setHotkeyBinding(.rightCommandPTT))
    }

    @objc private func onPresetRightOption() {
        hotkeyRecorder?.cancelRecording()
        dispatchAction(.setHotkeyBinding(.rightOptionPTT))
    }

    @objc private func onPresetFn() {
        hotkeyRecorder?.cancelRecording()
        dispatchAction(.setHotkeyBinding(.fnPTT))
    }

    @objc private func onPresetCmdShiftD() {
        hotkeyRecorder?.cancelRecording()
        dispatchAction(.setHotkeyBinding(.cmdShiftD))
    }

    @objc private func onSelectDirectTypingMode() {
        dispatchAction(.setTextInputMode(.directTyping))
    }

    @objc private func onSelectClipboardCompatMode() {
        dispatchAction(.setTextInputMode(.clipboardCompatibility))
    }

    @objc private func onLanguagePopupChanged(_ sender: NSPopUpButton) {
        let code: String
        switch sender.indexOfSelectedItem {
        case 1: code = "zh"
        case 2: code = "en"
        default: code = "auto"
        }
        dispatchAction(.setPreferredLanguage(code))
    }

    @objc private func onToggleFeedbackSounds(_ sender: NSButton) {
        dispatchAction(.setPlayFeedbackSounds(sender.state == .on))
    }

    @objc private func onModelIdleUnloadPolicyChanged(_ sender: NSPopUpButton) {
        let policies = ModelIdleUnloadPolicy.allCases
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < policies.count else { return }
        dispatchAction(.setModelIdleUnloadPolicy(policies[idx]))
    }

    @objc private func onImportModel() {
        let panel = NSOpenPanel()
        panel.title = "选择本地 .gguf 语音识别模型"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }
        let copyCheckbox = NSButton(
            checkboxWithTitle: "复制到应用目录（默认取消：原地引用，不额外占空间）",
            target: nil,
            action: nil
        )
        copyCheckbox.state = .off
        panel.accessoryView = copyCheckbox

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let mode: ModelStorageMode = (copyCheckbox.state == .on) ? .copied : .reference
        dispatchAction(.importModel(url: url, storageMode: mode))
    }

    @objc private func onRescanModels() { dispatchAction(.rescanDiscoveredModels) }

    @objc private func onSelectModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dispatchAction(.selectModel(id: id))
    }

    @objc private func onRemoveModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dispatchAction(.removeModel(id: id))
    }

    @objc private func onRelinkModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位缺失的 .gguf 模型文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dispatchAction(.relinkModel(id: id, newURL: url))
    }

    @objc private func onAddDiscoveredModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        dispatchAction(.importModel(url: URL(fileURLWithPath: path), storageMode: .reference))
    }

    @objc private func onSelectSmartAutoMic() { dispatchAction(.setAudioSelection(.smartAuto)) }

    @objc private func onSelectPinnedMic(_ sender: NSButton) {
        guard let uid = sender.identifier?.rawValue else { return }
        dispatchAction(.setAudioSelection(.pinned(deviceUID: uid)))
    }

    @objc private func onSaveDictionary() {
        let vocab = vocabTextView?.string ?? ""
        let aliases = aliasesTextView?.string ?? "{}"
        hasUnsavedDictEdits = false
        dispatchAction(.saveVocabularyAndAliases(vocabText: vocab, aliasesJSON: aliases))
    }

    @objc private func onOpenAppSupportFolder() { dispatchAction(.openConfigFile(.appSupportFolder)) }
    @objc private func onRequestAllMissingPermissions() { dispatchAction(.requestAllMissingPermissions) }
    @objc private func onRequestMicPermission() { dispatchAction(.requestMicrophonePermission) }
    @objc private func onRequestInputMonitoring() { dispatchAction(.requestInputMonitoringPermission) }
    @objc private func onRequestPostEvent() { dispatchAction(.requestPostEventPermission) }
    @objc private func onRequestAccessibility() { dispatchAction(.requestAccessibilityPermission) }
    @objc private func onOpenMicSettings() { dispatchAction(.openSystemSettings(.microphone)) }
    @objc private func onOpenInputMonitoringSettings() { dispatchAction(.openSystemSettings(.inputMonitoring)) }
    @objc private func onOpenAccessibilitySettings() { dispatchAction(.openSystemSettings(.accessibility)) }
    @objc private func onRefreshPermissions() { dispatchAction(.refreshPermissions) }
    @objc private func onRelaunchApp() { dispatchAction(.relaunchApplication) }
}
