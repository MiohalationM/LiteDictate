#include "CLiteDictateAudio.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// Apple Silicon cache line size (128 bytes) to eliminate producer/consumer false sharing.
#define LD_CACHELINE_BYTES 128

struct LDRingBuffer {
    uint32_t capacity_frames;
    uint32_t channels;
    size_t byte_capacity;
    float *samples;

    _Alignas(LD_CACHELINE_BYTES) _Atomic uint64_t write_pos;
    _Alignas(LD_CACHELINE_BYTES) _Atomic uint64_t read_pos;
};

static size_t ld_safe_mul(size_t a, size_t b) {
    if (a == 0 || b == 0) {
        return 0;
    }
    if (a > SIZE_MAX / b) {
        return SIZE_MAX;
    }
    return a * b;
}

LDRingBuffer *ld_ring_create_exact(uint32_t channels, uint32_t capacity_frames) {
    if (channels == 0 || channels > LD_AUDIO_MAX_CHANNELS || capacity_frames == 0) {
        return NULL;
    }

    size_t sample_count = ld_safe_mul((size_t)capacity_frames, (size_t)channels);
    size_t bytes = ld_safe_mul(sample_count, sizeof(float));
    if (bytes == 0 || bytes == SIZE_MAX) {
        return NULL;
    }

    LDRingBuffer *rb = NULL;
    if (posix_memalign((void **)&rb, LD_CACHELINE_BYTES, sizeof(LDRingBuffer)) != 0 || rb == NULL) {
        return NULL;
    }
    memset(rb, 0, sizeof(LDRingBuffer));

    float *samples = (float *)calloc(sample_count, sizeof(float));
    if (samples == NULL) {
        free(rb);
        return NULL;
    }

    rb->capacity_frames = capacity_frames;
    rb->channels = channels;
    rb->byte_capacity = bytes;
    rb->samples = samples;
    atomic_init(&rb->write_pos, 0);
    atomic_init(&rb->read_pos, 0);
    return rb;
}

LDRingBuffer *ld_ring_create(
    uint32_t channels,
    double sample_rate,
    double duration_seconds,
    size_t max_bytes
) {
    if (channels == 0 || channels > LD_AUDIO_MAX_CHANNELS) {
        return NULL;
    }
    if (sample_rate <= 0.0 || duration_seconds <= 0.0) {
        return NULL;
    }

    size_t cap_bytes = (max_bytes == 0) ? LD_AUDIO_DEFAULT_RING_MAX_BYTES : max_bytes;
    size_t bytes_per_frame = (size_t)channels * sizeof(float);
    size_t max_frames_by_mem = cap_bytes / bytes_per_frame;
    if (max_frames_by_mem == 0) {
        max_frames_by_mem = 1;
    }

    double desired_double = sample_rate * duration_seconds;
    uint32_t desired_frames = 1;
    if (desired_double >= (double)UINT32_MAX) {
        desired_frames = UINT32_MAX;
    } else if (desired_double >= 1.0) {
        desired_frames = (uint32_t)(desired_double + 0.5);
    }

    uint32_t capacity_frames = desired_frames;
    if ((size_t)capacity_frames > max_frames_by_mem) {
        capacity_frames = (max_frames_by_mem > (size_t)UINT32_MAX)
            ? UINT32_MAX
            : (uint32_t)max_frames_by_mem;
    }
    if (capacity_frames == 0) {
        capacity_frames = 1;
    }

    return ld_ring_create_exact(channels, capacity_frames);
}

void ld_ring_destroy(LDRingBuffer *rb) {
    if (rb == NULL) {
        return;
    }
    free(rb->samples);
    rb->samples = NULL;
    free(rb);
}

void ld_ring_reset(LDRingBuffer *rb) {
    atomic_store_explicit(&rb->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->read_pos, 0, memory_order_release);
}

uint32_t ld_ring_capacity_frames(const LDRingBuffer *rb) {
    return rb->capacity_frames;
}

uint32_t ld_ring_channels(const LDRingBuffer *rb) {
    return rb->channels;
}

size_t ld_ring_byte_capacity(const LDRingBuffer *rb) {
    return rb->byte_capacity;
}

uint32_t ld_ring_available_read(const LDRingBuffer *rb) {
    uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);
    return (w >= r) ? (uint32_t)(w - r) : 0U;
}

uint32_t ld_ring_available_write(const LDRingBuffer *rb) {
    uint32_t used = ld_ring_available_read(rb);
    return (used < rb->capacity_frames) ? (rb->capacity_frames - used) : 0U;
}

uint32_t ld_ring_write_interleaved(
    LDRingBuffer *rb,
    const float *interleaved_samples,
    uint32_t frame_count,
    uint32_t *out_dropped_frames
) {
    if (frame_count == 0) {
        if (out_dropped_frames != NULL) {
            *out_dropped_frames = 0;
        }
        return 0;
    }

    const uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_relaxed);
    const uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);
    const uint64_t used = (w >= r) ? (w - r) : 0;
    const uint64_t avail = (used < (uint64_t)rb->capacity_frames)
        ? ((uint64_t)rb->capacity_frames - used)
        : 0;

    // Overflow policy: preserve unread old frames, reject excess new incoming frames.
    const uint32_t to_write = ((uint64_t)frame_count <= avail)
        ? frame_count
        : (uint32_t)avail;
    const uint32_t dropped = frame_count - to_write;

    if (to_write > 0) {
        const uint32_t cap = rb->capacity_frames;
        const uint32_t start = (uint32_t)(w % (uint64_t)cap);
        uint32_t first = cap - start;
        if (first > to_write) {
            first = to_write;
        }
        const uint32_t second = to_write - first;
        const size_t stride = (size_t)rb->channels;

        memcpy(
            rb->samples + (size_t)start * stride,
            interleaved_samples,
            (size_t)first * stride * sizeof(float)
        );
        if (second > 0) {
            memcpy(
                rb->samples,
                interleaved_samples + (size_t)first * stride,
                (size_t)second * stride * sizeof(float)
            );
        }

        atomic_store_explicit(&rb->write_pos, w + (uint64_t)to_write, memory_order_release);
    }

    if (out_dropped_frames != NULL) {
        *out_dropped_frames = dropped;
    }
    return to_write;
}

uint32_t ld_ring_write_noninterleaved(
    LDRingBuffer *rb,
    const float *const *channel_ptrs,
    uint32_t num_channels,
    uint32_t frame_count,
    uint32_t *out_dropped_frames
) {
    if (frame_count == 0) {
        if (out_dropped_frames != NULL) {
            *out_dropped_frames = 0;
        }
        return 0;
    }

    const uint32_t channels = rb->channels;
    const uint32_t copy_channels = (num_channels < channels) ? num_channels : channels;

    const uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_relaxed);
    const uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);
    const uint64_t used = (w >= r) ? (w - r) : 0;
    const uint64_t avail = (used < (uint64_t)rb->capacity_frames)
        ? ((uint64_t)rb->capacity_frames - used)
        : 0;

    // Overflow policy: preserve unread old frames, reject excess new incoming frames.
    const uint32_t to_write = ((uint64_t)frame_count <= avail)
        ? frame_count
        : (uint32_t)avail;
    const uint32_t dropped = frame_count - to_write;

    if (to_write > 0) {
        const uint32_t cap = rb->capacity_frames;
        const uint32_t start = (uint32_t)(w % (uint64_t)cap);
        uint32_t first = cap - start;
        if (first > to_write) {
            first = to_write;
        }
        const uint32_t second = to_write - first;

        float *dst = rb->samples + (size_t)start * (size_t)channels;
        for (uint32_t f = 0; f < first; ++f) {
            for (uint32_t c = 0; c < copy_channels; ++c) {
                dst[(size_t)f * (size_t)channels + c] = channel_ptrs[c][f];
            }
            for (uint32_t c = copy_channels; c < channels; ++c) {
                dst[(size_t)f * (size_t)channels + c] = 0.0f;
            }
        }

        if (second > 0) {
            float *dst2 = rb->samples;
            for (uint32_t f = 0; f < second; ++f) {
                const uint32_t src_idx = first + f;
                for (uint32_t c = 0; c < copy_channels; ++c) {
                    dst2[(size_t)f * (size_t)channels + c] = channel_ptrs[c][src_idx];
                }
                for (uint32_t c = copy_channels; c < channels; ++c) {
                    dst2[(size_t)f * (size_t)channels + c] = 0.0f;
                }
            }
        }

        atomic_store_explicit(&rb->write_pos, w + (uint64_t)to_write, memory_order_release);
    }

    if (out_dropped_frames != NULL) {
        *out_dropped_frames = dropped;
    }
    return to_write;
}

uint32_t ld_ring_read_interleaved(
    LDRingBuffer *rb,
    float *out_interleaved,
    uint32_t max_frames
) {
    if (max_frames == 0) {
        return 0;
    }

    const uint64_t r = atomic_load_explicit(&rb->read_pos, memory_order_relaxed);
    const uint64_t w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    const uint64_t avail = (w >= r) ? (w - r) : 0;

    const uint32_t to_read = (avail < (uint64_t)max_frames)
        ? (uint32_t)avail
        : max_frames;

    if (to_read > 0) {
        const uint32_t cap = rb->capacity_frames;
        const uint32_t start = (uint32_t)(r % (uint64_t)cap);
        uint32_t first = cap - start;
        if (first > to_read) {
            first = to_read;
        }
        const uint32_t second = to_read - first;
        const size_t stride = (size_t)rb->channels;

        memcpy(
            out_interleaved,
            rb->samples + (size_t)start * stride,
            (size_t)first * stride * sizeof(float)
        );
        if (second > 0) {
            memcpy(
                out_interleaved + (size_t)first * stride,
                rb->samples,
                (size_t)second * stride * sizeof(float)
            );
        }

        atomic_store_explicit(&rb->read_pos, r + (uint64_t)to_read, memory_order_release);
    }

    return to_read;
}
