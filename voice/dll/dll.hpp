// Shared parts of GCloudVoice.dll: configuration, log, the state the threads share and their
// queues. Threads: the game's (engine calls, Poll), network, capture, render.
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "core/client.hpp"
#include "core/protocol.hpp"
#include "core/util.hpp"

namespace roe::voice::dll {

struct Config {
    std::string server;           // GCloudVoice.ini [voice] server=: overrides SetServerInfo
    float vad_threshold_db = -42.0f;
    int bitrate = 32000;          // until the game sets one (Invoke 5004, SetBitRate)
    bool bitrate_ini = false;     // GCloudVoice.ini [voice] bitrate= set: the game cannot change it
    int log_kb = 1024;            // log cap; GCloudVoice.1.log and .2.log keep the older ones
    bool tone_input = false;      // tests: a 440 Hz tone instead of the microphone
    bool no_input = false;        // tests: no microphone
    bool no_output = false;       // tests: decode and mix, but do not play
    int stats_ms = 10000;         // audio counters in the log
};

const Config& config();
// Opus bit rate the relay takes: 12..48 kbit/s (it limits audio to 8 KB/s per session).
inline int clamp_bitrate(int bps) { return bps < 12000 ? 12000 : (bps > 48000 ? 48000 : bps); }
void load_config();
std::filesystem::path module_dir();

void log_open();
// From the game thread the line is queued and written by the network thread (log_flush).
void log(const char* fmt, ...);
void log_flush();
// Thread tag in log lines.
void set_thread_name(const char* name);

std::int64_t now_ms();

// Game command for the network thread.
struct Command {
    enum class Type : std::uint8_t { Start, Join, Quit, Coord, RoomMic, RoomSpeaker, Speaker };
    Type type{};
    std::string room;
    bool flag = false;
    int value = 0;
    std::int64_t x = 0, y = 0, z = 0, radius = 0;
    std::string url, ticket, open_id;
};

struct EncodedFrame {
    std::uint16_t sequence = 0;
    std::uint16_t size = 0;
    std::array<std::uint8_t, kMaxOpusPacket> data{};
};

struct VoiceItem {
    std::int16_t stream = 0;
    bool reset = false;
    std::uint16_t sequence = 0;
    std::uint16_t size = 0;
    std::array<std::uint8_t, kMaxOpusPacket> data{};
};

struct Shared {
    std::atomic<bool> mic_open{false};
    std::atomic<bool> speaker_open{false};
    std::atomic<int> speaker_volume{100};
    std::atomic<int> mic_volume{100};
    std::atomic<int> bitrate{32000};
    std::atomic<bool> may_send{false};      // network: connected, a room with the mic on
    std::atomic<int> rooms{0};              // rooms joined or joining
    std::atomic<int> mic_level{0};          // GetMicLevel: > 0 only while sending
    std::atomic<bool> capture_device_changed{false};
    std::atomic<bool> render_device_changed{false};
    SpscQueue<EncodedFrame, 16> to_network;   // capture -> network
    SpscQueue<VoiceItem, 256> to_render;      // network -> render
    HANDLE network_wake = nullptr;
    HANDLE capture_wake = nullptr;
    HANDLE render_wake = nullptr;
};

Shared& shared();

// Gains from the game's volumes: 0..100 (speaker) and 100..150 (mic) from EUVOICECHATTABLE are
// percent; larger values are taken as the engine's 0..65535 scale.
float volume_gain(int value);

// network.cpp
void network_start();
void network_post(Command&& c);
// Events for Poll (game thread): moves them into `out`.
void network_take_events(std::vector<ClientEvent>& out);

// audio_io.cpp
void audio_start();

}  // namespace roe::voice::dll
