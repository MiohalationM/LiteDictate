#ifndef LITEDICTATE_LDP_PROTOCOL_HPP
#define LITEDICTATE_LDP_PROTOCOL_HPP

#include <cstddef>
#include <cstdint>

namespace litedictate {

constexpr char kLDPMagic[4] = {'L', 'D', 'P', '1'};
constexpr uint16_t kLDPVersion = 1;
constexpr uint32_t kMaxFrameBytes = 8u * 1024u * 1024u; // 8 MiB
constexpr size_t kMaxVocabularyEntries = 50;

// Protocol file descriptors mandated by LiteDictate Architecture Section 7.1
constexpr int kProtoReadFD = 3;
constexpr int kProtoWriteFD = 4;

// Host -> Worker messages
enum class LDPMessageType : uint16_t {
    Warmup      = 0x01,
    Transcribe  = 0x02,
    Cancel      = 0x03,
    Shutdown    = 0x04,
    Ping        = 0x05,
    ProbeModel  = 0x06,

    // Worker -> Host responses
    Ready       = 0x81,
    Result      = 0x82,
    Error       = 0x83,
    Bye         = 0x84,
    Pong        = 0x85,
    Cancelled   = 0x86,
    ProbeResult = 0x87
};

enum class LDPErrorCode : uint32_t {
    Ok                = 0,
    ErrProtocol       = 1,
    ErrBusy           = 2,
    ErrInvalidPayload = 3,
    ErrModelNotLoaded = 4,
    ErrModelLoad      = 5,
    ErrUnsupportedRole = 6,
    ErrInference      = 7,
    ErrInternal       = 8
};

constexpr uint32_t kResultFlagTruncated = 1u << 0;
constexpr uint32_t kResultFlagAborted   = 1u << 1;

inline const char *ldpErrorCodeName(LDPErrorCode code) {
    switch (code) {
        case LDPErrorCode::Ok:                 return "OK";
        case LDPErrorCode::ErrProtocol:        return "ERR_PROTOCOL";
        case LDPErrorCode::ErrBusy:            return "ERR_BUSY";
        case LDPErrorCode::ErrInvalidPayload:  return "ERR_INVALID_PAYLOAD";
        case LDPErrorCode::ErrModelNotLoaded:  return "ERR_MODEL_NOT_LOADED";
        case LDPErrorCode::ErrModelLoad:       return "ERR_MODEL_LOAD";
        case LDPErrorCode::ErrUnsupportedRole: return "ERR_UNSUPPORTED_ROLE";
        case LDPErrorCode::ErrInference:       return "ERR_INFERENCE";
        case LDPErrorCode::ErrInternal:        return "ERR_INTERNAL";
    }
    return "ERR_INTERNAL";
}

struct alignas(8) LDPFrameHeader {
    char     magic[4];        // Offset  0: {'L', 'D', 'P', '1'}
    uint16_t version;         // Offset  4: 1
    uint16_t msg_type;        // Offset  6: LDPMessageType
    uint64_t request_id;      // Offset  8: Request generation
    uint64_t attempt_id;      // Offset 16: Attempt generation
    uint32_t payload_len;     // Offset 24: Payload byte length (<= 8 MiB)
    uint32_t status_or_flags; // Offset 28: LDPErrorCode or result flags
};

static_assert(sizeof(LDPFrameHeader) == 32, "LDPFrameHeader must be 32 bytes");
static_assert(alignof(LDPFrameHeader) == 8, "LDPFrameHeader must be 8-byte aligned");
static_assert(offsetof(LDPFrameHeader, magic) == 0, "magic offset");
static_assert(offsetof(LDPFrameHeader, version) == 4, "version offset");
static_assert(offsetof(LDPFrameHeader, msg_type) == 6, "msg_type offset");
static_assert(offsetof(LDPFrameHeader, request_id) == 8, "request_id offset");
static_assert(offsetof(LDPFrameHeader, attempt_id) == 16, "attempt_id offset");
static_assert(offsetof(LDPFrameHeader, payload_len) == 24, "payload_len offset");
static_assert(offsetof(LDPFrameHeader, status_or_flags) == 28, "status_or_flags offset");

// Binary prefix at start of 0x02 TRANSCRIBE payload:
//   [0..3] uint32_t meta_json_len (LE)
//   [4..7] uint32_t sample_count  (LE)
//   [8 .. 8+meta_json_len-1] UTF-8 JSON metadata
//   [pad to 4-byte boundary: pcm_offset = (8 + meta_json_len + 3) & ~3u]
//   [pcm_offset .. pcm_offset + sample_count * 4 - 1] LE IEEE-754 float32 PCM
struct LDPTranscribePrefix {
    uint32_t meta_json_len;
    uint32_t sample_count;
};
static_assert(sizeof(LDPTranscribePrefix) == 8, "LDPTranscribePrefix must be 8 bytes");

inline uint32_t ldpAlign4(uint32_t n) {
    return (n + 3u) & ~3u;
}

} // namespace litedictate

#endif // LITEDICTATE_LDP_PROTOCOL_HPP
