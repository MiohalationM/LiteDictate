// Phase 1 Probe 1: Real-machine verification of signed litedictate-worker
// via posix_spawn + POSIX_SPAWN_CLOEXEC_DEFAULT + FD 3/4 protocol pipes.

#include "fd_io.hpp"
#include "json_codec.hpp"
#include "ldp_protocol.hpp"

#include <cassert>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <memory>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

extern char **environ;

using namespace litedictate;

namespace {

int relocateAbove4(int fd) {
    if (fd >= 5) return fd;
    int new_fd = ::fcntl(fd, F_DUPFD_CLOEXEC, 5);
    if (new_fd < 0) {
        std::perror("F_DUPFD_CLOEXEC");
        std::exit(1);
    }
    ::close(fd);
    return new_fd;
}

struct SpawnedWorker {
    pid_t pid = -1;
    int write_fd = -1; // host -> worker FD 3
    int read_fd = -1;  // worker FD 4 -> host
    int log_fd = -1;   // worker FD 1/2 -> host
    std::shared_ptr<std::string> stderr_log = std::make_shared<std::string>();
    std::thread log_drainer;

    static std::unique_ptr<SpawnedWorker> launch(const std::string &worker_path) {
        auto w = std::make_unique<SpawnedWorker>();
        int h2w[2], w2h[2], logp[2];
        if (::pipe(h2w) != 0 || ::pipe(w2h) != 0 || ::pipe(logp) != 0) {
            std::perror("pipe");
            std::exit(1);
        }
        // Relocate all source FDs above 4 before dup2 actions (Section 7.1)
        h2w[0] = relocateAbove4(h2w[0]);
        h2w[1] = relocateAbove4(h2w[1]);
        w2h[0] = relocateAbove4(w2h[0]);
        w2h[1] = relocateAbove4(w2h[1]);
        logp[0] = relocateAbove4(logp[0]);
        logp[1] = relocateAbove4(logp[1]);

        int devnull = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (devnull < 0) {
            std::perror("open /dev/null");
            std::exit(1);
        }
        devnull = relocateAbove4(devnull);

        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, devnull, 0);
        posix_spawn_file_actions_adddup2(&fa, logp[1], 1);
        posix_spawn_file_actions_adddup2(&fa, logp[1], 2);
        posix_spawn_file_actions_adddup2(&fa, h2w[0], kProtoReadFD);
        posix_spawn_file_actions_adddup2(&fa, w2h[1], kProtoWriteFD);

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;
        posix_spawnattr_setflags(&attr, flags);

        char *argv[] = {const_cast<char *>(worker_path.c_str()), nullptr};
        int rc = ::posix_spawn(&w->pid, worker_path.c_str(), &fa, &attr, argv, environ);

        posix_spawn_file_actions_destroy(&fa);
        posix_spawnattr_destroy(&attr);
        ::close(devnull);
        ::close(h2w[0]);
        ::close(w2h[1]);
        ::close(logp[1]);

        if (rc != 0) {
            std::fprintf(stderr, "posix_spawn failed: %s\n", std::strerror(rc));
            std::exit(1);
        }

        w->write_fd = h2w[1];
        w->read_fd = w2h[0];
        w->log_fd = logp[0];

        auto log_buf = w->stderr_log;
        int lfd = w->log_fd;
        w->log_drainer = std::thread([log_buf, lfd] {
            char buf[4096];
            while (true) {
                ssize_t n = ::read(lfd, buf, sizeof(buf));
                if (n > 0) {
                    if (log_buf->size() < 262144) {
                        log_buf->append(buf, static_cast<size_t>(n));
                    }
                } else if (n == 0) {
                    break;
                } else if (errno != EINTR) {
                    break;
                }
            }
        });
        return w;
    }

    bool sendFrame(
        LDPMessageType type,
        uint64_t req_id,
        uint64_t att_id,
        const void *payload,
        uint32_t payload_len,
        uint32_t flags = 0) {
        LDPFrameHeader h{};
        std::memcpy(h.magic, kLDPMagic, 4);
        h.version = kLDPVersion;
        h.msg_type = static_cast<uint16_t>(type);
        h.request_id = req_id;
        h.attempt_id = att_id;
        h.payload_len = payload_len;
        h.status_or_flags = flags;
        if (!writeAll(write_fd, &h, sizeof(h))) return false;
        if (payload_len > 0 && payload != nullptr) {
            return writeAll(write_fd, payload, payload_len);
        }
        return true;
    }

    bool sendJson(LDPMessageType type, uint64_t req_id, uint64_t att_id, const std::string &json) {
        return sendFrame(type, req_id, att_id, json.data(), static_cast<uint32_t>(json.size()));
    }

    bool recvFrame(LDPFrameHeader &h, std::string &payload) {
        if (readExact(read_fd, &h, sizeof(h)) != ReadStatus::Ok) {
            return false;
        }
        if (std::memcmp(h.magic, kLDPMagic, 4) != 0 || h.version != kLDPVersion) {
            std::fprintf(stderr, "Bad response magic/version!\n");
            return false;
        }
        payload.assign(h.payload_len, '\0');
        if (h.payload_len > 0 && readExact(read_fd, payload.data(), h.payload_len) != ReadStatus::Ok) {
            return false;
        }
        return true;
    }

    int reap() {
        if (write_fd >= 0) { ::close(write_fd); write_fd = -1; }
        if (read_fd >= 0) { ::close(read_fd); read_fd = -1; }
        int status = 0;
        while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        if (log_drainer.joinable()) log_drainer.join();
        if (log_fd >= 0) { ::close(log_fd); log_fd = -1; }
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) return -WTERMSIG(status);
        return -999;
    }
};

std::vector<uint8_t> buildTranscribePayload(
    const std::string &meta_json,
    const std::vector<float> &pcm) {
    LDPTranscribePrefix prefix{};
    prefix.meta_json_len = static_cast<uint32_t>(meta_json.size());
    prefix.sample_count = static_cast<uint32_t>(pcm.size());
    uint32_t pcm_offset = ldpAlign4(static_cast<uint32_t>(sizeof(prefix)) + prefix.meta_json_len);
    size_t total = pcm_offset + pcm.size() * sizeof(float);
    std::vector<uint8_t> buf(total, 0);
    std::memcpy(buf.data(), &prefix, sizeof(prefix));
    if (!meta_json.empty()) {
        std::memcpy(buf.data() + sizeof(prefix), meta_json.data(), meta_json.size());
    }
    if (!pcm.empty()) {
        std::memcpy(buf.data() + pcm_offset, pcm.data(), pcm.size() * sizeof(float));
    }
    return buf;
}

std::vector<float> loadFloat32File(const std::string &path) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return {};
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz <= 0 || (sz % 4) != 0) {
        std::fclose(f);
        return {};
    }
    std::vector<float> out(static_cast<size_t>(sz) / 4);
    size_t read_n = std::fread(out.data(), sizeof(float), out.size(), f);
    std::fclose(f);
    out.resize(read_n);
    return out;
}

std::vector<float> makeSyntheticTone(double seconds, int sample_rate = 16000) {
    size_t n = static_cast<size_t>(seconds * sample_rate);
    std::vector<float> pcm(n);
    for (size_t i = 0; i < n; ++i) {
        double t = static_cast<double>(i) / static_cast<double>(sample_rate);
        // Modulated multi-harmonic speech-band wave
        pcm[i] = static_cast<float>(0.15 * std::sin(2.0 * M_PI * 220.0 * t) +
                                    0.08 * std::sin(2.0 * M_PI * 440.0 * t));
    }
    return pcm;
}

void require(bool cond, const char *msg) {
    if (!cond) {
        std::fprintf(stderr, "[WorkerProbe] FAIL: %s\n", msg);
        std::exit(1);
    }
}

double mb(uint64_t bytes) {
    return static_cast<double>(bytes) / (1024.0 * 1024.0);
}

} // namespace

int main(int argc, char **argv) {
    struct sigaction sa{};
    sa.sa_handler = SIG_IGN;
    ::sigaction(SIGPIPE, &sa, nullptr);

    const char *home_env = std::getenv("HOME");
    std::string home_dir = home_env ? std::string(home_env) : ".";
    std::string worker_path = argc > 1 ? argv[1] : "Build/Worker/litedictate-worker";
    std::string asr_model = argc > 2 ? argv[2] : (home_dir + "/Library/Application Support/LiteDictate/models/Qwen3-ASR-0.6B-Q8_0.gguf");
    std::string vad_model = argc > 3 ? argv[3] : (home_dir + "/.t3/userdata/speech/models/silero-vad-v6.2-F32.gguf");
    std::string pcm_file  = argc > 4 ? argv[4] : "";

    std::printf("=== LiteDictate Phase 1 Probe 1 ===\n");
    std::printf("Worker:    %s\n", worker_path.c_str());
    std::printf("ASR Model: %s\n", asr_model.c_str());
    std::printf("VAD Model: %s\n", vad_model.c_str());

    // -------------------------------------------------------------------------
    // Session A: Full functional + SLO + ERR_BUSY drain + CANCEL + SHUTDOWN
    // -------------------------------------------------------------------------
    auto w = SpawnedWorker::launch(worker_path);
    LDPFrameHeader hdr{};
    std::string payload;
    JsonValue jv;
    std::string jerr;

    // 1. PING -> PONG (cold baseline)
    require(w->sendFrame(LDPMessageType::Ping, 1, 0, nullptr, 0), "send PING");
    require(w->recvFrame(hdr, payload), "recv PONG");
    require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Pong), "expected PONG");
    require(hdr.request_id == 1, "PONG request_id echo");
    require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse PONG JSON");
    uint64_t cold_fp = static_cast<uint64_t>(jv.find("physFootprintBytes")->asInt());
    std::printf("[PASS 1/11] Cold PING -> PONG | phys_footprint = %.2f MB\n", mb(cold_fp));

    // 2. PROBE_MODEL rejects silero-vad with ERR_UNSUPPORTED_ROLE
    {
        JsonBuilder jb;
        jb.addString("modelPath", vad_model);
        jb.addString("backend", "cpu");
        require(w->sendJson(LDPMessageType::ProbeModel, 2, 0, jb.finish()), "send PROBE vad");
        require(w->recvFrame(hdr, payload), "recv PROBE vad resp");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error), "VAD probe must return ERROR");
        require(hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrUnsupportedRole), "VAD must return ERR_UNSUPPORTED_ROLE");
        require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse VAD error JSON");
        const JsonValue *roles = jv.find("roles");
        require(roles && roles->isArray() && !roles->arr_val.empty() && roles->arr_val[0].str_val == "vad",
                "VAD error JSON must list actual role 'vad'");
        std::printf("[PASS 2/11] PROBE_MODEL(silero-vad) rejected with ERR_UNSUPPORTED_ROLE (roles=[\"vad\"])\n");
    }

    // 3. PROBE_MODEL accepts Qwen3-ASR
    {
        JsonBuilder jb;
        jb.addString("modelPath", asr_model);
        jb.addString("backend", "cpu");
        require(w->sendJson(LDPMessageType::ProbeModel, 3, 0, jb.finish()), "send PROBE asr");
        require(w->recvFrame(hdr, payload), "recv PROBE asr resp");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::ProbeResult), "ASR probe must return PROBE_RESULT");
        require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse PROBE_RESULT JSON");
        require(jv.find("arch")->str_val == "qwen3_asr", "arch == qwen3_asr");
        int64_t sr = jv.find("nativeSampleRate")->asInt();
        int64_t max_ms = jv.find("maxAudioMs")->asInt();
        require(sr >= 8000 && sr <= 48000, "nativeSampleRate clamped to 8000..48000");
        require(max_ms >= 1000 && max_ms <= 600000, "maxAudioMs clamped to 1000..600000");
        require(sr == 16000, "nativeSampleRate == 16000");
        require(jv.find("supportsVocabulary")->bool_val == true, "supportsVocabulary == true");
        require(jv.find("supportsCancellation")->bool_val == true, "supportsCancellation == true");
        std::printf("[PASS 3/11] PROBE_MODEL(Qwen3-ASR) -> PROBE_RESULT | arch=%s variant=%s sr=%lld maxAudioMs=%lld vocab=%d ctx=%d cancel=%d\n",
                    jv.find("arch")->str_val.c_str(),
                    jv.find("variant")->str_val.c_str(),
                    static_cast<long long>(jv.find("nativeSampleRate")->asInt()),
                    static_cast<long long>(jv.find("maxAudioMs")->asInt()),
                    jv.find("supportsVocabulary")->bool_val ? 1 : 0,
                    jv.find("supportsContextPrompt")->bool_val ? 1 : 0,
                    jv.find("supportsCancellation")->bool_val ? 1 : 0);
    }

    // 4. WARMUP (Metal GPU, noMmap=false) + verify PROBE_MODEL rejected while model resident
    {
        JsonBuilder jb;
        jb.addString("modelPath", asr_model);
        jb.addString("backend", "metal");
        jb.addBool("noMmap", false);
        require(w->sendJson(LDPMessageType::Warmup, 4, 0, jb.finish()), "send WARMUP");
        require(w->recvFrame(hdr, payload), "recv READY");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Ready), "expected READY");
        require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse READY JSON");
        uint64_t warm_fp = static_cast<uint64_t>(jv.find("physFootprintBytes")->asInt());
        double load_ms = jv.find("loadMs")->asDouble();
        double init_ms = jv.find("backendInitMs")->asDouble();

        // Zero dual-model residency guard: PROBE_MODEL must return ERR_BUSY while a model is resident
        JsonBuilder pjb;
        pjb.addString("modelPath", asr_model);
        pjb.addString("backend", "cpu");
        require(w->sendJson(LDPMessageType::ProbeModel, 41, 0, pjb.finish()), "send PROBE while warm");
        require(w->recvFrame(hdr, payload), "recv PROBE while warm resp");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrBusy),
                "PROBE_MODEL while resident must return ERR_BUSY");

        std::printf("[PASS 4/11] WARMUP(Metal) -> READY | backend=%s init=%.1f ms load=%.1f ms warm_phys_footprint=%.2f MB (dual-model PROBE guard=ERR_BUSY)\n",
                    jv.find("backend")->str_val.c_str(), init_ms, load_ms, mb(warm_fp));
    }

    // 5. Validation guards: NaN PCM, vocab > 50, unaligned PCM
    {
        // 5a: NaN PCM
        std::vector<float> bad_pcm = {0.0f, std::numeric_limits<float>::quiet_NaN(), 0.1f};
        auto bytes = buildTranscribePayload("{\"sampleRate\":16000}", bad_pcm);
        require(w->sendFrame(LDPMessageType::Transcribe, 50, 1, bytes.data(), static_cast<uint32_t>(bytes.size())), "send NaN");
        require(w->recvFrame(hdr, payload), "recv NaN err");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload), "NaN rejected");

        // 5b: vocab > 50 entries
        std::vector<std::string> big_vocab;
        for (int i = 0; i < 51; ++i) big_vocab.push_back("Term" + std::to_string(i));
        JsonBuilder vjb;
        vjb.addStringArray("vocabulary", big_vocab);
        auto vbytes = buildTranscribePayload(vjb.finish(), makeSyntheticTone(0.5));
        require(w->sendFrame(LDPMessageType::Transcribe, 51, 1, vbytes.data(), static_cast<uint32_t>(vbytes.size())), "send vocab51");
        require(w->recvFrame(hdr, payload), "recv vocab51 err");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload), "vocab>50 rejected");

        // 5c: unaligned PCM bytes
        auto ubytes = buildTranscribePayload("{\"sampleRate\":16000}", {0.0f, 0.1f});
        ubytes.push_back(0xAA); // breaks 4-byte alignment
        require(w->sendFrame(LDPMessageType::Transcribe, 52, 1, ubytes.data(), static_cast<uint32_t>(ubytes.size())), "send unaligned");
        require(w->recvFrame(hdr, payload), "recv unaligned err");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrInvalidPayload), "unaligned PCM rejected");

        std::printf("[PASS 5/11] Input validation guards (NaN, vocab>50, unaligned PCM) all rejected with ERR_INVALID_PAYLOAD\n");
    }

    // 6. Real TRANSCRIBE with vocabulary
    std::vector<float> test_pcm;
    if (!pcm_file.empty()) {
        test_pcm = loadFloat32File(pcm_file);
    }
    if (test_pcm.empty()) {
        test_pcm = makeSyntheticTone(2.0);
    }
    {
        JsonBuilder mjb;
        mjb.addInt64("sampleRate", 16000);
        mjb.addString("language", "auto");
        mjb.addStringArray("vocabulary", {"LiteDictate", "SwiftUI", "AUHAL"});
        auto bytes = buildTranscribePayload(mjb.finish(), test_pcm);
        require(w->sendFrame(LDPMessageType::Transcribe, 6, 1, bytes.data(), static_cast<uint32_t>(bytes.size())), "send TRANSCRIBE");
        require(w->recvFrame(hdr, payload), "recv RESULT");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Result), "expected RESULT");
        require(hdr.request_id == 6 && hdr.attempt_id == 1, "RESULT req/att echo");
        require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse RESULT JSON");
        uint64_t peak_fp = static_cast<uint64_t>(jv.find("peakFootprintBytes")->asInt());
        uint64_t post_fp = static_cast<uint64_t>(jv.find("postFreeFootprintBytes")->asInt());
        std::printf("[PASS 6/11] TRANSCRIBE (%.2fs audio) -> RESULT | lang=%s total=%.1f ms (init=%.1f mel=%.1f enc=%.1f dec=%.1f) peak=%.2f MB post_free=%.2f MB text=\"%s\"\n",
                    static_cast<double>(test_pcm.size()) / 16000.0,
                    jv.find("detectedLanguage")->str_val.c_str(),
                    jv.find("totalInferenceMs")->asDouble(),
                    jv.find("sessionInitMs")->asDouble(),
                    jv.find("melMs")->asDouble(),
                    jv.find("encodeMs")->asDouble(),
                    jv.find("decodeMs")->asDouble(),
                    mb(peak_fp),
                    mb(post_fp),
                    jv.find("text")->str_val.c_str());
    }

    // 7. ERR_BUSY payload drain + subsequent PING->PONG + CANCEL mid-flight
    {
        std::vector<float> long_pcm = makeSyntheticTone(25.0);
        if (test_pcm.size() > 8000) {
            long_pcm.clear();
            while (long_pcm.size() < 16000 * 25) {
                long_pcm.insert(long_pcm.end(), test_pcm.begin(), test_pcm.end());
            }
            long_pcm.resize(16000 * 25);
        }
        auto long_bytes = buildTranscribePayload("{\"sampleRate\":16000}", long_pcm);

        // Second TRANSCRIBE carrying 256 KiB of PCM while worker is busy
        std::vector<float> busy_pcm = makeSyntheticTone(4.0);
        auto busy_bytes = buildTranscribePayload("{\"sampleRate\":16000}", busy_pcm);

        require(w->sendFrame(LDPMessageType::Transcribe, 100, 1, long_bytes.data(), static_cast<uint32_t>(long_bytes.size())), "send long TRANSCRIBE");
        require(w->sendFrame(LDPMessageType::Transcribe, 101, 1, busy_bytes.data(), static_cast<uint32_t>(busy_bytes.size())), "send busy TRANSCRIBE");
        require(w->sendFrame(LDPMessageType::Ping, 102, 0, nullptr, 0), "send PING after busy");

        // Receive ERR_BUSY(101) and PONG(102) FIRST to verify Thread 1 did not block on Thread 2!
        bool got_busy = false;
        bool got_pong = false;
        bool got_cancelled = false;
        std::string cancel_stage;

        for (int i = 0; i < 2; ++i) {
            require(w->recvFrame(hdr, payload), "recv busy/pong response");
            if (hdr.request_id == 101) {
                require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error), "101 must be ERROR");
                require(hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrBusy), "101 must be ERR_BUSY");
                got_busy = true;
            } else if (hdr.request_id == 102) {
                require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Pong), "102 must be PONG");
                got_pong = true;
            } else {
                require(false, "expected ERR_BUSY(101) and PONG(102) before req 100 completes");
            }
        }
        require(got_busy && got_pong, "must receive ERR_BUSY and PONG while req 100 is running");

        // Let inference get into transcribe_run, then CANCEL(100, 1)
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        require(w->sendFrame(LDPMessageType::Cancel, 100, 1, nullptr, 0), "send CANCEL(100,1)");
        require(w->recvFrame(hdr, payload), "recv CANCELLED(100,1)");
        require(hdr.request_id == 100 && hdr.attempt_id == 1, "100 req/att echo");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Cancelled), "100 must be CANCELLED");
        require(JsonParser::parse(payload.data(), payload.size(), jv, jerr), "parse CANCELLED JSON");
        cancel_stage = jv.find("stage")->str_val;
        got_cancelled = true;
        require(got_cancelled, "must receive CANCELLED");
        std::printf("[PASS 7/11] ERR_BUSY drained %zu bytes cleanly -> subsequent PING->PONG intact -> CANCEL(100,1) -> CANCELLED (stage=%s)\n",
                    busy_bytes.size(), cancel_stage.c_str());
    }

    // 8. SHUTDOWN -> BYE -> exit(0)
    {
        require(w->sendFrame(LDPMessageType::Shutdown, 200, 0, nullptr, 0), "send SHUTDOWN");
        require(w->recvFrame(hdr, payload), "recv BYE");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Bye), "expected BYE");
        require(hdr.request_id == 200, "BYE request_id echo");
        int code = w->reap();
        require(code == 0, "worker must exit 0 on SHUTDOWN");
        std::printf("[PASS 8/11] SHUTDOWN -> BYE -> exit(0) (Cold = 0 MB, process gone)\n");
    }

    // -------------------------------------------------------------------------
    // Session B: Invalid magic -> ERR_PROTOCOL + _exit(2)
    // -------------------------------------------------------------------------
    {
        auto wb = SpawnedWorker::launch(worker_path);
        LDPFrameHeader bad{};
        std::memcpy(bad.magic, "BAD!", 4);
        bad.version = kLDPVersion;
        bad.msg_type = static_cast<uint16_t>(LDPMessageType::Ping);
        require(writeAll(wb->write_fd, &bad, sizeof(bad)), "send bad magic");
        require(wb->recvFrame(hdr, payload), "recv ERR_PROTOCOL for bad magic");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrProtocol), "bad magic -> ERR_PROTOCOL");
        int code = wb->reap();
        require(code == 2, "bad magic must exit(2)");
        std::printf("[PASS 9/11] Invalid magic -> ERR_PROTOCOL + _exit(2)\n");
    }

    // -------------------------------------------------------------------------
    // Session C: Oversized payload (> 8 MiB) -> ERR_PROTOCOL + _exit(2)
    // -------------------------------------------------------------------------
    {
        auto wc = SpawnedWorker::launch(worker_path);
        LDPFrameHeader huge{};
        std::memcpy(huge.magic, kLDPMagic, 4);
        huge.version = kLDPVersion;
        huge.msg_type = static_cast<uint16_t>(LDPMessageType::Transcribe);
        huge.payload_len = kMaxFrameBytes + 1;
        require(writeAll(wc->write_fd, &huge, sizeof(huge)), "send huge payload_len");
        require(wc->recvFrame(hdr, payload), "recv ERR_PROTOCOL for huge frame");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrProtocol), "huge frame -> ERR_PROTOCOL");
        int code = wc->reap();
        require(code == 2, "huge frame must exit(2)");
        std::printf("[PASS 10/11] Oversized frame (> 8 MiB) -> ERR_PROTOCOL + _exit(2)\n");
    }

    // -------------------------------------------------------------------------
    // Session D: Model file-size cap guard (LITEDICTATE_MAX_MODEL_BYTES)
    // -------------------------------------------------------------------------
    {
        ::setenv("LITEDICTATE_MAX_MODEL_BYTES", "1048576", 1); // 1 MiB cap for probe test
        auto wd = SpawnedWorker::launch(worker_path);
        ::unsetenv("LITEDICTATE_MAX_MODEL_BYTES");

        JsonBuilder jb;
        jb.addString("modelPath", asr_model);
        jb.addString("backend", "cpu");
        const std::string req_json = jb.finish();
        require(wd->sendJson(LDPMessageType::ProbeModel, 300, 0, req_json), "send oversized model PROBE");
        require(wd->recvFrame(hdr, payload), "recv oversized model err");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrModelLoad),
                "oversized model must be rejected with ERR_MODEL_LOAD");

        require(wd->sendJson(LDPMessageType::Warmup, 301, 0, req_json), "send oversized model WARMUP");
        require(wd->recvFrame(hdr, payload), "recv oversized model warmup err");
        require(hdr.msg_type == static_cast<uint16_t>(LDPMessageType::Error) &&
                hdr.status_or_flags == static_cast<uint32_t>(LDPErrorCode::ErrModelLoad),
                "oversized model WARMUP must be rejected with ERR_MODEL_LOAD");

        require(wd->sendFrame(LDPMessageType::Shutdown, 302, 0, nullptr, 0), "send SHUTDOWN");
        require(wd->recvFrame(hdr, payload), "recv BYE");
        require(wd->reap() == 0, "worker must exit 0");
        std::printf("[PASS 11/11] Model file-size cap guard rejects oversized GGUF in PROBE_MODEL & WARMUP with ERR_MODEL_LOAD\n");
    }

    std::printf("=== ALL 11/11 PHASE 1 PROBE 1 CHECKS PASSED ===\n");
    return 0;
}
