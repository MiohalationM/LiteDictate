#ifndef LITEDICTATE_FD_IO_HPP
#define LITEDICTATE_FD_IO_HPP

#include "ldp_protocol.hpp"

#include <algorithm>
#include <cerrno>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace litedictate {

enum class ReadStatus {
    Ok,
    CleanEof,     // EOF before reading any bytes
    TruncatedEof, // EOF mid-read
    Error
};

inline ReadStatus readExact(int fd, void *buf, size_t len) {
    uint8_t *p = static_cast<uint8_t *>(buf);
    size_t done = 0;
    while (done < len) {
        ssize_t n = ::read(fd, p + done, len - done);
        if (n > 0) {
            done += static_cast<size_t>(n);
        } else if (n == 0) {
            return done == 0 ? ReadStatus::CleanEof : ReadStatus::TruncatedEof;
        } else {
            if (errno == EINTR) continue;
            return ReadStatus::Error;
        }
    }
    return ReadStatus::Ok;
}

inline bool drainExact(int fd, size_t len) {
    uint8_t discard[16384];
    size_t remaining = len;
    while (remaining > 0) {
        size_t chunk = std::min(remaining, sizeof(discard));
        ssize_t n = ::read(fd, discard, chunk);
        if (n > 0) {
            remaining -= static_cast<size_t>(n);
        } else if (n == 0) {
            return false;
        } else {
            if (errno == EINTR) continue;
            return false;
        }
    }
    return true;
}

inline bool writeAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = static_cast<const uint8_t *>(buf);
    size_t done = 0;
    while (done < len) {
        ssize_t n = ::write(fd, p + done, len - done);
        if (n > 0) {
            done += static_cast<size_t>(n);
        } else if (n == 0) {
            return false;
        } else {
            if (errno == EINTR) continue;
            return false;
        }
    }
    return true;
}

// Bounded outgoing frame writer on FD 4.
class FrameWriter {
public:
    static constexpr size_t kMaxQueuedFrames = 64;

    explicit FrameWriter(int write_fd)
        : write_fd_(write_fd), thread_(&FrameWriter::run, this) {}

    ~FrameWriter() {
        stop();
    }

    FrameWriter(const FrameWriter &) = delete;
    FrameWriter &operator=(const FrameWriter &) = delete;

    bool enqueue(
        LDPMessageType type,
        uint64_t request_id,
        uint64_t attempt_id,
        uint32_t status_or_flags,
        std::string payload) {
        if (payload.size() > kMaxFrameBytes) {
            return false;
        }
        OutgoingFrame frame;
        std::memcpy(frame.header.magic, kLDPMagic, 4);
        frame.header.version = kLDPVersion;
        frame.header.msg_type = static_cast<uint16_t>(type);
        frame.header.request_id = request_id;
        frame.header.attempt_id = attempt_id;
        frame.header.payload_len = static_cast<uint32_t>(payload.size());
        frame.header.status_or_flags = status_or_flags;
        frame.payload = std::move(payload);

        std::unique_lock<std::mutex> lock(mu_);
        space_cv_.wait(lock, [&] {
            return stop_ || broken_ || queue_.size() < kMaxQueuedFrames;
        });
        if (stop_ || broken_) {
            return false;
        }
        queue_.push_back(std::move(frame));
        data_cv_.notify_one();
        return true;
    }

    // Blocks until every previously enqueued frame has been written to FD 4.
    void flush() {
        std::unique_lock<std::mutex> lock(mu_);
        flushed_cv_.wait(lock, [&] {
            return broken_ || (queue_.empty() && !writing_);
        });
    }

    void stop() {
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (stop_) return;
            stop_ = true;
        }
        data_cv_.notify_all();
        space_cv_.notify_all();
        flushed_cv_.notify_all();
        if (thread_.joinable()) {
            thread_.join();
        }
    }

private:
    struct OutgoingFrame {
        LDPFrameHeader header{};
        std::string payload;
    };

    void run() {
        while (true) {
            OutgoingFrame frame;
            {
                std::unique_lock<std::mutex> lock(mu_);
                data_cv_.wait(lock, [&] { return stop_ || broken_ || !queue_.empty(); });
                if (broken_) break;
                if (queue_.empty()) {
                    if (stop_) break;
                    continue;
                }
                frame = std::move(queue_.front());
                queue_.pop_front();
                writing_ = true;
                space_cv_.notify_one();
            }

            bool ok = writeAll(write_fd_, &frame.header, sizeof(frame.header));
            if (ok && !frame.payload.empty()) {
                ok = writeAll(write_fd_, frame.payload.data(), frame.payload.size());
            }

            {
                std::lock_guard<std::mutex> lock(mu_);
                writing_ = false;
                if (!ok) {
                    broken_ = true;
                    queue_.clear();
                    space_cv_.notify_all();
                    flushed_cv_.notify_all();
                    break;
                }
                if (queue_.empty()) {
                    flushed_cv_.notify_all();
                }
            }
        }
    }

    int write_fd_;
    std::mutex mu_;
    std::condition_variable data_cv_;
    std::condition_variable space_cv_;
    std::condition_variable flushed_cv_;
    std::deque<OutgoingFrame> queue_;
    bool writing_ = false;
    bool stop_ = false;
    bool broken_ = false;
    std::thread thread_;
};

} // namespace litedictate

#endif // LITEDICTATE_FD_IO_HPP
