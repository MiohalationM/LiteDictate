import CLiteDictateAtomics

/// Memory ordering for lock-free C11 atomics (macOS 14.0+ compatible).
public enum AtomicMemoryOrder: Sendable {
    case relaxed
    case acquire
    case release
    case acqRel
    case seqCst

    @inline(__always)
    var cOrder: ld_memory_order_t {
        switch self {
        case .relaxed: return LD_MEMORY_ORDER_RELAXED
        case .acquire: return LD_MEMORY_ORDER_ACQUIRE
        case .release: return LD_MEMORY_ORDER_RELEASE
        case .acqRel: return LD_MEMORY_ORDER_ACQ_REL
        case .seqCst: return LD_MEMORY_ORDER_SEQ_CST
        }
    }
}

/// Lock-free boolean backed by C11 `_Atomic bool` (`<stdatomic.h>`), compatible with macOS 14.0+.
public final class AtomicBool: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(_ initialValue: Bool = false) {
        self.handle = ld_atomic_bool_create(initialValue)
    }

    deinit {
        ld_atomic_bool_destroy(handle)
    }

    @inline(__always)
    public func load(ordering: AtomicMemoryOrder = .acquire) -> Bool {
        ld_atomic_bool_load(handle, ordering.cOrder)
    }

    @inline(__always)
    public func store(_ value: Bool, ordering: AtomicMemoryOrder = .release) {
        ld_atomic_bool_store(handle, value, ordering.cOrder)
    }

    @inline(__always)
    public func exchange(_ value: Bool, ordering: AtomicMemoryOrder = .acqRel) -> Bool {
        ld_atomic_bool_exchange(handle, value, ordering.cOrder)
    }

    @inline(__always)
    public func compareExchange(
        expected: Bool,
        desired: Bool,
        ordering: AtomicMemoryOrder = .acqRel
    ) -> Bool {
        ld_atomic_bool_compare_exchange(handle, expected, desired, ordering.cOrder)
    }
}

/// Lock-free 64-bit unsigned integer backed by C11 `_Atomic uint64_t`, compatible with macOS 14.0+.
public final class AtomicUInt64: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(_ initialValue: UInt64 = 0) {
        self.handle = ld_atomic_u64_create(initialValue)
    }

    deinit {
        ld_atomic_u64_destroy(handle)
    }

    @inline(__always)
    public func load(ordering: AtomicMemoryOrder = .acquire) -> UInt64 {
        ld_atomic_u64_load(handle, ordering.cOrder)
    }

    @inline(__always)
    public func store(_ value: UInt64, ordering: AtomicMemoryOrder = .release) {
        ld_atomic_u64_store(handle, value, ordering.cOrder)
    }

    /// Atomically adds `delta` and returns the PREVIOUS value.
    @inline(__always)
    @discardableResult
    public func fetchAdd(_ delta: UInt64 = 1, ordering: AtomicMemoryOrder = .acqRel) -> UInt64 {
        ld_atomic_u64_fetch_add(handle, delta, ordering.cOrder)
    }

    /// Atomically increments by 1 and returns the NEW value.
    @inline(__always)
    @discardableResult
    public func increment(ordering: AtomicMemoryOrder = .acqRel) -> UInt64 {
        ld_atomic_u64_fetch_add(handle, 1, ordering.cOrder) &+ 1
    }

    @inline(__always)
    public func exchange(_ value: UInt64, ordering: AtomicMemoryOrder = .acqRel) -> UInt64 {
        ld_atomic_u64_exchange(handle, value, ordering.cOrder)
    }

    @inline(__always)
    public func compareExchange(
        expected: UInt64,
        desired: UInt64,
        ordering: AtomicMemoryOrder = .acqRel
    ) -> Bool {
        ld_atomic_u64_compare_exchange(handle, expected, desired, ordering.cOrder)
    }
}
