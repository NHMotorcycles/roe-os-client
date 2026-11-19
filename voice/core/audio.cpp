#include "audio.hpp"

#include <cmath>

namespace roe::voice {

namespace {
constexpr float kKnee = 0.8f;
}

float soft_clip(float x) {
    const float a = std::fabs(x);
    if (a <= kKnee) return x;
    const float bent = kKnee + (1.0f - kKnee) * std::tanh((a - kKnee) / (1.0f - kKnee));
    return x < 0 ? -bent : bent;
}

std::int16_t to_pcm16(float x) {
    return static_cast<std::int16_t>(std::lrintf(soft_clip(x) * 32767.0f));
}

void Mixer::add(std::span<const float> frame, float gain) {
    const std::size_t n = frame.size() < mix_.size() ? frame.size() : mix_.size();
    for (std::size_t i = 0; i < n; ++i) mix_[i] += frame[i] * gain;
    ++voices_;
}

void Mixer::finish(float master, std::span<std::int16_t> out) const {
    const std::size_t n = out.size() < mix_.size() ? out.size() : mix_.size();
    for (std::size_t i = 0; i < n; ++i) out[i] = to_pcm16(mix_[i] * master);
}

void Mixer::finish(float master, std::span<float> out) const {
    const std::size_t n = out.size() < mix_.size() ? out.size() : mix_.size();
    for (std::size_t i = 0; i < n; ++i) out[i] = soft_clip(mix_[i] * master);
}

float rms(std::span<const float> frame) {
    if (frame.empty()) return 0.0f;
    double sum = 0;
    for (float v : frame) sum += static_cast<double>(v) * v;
    return static_cast<float>(std::sqrt(sum / static_cast<double>(frame.size())));
}

float to_dbfs(float rms_value) {
    if (rms_value <= 1e-6f) return -120.0f;
    return 20.0f * std::log10(rms_value);
}

bool TalkGate::update(float level_dbfs) {
    if (level_dbfs >= threshold_)
        left_ = hangover_ + 1;
    else if (left_ > 0)
        --left_;
    return open();
}

bool SpeakingTracker::on_voice(Key key, std::int64_t now_ms) {
    Entry* free_entry = nullptr;
    for (auto& e : entries_) {
        if (e.used && e.key == key) {
            e.last_ms = now_ms;
            return false;
        }
        if (!e.used && !free_entry) free_entry = &e;
    }
    if (!free_entry) return false;  // full: no indicator for this one
    free_entry->used = true;
    free_entry->key = key;
    free_entry->last_ms = now_ms;
    return true;
}

bool SpeakingTracker::speaking(Key key) const {
    for (const auto& e : entries_)
        if (e.used && e.key == key) return true;
    return false;
}

}  // namespace roe::voice
