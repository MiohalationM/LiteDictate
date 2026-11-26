import AppKit
import LiteDictateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var stateStore: AppStateStore?
    private var controller: AppController?
    private var statusBarController: StatusBarController?
    private var recordingOverlay: RecordingOverlay?
    private var recoveryPanel: RecoveryPanel?
    private var settingsWindowController: SettingsWindowController?
    private var subscriptionID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = AppStateStore()
        let audioDeviceManager = AudioDeviceManager()
        let audioCapture = AudioCaptureManager(deviceManager: audioDeviceManager)
        let hotkeyController = HotkeyController()
        let permissionManager = PermissionManager()
        let focusMonitor = FocusMonitor()
        let clipboardInjector = ClipboardInjector(allowArbitraryBoundedSnapshot: true)
        let directInjector = DirectTextInjector(clipboardFallback: clipboardInjector)
        let workerSupervisor = WorkerSupervisor()

        let controller = AppController(
            stateStore: store,
            audioDeviceManager: audioDeviceManager,
            audioCapture: audioCapture,
            hotkeyController: hotkeyController,
            permissionManager: permissionManager,
            focusMonitor: focusMonitor,
            directInjector: directInjector,
            clipboardInjector: clipboardInjector,
            workerSupervisor: workerSupervisor,
            modelProber: workerSupervisor,
            onCaptureReadySound: {
                DispatchQueue.main.async {
                    if let sound = NSSound(named: NSSound.Name("Tink")) {
                        sound.stop()
                        sound.currentTime = 0
                        sound.volume = 0.25
                        sound.play()
                    }
                }
            },
            onCommitSuccessSound: {
                DispatchQueue.main.async {
                    if let sound = NSSound(named: NSSound.Name("Pop")) {
                        sound.stop()
                        sound.currentTime = 0
                        sound.volume = 0.22
                        sound.play()
                    }
                }
            },
            onLimitTruncatedSound: {
                DispatchQueue.main.async {
                    if let sound = NSSound(named: NSSound.Name("Pop")) {
                        sound.stop()
                        sound.currentTime = 0
                        sound.volume = 0.30
                        sound.play()
                    }
                }
            },
            openSettingsWindowHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.openOrFocusSettingsWindow()
                }
            }
        )

        let dispatch: (AppActionCommand) -> Void = { [weak controller] command in
            controller?.dispatch(command)
        }

        let statusBar = StatusBarController(dispatchAction: dispatch)
        // Both overlays are 100% lazy (zero NSPanels allocated until actually displayed!).
        let overlay = RecordingOverlay()
        let recovery = RecoveryPanel(dispatchAction: dispatch)

        self.stateStore = store
        self.controller = controller
        self.statusBarController = statusBar
        self.recordingOverlay = overlay
        self.recoveryPanel = recovery

        self.subscriptionID = store.subscribe { [weak self] snapshot in
            guard let self else { return }
            self.statusBarController?.render(snapshot)
            self.recordingOverlay?.render(snapshot.overlay)
            self.recoveryPanel?.render(snapshot.recovery)
            self.settingsWindowController?.render(snapshot)
        }

        controller.start()
    }

    private func openOrFocusSettingsWindow() {
        if let existing = settingsWindowController {
            existing.present()
            return
        }
        guard let store = stateStore, let controller else { return }

        let settings = SettingsWindowController(
            initialSnapshot: store.snapshot,
            dispatchAction: { [weak controller] command in
                controller?.dispatch(command)
            },
            loadVocabAndAliases: { [weak controller] in
                controller?.loadVocabularyAndAliasesText() ?? ("", "{}\n")
            },
            onDidClose: { [weak self] in
                // Release SettingsWindowController completely when closed so idle RAM returns to <= 20 MB!
                self?.settingsWindowController = nil
            }
        )
        self.settingsWindowController = settings
        settings.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let id = subscriptionID {
            stateStore?.unsubscribe(id)
        }
        settingsWindowController?.close()
        settingsWindowController = nil
        controller?.dispatch(.prepareForQuit)
    }
}
