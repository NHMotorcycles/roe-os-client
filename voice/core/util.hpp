// Small helpers of the voice DLL: the server URL, a lock-free single-producer queue and the log
// file with size cap and rotation.
#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <string>
#include <string_view>

namespace roe::voice {

// "udp://host:port", "host:port", "host" (port 10101), "[v6 address]:port". False for another
// scheme, an empty host or a bad port.
bool parse_server_url(std::string_view url, std::string& host, std::uint16_t& port);

#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable : 4324)  // padded on purpose: head and tail on their own cache lines
#endif
// One producer thread, one consumer thread, fixed capacity (a power of two). push() fails when
// full; nothing allocates after construction.
template <class T, std::size_t N> class SpscQueue {
    static_assert(N >= 2 && (N & (N - 1)) == 0, "capacity must be a power of two");

public:
    // Producer: the slot to fill, or nullptr when full; then commit().
    T* claim() {
        const auto head = head_.load(std::memory_order_relaxed);
        if (head - tail_.load(std::memory_order_acquire) >= N) return nullptr;
        return &items_[head % N];
    }
    void commit() { head_.store(head_.load(std::memory_order_relaxed) + 1, std::memory_order_release); }
    // Consumer: the oldest item or nullptr; then release().
    T* front() {
        const auto tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) return nullptr;
        return &items_[tail % N];
    }
    void release() { tail_.store(tail_.load(std::memory_order_relaxed) + 1, std::memory_order_release); }
    std::size_t size() const { return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire); }

private:
    std::array<T, N> items_{};
    alignas(64) std::atomic<std::size_t> head_{0};
    alignas(64) std::atomic<std::size_t> tail_{0};
};
#ifdef _MSC_VER
#pragma warning(pop)
#endif

// Log file: one line per call, written at once. When the file would pass `cap_bytes` it is
// renamed to <name>.1 (the older ones move up to <name>.<keep>) and a new one starts.
class LogFile {
public:
    LogFile() = default;
    LogFile(const LogFile&) = delete;
    LogFile& operator=(const LogFile&) = delete;
    ~LogFile();
    bool open(const std::filesystem::path& path, std::uintmax_t cap_bytes, int keep);
    void write(std::string_view line);  // adds the newline
    void close();
    static std::filesystem::path rotated(const std::filesystem::path& path, int n);

private:
    void rotate_locked();
    std::mutex mutex_;
    void* file_ = nullptr;
    std::filesystem::path path_;
    std::uintmax_t cap_ = 0, size_ = 0;
    int keep_ = 1;
};

}  // namespace roe::voice
