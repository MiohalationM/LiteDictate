#ifndef LITEDICTATE_METRICS_HPP
#define LITEDICTATE_METRICS_HPP

#include <chrono>
#include <cstdint>

#include <mach/mach.h>
#include <mach/task_info.h>

namespace litedictate {

inline uint64_t currentPhysFootprintBytes() {
    task_vm_info_data_t vm_info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        reinterpret_cast<task_info_t>(&vm_info),
        &count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<uint64_t>(vm_info.phys_footprint);
}

class MonotonicTimer {
public:
    MonotonicTimer() : start_(std::chrono::steady_clock::now()) {}

    double elapsedMs() const {
        auto now = std::chrono::steady_clock::now();
        return std::chrono::duration<double, std::milli>(now - start_).count();
    }

private:
    std::chrono::steady_clock::time_point start_;
};

} // namespace litedictate

#endif // LITEDICTATE_METRICS_HPP
