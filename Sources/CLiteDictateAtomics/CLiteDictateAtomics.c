#include "CLiteDictateAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct ld_atomic_bool {
    _Atomic bool value;
};

struct ld_atomic_u64 {
    _Atomic uint64_t value;
};

static inline memory_order ld_map_load_order(ld_memory_order_t order) {
    switch (order) {
        case LD_MEMORY_ORDER_RELAXED:
            return memory_order_relaxed;
        case LD_MEMORY_ORDER_ACQUIRE:
        case LD_MEMORY_ORDER_ACQ_REL:
        case LD_MEMORY_ORDER_RELEASE:
            return memory_order_acquire;
        case LD_MEMORY_ORDER_SEQ_CST:
        default:
            return memory_order_seq_cst;
    }
}

static inline memory_order ld_map_store_order(ld_memory_order_t order) {
    switch (order) {
        case LD_MEMORY_ORDER_RELAXED:
            return memory_order_relaxed;
        case LD_MEMORY_ORDER_RELEASE:
        case LD_MEMORY_ORDER_ACQ_REL:
        case LD_MEMORY_ORDER_ACQUIRE:
            return memory_order_release;
        case LD_MEMORY_ORDER_SEQ_CST:
        default:
            return memory_order_seq_cst;
    }
}

static inline memory_order ld_map_rmw_order(ld_memory_order_t order) {
    switch (order) {
        case LD_MEMORY_ORDER_RELAXED:
            return memory_order_relaxed;
        case LD_MEMORY_ORDER_ACQUIRE:
            return memory_order_acquire;
        case LD_MEMORY_ORDER_RELEASE:
            return memory_order_release;
        case LD_MEMORY_ORDER_ACQ_REL:
            return memory_order_acq_rel;
        case LD_MEMORY_ORDER_SEQ_CST:
        default:
            return memory_order_seq_cst;
    }
}

ld_atomic_bool_t *ld_atomic_bool_create(bool initial_value) {
    ld_atomic_bool_t *a = (ld_atomic_bool_t *)malloc(sizeof(ld_atomic_bool_t));
    if (!a) {
        abort();
    }
    atomic_init(&a->value, initial_value);
    return a;
}

void ld_atomic_bool_destroy(ld_atomic_bool_t *atomic) {
    free(atomic);
}

bool ld_atomic_bool_load(const ld_atomic_bool_t *atomic, ld_memory_order_t order) {
    return atomic_load_explicit(&((ld_atomic_bool_t *)atomic)->value, ld_map_load_order(order));
}

void ld_atomic_bool_store(ld_atomic_bool_t *atomic, bool value, ld_memory_order_t order) {
    atomic_store_explicit(&atomic->value, value, ld_map_store_order(order));
}

bool ld_atomic_bool_exchange(ld_atomic_bool_t *atomic, bool value, ld_memory_order_t order) {
    return atomic_exchange_explicit(&atomic->value, value, ld_map_rmw_order(order));
}

bool ld_atomic_bool_compare_exchange(
    ld_atomic_bool_t *atomic,
    bool expected,
    bool desired,
    ld_memory_order_t order
) {
    bool exp = expected;
    memory_order success = ld_map_rmw_order(order);
    memory_order failure = (success == memory_order_acq_rel) ? memory_order_acquire
                         : (success == memory_order_release) ? memory_order_relaxed
                         : success;
    return atomic_compare_exchange_strong_explicit(&atomic->value, &exp, desired, success, failure);
}

ld_atomic_u64_t *ld_atomic_u64_create(uint64_t initial_value) {
    ld_atomic_u64_t *a = (ld_atomic_u64_t *)malloc(sizeof(ld_atomic_u64_t));
    if (!a) {
        abort();
    }
    atomic_init(&a->value, initial_value);
    return a;
}

void ld_atomic_u64_destroy(ld_atomic_u64_t *atomic) {
    free(atomic);
}

uint64_t ld_atomic_u64_load(const ld_atomic_u64_t *atomic, ld_memory_order_t order) {
    return atomic_load_explicit(&((ld_atomic_u64_t *)atomic)->value, ld_map_load_order(order));
}

void ld_atomic_u64_store(ld_atomic_u64_t *atomic, uint64_t value, ld_memory_order_t order) {
    atomic_store_explicit(&atomic->value, value, ld_map_store_order(order));
}

uint64_t ld_atomic_u64_fetch_add(ld_atomic_u64_t *atomic, uint64_t delta, ld_memory_order_t order) {
    return atomic_fetch_add_explicit(&atomic->value, delta, ld_map_rmw_order(order));
}

uint64_t ld_atomic_u64_exchange(ld_atomic_u64_t *atomic, uint64_t value, ld_memory_order_t order) {
    return atomic_exchange_explicit(&atomic->value, value, ld_map_rmw_order(order));
}

bool ld_atomic_u64_compare_exchange(
    ld_atomic_u64_t *atomic,
    uint64_t expected,
    uint64_t desired,
    ld_memory_order_t order
) {
    uint64_t exp = expected;
    memory_order success = ld_map_rmw_order(order);
    memory_order failure = (success == memory_order_acq_rel) ? memory_order_acquire
                         : (success == memory_order_release) ? memory_order_relaxed
                         : success;
    return atomic_compare_exchange_strong_explicit(&atomic->value, &exp, desired, success, failure);
}
