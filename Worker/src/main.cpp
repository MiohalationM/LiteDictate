#include "engine.hpp"
#include "fd_io.hpp"
#include "json_codec.hpp"
#include "ldp_protocol.hpp"
#include "metrics.hpp"

#include <atomic>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace litedictate {

namespace {

std::string makeSimpleErrorJson(LDPErrorCode code, const std::string &msg) {
    JsonBuilder jb;
    jb.addUint64("code", static_cast<uint32_t>(code));
    jb.addString("codeName", ldpErrorCodeName(code));
    jb.addString("message", msg);
    return jb.finish();
}

enum class ComputeOp {
    ProbeModel,
    Warmup,
    Transcribe
};

struct ComputeTask {
    ComputeOp op = ComputeOp::ProbeModel;
    uint64_t request_id = 0;
    uint64_t attempt_id = 0;
    std::string model_path;
    std::string backend;
    bool no_mmap = false;
    TranscribeRequest transcribe_req;
    std::shared_ptr<InferenceJob> job;
};

bool parseProbeOrWarmupJson(
    const std::string &payload,
    std::string &model_path,
    std::string &backend,
    bool &no_mmap,
    std::string &err) {
    JsonValue root;
    if (!JsonParser::parse(payload.data(), payload.size(), root, err) || !root.isObject()) {
        if (err.empty()) err = "Expected JSON object";
        return false;
    }
    const JsonValue *mp = root.find("modelPath");
    if (!mp || !mp->isString() || mp->str_val.empty()) {
        err = "Missing required string field 'modelPath'";
        return false;
    }
    model_path = mp->str_val;
    if (const JsonValue *b = root.find("backend")) {
        if (!b->isString()) { err = "Field 'backend' must be string"; return false; }
        backend = b->str_val;
    }
    if (const JsonValue *nm = root.find("noMmap")) {
        if (!nm->isBool()) { err = "Field 'noMmap' must be boolean"; return false; }
        no_mmap = nm->bool_val;
    }
    return true;
}

bool parseTranscribePayload(
    const std::vector<uint8_t> &raw,
    TranscribeRequest &req,
    std::string &err) {
    if (raw.size() < sizeof(LDPTranscribePrefix)) {
        err = "TRANSCRIBE payload smaller than 8-byte prefix";
        return false;
    }
    LDPTranscribePrefix prefix{};
    std::memcpy(&prefix, raw.data(), sizeof(prefix));

    if (prefix.meta_json_len > raw.size() - sizeof(LDPTranscribePrefix)) {
        err = "TRANSCRIBE meta_json_len exceeds payload_len";
        return false;
    }
    uint32_t pcm_offset = ldpAlign4(static_cast<uint32_t>(sizeof(LDPTranscribePrefix)) + prefix.meta_json_len);
    if (pcm_offset > raw.size()) {
        err = "TRANSCRIBE aligned pcm_offset exceeds payload_len";
        return false;
    }
    size_t pcm_bytes = raw.size() - pcm_offset;
    if ((pcm_bytes % 4u) != 0) {
        err = "PCM byte length is not 4-byte aligned";
        return false;
    }
    if (prefix.sample_count == 0) {
        err = "PCM sample_count must be > 0";
        return false;
    }
    if (static_cast<uint64_t>(prefix.sample_count) * 4u != pcm_bytes) {
        err = "PCM sample_count does not match remaining byte length";
        return false;
    }

    if (prefix.meta_json_len > 0) {
        JsonValue root;
        const char *jptr = reinterpret_cast<const char *>(raw.data() + sizeof(LDPTranscribePrefix));
        if (!JsonParser::parse(jptr, prefix.meta_json_len, root, err) || !root.isObject()) {
            if (err.empty()) err = "TRANSCRIBE metadata must be a JSON object";
            return false;
        }
        if (const JsonValue *sr = root.find("sampleRate")) {
            if (!sr->isNumber()) { err = "sampleRate must be number"; return false; }
            int64_t v = sr->asInt(-1);
            if (v < 0 || v > 384000) { err = "sampleRate out of range"; return false; }
            req.sample_rate = static_cast<int32_t>(v);
        }
        if (const JsonValue *lang = root.find("language")) {
            if (!lang->isString()) { err = "language must be string"; return false; }
            req.language = lang->str_val;
        }
        if (const JsonValue *ctx = root.find("contextPrompt")) {
            if (!ctx->isString()) { err = "contextPrompt must be string"; return false; }
            req.context_prompt = ctx->str_val;
        }
        if (const JsonValue *nt = root.find("nThreads")) {
            if (!nt->isNumber()) { err = "nThreads must be number"; return false; }
            int64_t v = nt->asInt(4);
            if (v > 0 && v <= 64) req.n_threads = static_cast<int32_t>(v);
        }
        if (const JsonValue *nc = root.find("nCtx")) {
            if (!nc->isNumber()) { err = "nCtx must be number"; return false; }
            int64_t v = nc->asInt(2048);
            if (v > 0 && v <= 65536) req.n_ctx = static_cast<int32_t>(v);
        }
        if (const JsonValue *pnc = root.find("pnc")) {
            if (!pnc->isString()) { err = "pnc must be string"; return false; }
            req.pnc = pnc->str_val;
        }
        if (const JsonValue *itn = root.find("itn")) {
            if (!itn->isString()) { err = "itn must be string"; return false; }
            req.itn = itn->str_val;
        }
        if (const JsonValue *voc = root.find("vocabulary")) {
            if (!voc->isArray()) { err = "vocabulary must be an array"; return false; }
            if (voc->arr_val.size() > kMaxVocabularyEntries) {
                err = "vocabulary exceeds maximum of 50 entries";
                return false;
            }
            req.vocabulary.reserve(voc->arr_val.size());
            for (const auto &entry : voc->arr_val) {
                if (!entry.isString()) { err = "vocabulary entries must be strings"; return false; }
                if (entry.str_val.find('\0') != std::string::npos) {
                    err = "vocabulary entry contains NUL";
                    return false;
                }
                req.vocabulary.push_back(entry.str_val);
            }
        }
    }

    req.pcm.resize(prefix.sample_count);
    std::memcpy(req.pcm.data(), raw.data() + pcm_offset, pcm_bytes);
    for (float s : req.pcm) {
        if (!std::isfinite(s)) {
            err = "PCM audio contains NaN or Inf";
            return false;
        }
    }
    return true;
}

} // namespace

} // namespace litedictate

int main() {
    using namespace litedictate;

    // 1. Ignore SIGPIPE so closed host pipe returns EPIPE instead of killing worker.
    struct sigaction sa{};
    sa.sa_handler = SIG_IGN;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    ::sigaction(SIGPIPE, &sa, nullptr);

    // 2. Verify protocol FDs 3 and 4 exist.
    if (::fcntl(kProtoReadFD, F_GETFD) < 0 || ::fcntl(kProtoWriteFD, F_GETFD) < 0) {
        std::fprintf(stderr, "[litedictate-worker] Fatal: protocol FDs 3/4 not open\n");
        std::fflush(stderr);
        ::_exit(2);
    }

    // 3. Route native logs to stderr and verify libtranscribe runtime ABI.
    TranscribeEngine::installStderrLogger();
    std::string abi_err;
    if (!TranscribeEngine::verifyRuntimeABI(abi_err)) {
        std::fprintf(stderr, "[litedictate-worker] Fatal ABI error: %s\n", abi_err.c_str());
        std::fflush(stderr);
        ::_exit(2);
    }

    FrameWriter writer(kProtoWriteFD);
    TranscribeEngine engine;

    std::mutex state_mu;
    std::condition_variable compute_cv;
    bool compute_busy = false;
    bool shutdown_requested = false;
    std::optional<ComputeTask> pending_task;
    std::shared_ptr<InferenceJob> active_job;
    std::atomic<bool> model_loaded_atomic{false};

    // Thread 2: Compute thread (exclusive owner of TranscribeEngine / transcribe_model*)
    std::thread compute_thread([&] {
        while (true) {
            ComputeTask task;
            {
                std::unique_lock<std::mutex> lock(state_mu);
                compute_cv.wait(lock, [&] { return pending_task.has_value() || shutdown_requested; });
                if (shutdown_requested) {
                    pending_task.reset();
                    active_job.reset();
                    compute_busy = false;
                    break;
                }
                task = std::move(*pending_task);
                pending_task.reset();
            }

            EngineOutcome outcome;
            switch (task.op) {
                case ComputeOp::ProbeModel:
                    outcome = engine.probeModel(task.model_path, task.backend);
                    break;
                case ComputeOp::Warmup:
                    outcome = engine.warmupModel(task.model_path, task.backend, task.no_mmap);
                    model_loaded_atomic.store(engine.isModelLoaded(), std::memory_order_release);
                    break;
                case ComputeOp::Transcribe:
                    outcome = engine.runTranscribe(task.job, task.transcribe_req);
                    break;
            }

            // Release compute slot BEFORE enqueueing response so the host's immediate
            // next sequential RPC can never race with compute_busy == true.
            {
                std::lock_guard<std::mutex> lock(state_mu);
                active_job.reset();
                compute_busy = false;
            }

            writer.enqueue(
                outcome.response_type,
                task.request_id,
                task.attempt_id,
                outcome.status_or_flags,
                std::move(outcome.payload_json));
        }
    });

    // Thread 1 (main thread): IPC Reader on FD 3. NEVER blocks waiting on compute slot.
    bool got_explicit_shutdown = false;
    uint64_t shutdown_req_id = 0;
    uint64_t shutdown_att_id = 0;
    int exit_code = 0;

    while (true) {
        LDPFrameHeader hdr{};
        ReadStatus rs = readExact(kProtoReadFD, &hdr, sizeof(hdr));
        if (rs == ReadStatus::CleanEof) {
            break;
        }
        if (rs != ReadStatus::Ok) {
            exit_code = 2;
            break;
        }

        // Strict frame header validation: invalid magic/version or > 8 MiB => protocol error + _exit(2)
        if (std::memcmp(hdr.magic, kLDPMagic, 4) != 0 ||
            hdr.version != kLDPVersion ||
            hdr.payload_len > kMaxFrameBytes) {
            writer.enqueue(
                LDPMessageType::Error,
                0,
                0,
                static_cast<uint32_t>(LDPErrorCode::ErrProtocol),
                makeSimpleErrorJson(
                    LDPErrorCode::ErrProtocol,
                    "Invalid LDP1 header magic/version or payload_len exceeds 8 MiB"));
            writer.flush();
            std::fflush(nullptr);
            ::_exit(2);
        }

        const auto msg_type = static_cast<LDPMessageType>(hdr.msg_type);

        if (msg_type == LDPMessageType::Ping) {
            if (hdr.payload_len > 0 && !drainExact(kProtoReadFD, hdr.payload_len)) {
                exit_code = 2;
                break;
            }
            bool busy_now = false;
            {
                std::lock_guard<std::mutex> lock(state_mu);
                busy_now = compute_busy;
            }
            JsonBuilder jb;
            jb.addBool("busy", busy_now);
            jb.addBool("modelLoaded", model_loaded_atomic.load(std::memory_order_acquire));
            jb.addUint64("physFootprintBytes", currentPhysFootprintBytes());
            writer.enqueue(LDPMessageType::Pong, hdr.request_id, hdr.attempt_id, 0, jb.finish());
            continue;
        }

        if (msg_type == LDPMessageType::Cancel) {
            if (hdr.payload_len > 0 && !drainExact(kProtoReadFD, hdr.payload_len)) {
                exit_code = 2;
                break;
            }
            std::lock_guard<std::mutex> lock(state_mu);
            if (active_job) {
                bool wildcard = (hdr.request_id == 0 && hdr.attempt_id == 0);
                bool exact = (active_job->request_id == hdr.request_id &&
                              active_job->attempt_id == hdr.attempt_id);
                if (wildcard || exact) {
                    active_job->cancelled.store(true, std::memory_order_release);
                }
            }
            continue;
        }

        if (msg_type == LDPMessageType::Shutdown) {
            if (hdr.payload_len > 0 && !drainExact(kProtoReadFD, hdr.payload_len)) {
                exit_code = 2;
                break;
            }
            got_explicit_shutdown = true;
            shutdown_req_id = hdr.request_id;
            shutdown_att_id = hdr.attempt_id;
            {
                std::lock_guard<std::mutex> lock(state_mu);
                shutdown_requested = true;
                if (active_job) {
                    active_job->cancelled.store(true, std::memory_order_release);
                }
            }
            compute_cv.notify_one();
            break;
        }

        if (msg_type == LDPMessageType::ProbeModel ||
            msg_type == LDPMessageType::Warmup ||
            msg_type == LDPMessageType::Transcribe) {
            bool is_busy = false;
            {
                std::lock_guard<std::mutex> lock(state_mu);
                is_busy = compute_busy;
            }

            if (is_busy) {
                // CRITICAL Section 7.2 P1-3: MUST drain and discard all payload_len bytes before replying ERR_BUSY
                if (hdr.payload_len > 0 && !drainExact(kProtoReadFD, hdr.payload_len)) {
                    exit_code = 2;
                    break;
                }
                writer.enqueue(
                    LDPMessageType::Error,
                    hdr.request_id,
                    hdr.attempt_id,
                    static_cast<uint32_t>(LDPErrorCode::ErrBusy),
                    makeSimpleErrorJson(LDPErrorCode::ErrBusy, "Worker compute slot is busy"));
                continue;
            }

            if (msg_type == LDPMessageType::ProbeModel || msg_type == LDPMessageType::Warmup) {
                std::string payload(hdr.payload_len, '\0');
                if (hdr.payload_len > 0 && readExact(kProtoReadFD, payload.data(), hdr.payload_len) != ReadStatus::Ok) {
                    exit_code = 2;
                    break;
                }
                std::string model_path;
                std::string backend;
                bool no_mmap = false;
                std::string perr;
                if (!parseProbeOrWarmupJson(payload, model_path, backend, no_mmap, perr)) {
                    writer.enqueue(
                        LDPMessageType::Error,
                        hdr.request_id,
                        hdr.attempt_id,
                        static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload),
                        makeSimpleErrorJson(LDPErrorCode::ErrInvalidPayload, perr));
                    continue;
                }

                ComputeTask task;
                task.op = (msg_type == LDPMessageType::ProbeModel) ? ComputeOp::ProbeModel : ComputeOp::Warmup;
                task.request_id = hdr.request_id;
                task.attempt_id = hdr.attempt_id;
                task.model_path = std::move(model_path);
                task.backend = std::move(backend);
                task.no_mmap = no_mmap;

                {
                    std::lock_guard<std::mutex> lock(state_mu);
                    compute_busy = true;
                    pending_task = std::move(task);
                }
                compute_cv.notify_one();
                continue;
            }

            // msg_type == LDPMessageType::Transcribe
            std::vector<uint8_t> raw(hdr.payload_len);
            if (hdr.payload_len > 0 && readExact(kProtoReadFD, raw.data(), hdr.payload_len) != ReadStatus::Ok) {
                exit_code = 2;
                break;
            }

            TranscribeRequest treq;
            std::string perr;
            if (!parseTranscribePayload(raw, treq, perr)) {
                writer.enqueue(
                    LDPMessageType::Error,
                    hdr.request_id,
                    hdr.attempt_id,
                    static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload),
                    makeSimpleErrorJson(LDPErrorCode::ErrInvalidPayload, perr));
                continue;
            }

            auto job = std::make_shared<InferenceJob>(hdr.request_id, hdr.attempt_id);
            ComputeTask task;
            task.op = ComputeOp::Transcribe;
            task.request_id = hdr.request_id;
            task.attempt_id = hdr.attempt_id;
            task.transcribe_req = std::move(treq);
            task.job = job;

            {
                std::lock_guard<std::mutex> lock(state_mu);
                compute_busy = true;
                active_job = std::move(job);
                pending_task = std::move(task);
            }
            compute_cv.notify_one();
            continue;
        }

        // Unknown message type: drain payload and return ERR_INVALID_PAYLOAD
        if (hdr.payload_len > 0 && !drainExact(kProtoReadFD, hdr.payload_len)) {
            exit_code = 2;
            break;
        }
        writer.enqueue(
            LDPMessageType::Error,
            hdr.request_id,
            hdr.attempt_id,
            static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload),
            makeSimpleErrorJson(LDPErrorCode::ErrInvalidPayload, "Unknown LDP1 message type"));
    }

    // Signal compute thread to finish any active work and stop (now idle, zero active sessions).
    {
        std::lock_guard<std::mutex> lock(state_mu);
        shutdown_requested = true;
        if (active_job) {
            active_job->cancelled.store(true, std::memory_order_release);
        }
    }
    compute_cv.notify_one();
    if (compute_thread.joinable()) {
        compute_thread.join();
    }

    if (got_explicit_shutdown) {
        JsonBuilder jb;
        jb.addUint64("physFootprintBytes", currentPhysFootprintBytes());
        writer.enqueue(LDPMessageType::Bye, shutdown_req_id, shutdown_att_id, 0, jb.finish());
        writer.flush();

#ifdef NDEBUG
        // Section 7.2 / 10.2: In Release when idle after flushing BYE, bypass static
        // destructors (and ggml-metal teardown stall/paging) and let kernel reclaim atomically.
        const char *clean_env = std::getenv("LITEDICTATE_CLEAN_EXIT");
        if (!clean_env || clean_env[0] != '1') {
            std::fflush(nullptr);
            ::_exit(0);
        }
#endif
    }

    writer.flush();
    writer.stop();
    engine.freeModel();
    return exit_code;
}
