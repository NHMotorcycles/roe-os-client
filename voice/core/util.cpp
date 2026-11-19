#include "util.hpp"

#include <charconv>
#include <system_error>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <cstdio>
#endif

#include "protocol.hpp"

namespace roe::voice {

bool parse_server_url(std::string_view url, std::string& host, std::uint16_t& port) {
    while (!url.empty() && (url.front() == ' ' || url.front() == '\t')) url.remove_prefix(1);
    while (!url.empty() && (url.back() == ' ' || url.back() == '\t' || url.back() == '\r' || url.back() == '\n'))
        url.remove_suffix(1);
    if (const auto scheme = url.find("://"); scheme != std::string_view::npos) {
        const auto name = url.substr(0, scheme);
        if (name != "udp" && name != "UDP") return false;
        url.remove_prefix(scheme + 3);
    }
    if (const auto slash = url.find('/'); slash != std::string_view::npos) url = url.substr(0, slash);
    std::string_view h, p;
    if (!url.empty() && url.front() == '[') {
        const auto close = url.find(']');
        if (close == std::string_view::npos) return false;
        h = url.substr(1, close - 1);
        const auto after = url.substr(close + 1);
        if (!after.empty()) {
            if (after.front() != ':') return false;
            p = after.substr(1);
        }
    } else {
        const auto colon = url.rfind(':');
        if (colon != std::string_view::npos && url.find(':') != colon) {
            h = url;  // bare IPv6 address without a port
        } else if (colon != std::string_view::npos) {
            h = url.substr(0, colon);
            p = url.substr(colon + 1);
        } else {
            h = url;
        }
    }
    if (h.empty()) return false;
    std::uint16_t value = kDefaultPort;
    if (!p.empty()) {
        unsigned parsed = 0;
        const auto [end, ec] = std::from_chars(p.data(), p.data() + p.size(), parsed);
        if (ec != std::errc{} || end != p.data() + p.size() || parsed == 0 || parsed > 65535) return false;
        value = static_cast<std::uint16_t>(parsed);
    }
    host.assign(h);
    port = value;
    return true;
}

namespace {

// Windows: plain file handles, so no CRT lock is involved (a thread killed at process exit
// could hold one).
#ifdef _WIN32
void* open_file(const std::filesystem::path& path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    return h == INVALID_HANDLE_VALUE ? nullptr : h;
}
void write_file(void* f, std::string_view data) {
    DWORD written = 0;
    WriteFile(static_cast<HANDLE>(f), data.data(), static_cast<DWORD>(data.size()), &written, nullptr);
}
void close_file(void* f) { CloseHandle(static_cast<HANDLE>(f)); }
#else
void* open_file(const std::filesystem::path& path) { return std::fopen(path.c_str(), "wb"); }
void write_file(void* f, std::string_view data) {
    std::fwrite(data.data(), 1, data.size(), static_cast<std::FILE*>(f));
    std::fflush(static_cast<std::FILE*>(f));
}
void close_file(void* f) { std::fclose(static_cast<std::FILE*>(f)); }
#endif

}  // namespace

LogFile::~LogFile() { close(); }

std::filesystem::path LogFile::rotated(const std::filesystem::path& path, int n) {
    auto p = path;
    p.replace_extension(std::to_string(n) + path.extension().string());
    return p;
}

bool LogFile::open(const std::filesystem::path& path, std::uintmax_t cap_bytes, int keep) {
    std::lock_guard lock(mutex_);
    path_ = path;
    cap_ = cap_bytes;
    keep_ = keep < 1 ? 1 : keep;
    // Each start begins a new file; the previous ones move to .1, .2, ...
    std::error_code ec;
    if (std::filesystem::exists(path, ec)) rotate_locked();
    file_ = open_file(path);
    size_ = 0;
    return file_ != nullptr;
}

void LogFile::rotate_locked() {
    if (file_) {
        close_file(file_);
        file_ = nullptr;
    }
    std::error_code ec;
    std::filesystem::remove(rotated(path_, keep_), ec);
    for (int n = keep_ - 1; n >= 1; --n) std::filesystem::rename(rotated(path_, n), rotated(path_, n + 1), ec);
    std::filesystem::rename(path_, rotated(path_, 1), ec);
}

void LogFile::write(std::string_view line) {
    std::lock_guard lock(mutex_);
    if (!file_) return;
    if (size_ > 0 && size_ + line.size() + 1 > cap_) {
        rotate_locked();
        file_ = open_file(path_);
        size_ = 0;
        if (!file_) return;
    }
    // One write per line, so a line is never torn.
    std::array<char, 1024> buf;
    const std::size_t n = line.size() < buf.size() - 1 ? line.size() : buf.size() - 1;
    line.copy(buf.data(), n);
    buf[n] = '\n';
    write_file(file_, std::string_view(buf.data(), n + 1));
    size_ += n + 1;
}

void LogFile::close() {
    std::lock_guard lock(mutex_);
    if (file_) close_file(file_);
    file_ = nullptr;
}

}  // namespace roe::voice
