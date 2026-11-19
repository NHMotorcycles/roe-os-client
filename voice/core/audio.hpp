// Audio helpers: frame format, mixing with a soft limiter, levels, the talk gate (free talk) and
// the speaking indicator of remote members. No allocation.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace roe::voice {

inline constexpr int kSampleRate = 48000;
inline constexpr int kFrameSamples = 960;  // 20 ms mono
inline constexpr int kFrameMs = 20;

// Soft clip: linear up to 0.8 of full scale, then bends smoothly towards 1 (never reaches it).
float soft_clip(float x);
// Float [-1, 1] to 16-bit with the soft clip.
std::int16_t to_pcm16(float x);

class Mixer {
public:
    void begin() { mix_.fill(0.0f); voices_ = 0; }
    void add(std::span<const float> frame, float gain = 1.0f);
    // Master gain and soft clip into `out` (kFrameSamples).
    void finish(float master, std::span<std::int16_t> out) const;
    void finish(float master, std::span<float> out) const;
    int voices() const { return voices_; }

private:
    std::array<float, kFrameSamples> mix_{};
    int voices_ = 0;
};

float rms(std::span<const float> frame);
float to_dbfs(float rms_value);

// Free talk: a frame counts as speech when its level is at least the threshold; the gate stays
// open for a hangover after the last loud frame, so word ends and short pauses are kept.
class TalkGate {
public:
    explicit TalkGate(float threshold_dbfs = -42.0f, int hangover_frames = 15)
        : threshold_(threshold_dbfs), hangover_(hangover_frames) {}
    void set_threshold(float dbfs) { threshold_ = dbfs; }
    bool update(float level_dbfs);
    bool open() const { return left_ > 0; }
    void reset() { left_ = 0; }

private:
    float threshold_;
    int hangover_;
    int left_ = 0;
};

// Speaking state of remote members (OnMemberVoice): start on the first frame, stop after
// `timeout_ms` without one. Fixed capacity; keys are the caller's (a room index and a member).
class SpeakingTracker {
public:
    static constexpr std::size_t kCapacity = 64;
    struct Key {
        std::uint32_t room = 0;
        std::int32_t member = 0;
        bool operator==(const Key&) const = default;
    };
    explicit SpeakingTracker(std::int64_t timeout_ms = 300) : timeout_(timeout_ms) {}
    // True when the member just started speaking.
    bool on_voice(Key key, std::int64_t now_ms);
    // Calls stopped(key) for every member silent for the timeout, and forgets them.
    template <class F> void expire(std::int64_t now_ms, F&& stopped) {
        for (auto& e : entries_)
            if (e.used && now_ms - e.last_ms >= timeout_) {
                e.used = false;
                stopped(e.key);
            }
    }
    // Forgets a member (or a whole room with member < 0), calling stopped(key) for each one.
    template <class F> void forget(std::uint32_t room, std::int32_t member, F&& stopped) {
        for (auto& e : entries_)
            if (e.used && e.key.room == room && (member < 0 || e.key.member == member)) {
                e.used = false;
                stopped(e.key);
            }
    }
    bool speaking(Key key) const;

private:
    struct Entry {
        bool used = false;
        Key key;
        std::int64_t last_ms = 0;
    };
    std::int64_t timeout_;
    std::array<Entry, kCapacity> entries_{};
};

}  // namespace roe::voice
