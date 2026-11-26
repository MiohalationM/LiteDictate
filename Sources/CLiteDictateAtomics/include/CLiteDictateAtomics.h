#ifndef CLITEDICTATE_ATOMICS_H
#define CLITEDICTATE_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ld_memory_order {
    LD_MEMORY_ORDER_RELAXED = 0,
    LD_MEMORY_ORDER_ACQUIRE = 1,
    LD_MEMORY_ORDER_RELEASE = 2,
    LD_MEMORY_ORDER_ACQ_REL = 3,
    LD_MEMORY_ORDER_SEQ_CST = 4
} ld_memory_order_t;

typedef struct ld_atomic_bool ld_atomic_bool_t;
typedef struct ld_atomic_u64 ld_atomic_u64_t;

ld_atomic_bool_t * _Nonnull ld_atomic_bool_create(bool initial_value);
void ld_atomic_bool_destroy(ld_atomic_bool_t * _Nonnull atomic);
bool ld_atomic_bool_load(const ld_atomic_bool_t * _Nonnull atomic, ld_memory_order_t order);
void ld_atomic_bool_store(ld_atomic_bool_t * _Nonnull atomic, bool value, ld_memory_order_t order);
bool ld_atomic_bool_exchange(ld_atomic_bool_t * _Nonnull atomic, bool value, ld_memory_order_t order);
bool ld_atomic_bool_compare_exchange(
    ld_atomic_bool_t * _Nonnull atomic,
    bool expected,
    bool desired,
    ld_memory_order_t order
);

ld_atomic_u64_t * _Nonnull ld_atomic_u64_create(uint64_t initial_value);
void ld_atomic_u64_destroy(ld_atomic_u64_t * _Nonnull atomic);
uint64_t ld_atomic_u64_load(const ld_atomic_u64_t * _Nonnull atomic, ld_memory_order_t order);
void ld_atomic_u64_store(ld_atomic_u64_t * _Nonnull atomic, uint64_t value, ld_memory_order_t order);
uint64_t ld_atomic_u64_fetch_add(ld_atomic_u64_t * _Nonnull atomic, uint64_t delta, ld_memory_order_t order);
uint64_t ld_atomic_u64_exchange(ld_atomic_u64_t * _Nonnull atomic, uint64_t value, ld_memory_order_t order);
bool ld_atomic_u64_compare_exchange(
    ld_atomic_u64_t * _Nonnull atomic,
    uint64_t expected,
    uint64_t desired,
    ld_memory_order_t order
);

#ifdef __cplusplus
}
#endif

#endif /* CLITEDICTATE_ATOMICS_H */
