#include "CLiteDictateAudio.h"

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Active-channel detection thresholds:
// - Noise floor below which we treat input as digital silence (-100 dBFS)
#define LD_SILENCE_FLOOR_RMS 1e-5f
// - A channel within -12 dB (0.25x) of the strongest channel is considered active.
//   An unplugged XLR/TRS input on a 2ch/4ch USB interface sits far below -12 dB relative
//   to the active mic and receives weight 0.0 (avoiding -6 dB / -12 dB attenuation).
#define LD_ACTIVE_CHANNEL_RATIO 0.25f
#define LD_ENERGY_ATTACK_ALPHA 0.60f
#define LD_ENERGY_DECAY_ALPHA 0.05f

struct LDPreDownmixer {
    uint32_t channels;
    bool initialized;
    float smoothed_rms[LD_AUDIO_MAX_CHANNELS];
    float last_weights[LD_AUDIO_MAX_CHANNELS];
};

LDPreDownmixer *ld_predownmixer_create(uint32_t channels) {
    if (channels == 0 || channels > LD_AUDIO_MAX_CHANNELS) {
        return NULL;
    }
    LDPreDownmixer *mixer = (LDPreDownmixer *)calloc(1, sizeof(LDPreDownmixer));
    if (mixer == NULL) {
        return NULL;
    }
    mixer->channels = channels;
    ld_predownmixer_reset(mixer);
    return mixer;
}

void ld_predownmixer_destroy(LDPreDownmixer *mixer) {
    free(mixer);
}

void ld_predownmixer_reset(LDPreDownmixer *mixer) {
    mixer->initialized = false;
    memset(mixer->smoothed_rms, 0, sizeof(mixer->smoothed_rms));
    float uniform = (mixer->channels > 0) ? (1.0f / (float)mixer->channels) : 1.0f;
    for (uint32_t c = 0; c < mixer->channels; ++c) {
        mixer->last_weights[c] = uniform;
    }
}

void ld_audio_measure_mono(
    const float *samples,
    uint32_t count,
    float *out_peak,
    float *out_rms
) {
    if (samples == NULL || count == 0) {
        if (out_peak != NULL) {
            *out_peak = 0.0f;
        }
        if (out_rms != NULL) {
            *out_rms = 0.0f;
        }
        return;
    }

    if (out_peak != NULL) {
        float peak = 0.0f;
        vDSP_maxmgv(samples, 1, &peak, (vDSP_Length)count);
        *out_peak = isfinite(peak) ? peak : 0.0f;
    }
    if (out_rms != NULL) {
        float rms = 0.0f;
        vDSP_rmsqv(samples, 1, &rms, (vDSP_Length)count);
        *out_rms = isfinite(rms) ? rms : 0.0f;
    }
}

float ld_predownmixer_process(
    LDPreDownmixer *mixer,
    const float *interleaved_in,
    float *mono_out,
    uint32_t frame_count
) {
    if (mixer == NULL || interleaved_in == NULL || mono_out == NULL || frame_count == 0) {
        return 0.0f;
    }

    const uint32_t channels = mixer->channels;
    if (channels == 1) {
        memcpy(mono_out, interleaved_in, (size_t)frame_count * sizeof(float));
        mixer->last_weights[0] = 1.0f;
        float peak = 0.0f;
        vDSP_maxmgv(mono_out, 1, &peak, (vDSP_Length)frame_count);
        return isfinite(peak) ? peak : 0.0f;
    }

    // Step 1: Measure per-channel RMS via strided Accelerate vDSP_rmsqv (zero deinterleave alloc).
    float chunk_rms[LD_AUDIO_MAX_CHANNELS];
    float chunk_max_rms = 0.0f;
    float prev_max_rms = 0.0f;

    for (uint32_t c = 0; c < channels; ++c) {
        float rms = 0.0f;
        vDSP_rmsqv(interleaved_in + c, (vDSP_Stride)channels, &rms, (vDSP_Length)frame_count);
        if (!isfinite(rms) || rms < 0.0f) {
            rms = 0.0f;
        }
        chunk_rms[c] = rms;
        if (rms > chunk_max_rms) {
            chunk_max_rms = rms;
        }
        if (mixer->smoothed_rms[c] > prev_max_rms) {
            prev_max_rms = mixer->smoothed_rms[c];
        }
    }

    // Step 2: Update per-channel smoothed energy tracker.
    // Snap immediately on first audio or when emerging from digital silence so active channels
    // lock in on the very first frame without any startup attenuation.
    const bool snap = (!mixer->initialized) || (prev_max_rms <= LD_SILENCE_FLOOR_RMS && chunk_max_rms > LD_SILENCE_FLOOR_RMS);
    float max_smoothed = 0.0f;
    for (uint32_t c = 0; c < channels; ++c) {
        if (snap) {
            mixer->smoothed_rms[c] = chunk_rms[c];
        } else {
            float prev = mixer->smoothed_rms[c];
            float alpha = (chunk_rms[c] > prev) ? LD_ENERGY_ATTACK_ALPHA : LD_ENERGY_DECAY_ALPHA;
            mixer->smoothed_rms[c] = prev + alpha * (chunk_rms[c] - prev);
        }
        if (mixer->smoothed_rms[c] > max_smoothed) {
            max_smoothed = mixer->smoothed_rms[c];
        }
    }
    mixer->initialized = true;

    // Step 3: Compute normalized active-channel weights (sum of weights == 1.0).
    float weights[LD_AUDIO_MAX_CHANNELS];
    memset(weights, 0, sizeof(weights));

    if (max_smoothed <= LD_SILENCE_FLOOR_RMS) {
        float uniform = 1.0f / (float)channels;
        for (uint32_t c = 0; c < channels; ++c) {
            weights[c] = uniform;
        }
    } else {
        const float active_cutoff = max_smoothed * LD_ACTIVE_CHANNEL_RATIO;
        float energy_sum = 0.0f;
        for (uint32_t c = 0; c < channels; ++c) {
            if (mixer->smoothed_rms[c] >= active_cutoff) {
                energy_sum += mixer->smoothed_rms[c];
            }
        }
        if (energy_sum > 0.0f) {
            for (uint32_t c = 0; c < channels; ++c) {
                if (mixer->smoothed_rms[c] >= active_cutoff) {
                    weights[c] = mixer->smoothed_rms[c] / energy_sum;
                }
            }
        } else {
            weights[0] = 1.0f;
        }
    }

    // Step 4: Mix active channels into mono_out via strided Accelerate vDSP_vsmul / vDSP_vsma.
    bool wrote_any = false;
    for (uint32_t c = 0; c < channels; ++c) {
        mixer->last_weights[c] = weights[c];
        float w = weights[c];
        if (w <= 0.0f) {
            continue;
        }
        if (!wrote_any) {
            vDSP_vsmul(
                interleaved_in + c,
                (vDSP_Stride)channels,
                &w,
                mono_out,
                1,
                (vDSP_Length)frame_count
            );
            wrote_any = true;
        } else {
            vDSP_vsma(
                interleaved_in + c,
                (vDSP_Stride)channels,
                &w,
                mono_out,
                1,
                mono_out,
                1,
                (vDSP_Length)frame_count
            );
        }
    }

    if (!wrote_any) {
        memset(mono_out, 0, (size_t)frame_count * sizeof(float));
    }

    float peak = 0.0f;
    vDSP_maxmgv(mono_out, 1, &peak, (vDSP_Length)frame_count);
    return isfinite(peak) ? peak : 0.0f;
}

uint32_t ld_predownmixer_get_last_weights(
    const LDPreDownmixer *mixer,
    float *out_weights,
    uint32_t max_channels
) {
    if (mixer == NULL || out_weights == NULL) {
        return 0;
    }
    uint32_t count = (mixer->channels < max_channels) ? mixer->channels : max_channels;
    for (uint32_t c = 0; c < count; ++c) {
        out_weights[c] = mixer->last_weights[c];
    }
    return count;
}
