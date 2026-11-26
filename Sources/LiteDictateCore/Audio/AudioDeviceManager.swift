import CoreAudio
import Foundation

/// Live CoreAudio input device paired with its transient `AudioDeviceID`.
/// `AudioDeviceID` is NEVER persisted — only `info.uid` (`AudioDeviceUID`) is stored in config.
public struct AudioDeviceEntry: Sendable, Equatable {
    public let deviceID: AudioDeviceID
    public let info: AudioDeviceInfo

    public init(deviceID: AudioDeviceID, info: AudioDeviceInfo) {
        self.deviceID = deviceID
        self.info = info
    }
}

/// Abstraction over CoreAudio HAL device enumeration & hotplug listeners for deterministic testing.
public protocol AudioDeviceProviding: AnyObject, Sendable {
    func enumerateInputDevices() -> [AudioDeviceEntry]
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool
    func installDevicesChangedListener(
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    func removeDevicesChangedListener(_ token: AnyObject)
}

/// Real CoreAudio HAL provider querying `kAudioHardwarePropertyDevices`.
public final class CoreAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private final class ListenerToken: @unchecked Sendable {
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock

        init(
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            block: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.address = address
            self.queue = queue
            self.block = block
        }
    }

    public init() {}

    public func enumerateInputDevices() -> [AudioDeviceEntry] {
        let allIDs = fetchAllAudioDeviceIDs()
        var entries: [AudioDeviceEntry] = []
        entries.reserveCapacity(allIDs.count)

        for deviceID in allIDs {
            let inputChannels = queryInputChannelCount(deviceID: deviceID)
            guard inputChannels > 0 else { continue }
            guard let uid = queryCFStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ), !uid.isEmpty else {
                continue
            }

            let name = queryCFStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? queryCFStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceNameCFString,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? uid

            let modelUID = queryCFStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyModelUID,
                scope: kAudioObjectPropertyScopeGlobal
            )

            let transportRaw = queryUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? kAudioDeviceTransportTypeUnknown

            let sampleRate = queryNominalSampleRate(deviceID: deviceID) ?? 48_000.0
            let transportKind = Self.classifyTransport(
                transportType: transportRaw,
                name: name,
                uid: uid,
                modelUID: modelUID
            )

            let info = AudioDeviceInfo(
                uid: uid,
                name: name,
                transportKind: transportKind,
                inputChannelCount: inputChannels,
                nominalSampleRate: sampleRate
            )
            entries.append(AudioDeviceEntry(deviceID: deviceID, info: info))
        }

        return entries
    }

    public func deviceID(forUID uid: String) -> AudioDeviceID? {
        enumerateInputDevices().first(where: { $0.info.uid == uid })?.deviceID
    }

    public func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard let alive = queryUInt32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return false
        }
        return alive != 0
    }

    public func installDevicesChangedListener(
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // CoreAudio invokes the block asynchronously on `queue` (audioControlQueue),
        // never blocking the HAL notification thread and never touching AUHAL synchronously.
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            return nil
        }
        return ListenerToken(address: address, queue: queue, block: block)
    }

    public func removeDevicesChangedListener(_ token: AnyObject) {
        guard let listener = token as? ListenerToken else { return }
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listener.queue,
            listener.block
        )
    }

    public static func classifyTransport(
        transportType: UInt32,
        name: String,
        uid: String,
        modelUID: String? = nil
    ) -> AudioTransportKind {
        switch transportType {
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeDisplayPort:
            return .usb
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuity
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default:
            if isLikelyContinuityDevice(name: name, uid: uid, modelUID: modelUID) {
                return .continuity
            }
            return .other
        }
    }

    private static func isLikelyContinuityDevice(name: String, uid: String, modelUID: String?) -> Bool {
        let combined = [name, uid, modelUID ?? ""].joined(separator: " ").lowercased()
        return combined.contains("continuity")
            || combined.contains("iphone")
            || combined.contains("ipad")
    }

    // MARK: - CoreAudio Property Queries

    private func fetchAllAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        let dataStatus = deviceIDs.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                base
            )
        }
        guard dataStatus == noErr else { return [] }
        return deviceIDs
    }

    private func queryInputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer)
        guard dataStatus == noErr else { return 0 }

        let ablPtr = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        var channels = 0
        for buf in buffers {
            channels += Int(buf.mNumberChannels)
        }
        return channels
    }

    private func queryNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        for scope in [kAudioDevicePropertyScopeInput, kAudioObjectPropertyScopeGlobal] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var rate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
            if status == noErr, rate > 0 {
                return rate
            }
        }
        return nil
    }

    private func queryUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func queryCFStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedString) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let retained = unmanagedString else { return nil }
        return retained.takeRetainedValue() as String
    }
}

/// Manages CoreAudio input device discovery, transport classification, hotplug observation,
/// and smartAuto / pinned(deviceUID) selection policies.
public final class AudioDeviceManager: AudioDeviceManaging, @unchecked Sendable {
    public let controlQueue: DispatchQueue
    private let provider: AudioDeviceProviding

    private let lock = NSLock()
    private var listenerToken: AnyObject?
    private var primaryObserver: (@Sendable ([AudioDeviceInfo]) -> Void)?
    private var internalObservers: [UUID: @Sendable ([AudioDeviceInfo]) -> Void] = [:]

    public convenience init(
        controlQueue: DispatchQueue = DispatchQueue(
            label: "io.github.litedictate.audio.control",
            qos: .userInitiated
        )
    ) {
        self.init(provider: CoreAudioDeviceProvider(), controlQueue: controlQueue)
    }

    public init(
        provider: AudioDeviceProviding,
        controlQueue: DispatchQueue = DispatchQueue(
            label: "io.github.litedictate.audio.control",
            qos: .userInitiated
        )
    ) {
        self.provider = provider
        self.controlQueue = controlQueue
    }

    deinit {
        tearDownHardwareListener()
    }

    public func availableInputDevices() -> [AudioDeviceInfo] {
        Self.sortDevices(provider.enumerateInputDevices().map(\.info))
    }

    public func availableInputDeviceEntries() -> [AudioDeviceEntry] {
        let entries = provider.enumerateInputDevices()
        return entries.sorted { lhs, rhs in
            Self.deviceSortPredicate(lhs.info, rhs.info)
        }
    }

    public func deviceID(forUID uid: String) -> AudioDeviceID? {
        provider.deviceID(forUID: uid)
    }

    public func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        provider.isDeviceAlive(deviceID)
    }

    /// Resolves the active microphone according to `.smartAuto` or `.pinned(deviceUID:)`.
    /// - `.smartAuto`: prioritizes `.usb` > `.builtIn`, explicitly skipping `.bluetooth`,
    ///   `.continuity`, `.virtual`, and `.other` (0 Bluetooth HFP switches).
    /// - `.pinned(deviceUID)`: resolves stable `AudioDeviceUID`; flags `isBluetoothHFPWarning`
    ///   for Bluetooth mics; if offline, falls back temporarily to `.smartAuto` with a notice
    ///   while preserving the pinned UID config (auto-restores once replugged).
    public func resolveDevice(for mode: AudioSelectionMode) -> AudioDeviceResolution {
        let devices = availableInputDevices()
        return Self.resolve(mode: mode, from: devices)
    }

    public static func resolve(
        mode: AudioSelectionMode,
        from devices: [AudioDeviceInfo]
    ) -> AudioDeviceResolution {
        let sorted = sortDevices(devices)
        switch mode {
        case .smartAuto:
            let selected = selectSmartAuto(from: sorted)
            return AudioDeviceResolution(
                device: selected,
                didFallbackFromPinned: false,
                fallbackNotice: nil,
                isBluetoothHFPWarning: false
            )

        case .pinned(let deviceUID):
            if let pinned = sorted.first(where: { $0.uid == deviceUID }) {
                return AudioDeviceResolution(
                    device: pinned,
                    didFallbackFromPinned: false,
                    fallbackNotice: nil,
                    isBluetoothHFPWarning: pinned.transportKind == .bluetooth
                )
            }

            // Pinned external mic is unplugged/offline: temporarily fall back to smartAuto
            // without overwriting the saved pinnedUID config.
            let fallback = selectSmartAuto(from: sorted)
            let notice: String
            if let fallback {
                notice = "已钉选的麦克风当前离线，已临时切换至「\(fallback.name)」，重新插入后将自动恢复。"
            } else {
                notice = "已钉选的麦克风当前离线，且未检测到可用的备用麦克风。"
            }
            return AudioDeviceResolution(
                device: fallback,
                didFallbackFromPinned: true,
                fallbackNotice: notice,
                isBluetoothHFPWarning: false
            )
        }
    }

    public func startObservingChanges(_ onChange: @escaping @Sendable ([AudioDeviceInfo]) -> Void) {
        lock.lock()
        primaryObserver = onChange
        ensureHardwareListenerLocked()
        lock.unlock()
    }

    public func stopObservingChanges() {
        lock.lock()
        primaryObserver = nil
        tearDownHardwareListenerIfUnusedLocked()
        lock.unlock()
    }

    /// Secondary internal observer registration (used by `AudioCaptureManager` for mid-recording unplug detection
    /// without clobbering the UI/Core `startObservingChanges` callback).
    @discardableResult
    internal func addInternalObserver(
        _ handler: @escaping @Sendable ([AudioDeviceInfo]) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        internalObservers[id] = handler
        ensureHardwareListenerLocked()
        lock.unlock()
        return id
    }

    internal func removeInternalObserver(id: UUID) {
        lock.lock()
        internalObservers.removeValue(forKey: id)
        tearDownHardwareListenerIfUnusedLocked()
        lock.unlock()
    }

    /// Triggers asynchronous device refresh on `controlQueue` (called by CoreAudio listener or tests).
    public func notifyDevicesChangedAsync() {
        controlQueue.async { [weak self] in
            self?.dispatchDeviceChangeOnControlQueue()
        }
    }

    private func dispatchDeviceChangeOnControlQueue() {
        let devices = availableInputDevices()
        lock.lock()
        let primary = primaryObserver
        let internals = Array(internalObservers.values)
        lock.unlock()

        primary?(devices)
        for observer in internals {
            observer(devices)
        }
    }

    private func ensureHardwareListenerLocked() {
        guard listenerToken == nil else { return }
        listenerToken = provider.installDevicesChangedListener(on: controlQueue) { [weak self] in
            // Always dispatch asynchronously on controlQueue so CoreAudio never executes
            // AUHAL teardown/rebuilds synchronously inside its HAL property callback.
            self?.notifyDevicesChangedAsync()
        }
    }

    private func tearDownHardwareListenerIfUnusedLocked() {
        guard primaryObserver == nil, internalObservers.isEmpty else { return }
        if let token = listenerToken {
            listenerToken = nil
            provider.removeDevicesChangedListener(token)
        }
    }

    private func tearDownHardwareListener() {
        lock.lock()
        let token = listenerToken
        listenerToken = nil
        primaryObserver = nil
        internalObservers.removeAll()
        lock.unlock()

        if let token {
            provider.removeDevicesChangedListener(token)
        }
    }

    private static func selectSmartAuto(from sortedDevices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        if let usb = sortedDevices.first(where: { $0.transportKind == .usb }) {
            return usb
        }
        if let builtIn = sortedDevices.first(where: { $0.transportKind == .builtIn }) {
            return builtIn
        }
        return nil
    }

    private static func sortDevices(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.sorted(by: deviceSortPredicate)
    }

    private static func deviceSortPredicate(_ lhs: AudioDeviceInfo, _ rhs: AudioDeviceInfo) -> Bool {
        let lp = transportSortPriority(lhs.transportKind)
        let rp = transportSortPriority(rhs.transportKind)
        if lp != rp { return lp < rp }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.uid < rhs.uid
    }

    private static func transportSortPriority(_ kind: AudioTransportKind) -> Int {
        switch kind {
        case .usb: return 0
        case .builtIn: return 1
        case .bluetooth: return 2
        case .continuity: return 3
        case .virtual: return 4
        case .other: return 5
        }
    }
}
