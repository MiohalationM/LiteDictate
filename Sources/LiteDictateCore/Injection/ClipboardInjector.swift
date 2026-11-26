import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Immutable representation of one pasteboard item's whitelisted representations.
public struct PasteboardSnapshotItem: Equatable, Sendable {
    public let representations: [(type: String, data: Data)]

    public init(representations: [(type: String, data: Data)]) {
        self.representations = representations
    }

    public static func == (lhs: PasteboardSnapshotItem, rhs: PasteboardSnapshotItem) -> Bool {
        guard lhs.representations.count == rhs.representations.count else { return false }
        for (a, b) in zip(lhs.representations, rhs.representations) {
            if a.type != b.type || a.data != b.data {
                return false
            }
        }
        return true
    }
}

/// Zero-copy metadata descriptor for one pasteboard item during tiered prescreening.
public struct PasteboardItemMetadata: Equatable, Sendable {
    public let itemIndex: Int
    public let types: [String]

    public init(itemIndex: Int, types: [String]) {
        self.itemIndex = itemIndex
        self.types = types
    }
}

/// Injectable pasteboard abstraction enabling 100% deterministic unit testing of tiered prescreening,
/// 8 MiB snapshot budget, transient markers, `changeCount` revalidation, and restore abandonment.
public protocol PasteboardAccessing: AnyObject, Sendable {
    var changeCount: Int { get }

    /// Pasteboard access permission state (`#available(macOS 15.4, *)` guarded on live pasteboard).
    func accessState() -> PasteboardAccessState

    /// Zero-copy metadata scan returning the declared type identifiers of every item without reading payload bytes.
    func inspectItemMetadata() -> [PasteboardItemMetadata]

    /// Reads payload bytes for a single `(itemIndex, type)` pair after prescreening passes.
    func readData(itemIndex: Int, type: String) -> Data?

    /// Clears pasteboard and writes a single item with the specified `(type, data)` pairs.
    /// Returns the resulting `changeCount`, or `nil` if `writeObjects` failed.
    @discardableResult
    func clearAndWriteSingleItem(_ representations: [(type: String, data: Data)]) -> Int?

    /// Clears pasteboard and writes back all previously snapshotted items.
    /// Returns the resulting `changeCount`, or `nil` if `writeObjects` failed.
    @discardableResult
    func clearAndRestoreItems(_ items: [PasteboardSnapshotItem]) -> Int?

    /// Clears pasteboard leaving it empty. Returns the resulting `changeCount`.
    @discardableResult
    func clearAll() -> Int
}

/// Production `NSPasteboard.general` adapter.
public final class SystemPasteboardAdapter: PasteboardAccessing, @unchecked Sendable {
    public init() {}

    public var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    public func accessState() -> PasteboardAccessState {
        PermissionManager.livePasteboardAccessState()
    }

    public func inspectItemMetadata() -> [PasteboardItemMetadata] {
        guard let items = NSPasteboard.general.pasteboardItems else {
            return []
        }
        return items.enumerated().map { index, item in
            PasteboardItemMetadata(
                itemIndex: index,
                types: item.types.map(\.rawValue)
            )
        }
    }

    public func readData(itemIndex: Int, type: String) -> Data? {
        guard let items = NSPasteboard.general.pasteboardItems,
              itemIndex >= 0,
              itemIndex < items.count
        else {
            return nil
        }
        return items[itemIndex].data(forType: NSPasteboard.PasteboardType(type))
    }

    @discardableResult
    public func clearAndWriteSingleItem(_ representations: [(type: String, data: Data)]) -> Int? {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in representations {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        guard pb.writeObjects([item]) else {
            return nil
        }
        return pb.changeCount
    }

    @discardableResult
    public func clearAndRestoreItems(_ items: [PasteboardSnapshotItem]) -> Int? {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else {
            return pb.changeCount
        }
        var pbItems: [NSPasteboardItem] = []
        pbItems.reserveCapacity(items.count)
        for snapshotItem in items {
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            pbItems.append(item)
        }
        guard pb.writeObjects(pbItems) else {
            return nil
        }
        return pb.changeCount
    }

    @discardableResult
    public func clearAll() -> Int {
        let pb = NSPasteboard.general
        return pb.clearContents()
    }
}

/// Description of the synthetic Cmd+V event pair for testing and production posting.
public struct SyntheticPasteSpec: Equatable, Sendable {
    public let virtualKey: UInt16
    public let flagsRawValue: UInt64
    public let userData: Int64

    public static let standardCmdV = SyntheticPasteSpec(
        virtualKey: HotkeyVirtualKeyCode.ansiV,
        flagsRawValue: CGEventFlags.maskCommand.rawValue,
        userData: LiteDictateConstants.syntheticEventUserData
    )

    public init(virtualKey: UInt16, flagsRawValue: UInt64, userData: Int64) {
        self.virtualKey = virtualKey
        self.flagsRawValue = flagsRawValue
        self.userData = userData
    }
}

/// Injectable synthetic paste poster so tests can inspect the exact Cmd+V event parameters
/// without injecting keystrokes into the host desktop.
public protocol SyntheticPastePosting: Sendable {
    func postCmdV(_ spec: SyntheticPasteSpec) -> Bool
}

/// Production synthetic `⌘V` poster gated on `CGPreflightPostEventAccess()` (P0-1),
/// using `.privateState`, explicit `.maskCommand` ONLY,
/// and `eventSourceUserData = 0x4C444943` ("LDIC") on both `keyDown` and `keyUp`.
public struct LiveSyntheticPastePoster: SyntheticPastePosting, Sendable {
    private let postEventAccessProbe: @Sendable () -> Bool

    public init(
        postEventAccessProbe: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        self.postEventAccessProbe = postEventAccessProbe
    }

    public func postCmdV(_ spec: SyntheticPasteSpec) -> Bool {
        // P0-1: Refuse to blindly post Cmd+V when post-event TCC permission is denied.
        guard postEventAccessProbe() else {
            return false
        }

        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(spec.virtualKey),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(spec.virtualKey),
                  keyDown: false
              )
        else {
            return false
        }

        let flags = CGEventFlags(rawValue: spec.flagsRawValue)
        keyDown.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: spec.userData)

        keyUp.flags = flags
        keyUp.setIntegerValueField(.eventSourceUserData, value: spec.userData)

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Unified clipboard `⌘V` injector (ZERO cross-process AX direct text writing).
///
/// Architectural guarantees:
/// - Dedicated serial `DispatchQueue` state machine: `Idle -> Preparing -> PasteDispatched -> AwaitingRestore -> Idle`.
/// - NEVER cancels an in-flight restore timer; queued callers wait asynchronously via `whenIdle`.
/// - Zero-copy tiered `types` prescreening before reading any payload bytes; 8 MiB hard snapshot budget.
/// - Writes `org.nspasteboard.TransientType` & `org.nspasteboard.AutoGeneratedType` alongside UTF-8 text.
/// - Restores snapshot ONLY if `changeCount` still matches our write (abandons if user copied something new).
/// - Strictly respects WeType 5 red lines and terminal newline/control-character safety guard.
public final class ClipboardInjector: ClipboardInjecting, @unchecked Sendable {
    public enum TransactionState: Equatable, Sendable {
        case idle
        case preparing
        case pasteDispatched
        case awaitingRestore
    }

    public enum PasteboardMarkerType {
        public static let utf8String = NSPasteboard.PasteboardType.string.rawValue
        public static let transient = "org.nspasteboard.TransientType"
        public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
        public static let concealed = "org.nspasteboard.ConcealedType"
    }

    /// Standard terminal application bundle identifiers (case-insensitive normalized).
    public static let defaultTerminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.googlecode.iterm2.nightly",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "dev.warp.warp-preview",
        "dev.warp.warp",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
        "com.termius-dmg.mac",
        "com.panic.prompt3",
    ]

    /// Whitelisted safe pasteboard types eligible for bounded 8 MiB snapshotting.
    public static let whitelistedSnapshotTypes: Set<String> = [
        NSPasteboard.PasteboardType.string.rawValue,
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.html.rawValue,
        NSPasteboard.PasteboardType.URL.rawValue,
        NSPasteboard.PasteboardType.fileURL.rawValue,
        NSPasteboard.PasteboardType.tabularText.rawValue,
        "public.url-name",
        "WebURLsWithTitlesPboardType",
        "org.chromium.source-url",
    ]

    /// High-risk large image / binary media types rejected during zero-copy metadata prescreening.
    public static let riskyLargeImageTypes: Set<String> = [
        NSPasteboard.PasteboardType.tiff.rawValue,
        NSPasteboard.PasteboardType.png.rawValue,
        NSPasteboard.PasteboardType.pdf.rawValue,
        NSPasteboard.PasteboardType.rtfd.rawValue,
        "public.jpeg",
        "public.heic",
        "public.heif",
        "public.image",
        "com.apple.pict",
        "public.movie",
        "public.audio",
        "com.apple.flat-rtfd",
        "NeXT TIFF v4.0 pasteboard type",
    ]

    /// Explicit file promise pasteboard types rejected during zero-copy metadata prescreening.
    public static let filePromiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "NSPromiseContentsPboardType",
        "NSFilesPromisePboardType",
    ]

    /// Benign marker-only types that carry no user content by themselves.
    private static let benignMarkerOnlyTypes: Set<String> = [
        PasteboardMarkerType.transient,
        PasteboardMarkerType.autoGenerated,
        "org.nspasteboard.source",
        "com.apple.is-remote-clipboard",
    ]

    private struct ActiveTransaction {
        let transactionID: UInt64
        let expectedChangeCount: Int
        let snapshot: [PasteboardSnapshotItem]
        let wasOriginallyEmpty: Bool
    }

    private let pasteboard: PasteboardAccessing
    private let pastePoster: SyntheticPastePosting
    private let postEventAccessProbe: @Sendable () -> Bool
    private let terminalBundleIDs: Set<String>
    private let snapshotBudgetBytes: Int
    private let minRestoreDelayMs: Int
    private let maxRestoreDelayMs: Int

    private let clipboardQueue = DispatchQueue(
        label: "io.github.litedictate.clipboard.serial",
        qos: .userInteractive
    )
    private let callbackQueue = DispatchQueue(
        label: "io.github.litedictate.clipboard.callbacks",
        qos: .userInteractive
    )

    private let isBusyAtomic = AtomicBool(false)

    // Exclusively owned by `clipboardQueue`.
    private var state: TransactionState = .idle
    private var nextTransactionID: UInt64 = 0
    private var activeTransaction: ActiveTransaction?
    private var idleWaiters: [@Sendable () -> Void] = []

    public init(
        pasteboard: PasteboardAccessing = SystemPasteboardAdapter(),
        pastePoster: SyntheticPastePosting = LiveSyntheticPastePoster(),
        postEventAccessProbe: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        extraTerminalBundleIDs: Set<String> = [],
        snapshotBudgetBytes: Int = LiteDictateConstants.clipboardSnapshotBudgetBytes,
        minRestoreDelayMs: Int = LiteDictateConstants.minPasteRestoreDelayMs,
        maxRestoreDelayMs: Int = LiteDictateConstants.maxPasteRestoreDelayMs
    ) {
        self.pasteboard = pasteboard
        self.pastePoster = pastePoster
        self.postEventAccessProbe = postEventAccessProbe
        self.terminalBundleIDs = Self.defaultTerminalBundleIDs.union(
            extraTerminalBundleIDs.map { $0.lowercased() }
        )
        self.snapshotBudgetBytes = snapshotBudgetBytes
        self.minRestoreDelayMs = max(0, minRestoreDelayMs)
        self.maxRestoreDelayMs = max(self.minRestoreDelayMs, maxRestoreDelayMs)
    }

    public var readiness: ClipboardReadiness {
        isBusyAtomic.load(ordering: .acquire) ? .busy : .idle
    }

    public func whenIdle(_ callback: @escaping @Sendable () -> Void) {
        clipboardQueue.async {
            if self.state == .idle {
                self.callbackQueue.async {
                    callback()
                }
            } else {
                self.idleWaiters.append(callback)
            }
        }
    }

    public func isTerminalApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return terminalBundleIDs.contains(bundleIdentifier.lowercased())
    }

    /// Returns `false` if text contains `\n`, `\r`, any control char `< 0x20` (except `\t`),
    /// `0x7F` (DEL), or Unicode line/paragraph separators (`U+0085`, `U+2028`, `U+2029`).
    public func isTextSafeForTerminal(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { // Horizontal tab '\t' is explicitly allowed.
                continue
            }
            if v < 0x20 || v == 0x7F || v == 0x85 || v == 0x2028 || v == 0x2029 {
                return false
            }
        }
        return true
    }

    public func preparePaste(
        text: String,
        targetBundleIdentifier: String?,
        completion: @escaping @Sendable (InjectionPreparationResult) -> Void
    ) {
        clipboardQueue.async { [self] in
            // 1. Terminal safety guard BEFORE touching clipboard.
            if self.isTerminalApplication(bundleIdentifier: targetBundleIdentifier),
               !self.isTextSafeForTerminal(text)
            {
                self.callbackQueue.async {
                    completion(.blocked(.terminalUnsafeCharacters))
                }
                return
            }

            // 2. Pasteboard permission guard (macOS 15.4+ `.alwaysDeny`).
            if self.pasteboard.accessState() == .alwaysDeny {
                self.callbackQueue.async {
                    completion(.blocked(.pasteboardAccessDenied))
                }
                return
            }

            // 3. Serialize strictly — never preempt an in-flight prepare or restore timer.
            guard self.state == .idle else {
                self.idleWaiters.append { [weak injector = self] in
                    injector?.preparePaste(
                        text: text,
                        targetBundleIdentifier: targetBundleIdentifier,
                        completion: completion
                    )
                }
                return
            }

            // 4. Tier 1: Zero-copy metadata prescreening of all pasteboard types.
            let metadataItems = self.pasteboard.inspectItemMetadata()
            if let blockReason = Self.prescreenMetadata(metadataItems) {
                self.callbackQueue.async {
                    completion(.blocked(blockReason))
                }
                return
            }

            // 5. Tier 2: Bounded 8 MiB snapshot of whitelisted formats ONLY (P1-3 & P1-4).
            var snapshot: [PasteboardSnapshotItem] = []
            var totalBytes = 0

            for meta in metadataItems {
                // P1-3: Never silently destroy custom non-whitelisted representations even when text is also present.
                let hasUnsupportedNonMarker = meta.types.contains {
                    !Self.whitelistedSnapshotTypes.contains($0) && !Self.benignMarkerOnlyTypes.contains($0)
                }
                if hasUnsupportedNonMarker {
                    snapshot.removeAll(keepingCapacity: false)
                    self.callbackQueue.async {
                        completion(.blocked(.largeImageOrUnsupported))
                    }
                    return
                }

                let whitelisted = meta.types.filter { Self.whitelistedSnapshotTypes.contains($0) }
                if whitelisted.isEmpty {
                    continue
                }

                var reps: [(type: String, data: Data)] = []
                reps.reserveCapacity(whitelisted.count)

                for type in whitelisted {
                    guard let data = self.pasteboard.readData(itemIndex: meta.itemIndex, type: type) else {
                        continue
                    }
                    // P1-4: Overflow-safe budget check BEFORE adding to `totalBytes`.
                    if Self.wouldExceedSnapshotBudget(
                        currentBytes: totalBytes,
                        addingBytes: data.count,
                        budgetBytes: self.snapshotBudgetBytes
                    ) {
                        // Immediately abort and free accumulated snapshot memory -> RecoveryPanel.
                        reps.removeAll(keepingCapacity: false)
                        snapshot.removeAll(keepingCapacity: false)
                        self.callbackQueue.async {
                            completion(.blocked(.snapshotExceededBudget))
                        }
                        return
                    }
                    totalBytes += data.count
                    reps.append((type: type, data: data))
                }

                if !reps.isEmpty {
                    snapshot.append(PasteboardSnapshotItem(representations: reps))
                } else {
                    // Whitelisted types were declared on this item, yet none could be read
                    // (e.g., macOS 15.4+ `.ask` permission denied or unresponsive source app).
                    // Abort BEFORE touching the clipboard so we never wipe user content.
                    snapshot.removeAll(keepingCapacity: false)
                    self.callbackQueue.async {
                        completion(.blocked(.pasteboardAccessDenied))
                    }
                    return
                }
            }

            // 6. Write text alongside TransientType & AutoGeneratedType markers (P1-2: check writeObjects return).
            let preWriteChangeCount = self.pasteboard.changeCount
            let utf8Data = Data(text.utf8)
            guard let newChangeCount = self.pasteboard.clearAndWriteSingleItem([
                (type: PasteboardMarkerType.utf8String, data: utf8Data),
                (type: PasteboardMarkerType.transient, data: Data()),
                (type: PasteboardMarkerType.autoGenerated, data: Data()),
            ]) else {
                // `writeObjects` failed: do NOT advance to `.preparing`; best-effort restore if clipboard changed.
                if self.pasteboard.changeCount != preWriteChangeCount, !snapshot.isEmpty {
                    _ = self.pasteboard.clearAndRestoreItems(snapshot)
                }
                self.callbackQueue.async {
                    completion(.blocked(.pasteboardAccessDenied))
                }
                return
            }

            self.nextTransactionID &+= 1
            let txID = self.nextTransactionID
            self.activeTransaction = ActiveTransaction(
                transactionID: txID,
                expectedChangeCount: newChangeCount,
                snapshot: snapshot,
                wasOriginallyEmpty: metadataItems.isEmpty
            )
            self.transitionState(.preparing)

            let preparation = InjectionPreparation(
                transactionID: txID,
                expectedChangeCount: newChangeCount,
                hadSnapshot: !snapshot.isEmpty
            )
            self.callbackQueue.async {
                completion(.ready(preparation))
            }
        }
    }

    public func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    public func dispatchSyntheticPaste(
        preparation: InjectionPreparation,
        restoreDelayMs: Int,
        prePostGuard: (@Sendable () -> Bool)?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        clipboardQueue.async { [self] in
            guard self.state == .preparing,
                  let tx = self.activeTransaction,
                  tx.transactionID == preparation.transactionID
            else {
                self.callbackQueue.async {
                    completion(false)
                }
                return
            }

            // Re-verify pasteboard ownership immediately before posting Cmd+V.
            guard self.pasteboard.changeCount == tx.expectedChangeCount else {
                self.finishTransactionAndBecomeIdle()
                self.callbackQueue.async {
                    completion(false)
                }
                return
            }

            // P0-1: Gate synthetic Cmd+V dispatch on post-event TCC permission.
            guard self.postEventAccessProbe() else {
                if self.pasteboard.changeCount == tx.expectedChangeCount {
                    self.restoreSnapshot(for: tx)
                }
                self.finishTransactionAndBecomeIdle()
                self.callbackQueue.async {
                    completion(false)
                }
                return
            }

            // P1-1: Synchronously invoke commit pre-post guard on `clipboardQueue` right before posting Cmd+V.
            if let prePostGuard, !prePostGuard() {
                if self.pasteboard.changeCount == tx.expectedChangeCount {
                    self.restoreSnapshot(for: tx)
                }
                self.finishTransactionAndBecomeIdle()
                self.callbackQueue.async {
                    completion(false)
                }
                return
            }

            let posted = self.pastePoster.postCmdV(.standardCmdV)
            guard posted else {
                // Posting failed: restore snapshot immediately if we still own the clipboard.
                if self.pasteboard.changeCount == tx.expectedChangeCount {
                    self.restoreSnapshot(for: tx)
                }
                self.finishTransactionAndBecomeIdle()
                self.callbackQueue.async {
                    completion(false)
                }
                return
            }

            self.transitionState(.pasteDispatched)
            self.transitionState(.awaitingRestore)

            let clampedDelayMs = min(self.maxRestoreDelayMs, max(self.minRestoreDelayMs, restoreDelayMs))
            let expectedTxID = tx.transactionID

            // Notify caller that paste has been dispatched; restore completes asynchronously.
            self.callbackQueue.async {
                completion(true)
            }

            // Non-cancelling restore timer on the dedicated serial clipboard queue.
            self.clipboardQueue.asyncAfter(deadline: .now() + .milliseconds(clampedDelayMs)) { [weak injector = self] in
                guard let injector else { return }
                guard injector.state == .awaitingRestore,
                      let currentTx = injector.activeTransaction,
                      currentTx.transactionID == expectedTxID
                else {
                    return
                }

                // Restore ONLY if changeCount still matches our write;
                // if the user copied something new in the meantime, abandon restore!
                if injector.pasteboard.changeCount == currentTx.expectedChangeCount {
                    injector.restoreSnapshot(for: currentTx)
                }

                injector.finishTransactionAndBecomeIdle()
            }
        }
    }

    public func restoreIfOwned(preparation: InjectionPreparation) {
        clipboardQueue.async {
            // Only rolls back a transaction still in `.preparing` (NEVER cancels `.awaitingRestore`).
            guard self.state == .preparing,
                  let tx = self.activeTransaction,
                  tx.transactionID == preparation.transactionID
            else {
                return
            }

            if self.pasteboard.changeCount == tx.expectedChangeCount {
                self.restoreSnapshot(for: tx)
            }

            self.finishTransactionAndBecomeIdle()
        }
    }

    public func copyTextForUser(_ text: String) {
        clipboardQueue.async {
            // Plain user copy: NO TransientType, NO AutoGeneratedType, NO auto-restore.
            // If an earlier transaction is in `.awaitingRestore`, this write increments `changeCount`
            // so the non-cancelled timer will naturally observe mismatch and abandon its restore.
            _ = self.pasteboard.clearAndWriteSingleItem([
                (type: PasteboardMarkerType.utf8String, data: Data(text.utf8)),
            ])
        }
    }

    // MARK: - Tier 1 Prescreening

    /// Pure zero-copy metadata check over pasteboard item types.
    public static func prescreenMetadata(_ items: [PasteboardItemMetadata]) -> InjectionBlockReason? {
        for item in items {
            for type in item.types {
                if type == PasteboardMarkerType.concealed || type.localizedCaseInsensitiveContains("concealedtype") {
                    return .concealedContent
                }
            }
        }

        for item in items {
            for type in item.types {
                if filePromiseTypes.contains(type)
                    || type.localizedCaseInsensitiveContains("nsfilepromise")
                    || type.localizedCaseInsensitiveContains("promised-file")
                    || type.localizedCaseInsensitiveContains("promise")
                {
                    return .filePromise
                }
            }
        }

        for item in items {
            for type in item.types {
                if riskyLargeImageTypes.contains(type) {
                    return .largeImageOrUnsupported
                }
            }
        }

        // P1-3: Reject any item carrying a non-marker representation outside `whitelistedSnapshotTypes`
        // (even if the item also carries `public.utf8-plain-text`), so custom rich representations are never lost.
        for item in items {
            for type in item.types {
                if !whitelistedSnapshotTypes.contains(type) && !benignMarkerOnlyTypes.contains(type) {
                    return .largeImageOrUnsupported
                }
            }
        }

        return nil
    }

    /// Overflow-free 8 MiB snapshot budget check (P1-4).
    public static func wouldExceedSnapshotBudget(
        currentBytes: Int,
        addingBytes: Int,
        budgetBytes: Int
    ) -> Bool {
        guard currentBytes >= 0, addingBytes >= 0, budgetBytes >= 0, currentBytes <= budgetBytes else {
            return true
        }
        return addingBytes > budgetBytes - currentBytes
    }

    // MARK: - Private State Machine Helpers

    private func transitionState(_ newState: TransactionState) {
        state = newState
        isBusyAtomic.store(newState != .idle, ordering: .release)
    }

    private func restoreSnapshot(for tx: ActiveTransaction) {
        if tx.wasOriginallyEmpty || tx.snapshot.isEmpty {
            _ = pasteboard.clearAll()
        } else {
            _ = pasteboard.clearAndRestoreItems(tx.snapshot)
        }
    }

    private func finishTransactionAndBecomeIdle() {
        activeTransaction = nil
        transitionState(.idle)

        if !idleWaiters.isEmpty {
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: false)
            callbackQueue.async {
                for waiter in waiters {
                    waiter()
                }
            }
        }
    }
}
