// Drives the built GCloudVoice.dll the way the game does (rea/VOICE.md: the slot order of the
// game's calls, callbacks from Poll, the World room settings in OnJoinRoom), against a fake relay
// in this process that speaks docs/VOICE-PROTOCOL.md. No real devices: a test tone instead of
// the microphone, no speaker output.
// Usage: voice_dll_test <GCloudVoice.dll>      (voice_dll_test --child <dll> <port>: exit test)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "core/protocol.hpp"

using namespace roe::voice;
namespace fs = std::filesystem;

namespace {

constexpr const char* kTicket = "0123456789abcdef0123456789abcdef";
constexpr const char* kTeam = "W0T7_roe";
constexpr const char* kWorld = "W12_roe";
constexpr const char* kForbidden = "W0T999_roe";

int g_failures = 0;
void check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++g_failures;
}

// ---------------------------------------------------------------- fake relay

class Relay {
public:
    std::atomic<int> hellos{0}, refused{0}, joins{0}, quits{0}, coords{0}, audio_frames{0}, audio_datagrams{0}, audio_gaps{0}, voice_sent{0},
        pings{0}, byes{0};
    std::atomic<bool> echo{false}, silent{false}, refuse_next{true};
    std::atomic<int> world_mic{-1}, world_speaker{-1}, team_speaker{-1};

    bool start() {
        sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(sock_, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) return false;
        int len = sizeof a;
        getsockname(sock_, reinterpret_cast<sockaddr*>(&a), &len);
        port_ = ntohs(a.sin_port);
        thread_ = std::thread([this] { run(); });
        return true;
    }
    void stop() {
        running_ = false;
        thread_.join();
        closesocket(sock_);
    }
    int port() const { return port_; }
    void send_reset() { reset_requested_ = true; }

private:
    struct Peer {
        std::uint32_t session = 0;
        std::map<std::string, std::int32_t> rooms;
    };

    void reply(const sockaddr_in& to, std::size_t n) {
        if (n) sendto(sock_, reinterpret_cast<const char*>(out_.data()), static_cast<int>(n), 0,
                      reinterpret_cast<const sockaddr*>(&to), sizeof to);
    }

    void run() {
        std::array<std::uint8_t, 2048> in{};
        while (running_) {
            if (reset_requested_.exchange(false)) {
                std::lock_guard lock(mutex_);
                for (auto& [key, p] : peers_) {
                    reply(addr_[key], encode_reset(out_));
                    p.session = 0;
                    p.rooms.clear();
                }
            }
            // select(), not SO_RCVTIMEO: a timed-out recvfrom can lose a datagram on Windows.
            fd_set set;
            FD_ZERO(&set);
            FD_SET(sock_, &set);
            timeval tv{0, 20000};
            if (select(0, &set, nullptr, nullptr, &tv) <= 0) continue;
            sockaddr_in from{};
            int from_len = sizeof from;
            const int n = recvfrom(sock_, reinterpret_cast<char*>(in.data()), static_cast<int>(in.size()), 0,
                                   reinterpret_cast<sockaddr*>(&from), &from_len);
            if (n <= 0 || silent) continue;
            handle(std::span<const std::uint8_t>(in.data(), static_cast<std::size_t>(n)), from);
        }
    }

    void handle(std::span<const std::uint8_t> d, const sockaddr_in& from) {
        std::lock_guard lock(mutex_);
        const std::uint64_t key = (static_cast<std::uint64_t>(from.sin_addr.s_addr) << 16) | from.sin_port;
        addr_[key] = from;
        Peer& p = peers_[key];
        Header h;
        Reader body({});
        if (!decode_header(d, h, body)) return;
        if (h.kind == Kind::Hello) {
            Hello hello;
            if (!decode_hello(body, hello)) return;
            ++hellos;
            if (hello.ticket != kTicket || refuse_next.exchange(false)) {
                ++refused;
                reply(from, encode_welcome(out_, 0));
                return;
            }
            if (p.session == 0) p.session = next_session_++;
            reply(from, encode_welcome(out_, p.session));
            return;
        }
        if (p.session == 0 || h.session != p.session) {
            reply(from, encode_reset(out_));
            return;
        }
        switch (h.kind) {
        case Kind::Join: {
            Join j;
            if (!decode_join(body, j)) return;
            ++joins;
            const std::string room(j.room);
            std::int32_t member = -1;
            if (room == kTeam) member = 1;
            if (room == kWorld) member = 5;
            if (member > 0) p.rooms[room] = member;
            reply(from, encode_joined(out_, p.session, j.request, room, member));
            if (member > 0) {
                const std::array<std::int32_t, 2> ids{member, 2};
                const std::array<std::string_view, 2> names{"1001", "1002"};
                reply(from, encode_members(out_, p.session, room, ids, names));
            }
            return;
        }
        case Kind::Quit: {
            std::string_view room;
            if (decode_quit(body, room)) {
                ++quits;
                p.rooms.erase(std::string(room));
            }
            return;
        }
        case Kind::Coord: {
            Coord c;
            if (decode_coord(body, c)) ++coords;
            return;
        }
        case Kind::State: {
            State s;
            if (!decode_state(body, s)) return;
            if (s.room == kWorld) {
                world_mic = s.mic;
                world_speaker = s.speaker;
            }
            if (s.room == kTeam) team_speaker = s.speaker;
            return;
        }
        case Kind::Audio: {
            Frames f;
            if (!decode_audio(body, f)) return;
            if (audio_frames > 0 && f.sequence != next_seq_) ++audio_gaps;
            next_seq_ = static_cast<std::uint16_t>(f.sequence + f.count);
            audio_frames += f.count;
            ++audio_datagrams;
            // As a teammate (member 2) would sound: the same frames back in the Team room.
            if (echo && p.rooms.count(kTeam)) {
                reply(from, encode_voice(out_, p.session, kTeam, 2, f));
                ++voice_sent;
            }
            return;
        }
        case Kind::Ping: {
            std::uint32_t t = 0;
            ++pings;
            if (decode_time(body, t)) reply(from, encode_pong(out_, p.session, t));
            return;
        }
        case Kind::Bye:
            ++byes;
            return;
        default:
            return;
        }
    }

    SOCKET sock_ = INVALID_SOCKET;
    int port_ = 0;
    std::thread thread_;
    std::atomic<bool> running_{true}, reset_requested_{false};
    std::mutex mutex_;
    std::map<std::uint64_t, Peer> peers_;
    std::map<std::uint64_t, sockaddr_in> addr_;
    std::uint32_t next_session_ = 0x5000;
    std::uint16_t next_seq_ = 0;
    std::array<std::uint8_t, kMaxDatagram> out_{};
};

// ---------------------------------------------------------------- the game's side

void* g_engine = nullptr;
DWORD g_main_thread = 0;
std::atomic<bool> g_wrong_thread{false};
double g_slowest_call_ms = 0;

template <class F> F slot(int offset) { return reinterpret_cast<F>((*reinterpret_cast<void***>(g_engine))[offset / 8]); }

// Times every engine call: none may block the game thread.
template <class R, class... A, class... B> R call(int offset, B... args) {
    const auto t0 = std::chrono::steady_clock::now();
    R r = slot<R (*)(void*, A...)>(offset)(g_engine, static_cast<A>(args)...);
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    if (ms > g_slowest_call_ms) g_slowest_call_ms = ms;
    return r;
}

struct Event {
    std::string kind, room;
    int code = 0, member = 0;
};
std::vector<Event> g_events;
bool g_channel_team = true;  // World room: neither hear nor talk (channel Team)

void on_thread() {
    if (GetCurrentThreadId() != g_main_thread) g_wrong_thread = true;
}
void __cdecl OnJoinRoom(void*, int code, const char* room, int member) {
    on_thread();
    g_events.push_back({"join", room, code, member});
    // The game sets the World room's speaker and mic here (0x1418dbc70).
    if (code == 1 && std::strcmp(room, kWorld) == 0) {
        call<int, const char*, bool>(0x1e8, room, !g_channel_team);
        call<int, const char*, bool>(0x1e0, room, !g_channel_team);
    }
    if (code == 1) call<int>(0x1c8);  // OpenSpeaker
}
void __cdecl OnStatusUpdate(void*, int code, const char* room, int member) {
    on_thread();
    g_events.push_back({"status", room, code, member});
}
void __cdecl OnQuitRoom(void*, int code, const char* room) {
    on_thread();
    g_events.push_back({"quit", room, code, 0});
}
void __cdecl OnMemberVoice(void*, const char* room, unsigned member, int status) {
    on_thread();
    g_events.push_back({"voice", room, status, static_cast<int>(member)});
}

int count(const char* kind, const char* room, int code, int member = -100) {
    int n = 0;
    for (const auto& e : g_events)
        n += e.kind == kind && e.room == room && e.code == code && (member == -100 || e.member == member);
    return n;
}

void poll_for(int ms, int coord_every_ms = 0) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    auto next_coord = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() < end) {
        call<int>(0x150);  // Poll
        if (coord_every_ms && std::chrono::steady_clock::now() >= next_coord) {
            next_coord += std::chrono::milliseconds(coord_every_ms);
            call<int, const char*, std::int64_t, std::int64_t, std::int64_t, std::int64_t>(0x188, kWorld, 100000, 200000,
                                                                                         3000, 5000);
        }
        Sleep(16);
    }
}

// Polls until `done` or the time runs out.
template <class F> bool wait_for(int ms, F done) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < end) {
        call<int>(0x150);
        if (done()) return true;
        Sleep(16);
    }
    return done();
}

void* g_notify[2];
void* g_notify_vtable[17];

bool load(const fs::path& dll) {
    HMODULE m = LoadLibraryW(dll.c_str());
    if (!m) {
        std::printf("LoadLibrary %ls failed %lu\n", dll.c_str(), GetLastError());
        return false;
    }
    auto get = reinterpret_cast<void* (*)()>(GetProcAddress(m, "GetVoiceEngine"));
    auto ctor = reinterpret_cast<void* (*)(void*)>(GetProcAddress(m, "??0IGCloudVoiceNotify@gcloud_voice@@QEAA@XZ"));
    if (!get || !ctor) {
        std::printf("exports missing\n");
        return false;
    }
    // Like the game: construct the base class, then put our own vtable with the overrides in.
    ctor(g_notify);
    std::memcpy(g_notify_vtable, *reinterpret_cast<void***>(g_notify), sizeof g_notify_vtable);
    g_notify_vtable[0x08 / 8] = reinterpret_cast<void*>(OnJoinRoom);
    g_notify_vtable[0x10 / 8] = reinterpret_cast<void*>(OnStatusUpdate);
    g_notify_vtable[0x18 / 8] = reinterpret_cast<void*>(OnQuitRoom);
    g_notify_vtable[0x20 / 8] = reinterpret_cast<void*>(OnMemberVoice);
    g_notify[0] = g_notify_vtable;
    g_engine = get();
    return g_engine != nullptr;
}

void start_engine(int port) {
    // The 2022 client's order (from its GCloudVoice.log): Init comes before SetServerInfo.
    const std::string url = "udp://127.0.0.1:" + std::to_string(port);
    call<int, const char*, const char*, const char*>(0x130, "roe", kTicket, "1001");  // SetAppInfo
    call<int>(0x138);                                         // Init
    call<int, bool>(0x08, true);                              // EnableLog
    call<int, void*>(0x140, g_notify);                        // SetNotify
    call<int, const char*>(0x128, url.c_str());                // SetServerInfo
    call<int, int>(0x148, 0);                                 // SetMode(RealTime)
    call<int, bool>(0x1d8, true);                             // EnableMultiRoom
    call<int>(0x1c8);                                         // OpenSpeaker
    call<int, int>(0x20, 80);                                 // SetSpeakerVolume
    call<int, int>(0x260, 120);                               // SetMicVolume
    call<int, unsigned, unsigned, unsigned, unsigned*>(0x48, 5004u, 64000u, 0u, nullptr);  // Invoke
}

std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

int child(const fs::path& dll, int port) {
    g_main_thread = GetCurrentThreadId();
    if (!load(dll)) return 2;
    start_engine(port);
    call<int, const char*, int>(0x170, kTeam, 10000);
    call<int>(0x1b8);  // OpenMic
    poll_for(1500);
    return 0;  // the process ends with the voice threads running: it must not hang
}

fs::path copy_dll(const fs::path& dll, const char* name) {
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    const fs::path dir = fs::path(tmp) / (std::string("roe_voice_test_") + name);
    std::error_code ec;
    fs::create_directories(dir, ec);
    fs::copy_file(dll, dir / "GCloudVoice.dll", fs::copy_options::overwrite_existing, ec);
    if (ec) std::printf("copy to %ls failed: %s\n", dir.c_str(), ec.message().c_str());
    return dir / "GCloudVoice.dll";
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    SetEnvironmentVariableA("GVOICE_INPUT", "tone");
    SetEnvironmentVariableA("GVOICE_OUTPUT", "none");
    SetEnvironmentVariableA("GVOICE_STATS_MS", "1000");
    if (argc == 4 && std::strcmp(argv[1], "--child") == 0) return child(argv[2], std::atoi(argv[3]));
    if (argc < 2) {
        std::printf("usage: voice_dll_test <GCloudVoice.dll>\n");
        return 2;
    }
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    Relay relay;
    if (!relay.start()) {
        std::printf("relay bind failed\n");
        return 2;
    }
    // Own copies, so the logs of this run and the child do not mix.
    const fs::path dll = copy_dll(argv[1], "main");
    const fs::path child_dll = copy_dll(argv[1], "child");
    g_main_thread = GetCurrentThreadId();
    if (!load(dll)) return 2;

    start_engine(relay.port());
    call<int, const char*, int>(0x170, kTeam, 10000);  // JoinTeamRoom
    check(wait_for(8000, [] { return count("join", kTeam, 1, 1) == 1; }), "team room joined as member 1 (after one refused HELLO)");
    check(relay.refused >= 1 && relay.hellos >= 2, "HELLO repeated after the refusal");

    relay.echo = true;
    call<int>(0x1b8);  // OpenMic
    poll_for(1500);
    check(relay.audio_frames >= 50, "about 50 audio frames a second reach the relay");
    check(count("voice", kTeam, 1, 2) == 1, "OnMemberVoice(team, 2, 1) when the teammate talks");
    check(call<bool>(0xd8), "IsMicOpened");
    check(call<int, bool>(0x10, true) > 0, "GetMicLevel > 0 while talking");
    check(relay.team_speaker == 1, "STATE: team speaker on after OpenSpeaker");

    call<int, const char*, int>(0x180, kWorld, 10000);  // JoinRangeRoom
    check(wait_for(3000, [] { return count("join", kWorld, 1, 5) == 1; }), "world room joined as member 5");
    poll_for(2500, 1000);
    check(relay.coords >= 2, "UpdateCoordinate reaches the relay");
    check(relay.world_mic == 0 && relay.world_speaker == 0, "channel Team: world room mic and speaker off");

    relay.echo = false;
    std::printf("relay: %d audio frames in %d datagrams (%d sequence gaps), %d voice datagrams back\n",
                relay.audio_frames.load(), relay.audio_datagrams.load(), relay.audio_gaps.load(), relay.voice_sent.load());
    check(relay.audio_gaps == 0, "audio sequence without gaps (every frame counted and sent)");
    call<int>(0x1c0);  // CloseMic (push-to-talk key released)
    poll_for(600);
    check(count("voice", kTeam, 0, 2) == 1, "OnMemberVoice(team, 2, 0) 300 ms after the last frame");
    const int frames = relay.audio_frames;
    poll_for(500);
    check(relay.audio_frames == frames, "no audio while the mic is closed");
    check(call<int, bool>(0x10, true) == 0, "GetMicLevel 0 with the mic closed");
    call<int>(0x1b8);  // push-to-talk again
    poll_for(500);
    check(relay.audio_frames > frames + 10, "audio again after OpenMic");
    call<int>(0x1c0);

    check(call<int>(0x2c0) == 0 && call<int>(0x2c0) == 0, "an unused slot (GetBGMPlayState) returns 0");

    call<int, const char*, int>(0x170, kForbidden, 10000);
    check(wait_for(3000, [] { return count("join", kForbidden, 3) == 1; }), "a room the relay refuses: OnJoinRoom(3)");

    // The relay forgets the session: rooms offline, the game joins again.
    const int hellos = relay.hellos;
    relay.send_reset();
    check(wait_for(2000, [] { return count("status", kTeam, 22) == 1 && count("status", kWorld, 22) == 1; }),
          "RESET: OnStatusUpdate(22) for both rooms");
    call<int, const char*, int>(0x170, kTeam, 10000);
    check(wait_for(4000, [] { return count("join", kTeam, 1, 1) == 2; }), "team room joined again after RESET");
    check(relay.hellos > hellos, "new HELLO after RESET");

    // The relay goes quiet: the DLL notices within about 6 s.
    relay.silent = true;
    check(wait_for(9000, [] { return count("status", kTeam, 22) == 2; }), "silent relay: OnStatusUpdate(22) by timeout");
    relay.silent = false;
    call<int, const char*, int>(0x170, kTeam, 10000);
    check(wait_for(8000, [] { return count("join", kTeam, 1, 1) == 3; }), "team room joined again after the relay came back");

    call<int, const char*, int>(0x1a8, kTeam, 10000);  // QuitRoom
    check(wait_for(2000, [] { return count("quit", kTeam, 6) == 1; }), "OnQuitRoom(6)");
    poll_for(300);
    check(relay.quits >= 1, "QUIT reaches the relay");

    check(!g_wrong_thread, "every callback ran on the game thread, inside Poll");
    std::printf("slowest engine call: %.3f ms\n", g_slowest_call_ms);
    check(g_slowest_call_ms < 5.0, "no engine call blocks the game thread (< 5 ms)");

    poll_for(1200);
    const std::string log = read_file(dll.parent_path() / "GCloudVoice.log");
    check(log.find("SetAppInfo(roe, <ticket of 32 characters>, 1001)") != std::string::npos, "SetAppInfo logged");
    check(log.find(kTicket) == std::string::npos, "the ticket is not in the log");
    check(log.find("Invoke 5004(64000) -> bit rate 48000") != std::string::npos, "Invoke 5004 sets the bit rate, capped at 48 kbit/s");
    check(log.find("audio out:") != std::string::npos && log.find("audio out: 0 frames played") == std::string::npos,
          "received voice was decoded and mixed");
    std::size_t unused = 0;
    for (std::size_t at = log.find("GetBGMPlayState"); at != std::string::npos; at = log.find("GetBGMPlayState", at + 1)) ++unused;
    check(unused == 1, "an unused slot is logged once");

    // Exit with running voice threads: a second process, which must end at once.
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(self) + L"\" --child \"" + child_dll.wstring() + L"\" " +
                       std::to_wstring(relay.port());
    const auto t0 = std::chrono::steady_clock::now();
    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        const DWORD w = WaitForSingleObject(pi.hProcess, 10000);
        DWORD code = 1;
        GetExitCodeProcess(pi.hProcess, &code);
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::printf("child ran %.1f s (1.5 s of it in the game loop)\n", s);
        check(w == WAIT_OBJECT_0 && code == 0 && s < 5.0, "the process exits at once with voice running");
        if (w != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    } else {
        check(false, "child process started");
    }

    relay.stop();
    std::printf("%s: %d failure(s)\n", g_failures ? "FAILED" : "OK", g_failures);
    // The DLL is pinned and its threads keep running: end the process directly.
    std::fflush(stdout);
    ExitProcess(g_failures ? 1 : 0);
}
