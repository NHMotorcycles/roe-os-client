// Configuration, log file and shared state of GCloudVoice.dll.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "dll.hpp"

namespace roe::voice::dll {

namespace {

// Never destroyed: threads may still log while the process ends.
Config* g_config = new Config();
LogFile* g_log = new LogFile();
Shared* g_shared = new Shared();
thread_local const char* t_name = "game";
// Lines of the game thread wait here for the network thread, so the game never writes files.
std::mutex* g_pending_mutex = new std::mutex();
std::vector<std::string>* g_pending = new std::vector<std::string>();
constexpr std::size_t kMaxPending = 512;

std::string narrow(const wchar_t* w) {
    char buf[512];
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, sizeof buf, nullptr, nullptr);
    return n > 0 ? std::string(buf, static_cast<std::size_t>(n - 1)) : std::string();
}

std::string env(const char* name) {
    char buf[64];
    const DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    return n > 0 && n < sizeof buf ? std::string(buf, n) : std::string();
}

}  // namespace

const Config& config() { return *g_config; }
Shared& shared() { return *g_shared; }

std::filesystem::path module_dir() {
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&module_dir), &self);
    wchar_t path[MAX_PATH] = {};
    const DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return std::filesystem::path();
    return std::filesystem::path(path).parent_path();
}

void load_config() {
    Config& c = *g_config;
    const std::wstring ini = (module_dir() / L"GCloudVoice.ini").wstring();
    wchar_t buf[256] = {};
    GetPrivateProfileStringW(L"voice", L"server", L"", buf, 256, ini.c_str());
    c.server = narrow(buf);
    GetPrivateProfileStringW(L"voice", L"vad_threshold_db", L"", buf, 256, ini.c_str());
    if (buf[0]) c.vad_threshold_db = static_cast<float>(_wtof(buf));
    if (const int b = static_cast<int>(GetPrivateProfileIntW(L"voice", L"bitrate", -1, ini.c_str())); b >= 0) {
        c.bitrate = clamp_bitrate(b);
        c.bitrate_ini = true;
    }
    c.log_kb = static_cast<int>(GetPrivateProfileIntW(L"voice", L"log_kb", static_cast<INT>(c.log_kb), ini.c_str()));
    if (c.log_kb < 64) c.log_kb = 64;
    const std::string input = env("GVOICE_INPUT");
    c.tone_input = input == "tone";
    c.no_input = input == "none";
    c.no_output = env("GVOICE_OUTPUT") == "none";
    if (const std::string s = env("GVOICE_STATS_MS"); !s.empty()) c.stats_ms = std::atoi(s.c_str());
    g_shared->bitrate = c.bitrate;
}

void log_open() {
    g_log->open(module_dir() / L"GCloudVoice.log", static_cast<std::uintmax_t>(config().log_kb) * 1024, 2);
}

void set_thread_name(const char* name) { t_name = name; }

void log(const char* fmt, ...) {
    char line[900];
    SYSTEMTIME t;
    GetLocalTime(&t);
    int n = std::snprintf(line, sizeof line, "%02u:%02u:%02u.%03u [%s] ", t.wHour, t.wMinute, t.wSecond,
                          t.wMilliseconds, t_name);
    if (n < 0) return;
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(line + n, sizeof line - static_cast<std::size_t>(n), fmt, args);
    va_end(args);
    if (std::strcmp(t_name, "game") != 0) {
        g_log->write(line);
        return;
    }
    {
        std::lock_guard lock(*g_pending_mutex);
        if (g_pending->size() >= kMaxPending) return;
        g_pending->emplace_back(line);
    }
    if (g_shared->network_wake) SetEvent(g_shared->network_wake);
}

void log_flush() {
    std::vector<std::string> lines;
    {
        std::lock_guard lock(*g_pending_mutex);
        lines.swap(*g_pending);
    }
    for (const auto& l : lines) g_log->write(l);
}

std::int64_t now_ms() { return static_cast<std::int64_t>(GetTickCount64()); }

float volume_gain(int value) {
    if (value <= 0) return 0.0f;
    const float g = value <= 200 ? static_cast<float>(value) / 100.0f : static_cast<float>(value) / 65535.0f;
    return g > 2.0f ? 2.0f : g;
}

}  // namespace roe::voice::dll
