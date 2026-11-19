// Jitter buffer of one remote member: Opus packets by sequence (one per 20 ms frame, the
// sender counts every captured frame, sent or not). Reorders, drops late and duplicate packets,
// asks for concealment (Opus PLC or FEC) on short gaps, adapts its depth to the jitter and trims
// latency that built up. Fixed size, no allocation.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

#include "protocol.hpp"

namespace roe::voice {

class JitterBuffer {
public:
    static constexpr int kSlots = 32;       // 640 ms
    static constexpr int kMinDepth = 2;     // frames buffered before playout starts
    static constexpr int kMaxDepth = 10;
    static constexpr int kStartDepth = 3;
    static constexpr int kMaxConceal = 3;   // concealed frames before an empty buffer stops
    static constexpr int kCalmFrames = 500; // 10 s without late packets: depth - 1

    enum class Out {
        Silence,  // nothing to play
        Packet,   // decode `packet`
        Conceal,  // one frame lost: PLC, or FEC from `packet` (the next frame) when not empty
    };

    struct Stats {
        std::uint64_t played = 0, concealed = 0, late = 0, duplicate = 0, trimmed = 0, underruns = 0;
    };

    void reset();
    // False when the packet was not taken (late, duplicate, empty or too big).
    bool push(std::uint16_t sequence, std::span<const std::uint8_t> packet);
    // Called once per 20 ms output frame.
    Out pop(std::span<const std::uint8_t>& packet);

    bool playing() const { return playing_; }
    int buffered() const { return count_; }
    int depth() const { return depth_; }
    const Stats& stats() const { return stats_; }

private:
    struct Slot {
        bool used = false;
        std::uint16_t sequence = 0;
        std::uint16_t size = 0;
        std::array<std::uint8_t, kMaxOpusPacket> data{};
    };
    Slot& slot(std::uint16_t sequence) { return slots_[sequence % kSlots]; }
    bool has(std::uint16_t sequence) const;
    void drop(std::uint16_t sequence);
    int nearest_after_next() const;  // frames from next_ to the oldest buffered packet, -1 if none

    std::array<Slot, kSlots> slots_{};
    int count_ = 0;
    bool playing_ = false;
    std::uint16_t next_ = 0;  // sequence to play next (while playing) or the oldest buffered one
    int depth_ = kStartDepth;
    int waited_ = 0;          // pops while buffering
    int concealed_run_ = 0;
    int calm_ = 0;
    std::uint16_t last_played_ = 0;
    bool any_played_ = false;
    Stats stats_;
};

}  // namespace roe::voice
