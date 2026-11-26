import AppKit
import LiteDictateCore
import UniformTypeIdentifiers

/// Pure-AppKit `NSStatusItem` + `NSMenu` shell with friendly everyday Chinese copy.
/// Strictly renders immutable `AppStateSnapshot` and dispatches `AppActionCommand`.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private enum MenuBarIconStyle: Hashable {
        case idleTemplate
    }

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let dispatchAction: (AppActionCommand) -> Void
    private var latestSnapshot: AppStateSnapshot = AppStateSnapshot()
    private var currentIconStyle: MenuBarIconStyle?
    private var cachedIcons: [MenuBarIconStyle: NSImage] = [:]

    init(dispatchAction: @escaping (AppActionCommand) -> Void) {
        self.dispatchAction = dispatchAction
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self

        if let button = statusItem.button {
            let icon = iconImage(for: .idleTemplate)
            button.image = icon
            button.imagePosition = .imageOnly
            button.title = ""
            currentIconStyle = .idleTemplate
        }
        statusItem.menu = menu
        render(latestSnapshot)
    }

    func menuWillOpen(_ menu: NSMenu) {
        dispatchAction(.refreshPermissions)
    }

    func render(_ snapshot: AppStateSnapshot) {
        let previous = latestSnapshot
        latestSnapshot = snapshot
        updateStatusIcon(snapshot)
        if shouldRebuildMenu(from: previous, to: snapshot) || menu.items.isEmpty {
            rebuildMenu(snapshot)
        }
    }

    private func shouldRebuildMenu(from old: AppStateSnapshot, to new: AppStateSnapshot) -> Bool {
        old.phase != new.phase ||
        old.workerState != new.workerState ||
        old.memoryPressure != new.memoryPressure ||
        old.isSecureInputPaused != new.isSecureInputPaused ||
        old.activeModelID != new.activeModelID ||
        old.models != new.models ||
        old.discoveredModels != new.discoveredModels ||
        old.isImportingModel != new.isImportingModel ||
        old.lastErrorMessage != new.lastErrorMessage ||
        old.audioSelection != new.audioSelection ||
        old.availableDevices != new.availableDevices ||
        old.resolvedDevice != new.resolvedDevice ||
        old.isBluetoothWarningActive != new.isBluetoothWarningActive ||
        old.hotkey != new.hotkey ||
        old.recentHistory != new.recentHistory ||
        old.permissions != new.permissions
    }

    private func updateStatusIcon(_ snapshot: AppStateSnapshot) {
        guard let button = statusItem.button else { return }
        if currentIconStyle != .idleTemplate {
            button.image = iconImage(for: .idleTemplate)
            button.imagePosition = .imageOnly
            button.title = ""
            currentIconStyle = .idleTemplate
        }
        // Keep the menu bar icon steady monochrome during dictation (the floating pill shows active state).
        // Only dim slightly when permissions are missing or macOS Secure Input pauses global hotkeys.
        button.appearsDisabled = snapshot.isSecureInputPaused || !snapshot.permissions.allCorePermissionsGranted
    }

    private func iconImage(for style: MenuBarIconStyle) -> NSImage {
        if let cached = cachedIcons[style] {
            return cached
        }
        let image = Self.makeMenuBarIcon(style: style)
        cachedIcons[style] = image
        return image
    }

    /// Renders the exact 18×18 `Resources/MenuBarIcon.svg` 5-bar acoustic waveform + bottom falling drop (`言落`)
    /// natively via vector `NSImage(size:flipped:drawingHandler:)` for crisp 1x/2x/3x Retina rendering.
    private static func makeMenuBarIcon(style: MenuBarIconStyle) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let primaryColor = NSColor.black
            let outerAlpha: CGFloat = 0.72
            let innerAlpha: CGFloat = 1.0

            // Exact geometry from Resources/MenuBarIcon.svg (viewBox="0 0 18 18")
            let bars: [(rect: NSRect, alpha: CGFloat)] = [
                (NSRect(x: 2.2, y: 5.8, width: 1.8, height: 4.4), outerAlpha),
                (NSRect(x: 5.1, y: 3.6, width: 1.8, height: 8.4), innerAlpha),
                (NSRect(x: 8.1, y: 2.0, width: 1.8, height: 10.2), innerAlpha),
                (NSRect(x: 11.1, y: 3.6, width: 1.8, height: 8.4), innerAlpha),
                (NSRect(x: 14.0, y: 5.8, width: 1.8, height: 4.4), outerAlpha),
            ]

            for bar in bars {
                primaryColor.withAlphaComponent(bar.alpha).setFill()
                NSBezierPath(roundedRect: bar.rect, xRadius: 0.9, yRadius: 0.9).fill()
            }

            // Falling word-drop dot: <circle cx="9.0" cy="14.9" r="1.45"/>
            let dotRadius: CGFloat = 1.45
            let dotRect = NSRect(
                x: 9.0 - dotRadius,
                y: 14.9 - dotRadius,
                width: dotRadius * 2.0,
                height: dotRadius * 2.0
            )
            primaryColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "言落"
        return image
    }

    private func rebuildMenu(_ snapshot: AppStateSnapshot) {
        menu.removeAllItems()

        // Conditional top alerts — hidden completely during normal operation to keep the menu crisp & compact.
        var hasTopAlert = false
        if !snapshot.permissions.allCorePermissionsGranted {
            let permAlert = NSMenuItem(title: "⚡ 开启系统权限…", action: nil, keyEquivalent: "")
            let permMenu = NSMenu()
            populatePermissionsSubmenu(permMenu, permissions: snapshot.permissions)
            permAlert.submenu = permMenu
            menu.addItem(permAlert)
            hasTopAlert = true
        }
        if snapshot.memoryPressure == .critical {
            let memItem = NSMenuItem(title: "⚠ 系统内存紧张，已暂停识别", action: nil, keyEquivalent: "")
            memItem.isEnabled = false
            menu.addItem(memItem)
            hasTopAlert = true
        }
        if snapshot.isSecureInputPaused {
            let secItem = NSMenuItem(title: "密码输入框中 · 已暂停", action: nil, keyEquivalent: "")
            secItem.isEnabled = false
            menu.addItem(secItem)
            hasTopAlert = true
        }
        if let err = snapshot.lastErrorMessage, !err.isEmpty {
            let errItem = NSMenuItem(title: "⚠ \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            hasTopAlert = true
        }
        if hasTopAlert {
            menu.addItem(.separator())
        }

        // 1. Primary action: Start / Stop Dictation
        let isActiveRecording = (snapshot.phase == .recording || snapshot.phase == .arming)
        let toggleTitle = isActiveRecording
            ? "停止说话 (\(snapshot.hotkey.displayString))"
            : "开始说话 (\(snapshot.hotkey.displayString))"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(onToggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // 2. Recent 5 in-memory transcripts (click to copy; 0 disk, wiped on sleep/lock/quit)
        if !snapshot.recentHistory.isEmpty {
            let historyRoot = NSMenuItem(
                title: "最近识别 (\(snapshot.recentHistory.count))",
                action: nil,
                keyEquivalent: ""
            )
            let historyMenu = NSMenu()
            populateHistorySubmenu(historyMenu, entries: snapshot.recentHistory)
            historyRoot.submenu = historyMenu
            menu.addItem(historyRoot)
        }

        menu.addItem(.separator())

        // 3. Hotkey & Trigger Mode quick switcher
        let modeShort = snapshot.hotkey.triggerMode == .pushToTalk ? "按住" : "开关"
        let hotkeyRoot = NSMenuItem(
            title: "快捷键 · \(modeShort) \(snapshot.hotkey.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        let hotkeyMenu = NSMenu()
        populateHotkeySubmenu(hotkeyMenu, current: snapshot.hotkey)
        hotkeyRoot.submenu = hotkeyMenu
        menu.addItem(hotkeyRoot)

        // 4. Model Submenu (concise label)
        let activeModelLabel: String
        if let model = snapshot.activeModel {
            let base = truncatedMenuLabel(model.displayName, maxLength: 24)
            activeModelLabel = model.isFileMissing ? "\(base)（缺失）" : base
        } else {
            activeModelLabel = "未选择"
        }
        let modelRoot = NSMenuItem(title: "模型 · \(activeModelLabel)", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        populateModelSubmenu(modelMenu, snapshot: snapshot)
        modelRoot.submenu = modelMenu
        menu.addItem(modelRoot)

        // 5. Microphone Submenu (concise resolved name)
        let rawMicName = snapshot.resolvedDevice?.name ?? "未连接"
        let micRoot = NSMenuItem(
            title: "麦克风 · \(truncatedMenuLabel(rawMicName, maxLength: 22))",
            action: nil,
            keyEquivalent: ""
        )
        let micMenu = NSMenu()
        populateMicSubmenu(micMenu, snapshot: snapshot)
        micRoot.submenu = micMenu
        menu.addItem(micRoot)

        menu.addItem(.separator())

        // 6. Preferences & Quit
        let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(onOpenPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "退出言落", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func truncatedMenuLabel(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    private func populateHistorySubmenu(_ submenu: NSMenu, entries: [RecentTranscriptEntry]) {
        for entry in entries {
            let item = NSMenuItem(
                title: entry.menuPreview(maxCharacters: 22),
                action: #selector(onCopyHistoryItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "清空记录",
            action: #selector(onClearRecentHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        submenu.addItem(clearItem)
    }

    private func populateHotkeySubmenu(_ submenu: NSMenu, current: HotkeyBinding) {
        let pttItem = NSMenuItem(
            title: HotkeyTriggerMode.pushToTalk.displayTitle,
            action: #selector(onSelectPTTMode),
            keyEquivalent: ""
        )
        pttItem.target = self
        pttItem.state = (current.triggerMode == .pushToTalk) ? .on : .off
        submenu.addItem(pttItem)

        let toggleItem = NSMenuItem(
            title: HotkeyTriggerMode.toggle.displayTitle,
            action: #selector(onSelectToggleMode),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = (current.triggerMode == .toggle) ? .on : .off
        submenu.addItem(toggleItem)

        submenu.addItem(.separator())

        let presets: [(title: String, binding: HotkeyBinding, selector: Selector)] = [
            ("右 ⌘（按住说话 · 默认）", .rightCommandPTT, #selector(onPresetRightCommandPTT)),
            ("右 ⌥（按住说话）", .rightOptionPTT, #selector(onPresetRightOptionPTT)),
            ("Fn（按住说话）", .fnPTT, #selector(onPresetFnPTT)),
            ("⌘⇧D（按一下开关）", .cmdShiftD, #selector(onPresetCmdShiftD)),
        ]
        for preset in presets {
            let item = NSMenuItem(title: preset.title, action: preset.selector, keyEquivalent: "")
            item.target = self
            let isSelected = (current.kind == preset.binding.kind &&
                              current.keyCode == preset.binding.keyCode &&
                              current.modifiers == preset.binding.modifiers &&
                              current.triggerMode == preset.binding.triggerMode)
            item.state = isSelected ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let customItem = NSMenuItem(title: "自定义快捷键…", action: #selector(onOpenPreferences), keyEquivalent: "")
        customItem.target = self
        submenu.addItem(customItem)
    }

    private func populateModelSubmenu(_ submenu: NSMenu, snapshot: AppStateSnapshot) {
        if snapshot.isImportingModel {
            let busy = NSMenuItem(title: "正在校验并加载模型…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            submenu.addItem(busy)
            submenu.addItem(.separator())
        }

        if snapshot.models.isEmpty {
            let empty = NSMenuItem(title: "尚未导入语音模型（支持 Qwen3-ASR / Whisper / SenseVoice）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for model in snapshot.models {
                let sizeMB = Double(model.fileSizeBytes) / (1024.0 * 1024.0)
                let missingTag = model.isFileMissing ? " [文件缺失]" : ""
                let title = String(format: "%@ (%.0f MB)%@", model.displayName, sizeMB, missingTag)
                let item = NSMenuItem(title: title, action: #selector(onSelectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.id
                item.state = (model.id == snapshot.activeModelID) ? .on : .off
                submenu.addItem(item)

                if model.isFileMissing {
                    let relink = NSMenuItem(title: "   ↳ 重新定位 \(model.displayName)…", action: #selector(onRelinkModel(_:)), keyEquivalent: "")
                    relink.target = self
                    relink.representedObject = model.id
                    submenu.addItem(relink)
                }
            }
        }

        submenu.addItem(.separator())

        let importItem = NSMenuItem(title: "导入本地 .gguf 模型…", action: #selector(onImportModel), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = !snapshot.isImportingModel
        submenu.addItem(importItem)

        if !snapshot.discoveredModels.isEmpty {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: "本机已发现模型（一键启用）：", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            for candidate in snapshot.discoveredModels {
                let sizeMB = Double(candidate.fileSizeBytes) / (1024.0 * 1024.0)
                let title = String(format: "+ %@ (%.0f MB)", candidate.fileName, sizeMB)
                let item = NSMenuItem(title: title, action: #selector(onAddDiscoveredModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = candidate.filePath
                item.isEnabled = !snapshot.isImportingModel
                submenu.addItem(item)
            }
        }

        let rescan = NSMenuItem(title: "重新扫描本机目录", action: #selector(onRescanModels), keyEquivalent: "")
        rescan.target = self
        submenu.addItem(rescan)

        if snapshot.workerState == .warmModel {
            submenu.addItem(.separator())
            let unloadItem = NSMenuItem(title: "立即释放模型内存", action: #selector(onShutdownWorker), keyEquivalent: "")
            unloadItem.target = self
            submenu.addItem(unloadItem)
        }
    }

    private func populateMicSubmenu(_ submenu: NSMenu, snapshot: AppStateSnapshot) {
        let smartItem = NSMenuItem(
            title: "智能选择（推荐：优先外接/内置麦，听歌不降音质）",
            action: #selector(onSelectSmartAutoMic),
            keyEquivalent: ""
        )
        smartItem.target = self
        if case .smartAuto = snapshot.audioSelection {
            smartItem.state = .on
        }
        submenu.addItem(smartItem)
        submenu.addItem(.separator())

        if snapshot.availableDevices.isEmpty {
            let none = NSMenuItem(title: "未检测到输入麦克风", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for device in snapshot.availableDevices {
                let btWarn = device.isBluetoothHFPWarning ? "（听歌可能降音质）" : ""
                let title = "[\(device.transportKind.displayBadge)] \(device.name)\(btWarn)"
                let item = NSMenuItem(title: title, action: #selector(onSelectPinnedMic(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                if case let .pinned(uid) = snapshot.audioSelection, uid == device.uid {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }

        if snapshot.isBluetoothWarningActive {
            submenu.addItem(.separator())
            let warn = NSMenuItem(
                title: "提示：使用蓝牙麦时可能切到通话模式，影响音乐音质",
                action: nil,
                keyEquivalent: ""
            )
            warn.isEnabled = false
            submenu.addItem(warn)
        }
    }

    private func populatePermissionsSubmenu(_ submenu: NSMenu, permissions: PermissionSnapshot) {
        if !permissions.allCorePermissionsGranted {
            let pullAllItem = NSMenuItem(
                title: "⚡ 一键开启所有缺失权限…",
                action: #selector(onRequestAllMissingPermissions),
                keyEquivalent: ""
            )
            pullAllItem.target = self
            submenu.addItem(pullAllItem)
            submenu.addItem(.separator())
        }

        let micOk = permissions.microphone == .granted
        let micItem = NSMenuItem(
            title: "\(micOk ? "✓" : "✗") 麦克风",
            action: micOk ? #selector(onOpenMicSettings) : #selector(onRequestMicPermission),
            keyEquivalent: ""
        )
        micItem.target = self
        submenu.addItem(micItem)

        let listenItem = NSMenuItem(
            title: "\(permissions.listenEventAccess ? "✓" : "✗") 快捷键监听",
            action: permissions.listenEventAccess ? #selector(onOpenInputMonitoringSettings) : #selector(onRequestInputMonitoring),
            keyEquivalent: ""
        )
        listenItem.target = self
        submenu.addItem(listenItem)

        let postItem = NSMenuItem(
            title: "\(permissions.postEventAccess ? "✓" : "✗") 自动输入文字",
            action: permissions.postEventAccess ? #selector(onOpenAccessibilitySettings) : #selector(onRequestPostEvent),
            keyEquivalent: ""
        )
        postItem.target = self
        submenu.addItem(postItem)

        let axItem = NSMenuItem(
            title: "\(permissions.accessibilityTrusted ? "✓" : "✗") 识别当前输入框",
            action: permissions.accessibilityTrusted ? #selector(onOpenAccessibilitySettings) : #selector(onRequestAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        submenu.addItem(axItem)

        submenu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新权限状态", action: #selector(onRefreshPermissions), keyEquivalent: "")
        refresh.target = self
        submenu.addItem(refresh)

        if !permissions.eventTapAlive || !permissions.allCorePermissionsGranted {
            let relaunch = NSMenuItem(
                title: "↻ 重启言落使权限立即生效",
                action: #selector(onRelaunchApp),
                keyEquivalent: ""
            )
            relaunch.target = self
            submenu.addItem(relaunch)
        }
    }

    // MARK: - Actions

    @objc private func onToggleRecording() { dispatchAction(.toggleRecording) }
    @objc private func onCopyHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        dispatchAction(.copyHistoryItem(id: id))
    }
    @objc private func onClearRecentHistory() { dispatchAction(.clearRecentHistory) }
    @objc private func onShutdownWorker() { dispatchAction(.shutdownWorkerNow) }
    @objc private func onRescanModels() { dispatchAction(.rescanDiscoveredModels) }
    @objc private func onSelectSmartAutoMic() { dispatchAction(.setAudioSelection(.smartAuto)) }
    @objc private func onSelectToggleMode() { dispatchAction(.setTriggerMode(.toggle)) }
    @objc private func onSelectPTTMode() { dispatchAction(.setTriggerMode(.pushToTalk)) }
    @objc private func onPresetRightCommandPTT() { dispatchAction(.setHotkeyBinding(.rightCommandPTT)) }
    @objc private func onPresetRightOptionPTT() { dispatchAction(.setHotkeyBinding(.rightOptionPTT)) }
    @objc private func onPresetFnPTT() { dispatchAction(.setHotkeyBinding(.fnPTT)) }
    @objc private func onPresetCmdShiftD() { dispatchAction(.setHotkeyBinding(.cmdShiftD)) }
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
    @objc private func onOpenLoginItemsSettings() { dispatchAction(.openLoginItemsSettings) }
    @objc private func onOpenPreferences() { dispatchAction(.openSettingsWindow) }

    @objc private func onToggleLaunchAtLogin() {
        let shouldEnable = (latestSnapshot.launchAtLogin != .enabled)
        dispatchAction(.setLaunchAtLogin(shouldEnable))
    }

    @objc private func onSelectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dispatchAction(.selectModel(id: id))
    }

    @objc private func onAddDiscoveredModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        dispatchAction(.importModel(url: URL(fileURLWithPath: path), storageMode: .reference))
    }

    @objc private func onSelectPinnedMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        dispatchAction(.setAudioSelection(.pinned(deviceUID: uid)))
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

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let mode: ModelStorageMode = (copyCheckbox.state == .on) ? .copied : .reference
        dispatchAction(.importModel(url: url, storageMode: mode))
    }

    @objc private func onRelinkModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位缺失的 .gguf 模型文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dispatchAction(.relinkModel(id: modelID, newURL: url))
    }

    @objc private func onQuit() {
        dispatchAction(.prepareForQuit)
        NSApp.terminate(nil)
    }
}
