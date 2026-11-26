#ifndef LITEDICTATE_ENGINE_HPP
#define LITEDICTATE_ENGINE_HPP

#include "ldp_protocol.hpp"
#include "transcribe.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace litedictate {

struct InferenceJob {
    uint64_t request_id = 0;
    uint64_t attempt_id = 0;
    std::atomic<bool> cancelled{false};

    InferenceJob(uint64_t req_id, uint64_t att_id)
        : request_id(req_id), attempt_id(att_id) {}
};

struct ModelMetadata {
    std::string model_path;
    std::vector<std::string> roles;
    std::string arch;
    std::string variant;
    std::string backend;
    int32_t native_sample_rate = 16000;
    int64_t max_audio_ms = 30000;
    std::vector<std::string> languages;
    bool supports_language_detect = false;
    bool supports_streaming = false;
    bool supports_vocabulary = false;
    bool supports_context_prompt = false;
    bool supports_initial_prompt = false;
    bool accepts_whisper_run_ext = false;
    bool supports_pnc = false;
    bool supports_itn = false;
    bool supports_cancellation = false;
    double backend_init_ms = 0.0;
    double load_ms = 0.0;
    uint64_t phys_footprint_bytes = 0;
};

struct TranscribeRequest {
    int32_t sample_rate = 0; // 0 => default to model native_sample_rate
    std::string language;    // "" or "auto" => auto-detect
    std::vector<std::string> vocabulary;
    std::string context_prompt;
    int32_t n_threads = 4;
    int32_t n_ctx = 2048;
    std::string pnc = "default";
    std::string itn = "default";
    std::vector<float> pcm;
};

struct EngineOutcome {
    LDPMessageType response_type = LDPMessageType::Error;
    uint32_t status_or_flags = 0;
    std::string payload_json;
};

class TranscribeEngine {
public:
    TranscribeEngine() = default;
    ~TranscribeEngine();

    TranscribeEngine(const TranscribeEngine &) = delete;
    TranscribeEngine &operator=(const TranscribeEngine &) = delete;

    // Runtime ABI sanity check against loaded libtranscribe.dylib.
    static bool verifyRuntimeABI(std::string &err_out);

    // Install native log callback to stderr (never touches FD 4 or transcript text).
    static void installStderrLogger();

    bool isModelLoaded() const { return model_ != nullptr; }

    EngineOutcome probeModel(const std::string &model_path, const std::string &backend_name);
    EngineOutcome warmupModel(const std::string &model_path, const std::string &backend_name, bool no_mmap);
    EngineOutcome runTranscribe(const std::shared_ptr<InferenceJob> &job, const TranscribeRequest &req);

    void freeModel();

private:
    bool ensureBackendsInitialized(double &init_ms_out, std::string &err_out);
    static transcribe_backend_request parseBackend(const std::string &name, transcribe_backend_request fallback);
    static std::vector<std::string> rolesToStrings(uint32_t role_mask);
    static ModelMetadata inspectModel(
        const transcribe_model *model,
        const std::string &model_path,
        double backend_init_ms,
        double load_ms);
    static std::string serializeModelMetadata(const ModelMetadata &meta, bool include_backend_init);
    static std::string serializeError(
        LDPErrorCode code,
        const std::string &message,
        int native_status = 0,
        const std::vector<std::string> *roles = nullptr,
        const std::string *arch = nullptr,
        const std::string *variant = nullptr);

    bool backends_initialized_ = false;
    transcribe_model *model_ = nullptr;
    ModelMetadata active_meta_{};
};

} // namespace litedictate

#endif // LITEDICTATE_ENGINE_HPP
