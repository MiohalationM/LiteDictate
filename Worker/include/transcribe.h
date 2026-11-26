#ifndef LITEDICTATE_TRANSCRIBE_H
#define LITEDICTATE_TRANSCRIBE_H

// C ABI header for handy-computer/transcribe.cpp v0.4.1 (MIT)
// ABI header hash: f99ad4169374b8f3
// Layouts verified against libtranscribe.dylib exported ABI table.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Status codes ----------------------------------------------------------

typedef enum transcribe_status {
    TRANSCRIBE_OK = 0,
    TRANSCRIBE_ERR_INVALID_ARG = 1,
    TRANSCRIBE_ERR_NOT_IMPLEMENTED = 2,
    TRANSCRIBE_ERR_FILE_NOT_FOUND = 3,
    TRANSCRIBE_ERR_GGUF = 4,
    TRANSCRIBE_ERR_UNSUPPORTED_ARCH = 5,
    TRANSCRIBE_ERR_UNSUPPORTED_VARIANT = 6,
    TRANSCRIBE_ERR_OOM = 7,
    TRANSCRIBE_ERR_BACKEND = 8,
    TRANSCRIBE_ERR_SAMPLE_RATE = 9,
    TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE = 10,
    TRANSCRIBE_ERR_UNSUPPORTED_TASK = 11,
    TRANSCRIBE_ERR_UNSUPPORTED_TIMESTAMPS = 12,
    TRANSCRIBE_ERR_ABORTED = 13,
    TRANSCRIBE_ERR_BAD_STRUCT_SIZE = 14,
    TRANSCRIBE_ERR_UNSUPPORTED_PNC = 15,
    TRANSCRIBE_ERR_UNSUPPORTED_ITN = 16,
    TRANSCRIBE_ERR_INPUT_TOO_LONG = 17,
    TRANSCRIBE_ERR_OUTPUT_TRUNCATED = 18,
    TRANSCRIBE_ERR_OUTPUT_REPETITION = 19,
    TRANSCRIBE_ERR_UNSUPPORTED_ROLE = 20,
    TRANSCRIBE_ERR_INPUT_TOO_SHORT = 21
} transcribe_status;

typedef enum transcribe_abi_struct {
    TRANSCRIBE_ABI_MODEL_LOAD_PARAMS = 0,
    TRANSCRIBE_ABI_SESSION_PARAMS = 1,
    TRANSCRIBE_ABI_RUN_PARAMS = 2,
    TRANSCRIBE_ABI_STREAM_PARAMS = 3,
    TRANSCRIBE_ABI_CAPABILITIES = 4,
    TRANSCRIBE_ABI_TIMINGS = 5,
    TRANSCRIBE_ABI_SEGMENT = 6,
    TRANSCRIBE_ABI_WORD = 7,
    TRANSCRIBE_ABI_TOKEN = 8,
    TRANSCRIBE_ABI_STREAM_UPDATE = 9,
    TRANSCRIBE_ABI_STREAM_TEXT = 10,
    TRANSCRIBE_ABI_SESSION_LIMITS = 11,
    TRANSCRIBE_ABI_EXT = 12,
    TRANSCRIBE_ABI_DEVICE_INFO = 13,
    TRANSCRIBE_ABI_SPEAKER_SEGMENT = 14,
    TRANSCRIBE_ABI_BACKEND_INIT_PARAMS = 15
} transcribe_abi_struct;

typedef enum transcribe_log_level {
    TRANSCRIBE_LOG_LEVEL_NONE = 0,
    TRANSCRIBE_LOG_LEVEL_INFO = 1,
    TRANSCRIBE_LOG_LEVEL_WARN = 2,
    TRANSCRIBE_LOG_LEVEL_ERROR = 3,
    TRANSCRIBE_LOG_LEVEL_DEBUG = 4,
    TRANSCRIBE_LOG_LEVEL_CONT = 5
} transcribe_log_level;

typedef enum transcribe_task {
    TRANSCRIBE_TASK_TRANSCRIBE = 0,
    TRANSCRIBE_TASK_TRANSLATE = 1,
    TRANSCRIBE_TASK_INSTRUCT = 2
} transcribe_task;

typedef enum transcribe_timestamp_kind {
    TRANSCRIBE_TIMESTAMPS_NONE = 0,
    TRANSCRIBE_TIMESTAMPS_AUTO = 1,
    TRANSCRIBE_TIMESTAMPS_SEGMENT = 2,
    TRANSCRIBE_TIMESTAMPS_WORD = 3,
    TRANSCRIBE_TIMESTAMPS_TOKEN = 4
} transcribe_timestamp_kind;

typedef enum transcribe_kv_type {
    TRANSCRIBE_KV_TYPE_AUTO = 0,
    TRANSCRIBE_KV_TYPE_F32 = 1,
    TRANSCRIBE_KV_TYPE_F16 = 2
} transcribe_kv_type;

typedef enum transcribe_pnc_mode {
    TRANSCRIBE_PNC_MODE_DEFAULT = 0,
    TRANSCRIBE_PNC_MODE_OFF = 1,
    TRANSCRIBE_PNC_MODE_ON = 2
} transcribe_pnc_mode;

typedef enum transcribe_itn_mode {
    TRANSCRIBE_ITN_MODE_DEFAULT = 0,
    TRANSCRIBE_ITN_MODE_OFF = 1,
    TRANSCRIBE_ITN_MODE_ON = 2
} transcribe_itn_mode;

typedef enum transcribe_diarize_mode {
    TRANSCRIBE_DIARIZE_MODE_DEFAULT = 0,
    TRANSCRIBE_DIARIZE_MODE_OFF = 1,
    TRANSCRIBE_DIARIZE_MODE_ON = 2
} transcribe_diarize_mode;

typedef enum transcribe_ext_slot {
    TRANSCRIBE_EXT_SLOT_RUN = 0,
    TRANSCRIBE_EXT_SLOT_STREAM = 1,
    TRANSCRIBE_EXT_SLOT_DIARIZE_RUN = 2
} transcribe_ext_slot;

typedef enum transcribe_backend_request {
    TRANSCRIBE_BACKEND_AUTO = 0,
    TRANSCRIBE_BACKEND_CPU = 1,
    TRANSCRIBE_BACKEND_METAL = 2,
    TRANSCRIBE_BACKEND_VULKAN = 3,
    TRANSCRIBE_BACKEND_CPU_ACCEL = 4,
    TRANSCRIBE_BACKEND_CUDA = 5,
    TRANSCRIBE_BACKEND_ROCM = 6
} transcribe_backend_request;

typedef enum transcribe_device_type {
    TRANSCRIBE_DEVICE_TYPE_CPU = 0,
    TRANSCRIBE_DEVICE_TYPE_GPU = 1,
    TRANSCRIBE_DEVICE_TYPE_IGPU = 2,
    TRANSCRIBE_DEVICE_TYPE_ACCEL = 3
} transcribe_device_type;

typedef enum transcribe_role {
    TRANSCRIBE_ROLE_ASR = 1,
    TRANSCRIBE_ROLE_DIARIZE = 2,
    TRANSCRIBE_ROLE_LANGID = 4,
    TRANSCRIBE_ROLE_VAD = 8
} transcribe_role;

typedef enum transcribe_feature {
    TRANSCRIBE_FEATURE_INITIAL_PROMPT = 0,
    TRANSCRIBE_FEATURE_TEMPERATURE_FALLBACK = 1,
    TRANSCRIBE_FEATURE_LONG_FORM = 2,
    TRANSCRIBE_FEATURE_CANCELLATION = 3,
    TRANSCRIBE_FEATURE_PNC = 4,
    TRANSCRIBE_FEATURE_ITN = 5,
    TRANSCRIBE_FEATURE_DIARIZATION = 6,
    TRANSCRIBE_FEATURE_VOCABULARY = 7,
    TRANSCRIBE_FEATURE_CONTEXT_PROMPT = 8,
    TRANSCRIBE_FEATURE_INSTRUCT = 9,
    TRANSCRIBE_FEATURE_TRANSCRIPT_PREFIX = 10
} transcribe_feature;

typedef enum transcribe_whisper_prompt_condition {
    TRANSCRIBE_WHISPER_PROMPT_FIRST_SEGMENT = 0,
    TRANSCRIBE_WHISPER_PROMPT_ALL_SEGMENTS = 1
} transcribe_whisper_prompt_condition;

#define TRANSCRIBE_BACKEND_MASK_ALL   0xFFFFFFFFu
#define TRANSCRIBE_BACKEND_MASK_CPU   0x00000001u
#define TRANSCRIBE_BACKEND_MASK_METAL 0x00000002u

#define TRANSCRIBE_EXT_KIND_WHISPER_RUN 1314015319u

// ---- Opaque handles & callbacks --------------------------------------------

struct transcribe_model;
struct transcribe_session;
typedef void *transcribe_device_t;

typedef bool (*transcribe_abort_callback)(void *userdata);
typedef void (*transcribe_log_callback)(int level, const char *msg, void *userdata);

// ---- ABI Structs -----------------------------------------------------------

struct transcribe_ext {
    uint64_t size;
    uint32_t kind;
};

struct transcribe_backend_init_params {
    uint64_t struct_size;
    const char *artifact_dir;
    uint32_t allowed_backends;
};

struct transcribe_device_info {
    uint64_t struct_size;
    const char *name;
    const char *description;
    const char *kind;
    const char *device_id;
    uint64_t memory_total;
    uint64_t memory_free;
    int device_type;
};

struct transcribe_model_load_params {
    uint64_t struct_size;
    int backend;
    transcribe_device_t device;
    bool no_mmap;
};

struct transcribe_session_params {
    uint64_t struct_size;
    int n_threads;
    int kv_type;
    int32_t n_ctx;
};

struct transcribe_run_params {
    uint64_t struct_size;
    int task;
    int timestamps;
    int pnc;
    int itn;
    int diarize;
    const char *language;
    const char *target_language;
    bool keep_special_tags;
    const void *family;
    int32_t spec_k_drafts;
    const char *const *vocabulary;
    int32_t n_vocabulary;
    const char *prompt;
    const char *prefix;
};

struct transcribe_capabilities {
    uint64_t struct_size;
    int32_t native_sample_rate;
    int n_languages;
    const char *const *languages;
    int max_timestamp_kind;
    bool supports_language_detect;
    bool supports_translate;
    bool supports_streaming;
    bool supports_spec_decode;
    int64_t max_audio_ms;
    int n_translate_target_languages;
    const char *const *translate_target_languages;
};

struct transcribe_session_limits {
    uint64_t struct_size;
    int32_t effective_n_ctx;
    int64_t effective_max_audio_ms;
    int64_t max_kv_bytes;
};

struct transcribe_timings {
    uint64_t struct_size;
    float load_ms;
    float mel_ms;
    float encode_ms;
    float decode_ms;
};

struct transcribe_whisper_run_ext {
    struct transcribe_ext ext;
    const char *initial_prompt;
    const int32_t *prompt_tokens;
    size_t n_prompt_tokens;
    int prompt_condition;
    bool condition_on_prev_tokens;
    int32_t max_prev_context_tokens;
    float temperature;
    float temperature_inc;
    float compression_ratio_thold;
    float logprob_thold;
    float no_speech_thold;
    uint32_t seed;
    float max_initial_timestamp;
};

// ---- Functions -------------------------------------------------------------

const char *transcribe_version(void);
const char *transcribe_version_commit(void);
const char *transcribe_status_string(int status);
size_t transcribe_abi_struct_size(transcribe_abi_struct s);
size_t transcribe_abi_struct_align(transcribe_abi_struct s);

void transcribe_log_set(transcribe_log_callback cb, void *userdata);

void transcribe_backend_init_params_init(struct transcribe_backend_init_params *params);
transcribe_status transcribe_init_backends(const char *artifact_dir);
transcribe_status transcribe_init_backends_default(void);
transcribe_status transcribe_init_backends_ex(const struct transcribe_backend_init_params *params);
uint32_t transcribe_allowed_backends(void);
bool transcribe_backend_available(transcribe_backend_request backend);
int transcribe_device_count(void);
transcribe_device_t transcribe_device_get(int index);
void transcribe_device_info_init(struct transcribe_device_info *info);
transcribe_status transcribe_device_get_info(transcribe_device_t device, struct transcribe_device_info *info);

void transcribe_model_load_params_init(struct transcribe_model_load_params *params);
transcribe_status transcribe_model_load_file(
    const char *path,
    const struct transcribe_model_load_params *params,
    struct transcribe_model **out_model);
void transcribe_model_free(struct transcribe_model *model);

const char *transcribe_model_arch_string(const struct transcribe_model *model);
const char *transcribe_model_variant_string(const struct transcribe_model *model);
const char *transcribe_model_backend(const struct transcribe_model *model);
transcribe_device_t transcribe_model_device(const struct transcribe_model *model);
uint32_t transcribe_model_roles(const struct transcribe_model *model);
bool transcribe_model_supports(const struct transcribe_model *model, transcribe_feature feature);
bool transcribe_model_accepts_ext_kind(
    const struct transcribe_model *model,
    transcribe_ext_slot slot,
    uint32_t kind);

void transcribe_capabilities_init(struct transcribe_capabilities *caps);
transcribe_status transcribe_model_get_capabilities(
    const struct transcribe_model *model,
    struct transcribe_capabilities *out_caps);

void transcribe_session_params_init(struct transcribe_session_params *params);
transcribe_status transcribe_session_init(
    struct transcribe_model *model,
    const struct transcribe_session_params *params,
    struct transcribe_session **out_session);
void transcribe_session_free(struct transcribe_session *session);

void transcribe_session_limits_init(struct transcribe_session_limits *limits);
transcribe_status transcribe_session_get_limits(
    const struct transcribe_session *session,
    struct transcribe_session_limits *out_limits);

void transcribe_set_abort_callback(
    struct transcribe_session *session,
    transcribe_abort_callback cb,
    void *userdata);
bool transcribe_was_aborted(const struct transcribe_session *session);
bool transcribe_was_truncated(const struct transcribe_session *session);

void transcribe_run_params_init(struct transcribe_run_params *params);
void transcribe_whisper_run_ext_init(struct transcribe_whisper_run_ext *ext);
transcribe_status transcribe_run(
    struct transcribe_session *session,
    const float *samples,
    int n_samples,
    const struct transcribe_run_params *params);

const char *transcribe_full_text(const struct transcribe_session *session);
const char *transcribe_raw_text(const struct transcribe_session *session);
const char *transcribe_detected_language(const struct transcribe_session *session);

void transcribe_timings_init(struct transcribe_timings *timings);
transcribe_status transcribe_get_timings(
    const struct transcribe_session *session,
    struct transcribe_timings *out_timings);

#ifdef __cplusplus
}

// Compile-time ABI layout verification against transcribe.cpp v0.4.1
static_assert(sizeof(transcribe_ext) == 16, "ABI mismatch: transcribe_ext");
static_assert(sizeof(transcribe_backend_init_params) == 24, "ABI mismatch: transcribe_backend_init_params");
static_assert(sizeof(transcribe_device_info) == 64, "ABI mismatch: transcribe_device_info");
static_assert(sizeof(transcribe_model_load_params) == 32, "ABI mismatch: transcribe_model_load_params");
static_assert(sizeof(transcribe_session_params) == 24, "ABI mismatch: transcribe_session_params");
static_assert(sizeof(transcribe_run_params) == 104, "ABI mismatch: transcribe_run_params");
static_assert(sizeof(transcribe_capabilities) == 56, "ABI mismatch: transcribe_capabilities");
static_assert(sizeof(transcribe_session_limits) == 32, "ABI mismatch: transcribe_session_limits");
static_assert(sizeof(transcribe_timings) == 24, "ABI mismatch: transcribe_timings");
static_assert(sizeof(transcribe_whisper_run_ext) == 80, "ABI mismatch: transcribe_whisper_run_ext");

static_assert(offsetof(transcribe_model_load_params, no_mmap) == 24, "ABI offset mismatch");
static_assert(offsetof(transcribe_run_params, vocabulary) == 72, "ABI offset mismatch");
static_assert(offsetof(transcribe_run_params, n_vocabulary) == 80, "ABI offset mismatch");
static_assert(offsetof(transcribe_run_params, prompt) == 88, "ABI offset mismatch");
static_assert(offsetof(transcribe_run_params, prefix) == 96, "ABI offset mismatch");
static_assert(offsetof(transcribe_capabilities, max_audio_ms) == 32, "ABI offset mismatch");
static_assert(offsetof(transcribe_whisper_run_ext, initial_prompt) == 16, "ABI offset mismatch");
#endif

#endif // LITEDICTATE_TRANSCRIBE_H
