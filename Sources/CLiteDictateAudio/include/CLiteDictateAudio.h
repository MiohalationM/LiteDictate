#ifndef CLITEDICTATE_AUDIO_H
#define CLITEDICTATE_AUDIO_H

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Hard maximum input channels tracked by pre-downmixer and capture context.
#define LD_AUDIO_MAX_CHANNELS 16U

/// Default cap on SPSC ring buffer backing storage (512 KiB).
/// Combined with 29.5s 16 kHz mono PCMStore (1.888 MB) and scratch buffers,
/// total streaming audio RAM stays strictly <= 2.5 MB regardless of hardware
/// channel count or sample rate.
#define LD_AUDIO_DEFAULT_RING_MAX_BYTES (512U * 1024U)

/// Custom OSStatus returned by the AudioConverter input callback when the
/// ring buffer is temporarily starved (NOT end-of-stream) so AudioConverter
/// preserves its resampling filter state ('LDnd' = 0x4C446E64).
static const OSStatus kLiteDictateAudioNoDataNow = (OSStatus)0x4C446E64;

// MARK: - Lock-Free SPSC Ring Buffer (C11 <stdatomic.h>)

typedef struct LDRingBuffer LDRingBuffer;

/// Allocates a bounded C11 lock-free SPSC ring buffer for interleaved Float32 frames.
///
/// Capacity in frames is `min(ceil(sample_rate * duration_seconds), max_bytes / (channels * sizeof(float)))`,
/// clamped to at least 1 frame. Passing `max_bytes == 0` uses `LD_AUDIO_DEFAULT_RING_MAX_BYTES`.
LDRingBuffer * _Nullable ld_ring_create(
    uint32_t channels,
    double sample_rate,
    double duration_seconds,
    size_t max_bytes
);

/// Allocates a C11 lock-free SPSC ring buffer with an explicit frame capacity (for deterministic tests).
LDRingBuffer * _Nullable ld_ring_create_exact(uint32_t channels, uint32_t capacity_frames);

void ld_ring_destroy(LDRingBuffer * _Nullable rb);

/// Resets read/write indices to 0. Caller MUST ensure neither producer nor consumer is running.
void ld_ring_reset(LDRingBuffer * _Nonnull rb);

uint32_t ld_ring_capacity_frames(const LDRingBuffer * _Nonnull rb);
uint32_t ld_ring_channels(const LDRingBuffer * _Nonnull rb);
size_t ld_ring_byte_capacity(const LDRingBuffer * _Nonnull rb);
uint32_t ld_ring_available_read(const LDRingBuffer * _Nonnull rb);
uint32_t ld_ring_available_write(const LDRingBuffer * _Nonnull rb);

/// Producer-only lock-free write of interleaved Float32 frames.
/// Overflow policy: preserves all unread old frames, writes up to available space,
/// rejects remaining new frames, and writes rejected count to `*out_dropped_frames` (if non-NULL).
/// Returns number of frames actually written.
uint32_t ld_ring_write_interleaved(
    LDRingBuffer * _Nonnull rb,
    const float * _Nonnull interleaved_samples,
    uint32_t frame_count,
    uint32_t * _Nullable out_dropped_frames
);

/// Producer-only lock-free write from non-interleaved channel pointers.
/// Same overflow policy as `ld_ring_write_interleaved`. Zero heap allocations.
uint32_t ld_ring_write_noninterleaved(
    LDRingBuffer * _Nonnull rb,
    const float * _Nonnull const * _Nonnull channel_ptrs,
    uint32_t num_channels,
    uint32_t frame_count,
    uint32_t * _Nullable out_dropped_frames
);

/// Consumer-only lock-free read of interleaved Float32 frames.
/// Returns number of frames actually read (up to `max_frames`).
uint32_t ld_ring_read_interleaved(
    LDRingBuffer * _Nonnull rb,
    float * _Nonnull out_interleaved,
    uint32_t max_frames
);

// MARK: - Monotonic Consumer Waiter (pthread_cond_timedwait_relative_np)

typedef struct LDConsumerWaiter LDConsumerWaiter;

LDConsumerWaiter * _Nullable ld_waiter_create(void);
void ld_waiter_destroy(LDConsumerWaiter * _Nullable waiter);

/// Resets wake flag prior to starting consumer loop.
void ld_waiter_reset(LDConsumerWaiter * _Nonnull waiter);

/// Waits up to `timeout_ms` on the Darwin monotonic clock, returning early if signalled.
/// Returns true if woken by an explicit signal, false on timeout.
bool ld_waiter_wait_ms(LDConsumerWaiter * _Nonnull waiter, uint32_t timeout_ms);

/// Wakes the consumer immediately (called by control thread on Draining/Stop, NEVER from RT callback).
void ld_waiter_signal(LDConsumerWaiter * _Nonnull waiter);

// MARK: - Independent Heap-Allocated Capture Context & Pure C RT Callback

typedef struct LDCaptureContext LDCaptureContext;

typedef struct LDCaptureTelemetry {
    bool capture_started;
    bool first_frame_received;
    bool speech_detected;
    bool audio_interrupted;
    uint64_t dropped_frames;
    uint64_t total_frames_received;
    uint64_t render_error_count;
    int32_t last_render_status;
    uint64_t first_frame_host_time;
    float meter_peak_linear;
    float meter_rms_linear;
    float session_peak_linear;
} LDCaptureTelemetry;

/// Creates an independent heap-allocated capture context owning the pre-allocated
/// scratch AudioBufferList, bounded 2-second SPSC ring buffer, and atomic flags/telemetry.
/// MUST NOT be destroyed until AUHAL is stopped, callback cleared, AudioComponentInstanceDispose
/// has returned, and the consumer thread has exited.
LDCaptureContext * _Nullable ld_capture_context_create(
    uint32_t channels,
    double sample_rate,
    uint32_t max_frames_per_slice,
    bool is_non_interleaved,
    double ring_duration_seconds,
    size_t ring_max_bytes
);

void ld_capture_context_destroy(LDCaptureContext * _Nullable ctx);

/// Binds (or clears with NULL) the AudioUnit pulled by `ld_auhal_input_callback`.
/// Caller MUST only invoke when the AUHAL is stopped.
void ld_capture_context_set_audio_unit(
    LDCaptureContext * _Nonnull ctx,
    AudioUnit _Nullable audio_unit
);

/// Resets ring buffer and all per-session atomic counters/flags for a fresh capture.
/// Caller MUST only invoke when AUHAL is stopped and consumer thread is not running.
void ld_capture_context_reset_session(LDCaptureContext * _Nonnull ctx);

/// Enables or disables RT callback ingestion (atomic release store).
/// Set true before AudioOutputUnitStart; set false immediately when entering Stopping/Quiescing.
void ld_capture_context_set_accept_audio(LDCaptureContext * _Nonnull ctx, bool accept);
bool ld_capture_context_get_accept_audio(const LDCaptureContext * _Nonnull ctx);

/// Marks audio interrupted externally (e.g. pinned microphone unplugged mid-recording).
void ld_capture_context_mark_interrupted(LDCaptureContext * _Nonnull ctx);

/// Sets linear RMS threshold above which `speech_detected` latches true (default ~0.0056 = -45 dBFS).
void ld_capture_context_set_speech_threshold(LDCaptureContext * _Nonnull ctx, float linear_rms);

/// Atomically reads a snapshot of RT state flags and meter levels (safe at 15 Hz from any thread).
LDCaptureTelemetry ld_capture_context_read_telemetry(const LDCaptureContext * _Nonnull ctx);

/// Returns direct pointer to the owned SPSC ring buffer for the consumer thread.
LDRingBuffer * _Nonnull ld_capture_context_ring_buffer(LDCaptureContext * _Nonnull ctx);

uint32_t ld_capture_context_channels(const LDCaptureContext * _Nonnull ctx);
double ld_capture_context_sample_rate(const LDCaptureContext * _Nonnull ctx);
size_t ld_capture_context_memory_bytes(const LDCaptureContext * _Nonnull ctx);

/// Pure C `@convention(c)` AUHAL Input Render Callback.
/// RT SAFETY CONTRACT:
///   - ZERO heap allocations
///   - ZERO locks / mutexes / condition signals
///   - ZERO Swift ARC / Swift runtime calls
///   - ZERO Objective-C messaging
///   - ZERO blocking syscalls or logging
OSStatus ld_auhal_input_callback(
    void * _Nonnull inRefCon,
    AudioUnitRenderActionFlags * _Nonnull ioActionFlags,
    const AudioTimeStamp * _Nonnull inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList * _Nullable ioData
);

/// Deterministic helper exercising the exact same lock-free ingest, validation,
/// meter update, and overflow logic as `ld_auhal_input_callback` without hardware I/O.
void ld_capture_context_ingest_interleaved_for_testing(
    LDCaptureContext * _Nonnull ctx,
    const float * _Nonnull interleaved_samples,
    uint32_t frame_count,
    uint64_t host_time
);

// MARK: - Multi-Channel Pre-Downmix Helper (P1-4, Accelerate/vDSP)

typedef struct LDPreDownmixer LDPreDownmixer;

LDPreDownmixer * _Nullable ld_predownmixer_create(uint32_t channels);
void ld_predownmixer_destroy(LDPreDownmixer * _Nullable mixer);
void ld_predownmixer_reset(LDPreDownmixer * _Nonnull mixer);

/// Downmixes `frame_count` interleaved `channels`-channel Float32 frames to `1ch` Float32
/// at the native hardware sample rate using Accelerate `vDSP` with active-channel RMS energy tracking.
/// Avoids `-6 dB` / `-12 dB` attenuation when only a subset of interface inputs are plugged in.
/// Returns the chunk's peak absolute amplitude in the resulting mono buffer.
float ld_predownmixer_process(
    LDPreDownmixer * _Nonnull mixer,
    const float * _Nonnull interleaved_in,
    float * _Nonnull mono_out,
    uint32_t frame_count
);

/// Reads the last computed per-channel weights (up to `max_channels`), returning actual channel count.
uint32_t ld_predownmixer_get_last_weights(
    const LDPreDownmixer * _Nonnull mixer,
    float * _Nonnull out_weights,
    uint32_t max_channels
);

/// Computes peak absolute amplitude and RMS of a mono Float32 buffer using Accelerate `vDSP`.
void ld_audio_measure_mono(
    const float * _Nonnull samples,
    uint32_t count,
    float * _Nullable out_peak,
    float * _Nullable out_rms
);

#ifdef __cplusplus
}
#endif

#endif /* CLITEDICTATE_AUDIO_H */
