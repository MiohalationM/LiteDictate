#include "CLiteDictateAudio.h"

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// MARK: - Helpers for Lock-Free Float Bit Packing

static inline uint32_t ld_float_to_bits(float v) {
    uint32_t bits = 0;
    memcpy(&bits, &v, sizeof(uint32_t));
    return bits;
}

static inline float ld_bits_to_float(uint32_t bits) {
    float v = 0.0f;
    memcpy(&v, &bits, sizeof(float));
    return v;
}

// MARK: - Monotonic Consumer Waiter

struct LDConsumerWaiter {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool signalled;
};

LDConsumerWaiter *ld_waiter_create(void) {
    LDConsumerWaiter *w = (LDConsumerWaiter *)calloc(1, sizeof(LDConsumerWaiter));
    if (w == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&w->mutex, NULL) != 0) {
        free(w);
        return NULL;
    }
    if (pthread_cond_init(&w->cond, NULL) != 0) {
        pthread_mutex_destroy(&w->mutex);
        free(w);
        return NULL;
    }
    w->signalled = false;
    return w;
}

void ld_waiter_destroy(LDConsumerWaiter *waiter) {
    if (waiter == NULL) {
        return;
    }
    pthread_cond_destroy(&waiter->cond);
    pthread_mutex_destroy(&waiter->mutex);
    free(waiter);
}

void ld_waiter_reset(LDConsumerWaiter *waiter) {
    pthread_mutex_lock(&waiter->mutex);
    waiter->signalled = false;
    pthread_mutex_unlock(&waiter->mutex);
}

bool ld_waiter_wait_ms(LDConsumerWaiter *waiter, uint32_t timeout_ms) {
    struct timespec rel;
    rel.tv_sec = (time_t)(timeout_ms / 1000U);
    rel.tv_nsec = (long)(timeout_ms % 1000U) * 1000000L;

    pthread_mutex_lock(&waiter->mutex);
    if (!waiter->signalled) {
        // Darwin monotonic relative-timeout wait (immune to wall-clock adjustments).
        (void)pthread_cond_timedwait_relative_np(&waiter->cond, &waiter->mutex, &rel);
    }
    bool was_signalled = waiter->signalled;
    waiter->signalled = false;
    pthread_mutex_unlock(&waiter->mutex);
    return was_signalled;
}

void ld_waiter_signal(LDConsumerWaiter *waiter) {
    pthread_mutex_lock(&waiter->mutex);
    waiter->signalled = true;
    pthread_cond_signal(&waiter->cond);
    pthread_mutex_unlock(&waiter->mutex);
}

// MARK: - Independent Heap-Allocated Capture Context

struct LDCaptureContext {
    AudioUnit audio_unit;
    uint32_t channels;
    double sample_rate;
    uint32_t max_frames_per_slice;
    bool is_non_interleaved;
    uint32_t abl_buffer_count;

    AudioBufferList *scratch_abl;
    float *scratch_storage;
    size_t scratch_storage_bytes;
    const float *noninterleaved_ptrs[LD_AUDIO_MAX_CHANNELS];

    LDRingBuffer *ring;

    // RT-accessible atomic flags and counters (ZERO locks)
    _Atomic bool accept_audio;
    _Atomic bool capture_started;
    _Atomic bool first_frame_received;
    _Atomic bool speech_detected;
    _Atomic bool audio_interrupted;

    _Atomic uint64_t dropped_frames;
    _Atomic uint64_t total_frames_received;
    _Atomic uint64_t render_error_count;
    _Atomic int32_t last_render_status;
    _Atomic uint64_t first_frame_host_time;

    _Atomic uint32_t speech_rms_threshold_bits;
    _Atomic uint32_t meter_peak_bits;
    _Atomic uint32_t meter_rms_bits;
    _Atomic uint32_t session_peak_bits;
};

LDCaptureContext *ld_capture_context_create(
    uint32_t channels,
    double sample_rate,
    uint32_t max_frames_per_slice,
    bool is_non_interleaved,
    double ring_duration_seconds,
    size_t ring_max_bytes
) {
    if (channels == 0 || channels > LD_AUDIO_MAX_CHANNELS) {
        return NULL;
    }
    if (sample_rate <= 0.0 || max_frames_per_slice == 0) {
        return NULL;
    }

    LDCaptureContext *ctx = (LDCaptureContext *)calloc(1, sizeof(LDCaptureContext));
    if (ctx == NULL) {
        return NULL;
    }

    LDRingBuffer *ring = ld_ring_create(channels, sample_rate, ring_duration_seconds, ring_max_bytes);
    if (ring == NULL) {
        free(ctx);
        return NULL;
    }

    uint32_t num_buffers = is_non_interleaved ? channels : 1U;
    size_t abl_size = offsetof(AudioBufferList, mBuffers) + (size_t)num_buffers * sizeof(AudioBuffer);
    AudioBufferList *abl = (AudioBufferList *)calloc(1, abl_size);
    if (abl == NULL) {
        ld_ring_destroy(ring);
        free(ctx);
        return NULL;
    }

    size_t scratch_samples = (size_t)max_frames_per_slice * (size_t)channels;
    size_t scratch_bytes = scratch_samples * sizeof(float);
    float *storage = (float *)calloc(scratch_samples, sizeof(float));
    if (storage == NULL) {
        free(abl);
        ld_ring_destroy(ring);
        free(ctx);
        return NULL;
    }

    abl->mNumberBuffers = num_buffers;
    if (is_non_interleaved) {
        for (uint32_t c = 0; c < channels; ++c) {
            float *chan_buf = storage + (size_t)c * (size_t)max_frames_per_slice;
            abl->mBuffers[c].mNumberChannels = 1;
            abl->mBuffers[c].mDataByteSize = max_frames_per_slice * (UInt32)sizeof(float);
            abl->mBuffers[c].mData = chan_buf;
            ctx->noninterleaved_ptrs[c] = chan_buf;
        }
    } else {
        abl->mBuffers[0].mNumberChannels = channels;
        abl->mBuffers[0].mDataByteSize = max_frames_per_slice * channels * (UInt32)sizeof(float);
        abl->mBuffers[0].mData = storage;
    }

    ctx->audio_unit = NULL;
    ctx->channels = channels;
    ctx->sample_rate = sample_rate;
    ctx->max_frames_per_slice = max_frames_per_slice;
    ctx->is_non_interleaved = is_non_interleaved;
    ctx->abl_buffer_count = num_buffers;
    ctx->scratch_abl = abl;
    ctx->scratch_storage = storage;
    ctx->scratch_storage_bytes = scratch_bytes;
    ctx->ring = ring;

    atomic_init(&ctx->accept_audio, false);
    atomic_init(&ctx->capture_started, false);
    atomic_init(&ctx->first_frame_received, false);
    atomic_init(&ctx->speech_detected, false);
    atomic_init(&ctx->audio_interrupted, false);
    atomic_init(&ctx->dropped_frames, 0);
    atomic_init(&ctx->total_frames_received, 0);
    atomic_init(&ctx->render_error_count, 0);
    atomic_init(&ctx->last_render_status, 0);
    atomic_init(&ctx->first_frame_host_time, 0);
    // Default speech detection threshold: -45 dBFS (~0.005623 linear RMS)
    atomic_init(&ctx->speech_rms_threshold_bits, ld_float_to_bits(0.00562341325f));
    atomic_init(&ctx->meter_peak_bits, ld_float_to_bits(0.0f));
    atomic_init(&ctx->meter_rms_bits, ld_float_to_bits(0.0f));
    atomic_init(&ctx->session_peak_bits, ld_float_to_bits(0.0f));

    return ctx;
}

void ld_capture_context_destroy(LDCaptureContext *ctx) {
    if (ctx == NULL) {
        return;
    }
    free(ctx->scratch_storage);
    ctx->scratch_storage = NULL;
    free(ctx->scratch_abl);
    ctx->scratch_abl = NULL;
    ld_ring_destroy(ctx->ring);
    ctx->ring = NULL;
    free(ctx);
}

void ld_capture_context_set_audio_unit(LDCaptureContext *ctx, AudioUnit audio_unit) {
    ctx->audio_unit = audio_unit;
}

void ld_capture_context_reset_session(LDCaptureContext *ctx) {
    ld_ring_reset(ctx->ring);
    atomic_store_explicit(&ctx->accept_audio, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->capture_started, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->first_frame_received, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->speech_detected, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->audio_interrupted, false, memory_order_relaxed);
    atomic_store_explicit(&ctx->dropped_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->total_frames_received, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->render_error_count, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->last_render_status, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->first_frame_host_time, 0, memory_order_relaxed);
    atomic_store_explicit(&ctx->meter_peak_bits, ld_float_to_bits(0.0f), memory_order_relaxed);
    atomic_store_explicit(&ctx->meter_rms_bits, ld_float_to_bits(0.0f), memory_order_relaxed);
    atomic_store_explicit(&ctx->session_peak_bits, ld_float_to_bits(0.0f), memory_order_release);
}

void ld_capture_context_set_accept_audio(LDCaptureContext *ctx, bool accept) {
    atomic_store_explicit(&ctx->accept_audio, accept, memory_order_release);
}

bool ld_capture_context_get_accept_audio(const LDCaptureContext *ctx) {
    return atomic_load_explicit(&ctx->accept_audio, memory_order_acquire);
}

void ld_capture_context_mark_interrupted(LDCaptureContext *ctx) {
    atomic_store_explicit(&ctx->audio_interrupted, true, memory_order_release);
}

void ld_capture_context_set_speech_threshold(LDCaptureContext *ctx, float linear_rms) {
    float clamped = (linear_rms < 0.0f || !isfinite(linear_rms)) ? 0.0f : linear_rms;
    atomic_store_explicit(&ctx->speech_rms_threshold_bits, ld_float_to_bits(clamped), memory_order_release);
}

LDCaptureTelemetry ld_capture_context_read_telemetry(const LDCaptureContext *ctx) {
    LDCaptureTelemetry t;
    t.capture_started = atomic_load_explicit(&ctx->capture_started, memory_order_acquire);
    t.first_frame_received = atomic_load_explicit(&ctx->first_frame_received, memory_order_acquire);
    t.speech_detected = atomic_load_explicit(&ctx->speech_detected, memory_order_acquire);
    t.audio_interrupted = atomic_load_explicit(&ctx->audio_interrupted, memory_order_acquire);
    t.dropped_frames = atomic_load_explicit(&ctx->dropped_frames, memory_order_relaxed);
    t.total_frames_received = atomic_load_explicit(&ctx->total_frames_received, memory_order_relaxed);
    t.render_error_count = atomic_load_explicit(&ctx->render_error_count, memory_order_relaxed);
    t.last_render_status = atomic_load_explicit(&ctx->last_render_status, memory_order_relaxed);
    t.first_frame_host_time = atomic_load_explicit(&ctx->first_frame_host_time, memory_order_relaxed);
    t.meter_peak_linear = ld_bits_to_float(atomic_load_explicit(&ctx->meter_peak_bits, memory_order_relaxed));
    t.meter_rms_linear = ld_bits_to_float(atomic_load_explicit(&ctx->meter_rms_bits, memory_order_relaxed));
    t.session_peak_linear = ld_bits_to_float(atomic_load_explicit(&ctx->session_peak_bits, memory_order_relaxed));
    return t;
}

LDRingBuffer *ld_capture_context_ring_buffer(LDCaptureContext *ctx) {
    return ctx->ring;
}

uint32_t ld_capture_context_channels(const LDCaptureContext *ctx) {
    return ctx->channels;
}

double ld_capture_context_sample_rate(const LDCaptureContext *ctx) {
    return ctx->sample_rate;
}

size_t ld_capture_context_memory_bytes(const LDCaptureContext *ctx) {
    size_t abl_size = offsetof(AudioBufferList, mBuffers) + (size_t)ctx->abl_buffer_count * sizeof(AudioBuffer);
    return sizeof(LDCaptureContext) + abl_size + ctx->scratch_storage_bytes + ld_ring_byte_capacity(ctx->ring);
}

// MARK: - Pure C Lock-Free RT Helpers (ZERO alloc, ZERO locks, ZERO ObjC/Swift)

static inline void ld_rt_update_metrics_and_flags(
    LDCaptureContext *ctx,
    float peak,
    float rms,
    bool has_valid_pcm,
    uint64_t host_time,
    uint32_t written,
    uint32_t dropped
) {
    atomic_store_explicit(&ctx->meter_peak_bits, ld_float_to_bits(peak), memory_order_relaxed);
    atomic_store_explicit(&ctx->meter_rms_bits, ld_float_to_bits(rms), memory_order_relaxed);

    float prev_session_peak = ld_bits_to_float(
        atomic_load_explicit(&ctx->session_peak_bits, memory_order_relaxed)
    );
    if (peak > prev_session_peak) {
        atomic_store_explicit(&ctx->session_peak_bits, ld_float_to_bits(peak), memory_order_relaxed);
    }

    float speech_thresh = ld_bits_to_float(
        atomic_load_explicit(&ctx->speech_rms_threshold_bits, memory_order_relaxed)
    );
    if (rms >= speech_thresh && speech_thresh > 0.0f) {
        atomic_store_explicit(&ctx->speech_detected, true, memory_order_release);
    }

    if (has_valid_pcm) {
        if (!atomic_load_explicit(&ctx->first_frame_received, memory_order_relaxed)) {
            atomic_store_explicit(&ctx->first_frame_host_time, host_time, memory_order_relaxed);
            atomic_store_explicit(&ctx->first_frame_received, true, memory_order_release);
        }
    }

    if (written > 0) {
        atomic_fetch_add_explicit(&ctx->total_frames_received, (uint64_t)written, memory_order_relaxed);
    }

    if (dropped > 0) {
        atomic_fetch_add_explicit(&ctx->dropped_frames, (uint64_t)dropped, memory_order_relaxed);
        atomic_store_explicit(&ctx->audio_interrupted, true, memory_order_release);
    }
}

static inline void ld_rt_sanitize_and_measure_interleaved(
    float *samples,
    uint32_t total_samples,
    float *out_peak,
    float *out_rms,
    bool *out_has_valid
) {
    float peak = 0.0f;
    double sum_sq = 0.0;
    bool any_valid = false;

    for (uint32_t i = 0; i < total_samples; ++i) {
        float s = samples[i];
        if (!isfinite(s)) {
            s = 0.0f;
            samples[i] = 0.0f;
        } else {
            any_valid = true;
            float a = fabsf(s);
            if (a > peak) {
                peak = a;
            }
            sum_sq += (double)s * (double)s;
        }
    }

    *out_peak = peak;
    *out_rms = (total_samples > 0) ? (float)sqrt(sum_sq / (double)total_samples) : 0.0f;
    *out_has_valid = any_valid;
}

static inline void ld_rt_sanitize_and_measure_noninterleaved(
    AudioBufferList *abl,
    uint32_t channels,
    uint32_t frame_count,
    float *out_peak,
    float *out_rms,
    bool *out_has_valid
) {
    float peak = 0.0f;
    double sum_sq = 0.0;
    bool any_valid = false;
    uint32_t active_ch = (abl->mNumberBuffers < channels) ? abl->mNumberBuffers : channels;

    for (uint32_t c = 0; c < active_ch; ++c) {
        float *buf = (float *)abl->mBuffers[c].mData;
        if (buf == NULL) {
            continue;
        }
        for (uint32_t f = 0; f < frame_count; ++f) {
            float s = buf[f];
            if (!isfinite(s)) {
                s = 0.0f;
                buf[f] = 0.0f;
            } else {
                any_valid = true;
                float a = fabsf(s);
                if (a > peak) {
                    peak = a;
                }
                sum_sq += (double)s * (double)s;
            }
        }
    }

    uint32_t total_samples = active_ch * frame_count;
    *out_peak = peak;
    *out_rms = (total_samples > 0) ? (float)sqrt(sum_sq / (double)total_samples) : 0.0f;
    *out_has_valid = any_valid;
}

// MARK: - Pure C AUHAL Input Render Callback

OSStatus ld_auhal_input_callback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)ioData;

    LDCaptureContext *ctx = (LDCaptureContext *)inRefCon;
    if (ctx == NULL) {
        return noErr;
    }

    if (!atomic_load_explicit(&ctx->accept_audio, memory_order_acquire)) {
        return noErr;
    }

    if (!atomic_load_explicit(&ctx->capture_started, memory_order_relaxed)) {
        atomic_store_explicit(&ctx->capture_started, true, memory_order_release);
    }

    if (inNumberFrames == 0) {
        return noErr;
    }

    if (inNumberFrames > ctx->max_frames_per_slice || ctx->audio_unit == NULL) {
        atomic_fetch_add_explicit(&ctx->dropped_frames, (uint64_t)inNumberFrames, memory_order_relaxed);
        atomic_store_explicit(&ctx->audio_interrupted, true, memory_order_release);
        return noErr;
    }

    // Re-arm pre-allocated scratch ABL sizes/pointers (zero allocation).
    AudioBufferList *abl = ctx->scratch_abl;
    if (ctx->is_non_interleaved) {
        abl->mNumberBuffers = ctx->channels;
        const UInt32 chan_bytes = inNumberFrames * (UInt32)sizeof(float);
        for (uint32_t c = 0; c < ctx->channels; ++c) {
            float *chan_buf = ctx->scratch_storage + (size_t)c * (size_t)ctx->max_frames_per_slice;
            abl->mBuffers[c].mNumberChannels = 1;
            abl->mBuffers[c].mDataByteSize = chan_bytes;
            abl->mBuffers[c].mData = chan_buf;
            ctx->noninterleaved_ptrs[c] = chan_buf;
        }
    } else {
        abl->mNumberBuffers = 1;
        abl->mBuffers[0].mNumberChannels = ctx->channels;
        abl->mBuffers[0].mDataByteSize = inNumberFrames * ctx->channels * (UInt32)sizeof(float);
        abl->mBuffers[0].mData = ctx->scratch_storage;
    }

    OSStatus status = AudioUnitRender(
        ctx->audio_unit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        abl
    );
    if (status != noErr) {
        atomic_store_explicit(&ctx->last_render_status, (int32_t)status, memory_order_relaxed);
        atomic_fetch_add_explicit(&ctx->render_error_count, 1, memory_order_relaxed);
        atomic_store_explicit(&ctx->audio_interrupted, true, memory_order_release);
        return noErr;
    }

    // Re-check accept_audio after AudioUnitRender in case Quiescing began mid-pull.
    if (!atomic_load_explicit(&ctx->accept_audio, memory_order_acquire)) {
        return noErr;
    }

    float peak = 0.0f;
    float rms = 0.0f;
    bool has_valid_pcm = false;
    uint32_t dropped = 0;
    uint32_t written = 0;

    if (ctx->is_non_interleaved) {
        ld_rt_sanitize_and_measure_noninterleaved(
            abl,
            ctx->channels,
            inNumberFrames,
            &peak,
            &rms,
            &has_valid_pcm
        );
        written = ld_ring_write_noninterleaved(
            ctx->ring,
            ctx->noninterleaved_ptrs,
            ctx->channels,
            inNumberFrames,
            &dropped
        );
    } else {
        float *samples = (float *)abl->mBuffers[0].mData;
        if (samples == NULL) {
            atomic_store_explicit(&ctx->audio_interrupted, true, memory_order_release);
            return noErr;
        }
        const uint32_t total_samples = inNumberFrames * ctx->channels;
        ld_rt_sanitize_and_measure_interleaved(
            samples,
            total_samples,
            &peak,
            &rms,
            &has_valid_pcm
        );
        written = ld_ring_write_interleaved(
            ctx->ring,
            samples,
            inNumberFrames,
            &dropped
        );
    }

    uint64_t host_time = (inTimeStamp != NULL) ? inTimeStamp->mHostTime : 0;
    ld_rt_update_metrics_and_flags(ctx, peak, rms, has_valid_pcm, host_time, written, dropped);
    return noErr;
}

// Compile-time check that ld_auhal_input_callback matches CoreAudio's AURenderCallback exactly.
static const AURenderCallback _ld_unused_callback_sig_check __attribute__((unused)) = ld_auhal_input_callback;

void ld_capture_context_ingest_interleaved_for_testing(
    LDCaptureContext *ctx,
    const float *interleaved_samples,
    uint32_t frame_count,
    uint64_t host_time
) {
    if (ctx == NULL || interleaved_samples == NULL || frame_count == 0) {
        return;
    }
    if (!atomic_load_explicit(&ctx->accept_audio, memory_order_acquire)) {
        return;
    }
    if (!atomic_load_explicit(&ctx->capture_started, memory_order_relaxed)) {
        atomic_store_explicit(&ctx->capture_started, true, memory_order_release);
    }

    float peak = 0.0f;
    double sum_sq = 0.0;
    bool has_valid = false;
    const uint32_t total_samples = frame_count * ctx->channels;
    for (uint32_t i = 0; i < total_samples; ++i) {
        float s = interleaved_samples[i];
        if (isfinite(s)) {
            has_valid = true;
            float a = fabsf(s);
            if (a > peak) {
                peak = a;
            }
            sum_sq += (double)s * (double)s;
        }
    }
    float rms = (total_samples > 0) ? (float)sqrt(sum_sq / (double)total_samples) : 0.0f;

    uint32_t dropped = 0;
    uint32_t written = ld_ring_write_interleaved(ctx->ring, interleaved_samples, frame_count, &dropped);
    ld_rt_update_metrics_and_flags(ctx, peak, rms, has_valid, host_time, written, dropped);
}
