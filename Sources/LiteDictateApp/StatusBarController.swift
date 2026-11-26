import AppKit
import LiteDictateCore
import UniformTypeIdentifiers

/// Pure-AppKit `NSStatusItem` + `NSMenu` shell with friendly everyday Chinese copy.
/// Strictly renders immutable `AppStateSnapshot` and dispatches `AppActionCommand`.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private enum MenuBarIconStyle: Hashable {
        case idleTemplate
        case recording
        case transcribing
        case alert
        case secureInputPaused
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
        old.workerFootprintBytes != new.workerFootprintBytes ||
        old.isSecureInputPaused != new.isSecureInputPaused ||
        old.activeModelID != new.activeModelID ||
        old.models != new.models ||
        old.discoveredModels != new.discoveredModels ||
        old.isImportingModel != new.isImportingModel ||
        old.lastErrorMessage != new.lastErrorMessage ||
        old.lastNoticeMessage != new.lastNoticeMessage ||
        old.audioSelection != new.audioSelection ||
        old.availableDevices != new.availableDevices ||
        old.resolvedDevice != new.resolvedDevice ||
        old.isBluetoothWarningActive != new.isBluetoothWarningActive ||
        old.hotkey != new.hotkey ||
        old.preferredLanguage != new.preferredLanguage ||
        old.inputMode != new.inputMode ||
        old.launchAtLogin != new.launchAtLogin ||
        old.hasLastCommittedText != new.hasLastCommittedText ||
        old.permissions != new.permissions
    }

    private func iconStyle(for snapshot: AppStateSnapshot) -> MenuBarIconStyle {
        if snapshot.isSecureInputPaused {
            return .secureInputPaused
        }
        switch snapshot.phase {
        case .arming, .recording, .draining:
            return .recording
        case .waitingWorkerReady, .transcribing, .validating, .awaitingPreCommitReadiness, .preparingInjection, .revalidating, .commitStarted:
            return .transcribing
        case .recovery:
            return .alert
        case .idle:
            if snapshot.memoryPressure == .critical || snapshot.activeModel?.isFileMissing == true || snapshot.lastErrorMessage != nil {
                return .alert
            }
            return .idleTemplate
        }
    }

    private func updateStatusIcon(_ snapshot: AppStateSnapshot) {
        guard let button = statusItem.button else { return }
        let style = iconStyle(for: snapshot)
        if currentIconStyle != style {
            button.image = iconImage(for: style)
            button.imagePosition = .imageOnly
            button.title = ""
            currentIconStyle = style
        }
        button.appearsDisabled = (style == .secureInputPaused)
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
            let primaryColor: NSColor
            let outerAlpha: CGFloat
            let innerAlpha: CGFloat
            let dotColor: NSColor
            let drawPausedSlash: Bool

            switch style {
            case .idleTemplate:
                primaryColor = .black
                outerAlpha = 0.72
                innerAlpha = 1.0
                dotColor = .black
                drawPausedSlash = false
            case .recording:
                primaryColor = .systemRed
                outerAlpha = 0.72
                innerAlpha = 1.0
                dotColor = .systemRed
                drawPausedSlash = false
            case .transcribing:
                primaryColor = .systemBlue
                outerAlpha = 0.72
                innerAlpha = 1.0
                dotColor = .systemBlue
                drawPausedSlash = false
            case .alert:
                primaryColor = .systemOrange
                outerAlpha = 0.72
                innerAlpha = 1.0
                dotColor = .systemOrange
                drawPausedSlash = false
            case .secureInputPaused:
                primaryColor = .black
                outerAlpha = 0.36
                innerAlpha = 0.55
                dotColor = NSColor.black.withAlphaComponent(0.55)
                drawPausedSlash = true
            }

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
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            if drawPausedSlash {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.4, y: 15.2))
                slash.line(to: NSPoint(x: 15.6, y: 2.4))
                slash.lineWidth = 1.45
                slash.lineCapStyle = .round
                NSColor.black.withAlphaComponent(0.88).setStroke()
                slash.stroke()
            }

            return true
        }
        image.isTemplate = (style == .idleTemplate || style == .secureInputPaused)
        image.accessibilityDescription = "言落"
        return image
    }

    private func rebuildMenu(_ snapshot: AppStateSnapshot) {
        menu.removeAllItems()

        // 1. Friendly Status Header
        let statusLine: String
        if snapshot.memoryPressure == .critical {
            statusLine = "言落 · 系统内存紧张，已暂停后台引擎"
        } else if snapshot.workerState == .stopped {
            statusLine = "言落 · 待命中（零模型占用）"
        } else if snapshot.workerState == .warmModel {
            statusLine = "言落 · 已就绪（模型待机中）"
        } else {
            statusLine = "言落 · \(snapshot.workerState.displayTitle)"
        }
        let headerItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if snapshot.isSecureInputPaused {
            let secItem = NSMenuItem(title: "当前在密码输入框中，已暂停语音输入", action: nil, keyEquivalent: "")
            secItem.isEnabled = false
            menu.addItem(secItem)
        }
        if let err = snapshot.lastErrorMessage, !err.isEmpty {
            let errItem = NSMenuItem(title: "⚠ \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        } else if let notice = snapshot.lastNoticeMessage, !notice.isEmpty {
            let noticeItem = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            noticeItem.isEnabled = false
            menu.addItem(noticeItem)
        }

        menu.addItem(.separator())

        // Prominent 1-click guided permission setup whenever any core permission is missing.
        if !snapshot.permissions.allCorePermissionsGranted {
            let pullAllTop = NSMenuItem(
                title: "⚡ 开启系统权限以开始使用…",
                action: #selector(onRequestAllMissingPermissions),
                keyEquivalent: ""
            )
            pullAllTop.target = self
            menu.addItem(pullAllTop)
            menu.addItem(.separator())
        }

        // 2. Quick Dictation Toggle
        let toggleTitle: String
        if snapshot.phase == .recording || snapshot.phase == .arming {
            toggleTitle = "停止说话并识别 (\(snapshot.hotkey.displayString))"
        } else {
            toggleTitle = "开始语音输入 (\(snapshot.hotkey.displayString))"
        }
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(onToggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        if snapshot.hasLastCommittedText {
            let copyLastItem = NSMenuItem(
                title: "复制上一次识别文字",
                action: #selector(onCopyLastCommittedText),
                keyEquivalent: ""
            )
            copyLastItem.target = self
            menu.addItem(copyLastItem)
        }

        // 3. Speaking Mode Submenu
        let modeRoot = NSMenuItem(
            title: "说话方式：\(snapshot.hotkey.triggerMode.shortTitle)",
            action: nil,
            keyEquivalent: ""
        )
        let modeMenu = NSMenu()
        let toggleModeItem = NSMenuItem(
            title: HotkeyTriggerMode.toggle.displayTitle,
            action: #selector(onSelectToggleMode),
            keyEquivalent: ""
        )
        toggleModeItem.target = self
        toggleModeItem.state = (snapshot.hotkey.triggerMode == .toggle) ? .on : .off
        modeMenu.addItem(toggleModeItem)

        let pttModeItem = NSMenuItem(
            title: HotkeyTriggerMode.pushToTalk.displayTitle,
            action: #selector(onSelectPTTMode),
            keyEquivalent: ""
        )
        pttModeItem.target = self
        pttModeItem.state = (snapshot.hotkey.triggerMode == .pushToTalk) ? .on : .off
        modeMenu.addItem(pttModeItem)
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        menu.addItem(.separator())

        // 4. Models Submenu
        let activeModelLabel = snapshot.activeModel.map {
            $0.isFileMissing ? "\($0.displayName)（文件缺失）" : $0.displayName
        } ?? "尚未选择"
        let modelRoot = NSMenuItem(title: "语音模型：\(activeModelLabel)", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        populateModelSubmenu(modelMenu, snapshot: snapshot)
        modelRoot.submenu = modelMenu
        menu.addItem(modelRoot)

        // 5. Microphone Submenu
        let micLabel: String
        switch snapshot.audioSelection {
        case .smartAuto:
            let resolved = snapshot.resolvedDevice?.name ?? "无可用麦克风"
            micLabel = "智能选择 (\(resolved))"
        case .pinned:
            let resolved = snapshot.resolvedDevice?.name ?? "已指定（当前离线）"
            micLabel = resolved
        }
        let micRoot = NSMenuItem(title: "麦克风：\(micLabel)", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        populateMicSubmenu(micMenu, snapshot: snapshot)
        micRoot.submenu = micMenu
        menu.addItem(micRoot)

        menu.addItem(.separator())

        // 6. Launch at Login Toggle
        let loginItem: NSMenuItem
        switch snapshot.launchAtLogin {
        case .enabled:
            loginItem = NSMenuItem(title: "开机自动启动", action: #selector(onToggleLaunchAtLogin), keyEquivalent: "")
            loginItem.state = .on
            loginItem.target = self
        case .notRegistered:
            loginItem = NSMenuItem(title: "开机自动启动", action: #selector(onToggleLaunchAtLogin), keyEquivalent: "")
            loginItem.state = .off
            loginItem.target = self
        case .requiresApproval:
            loginItem = NSMenuItem(title: "开机自动启动（需在系统设置批准）…", action: #selector(onOpenLoginItemsSettings), keyEquivalent: "")
            loginItem.state = .mixed
            loginItem.target = self
        case .unavailable:
            loginItem = NSMenuItem(title: "开机自动启动（需从应用程序启动）", action: nil, keyEquivalent: "")
            loginItem.isEnabled = false
        }
        menu.addItem(loginItem)

        // 7. Preferences Window
        let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(onOpenPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        if snapshot.workerState == .warmModel {
            let unloadItem = NSMenuItem(title: "立即释放模型内存", action: #selector(onShutdownWorker), keyEquivalent: "")
            unloadItem.target = self
            menu.addItem(unloadItem)
        }

        // 8. System Permissions Submenu
        let permStatus = snapshot.permissions.allCorePermissionsGranted ? "已全部开启" : "待开启"
        let permRoot = NSMenuItem(title: "系统权限：\(permStatus)", action: nil, keyEquivalent: "")
        let permMenu = NSMenu()
        populatePermissionsSubmenu(permMenu, permissions: snapshot.permissions)
        permRoot.submenu = permMenu
        menu.addItem(permRoot)

        menu.addItem(.separator())

        // 9. Quit
        let quitItem = NSMenuItem(title: "退出言落", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
    @objc private func onCopyLastCommittedText() { dispatchAction(.copyLastCommittedText) }
    @objc private func onShutdownWorker() { dispatchAction(.shutdownWorkerNow) }
    @objc private func onRescanModels() { dispatchAction(.rescanDiscoveredModels) }
    @objc private func onSelectSmartAutoMic() { dispatchAction(.setAudioSelection(.smartAuto)) }
    @objc private func onSelectToggleMode() { dispatchAction(.setTriggerMode(.toggle)) }
    @objc private func onSelectPTTMode() { dispatchAction(.setTriggerMode(.pushToTalk)) }
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
