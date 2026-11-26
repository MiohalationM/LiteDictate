#include "engine.hpp"
#include "json_codec.hpp"
#include "metrics.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <sys/stat.h>

namespace litedictate {

namespace {

constexpr uint64_t kDefaultMaxModelBytes = 4ULL * 1024ULL * 1024ULL * 1024ULL; // 4 GiB
constexpr int32_t kMinSampleRateHz = 8000;
constexpr int32_t kMaxSampleRateHz = 48000;
constexpr int32_t kDefaultSampleRateHz = 16000;
constexpr int64_t kMinMaxAudioMs = 1000;
constexpr int64_t kMaxMaxAudioMs = 600000;
constexpr int64_t kDefaultMaxAudioMs = 30000;

uint64_t effectiveMaxModelBytes() {
    const char *env = std::getenv("LITEDICTATE_MAX_MODEL_BYTES");
    if (!env || env[0] == '\0') {
        return kDefaultMaxModelBytes;
    }
    char *endp = nullptr;
    errno = 0;
    unsigned long long parsed = std::strtoull(env, &endp, 10);
    if (errno != 0 || !endp || *endp != '\0' || parsed == 0) {
        return kDefaultMaxModelBytes;
    }
    return static_cast<uint64_t>(parsed);
}

bool validateModelFile(const std::string &model_path, std::string &err_out) {
    struct stat st_buf{};
    if (::stat(model_path.c_str(), &st_buf) != 0 || !S_ISREG(st_buf.st_mode)) {
        err_out = "Model file does not exist or is not a regular file";
        return false;
    }
    if (st_buf.st_size <= 0) {
        err_out = "Model file is empty";
        return false;
    }
    const uint64_t file_size = static_cast<uint64_t>(st_buf.st_size);
    const uint64_t max_bytes = effectiveMaxModelBytes();
    if (file_size > max_bytes) {
        err_out = "Model file exceeds maximum allowed size (" +
                  std::to_string(file_size) + " bytes > " +
                  std::to_string(max_bytes) + " bytes limit)";
        return false;
    }
    return true;
}

int32_t sanitizeSampleRate(int32_t rate) {
    if (rate >= kMinSampleRateHz && rate <= kMaxSampleRateHz) {
        return rate;
    }
    return kDefaultSampleRateHz;
}

int64_t sanitizeMaxAudioMs(int64_t ms) {
    if (ms < kMinMaxAudioMs) {
        return kDefaultMaxAudioMs;
    }
    if (ms > kMaxMaxAudioMs) {
        return kMaxMaxAudioMs;
    }
    return ms;
}

void nativeLogCallback(int level, const char *msg, void * /*userdata*/) {
    if (!msg || level == TRANSCRIBE_LOG_LEVEL_NONE) return;
    // Route ggml/transcribe diagnostics strictly to stderr (FD 2).
    std::fprintf(stderr, "[transcribe:%d] %s", level, msg);
    size_t len = std::strlen(msg);
    if (len == 0 || msg[len - 1] != '\n') {
        std::fputc('\n', stderr);
    }
    std::fflush(stderr);
}

bool abortCallbackThunk(void *userdata) {
    if (!userdata) return false;
    auto *flag = static_cast<std::atomic<bool> *>(userdata);
    return flag->load(std::memory_order_acquire);
}

std::string resolveEngineArtifactDir() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void *>(&transcribe_version), &info) != 0 && info.dli_fname) {
        std::string path(info.dli_fname);
        auto slash = path.find_last_of('/');
        if (slash != std::string::npos) {
            return path.substr(0, slash);
        }
    }
    return {};
}

transcribe_pnc_mode parsePncMode(const std::string &s) {
    if (s == "on") return TRANSCRIBE_PNC_MODE_ON;
    if (s == "off") return TRANSCRIBE_PNC_MODE_OFF;
    return TRANSCRIBE_PNC_MODE_DEFAULT;
}

transcribe_itn_mode parseItnMode(const std::string &s) {
    if (s == "on") return TRANSCRIBE_ITN_MODE_ON;
    if (s == "off") return TRANSCRIBE_ITN_MODE_OFF;
    return TRANSCRIBE_ITN_MODE_DEFAULT;
}

std::string joinVocabularyHint(const std::string &context_prompt, const std::vector<std::string> &vocab) {
    std::string out = context_prompt;
    if (!vocab.empty()) {
        if (!out.empty()) {
            out.append(" ");
        }
        for (size_t i = 0; i < vocab.size(); ++i) {
            if (i > 0) out.append(", ");
            out.append(vocab[i]);
        }
    }
    return out;
}

} // namespace

TranscribeEngine::~TranscribeEngine() {
    freeModel();
}

void TranscribeEngine::installStderrLogger() {
    transcribe_log_set(&nativeLogCallback, nullptr);
}

bool TranscribeEngine::verifyRuntimeABI(std::string &err_out) {
    struct Check {
        const char *name;
        transcribe_abi_struct id;
        size_t expected_size;
        size_t expected_align;
    };
    const Check checks[] = {
        {"transcribe_model_load_params", TRANSCRIBE_ABI_MODEL_LOAD_PARAMS, sizeof(transcribe_model_load_params), alignof(transcribe_model_load_params)},
        {"transcribe_session_params",    TRANSCRIBE_ABI_SESSION_PARAMS,    sizeof(transcribe_session_params),    alignof(transcribe_session_params)},
        {"transcribe_run_params",        TRANSCRIBE_ABI_RUN_PARAMS,        sizeof(transcribe_run_params),        alignof(transcribe_run_params)},
        {"transcribe_capabilities",      TRANSCRIBE_ABI_CAPABILITIES,      sizeof(transcribe_capabilities),      alignof(transcribe_capabilities)},
        {"transcribe_timings",           TRANSCRIBE_ABI_TIMINGS,           sizeof(transcribe_timings),           alignof(transcribe_timings)},
        {"transcribe_session_limits",    TRANSCRIBE_ABI_SESSION_LIMITS,    sizeof(transcribe_session_limits),    alignof(transcribe_session_limits)},
        {"transcribe_ext",               TRANSCRIBE_ABI_EXT,               sizeof(transcribe_ext),               alignof(transcribe_ext)},
        {"transcribe_device_info",       TRANSCRIBE_ABI_DEVICE_INFO,       sizeof(transcribe_device_info),       alignof(transcribe_device_info)},
    };
    for (const auto &c : checks) {
        size_t lib_size = transcribe_abi_struct_size(c.id);
        size_t lib_align = transcribe_abi_struct_align(c.id);
        if (lib_size != c.expected_size || lib_align != c.expected_align) {
            err_out = std::string("ABI mismatch for ") + c.name +
                      ": header=(" + std::to_string(c.expected_size) + "," + std::to_string(c.expected_align) +
                      ") lib=(" + std::to_string(lib_size) + "," + std::to_string(lib_align) + ")";
            return false;
        }
    }
    return true;
}

void TranscribeEngine::freeModel() {
    if (model_) {
        transcribe_model_free(model_);
        model_ = nullptr;
        active_meta_ = ModelMetadata{};
    }
}

bool TranscribeEngine::ensureBackendsInitialized(double &init_ms_out, std::string &err_out) {
    init_ms_out = 0.0;
    if (backends_initialized_) {
        return true;
    }
    MonotonicTimer timer;
    std::string artifact_dir = resolveEngineArtifactDir();
    transcribe_status st = TRANSCRIBE_ERR_BACKEND;
    if (!artifact_dir.empty()) {
        st = transcribe_init_backends(artifact_dir.c_str());
    }
    if (st != TRANSCRIBE_OK) {
        st = transcribe_init_backends_default();
    }
    if (st != TRANSCRIBE_OK) {
        const char *s = transcribe_status_string(static_cast<int>(st));
        err_out = std::string("transcribe_init_backends failed: ") + (s ? s : "unknown");
        return false;
    }
    int count = transcribe_device_count();
    if (count <= 0) {
        err_out = "transcribe_init_backends found zero compute devices";
        return false;
    }
    init_ms_out = timer.elapsedMs();
    backends_initialized_ = true;
    return true;
}

transcribe_backend_request TranscribeEngine::parseBackend(
    const std::string &name,
    transcribe_backend_request fallback) {
    if (name == "metal") return TRANSCRIBE_BACKEND_METAL;
    if (name == "cpu") return TRANSCRIBE_BACKEND_CPU;
    if (name == "auto") return TRANSCRIBE_BACKEND_AUTO;
    return fallback;
}

std::vector<std::string> TranscribeEngine::rolesToStrings(uint32_t role_mask) {
    std::vector<std::string> out;
    if (role_mask & TRANSCRIBE_ROLE_ASR) out.emplace_back("asr");
    if (role_mask & TRANSCRIBE_ROLE_DIARIZE) out.emplace_back("diarize");
    if (role_mask & TRANSCRIBE_ROLE_LANGID) out.emplace_back("langid");
    if (role_mask & TRANSCRIBE_ROLE_VAD) out.emplace_back("vad");
    return out;
}

ModelMetadata TranscribeEngine::inspectModel(
    const transcribe_model *model,
    const std::string &model_path,
    double backend_init_ms,
    double load_ms) {
    ModelMetadata meta;
    meta.model_path = model_path;
    meta.roles = rolesToStrings(transcribe_model_roles(model));
    const char *arch = transcribe_model_arch_string(model);
    const char *variant = transcribe_model_variant_string(model);
    const char *backend = transcribe_model_backend(model);
    meta.arch = arch ? arch : "";
    meta.variant = variant ? variant : "";
    meta.backend = backend ? backend : "";
    meta.backend_init_ms = backend_init_ms;
    meta.load_ms = load_ms;

    transcribe_capabilities caps{};
    transcribe_capabilities_init(&caps);
    if (transcribe_model_get_capabilities(model, &caps) == TRANSCRIBE_OK) {
        meta.native_sample_rate = sanitizeSampleRate(caps.native_sample_rate);
        meta.max_audio_ms = sanitizeMaxAudioMs(caps.max_audio_ms);
        meta.supports_language_detect = caps.supports_language_detect;
        meta.supports_streaming = caps.supports_streaming;
        if (caps.languages && caps.n_languages > 0) {
            meta.languages.reserve(static_cast<size_t>(caps.n_languages));
            for (int i = 0; i < caps.n_languages; ++i) {
                if (caps.languages[i]) {
                    meta.languages.emplace_back(caps.languages[i]);
                }
            }
        }
    } else {
        meta.native_sample_rate = kDefaultSampleRateHz;
        meta.max_audio_ms = kDefaultMaxAudioMs;
    }

    meta.supports_vocabulary = transcribe_model_supports(model, TRANSCRIBE_FEATURE_VOCABULARY);
    meta.supports_context_prompt = transcribe_model_supports(model, TRANSCRIBE_FEATURE_CONTEXT_PROMPT);
    meta.supports_initial_prompt = transcribe_model_supports(model, TRANSCRIBE_FEATURE_INITIAL_PROMPT);
    meta.accepts_whisper_run_ext = transcribe_model_accepts_ext_kind(
        model, TRANSCRIBE_EXT_SLOT_RUN, TRANSCRIBE_EXT_KIND_WHISPER_RUN);
    meta.supports_pnc = transcribe_model_supports(model, TRANSCRIBE_FEATURE_PNC);
    meta.supports_itn = transcribe_model_supports(model, TRANSCRIBE_FEATURE_ITN);
    meta.supports_cancellation = transcribe_model_supports(model, TRANSCRIBE_FEATURE_CANCELLATION);
    meta.phys_footprint_bytes = currentPhysFootprintBytes();
    return meta;
}

std::string TranscribeEngine::serializeModelMetadata(const ModelMetadata &meta, bool include_backend_init) {
    JsonBuilder jb;
    jb.addString("modelPath", meta.model_path);
    jb.addStringArray("roles", meta.roles);
    jb.addString("arch", meta.arch);
    jb.addString("variant", meta.variant);
    jb.addString("backend", meta.backend);
    jb.addInt64("nativeSampleRate", meta.native_sample_rate);
    jb.addInt64("maxAudioMs", meta.max_audio_ms);
    jb.addStringArray("languages", meta.languages);
    jb.addBool("supportsLanguageDetect", meta.supports_language_detect);
    jb.addBool("supportsStreaming", meta.supports_streaming);
    jb.addBool("supportsVocabulary", meta.supports_vocabulary);
    jb.addBool("supportsContextPrompt", meta.supports_context_prompt);
    jb.addBool("supportsInitialPrompt", meta.supports_initial_prompt);
    jb.addBool("supportsPnc", meta.supports_pnc);
    jb.addBool("supportsItn", meta.supports_itn);
    jb.addBool("supportsCancellation", meta.supports_cancellation);
    if (include_backend_init) {
        jb.addDouble("backendInitMs", meta.backend_init_ms);
    }
    jb.addDouble("loadMs", meta.load_ms);
    jb.addUint64("physFootprintBytes", meta.phys_footprint_bytes);
    return jb.finish();
}

std::string TranscribeEngine::serializeError(
    LDPErrorCode code,
    const std::string &message,
    int native_status,
    const std::vector<std::string> *roles,
    const std::string *arch,
    const std::string *variant) {
    JsonBuilder jb;
    jb.addUint64("code", static_cast<uint32_t>(code));
    jb.addString("codeName", ldpErrorCodeName(code));
    jb.addString("message", message);
    if (native_status != 0) {
        jb.addInt64("nativeStatus", native_status);
    }
    if (roles) {
        jb.addStringArray("roles", *roles);
    }
    if (arch && !arch->empty()) {
        jb.addString("arch", *arch);
    }
    if (variant && !variant->empty()) {
        jb.addString("variant", *variant);
    }
    return jb.finish();
}

EngineOutcome TranscribeEngine::probeModel(const std::string &model_path, const std::string &backend_name) {
    EngineOutcome out;
    if (model_ != nullptr) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrBusy);
        out.payload_json = serializeError(
            LDPErrorCode::ErrBusy,
            "Cannot probe model while another model is resident (zero dual-model residency)");
        return out;
    }
    if (model_path.empty()) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "modelPath is required");
        return out;
    }

    std::string file_err;
    if (!validateModelFile(model_path, file_err)) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(LDPErrorCode::ErrModelLoad, file_err);
        return out;
    }

    double backend_init_ms = 0.0;
    std::string init_err;
    if (!ensureBackendsInitialized(backend_init_ms, init_err)) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(LDPErrorCode::ErrModelLoad, init_err);
        return out;
    }

    transcribe_model_load_params lparams{};
    transcribe_model_load_params_init(&lparams);
    transcribe_backend_request req_backend = parseBackend(backend_name, TRANSCRIBE_BACKEND_CPU);
    if (req_backend != TRANSCRIBE_BACKEND_AUTO && !transcribe_backend_available(req_backend)) {
        req_backend = TRANSCRIBE_BACKEND_AUTO;
    }
    lparams.backend = static_cast<int>(req_backend);
    lparams.no_mmap = false;

    transcribe_model *probed = nullptr;
    MonotonicTimer load_timer;
    transcribe_status st = transcribe_model_load_file(model_path.c_str(), &lparams, &probed);
    double load_ms = load_timer.elapsedMs();

    if (st != TRANSCRIBE_OK || !probed) {
        const char *msg = transcribe_status_string(static_cast<int>(st));
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(
            LDPErrorCode::ErrModelLoad,
            std::string("Failed to load model for probe: ") + (msg ? msg : "unknown"),
            static_cast<int>(st));
        return out;
    }

    uint32_t role_mask = transcribe_model_roles(probed);
    std::vector<std::string> roles = rolesToStrings(role_mask);
    if ((role_mask & TRANSCRIBE_ROLE_ASR) == 0) {
        const char *arch_c = transcribe_model_arch_string(probed);
        const char *var_c = transcribe_model_variant_string(probed);
        std::string arch = arch_c ? arch_c : "";
        std::string variant = var_c ? var_c : "";
        transcribe_model_free(probed);

        std::string role_list;
        for (size_t i = 0; i < roles.size(); ++i) {
            if (i > 0) role_list += ",";
            role_list += roles[i];
        }
        if (role_list.empty()) role_list = "none";

        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrUnsupportedRole);
        out.payload_json = serializeError(
            LDPErrorCode::ErrUnsupportedRole,
            "Model does not support ASR role (actual roles: " + role_list + ")",
            static_cast<int>(TRANSCRIBE_ERR_UNSUPPORTED_ROLE),
            &roles,
            &arch,
            &variant);
        return out;
    }

    ModelMetadata meta = inspectModel(probed, model_path, backend_init_ms, load_ms);
    transcribe_model_free(probed);
    meta.phys_footprint_bytes = currentPhysFootprintBytes();

    out.response_type = LDPMessageType::ProbeResult;
    out.status_or_flags = 0;
    out.payload_json = serializeModelMetadata(meta, false);
    return out;
}

EngineOutcome TranscribeEngine::warmupModel(
    const std::string &model_path,
    const std::string &backend_name,
    bool no_mmap) {
    EngineOutcome out;
    if (model_path.empty()) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "modelPath is required");
        return out;
    }

    std::string file_err;
    if (!validateModelFile(model_path, file_err)) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(LDPErrorCode::ErrModelLoad, file_err);
        return out;
    }

    // Never hold two models resident simultaneously.
    freeModel();

    double backend_init_ms = 0.0;
    std::string init_err;
    if (!ensureBackendsInitialized(backend_init_ms, init_err)) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(LDPErrorCode::ErrModelLoad, init_err);
        return out;
    }

    transcribe_model_load_params lparams{};
    transcribe_model_load_params_init(&lparams);
    transcribe_backend_request req_backend = parseBackend(backend_name, TRANSCRIBE_BACKEND_METAL);
    if (req_backend != TRANSCRIBE_BACKEND_AUTO && !transcribe_backend_available(req_backend)) {
        req_backend = TRANSCRIBE_BACKEND_AUTO;
    }
    lparams.backend = static_cast<int>(req_backend);
    lparams.no_mmap = no_mmap;

    transcribe_model *loaded = nullptr;
    MonotonicTimer load_timer;
    transcribe_status st = transcribe_model_load_file(model_path.c_str(), &lparams, &loaded);
    double load_ms = load_timer.elapsedMs();

    if (st != TRANSCRIBE_OK || !loaded) {
        const char *msg = transcribe_status_string(static_cast<int>(st));
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelLoad);
        out.payload_json = serializeError(
            LDPErrorCode::ErrModelLoad,
            std::string("Failed to load model: ") + (msg ? msg : "unknown"),
            static_cast<int>(st));
        return out;
    }

    uint32_t role_mask = transcribe_model_roles(loaded);
    std::vector<std::string> roles = rolesToStrings(role_mask);
    if ((role_mask & TRANSCRIBE_ROLE_ASR) == 0) {
        const char *arch_c = transcribe_model_arch_string(loaded);
        const char *var_c = transcribe_model_variant_string(loaded);
        std::string arch = arch_c ? arch_c : "";
        std::string variant = var_c ? var_c : "";
        transcribe_model_free(loaded);

        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrUnsupportedRole);
        out.payload_json = serializeError(
            LDPErrorCode::ErrUnsupportedRole,
            "Model does not support ASR role",
            static_cast<int>(TRANSCRIBE_ERR_UNSUPPORTED_ROLE),
            &roles,
            &arch,
            &variant);
        return out;
    }

    model_ = loaded;
    active_meta_ = inspectModel(model_, model_path, backend_init_ms, load_ms);

    out.response_type = LDPMessageType::Ready;
    out.status_or_flags = 0;
    out.payload_json = serializeModelMetadata(active_meta_, true);
    return out;
}

EngineOutcome TranscribeEngine::runTranscribe(
    const std::shared_ptr<InferenceJob> &job,
    const TranscribeRequest &req) {
    EngineOutcome out;
    if (!model_) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrModelNotLoaded);
        out.payload_json = serializeError(LDPErrorCode::ErrModelNotLoaded, "No model warmed up");
        return out;
    }

    if (req.sample_rate != 0 && req.sample_rate != active_meta_.native_sample_rate) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(
            LDPErrorCode::ErrInvalidPayload,
            "Sample rate mismatch: expected " + std::to_string(active_meta_.native_sample_rate));
        return out;
    }

    if (req.vocabulary.size() > kMaxVocabularyEntries) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "Vocabulary exceeds 50 entries");
        return out;
    }

    if (req.pcm.empty()) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "PCM audio is empty");
        return out;
    }

    // Reject NaN / Inf in PCM input
    for (float sample : req.pcm) {
        if (!std::isfinite(sample)) {
            out.response_type = LDPMessageType::Error;
            out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
            out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "PCM contains NaN or Inf");
            return out;
        }
    }

    // Clamp sample count against model max_audio_ms (defense-in-depth).
    size_t sample_count = req.pcm.size();
    if (active_meta_.max_audio_ms > 0 && active_meta_.native_sample_rate > 0) {
        uint64_t max_samples =
            (static_cast<uint64_t>(active_meta_.max_audio_ms) *
             static_cast<uint64_t>(active_meta_.native_sample_rate)) / 1000u;
        if (max_samples > 0 && sample_count > max_samples) {
            sample_count = static_cast<size_t>(max_samples);
        }
    }
    if (sample_count > static_cast<size_t>(std::numeric_limits<int>::max())) {
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload);
        out.payload_json = serializeError(LDPErrorCode::ErrInvalidPayload, "PCM sample count overflow");
        return out;
    }

    // Double cancellation check #1: BEFORE transcribe_session_init
    if (job->cancelled.load(std::memory_order_acquire)) {
        JsonBuilder jb;
        jb.addString("stage", "before_session_init");
        jb.addUint64("postFreeFootprintBytes", currentPhysFootprintBytes());
        out.response_type = LDPMessageType::Cancelled;
        out.status_or_flags = 0;
        out.payload_json = jb.finish();
        return out;
    }

    transcribe_session_params sparams{};
    transcribe_session_params_init(&sparams);
    if (req.n_threads > 0) {
        sparams.n_threads = req.n_threads;
    }
    if (req.n_ctx > 0) {
        sparams.n_ctx = req.n_ctx;
    }

    transcribe_session *session = nullptr;
    MonotonicTimer total_timer;
    MonotonicTimer session_timer;
    transcribe_status st = transcribe_session_init(model_, &sparams, &session);
    double session_init_ms = session_timer.elapsedMs();

    if (st != TRANSCRIBE_OK || !session) {
        const char *msg = transcribe_status_string(static_cast<int>(st));
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInference);
        out.payload_json = serializeError(
            LDPErrorCode::ErrInference,
            std::string("transcribe_session_init failed: ") + (msg ? msg : "unknown"),
            static_cast<int>(st));
        return out;
    }

    // Clamp again against session effective_max_audio_ms if tighter.
    transcribe_session_limits limits{};
    transcribe_session_limits_init(&limits);
    if (transcribe_session_get_limits(session, &limits) == TRANSCRIBE_OK &&
        limits.effective_max_audio_ms > 0 && active_meta_.native_sample_rate > 0) {
        uint64_t eff_max_samples =
            (static_cast<uint64_t>(limits.effective_max_audio_ms) *
             static_cast<uint64_t>(active_meta_.native_sample_rate)) / 1000u;
        if (eff_max_samples > 0 && sample_count > eff_max_samples) {
            sample_count = static_cast<size_t>(eff_max_samples);
        }
    }

    // Double cancellation check #2: BEFORE transcribe_run
    if (job->cancelled.load(std::memory_order_acquire)) {
        transcribe_session_free(session);
        JsonBuilder jb;
        jb.addString("stage", "before_run");
        jb.addUint64("postFreeFootprintBytes", currentPhysFootprintBytes());
        out.response_type = LDPMessageType::Cancelled;
        out.status_or_flags = 0;
        out.payload_json = jb.finish();
        return out;
    }

    // Build run parameters dynamically adapted to model capabilities
    transcribe_run_params rparams{};
    transcribe_run_params_init(&rparams);
    rparams.task = TRANSCRIBE_TASK_TRANSCRIBE;
    rparams.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
    if (active_meta_.supports_pnc) {
        rparams.pnc = static_cast<int>(parsePncMode(req.pnc));
    }
    if (active_meta_.supports_itn) {
        rparams.itn = static_cast<int>(parseItnMode(req.itn));
    }
    if (!req.language.empty() && req.language != "auto") {
        rparams.language = req.language.c_str();
    }

    std::vector<const char *> vocab_ptrs;
    std::string combined_prompt;
    transcribe_whisper_run_ext whisper_ext{};
    bool use_whisper_ext = false;

    if (active_meta_.supports_vocabulary && !req.vocabulary.empty()) {
        vocab_ptrs.reserve(req.vocabulary.size());
        for (const auto &term : req.vocabulary) {
            if (!term.empty()) {
                vocab_ptrs.push_back(term.c_str());
            }
        }
        if (!vocab_ptrs.empty()) {
            rparams.vocabulary = vocab_ptrs.data();
            rparams.n_vocabulary = static_cast<int32_t>(vocab_ptrs.size());
        }
    }

    if (active_meta_.supports_context_prompt) {
        if (active_meta_.supports_vocabulary) {
            if (!req.context_prompt.empty()) {
                rparams.prompt = req.context_prompt.c_str();
            }
        } else {
            combined_prompt = joinVocabularyHint(req.context_prompt, req.vocabulary);
            if (!combined_prompt.empty()) {
                rparams.prompt = combined_prompt.c_str();
            }
        }
    } else if (!active_meta_.supports_vocabulary &&
               active_meta_.supports_initial_prompt &&
               active_meta_.accepts_whisper_run_ext) {
        combined_prompt = joinVocabularyHint(req.context_prompt, req.vocabulary);
        if (!combined_prompt.empty()) {
            transcribe_whisper_run_ext_init(&whisper_ext);
            whisper_ext.initial_prompt = combined_prompt.c_str();
            use_whisper_ext = true;
            rparams.family = &whisper_ext;
        }
    }
    (void)use_whisper_ext;

    // Wire cooperative abort callback to job->cancelled atomic
    transcribe_set_abort_callback(session, &abortCallbackThunk, &job->cancelled);

    transcribe_status run_st = transcribe_run(
        session,
        req.pcm.data(),
        static_cast<int>(sample_count),
        &rparams);

    double total_ms = total_timer.elapsedMs();
    uint64_t peak_footprint = currentPhysFootprintBytes();

    bool was_aborted = transcribe_was_aborted(session);
    bool was_truncated = transcribe_was_truncated(session);
    std::string full_text;
    std::string raw_text;
    std::string detected_lang;
    float mel_ms = 0.0f;
    float encode_ms = 0.0f;
    float decode_ms = 0.0f;

    bool ok_result = (run_st == TRANSCRIBE_OK ||
                      run_st == TRANSCRIBE_ERR_OUTPUT_TRUNCATED ||
                      run_st == TRANSCRIBE_ERR_OUTPUT_REPETITION);
    if (ok_result) {
        const char *ft = transcribe_full_text(session);
        const char *rt = transcribe_raw_text(session);
        const char *dl = transcribe_detected_language(session);
        if (ft) full_text = ft;
        if (rt) raw_text = rt;
        if (dl) detected_lang = dl;
        if (run_st == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || run_st == TRANSCRIBE_ERR_OUTPUT_REPETITION) {
            was_truncated = true;
        }
        transcribe_timings tm{};
        transcribe_timings_init(&tm);
        if (transcribe_get_timings(session, &tm) == TRANSCRIBE_OK) {
            mel_ms = tm.mel_ms;
            encode_ms = tm.encode_ms;
            decode_ms = tm.decode_ms;
        }
    }

    // CRITICAL SAFETY ORDER: Clear abort callback BEFORE transcribe_session_free
    transcribe_set_abort_callback(session, nullptr, nullptr);
    transcribe_session_free(session);
    session = nullptr;

    uint64_t post_free_footprint = currentPhysFootprintBytes();

    if (run_st == TRANSCRIBE_ERR_ABORTED || was_aborted || job->cancelled.load(std::memory_order_acquire)) {
        JsonBuilder jb;
        jb.addString("stage", "during_run");
        jb.addUint64("postFreeFootprintBytes", post_free_footprint);
        out.response_type = LDPMessageType::Cancelled;
        out.status_or_flags = 0;
        out.payload_json = jb.finish();
        return out;
    }

    if (!ok_result) {
        const char *msg = transcribe_status_string(static_cast<int>(run_st));
        out.response_type = LDPMessageType::Error;
        out.status_or_flags = static_cast<uint32_t>(LDPErrorCode::ErrInference);
        out.payload_json = serializeError(
            LDPErrorCode::ErrInference,
            std::string("transcribe_run failed: ") + (msg ? msg : "unknown"),
            static_cast<int>(run_st));
        return out;
    }

    uint32_t flags = 0;
    if (was_truncated) flags |= kResultFlagTruncated;
    if (was_aborted) flags |= kResultFlagAborted;

    JsonBuilder jb;
    jb.addString("text", full_text);
    jb.addString("rawText", raw_text);
    jb.addString("detectedLanguage", detected_lang);
    jb.addBool("wasTruncated", was_truncated);
    jb.addBool("wasAborted", was_aborted);
    jb.addDouble("sessionInitMs", session_init_ms);
    jb.addDouble("melMs", static_cast<double>(mel_ms));
    jb.addDouble("encodeMs", static_cast<double>(encode_ms));
    jb.addDouble("decodeMs", static_cast<double>(decode_ms));
    jb.addDouble("totalInferenceMs", total_ms);
    jb.addUint64("peakFootprintBytes", peak_footprint);
    jb.addUint64("postFreeFootprintBytes", post_free_footprint);

    out.response_type = LDPMessageType::Result;
    out.status_or_flags = flags;
    out.payload_json = jb.finish();
    return out;
}

} // namespace litedictate
