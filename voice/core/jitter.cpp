#include "jitter.hpp"

#include <algorithm>
#include <cstring>

namespace roe::voice {

namespace {
// Signed distance a - b on the 16-bit sequence circle.
int diff(std::uint16_t a, std::uint16_t b) { return static_cast<std::int16_t>(static_cast<std::uint16_t>(a - b)); }
}  // namespace

void JitterBuffer::reset() {
    for (auto& s : slots_) s.used = false;
    count_ = 0;
    playing_ = false;
    waited_ = 0;
    concealed_run_ = 0;
    calm_ = 0;
    any_played_ = false;
    depth_ = kStartDepth;
}

bool JitterBuffer::has(std::uint16_t sequence) const {
    const Slot& s = slots_[sequence % kSlots];
    return s.used && s.sequence == sequence;
}

void JitterBuffer::drop(std::uint16_t sequence) {
    Slot& s = slot(sequence);
    if (s.used && s.sequence == sequence) {
        s.used = false;
        --count_;
    }
}

int JitterBuffer::nearest_after_next() const {
    if (count_ == 0) return -1;
    for (int d = 0; d < kSlots; ++d)
        if (has(static_cast<std::uint16_t>(next_ + d))) return d;
    return -1;
}

bool JitterBuffer::push(std::uint16_t sequence, std::span<const std::uint8_t> packet) {
    if (packet.empty() || packet.size() > kMaxOpusPacket) return false;
    if (any_played_ && diff(sequence, last_played_) <= 0 && diff(sequence, last_played_) > -kSlots * 4) {
        ++stats_.late;  // a frame of a talk spurt already played or given up
        return false;
    }
    if (!playing_ && count_ == 0) {
        next_ = sequence;
    } else {
        const int d = diff(sequence, next_);
        if (d < 0 && playing_) {
            ++stats_.late;
            depth_ = std::min(kMaxDepth, depth_ + 1);
            calm_ = 0;
            return false;
        }
        if (d < 0) {
            // Buffering and an older frame arrived: it becomes the first one if all still fit.
            int newest = 0;
            for (int k = 0; k < kSlots; ++k)
                if (has(static_cast<std::uint16_t>(next_ + k))) newest = k;
            if (newest - d >= kSlots) return false;
            next_ = sequence;
        } else if (d >= kSlots) {
            // Far ahead: a new stream (sender restarted, or a long gap); start over.
            const auto keep_depth = depth_;
            const auto keep_stats = stats_;
            reset();
            depth_ = keep_depth;
            stats_ = keep_stats;
            next_ = sequence;
        }
    }
    Slot& s = slot(sequence);
    if (s.used && s.sequence == sequence) {
        ++stats_.duplicate;
        return false;
    }
    if (!s.used) ++count_;
    s.used = true;
    s.sequence = sequence;
    s.size = static_cast<std::uint16_t>(packet.size());
    std::memcpy(s.data.data(), packet.data(), packet.size());
    return true;
}

JitterBuffer::Out JitterBuffer::pop(std::span<const std::uint8_t>& packet) {
    packet = {};
    if (!playing_) {
        if (count_ == 0) return Out::Silence;
        ++waited_;
        // Start when the buffer is deep enough, or a short burst has waited as long.
        if (count_ < depth_ && waited_ < depth_) return Out::Silence;
        playing_ = true;
        waited_ = 0;
        concealed_run_ = 0;
        const int first = nearest_after_next();
        if (first > 0) next_ = static_cast<std::uint16_t>(next_ + first);
    }
    // Too much latency built up (clock drift, a burst after a stall): skip one frame.
    if (count_ > depth_ + 3) {
        drop(next_);
        next_ = static_cast<std::uint16_t>(next_ + 1);
        ++stats_.trimmed;
    }
    if (has(next_)) {
        Slot& s = slot(next_);
        s.used = false;  // the data stays valid until the next push to this slot
        --count_;
        packet = std::span<const std::uint8_t>(s.data.data(), s.size);
        last_played_ = next_;
        any_played_ = true;
        next_ = static_cast<std::uint16_t>(next_ + 1);
        concealed_run_ = 0;
        ++stats_.played;
        if (++calm_ >= kCalmFrames) {
            calm_ = 0;
            depth_ = std::max(kMinDepth, depth_ - 1);
        }
        return Out::Packet;
    }
    const int gap = nearest_after_next();
    if (gap < 0) {
        // Nothing buffered: conceal a few frames (the voice fades), then stop.
        if (++concealed_run_ > kMaxConceal) {
            playing_ = false;
            waited_ = 0;
            ++stats_.underruns;
            return Out::Silence;
        }
        next_ = static_cast<std::uint16_t>(next_ + 1);
        ++stats_.concealed;
        return Out::Conceal;
    }
    if (gap > kMaxConceal) {
        // A pause of the sender, not a loss: jump to the next talk spurt.
        next_ = static_cast<std::uint16_t>(next_ + gap);
        playing_ = false;
        waited_ = 0;
        return Out::Silence;
    }
    // One frame lost: conceal it; the following frame, when here, carries its FEC.
    next_ = static_cast<std::uint16_t>(next_ + 1);
    ++concealed_run_;
    ++stats_.concealed;
    if (has(next_)) {
        const Slot& s = slot(next_);
        packet = std::span<const std::uint8_t>(s.data.data(), s.size);
    }
    return Out::Conceal;
}

}  // namespace roe::voice
