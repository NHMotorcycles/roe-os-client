// Capture and render threads: WASAPI shared mode on the default devices (48 kHz mono 16-bit,
// Windows converts), Opus encode / decode, jitter buffers and the mix. The devices follow
// default device changes and come back after an error. Nothing allocates once a thread runs.
#include <audioclient.h>
#include <audiopolicy.h>
#include <avrt.h>
#include <mmdeviceapi.h>

#include <opus.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <thread>

#include "core/audio.hpp"
#include "core/jitter.hpp"
#include "dll.hpp"

namespace roe::voice::dll {

namespace {

constexpr std::int64_t kLingerMs = 30000;  // devices stay open this long after the last use
constexpr std::int64_t kRetryMs = 2000;

std::int64_t now_us() {
    static const LONGLONG freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return f.QuadPart;
    }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return static_cast<std::int64_t>(c.QuadPart / freq * 1000000 + (c.QuadPart % freq) * 1000000 / freq);
}

template <class T> void release(T*& p) {
    if (p) p->Release();
    p = nullptr;
}

// Default device changes (any thread): flag the stream and wake its thread.
class DeviceWatcher final : public IMMNotificationClient {
public:
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
            *out = static_cast<IMMNotificationClient*>(this);
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        if (role != eConsole) return S_OK;
        auto& s = shared();
        if (flow == eCapture || flow == eAll) {
            s.capture_device_changed = true;
            SetEvent(s.capture_wake);
        }
        if (flow == eRender || flow == eAll) {
            s.render_device_changed = true;
            SetEvent(s.render_wake);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
};

DeviceWatcher g_watcher;

struct Stream {
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    IAudioRenderClient* render = nullptr;
    HANDLE event = nullptr;
    UINT32 buffer_frames = 0;
    bool open = false;

    bool start(EDataFlow flow) {
        IMMDeviceEnumerator* en = nullptr;
        IMMDevice* dev = nullptr;
        HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&en));
        if (SUCCEEDED(hr)) hr = en->GetDefaultAudioEndpoint(flow, eConsole, &dev);
        release(en);
        if (SUCCEEDED(hr)) hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client));
        release(dev);
        WAVEFORMATEX f{};
        f.wFormatTag = WAVE_FORMAT_PCM;
        f.nChannels = 1;
        f.nSamplesPerSec = kSampleRate;
        f.wBitsPerSample = 16;
        f.nBlockAlign = 2;
        f.nAvgBytesPerSec = kSampleRate * 2;
        const DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        if (SUCCEEDED(hr)) hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 400000 /* 40 ms */, 0, &f, nullptr);
        if (SUCCEEDED(hr)) {
            event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            hr = client->SetEventHandle(event);
        }
        if (SUCCEEDED(hr)) hr = client->GetBufferSize(&buffer_frames);
        if (SUCCEEDED(hr)) {
            hr = flow == eCapture
                     ? client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&capture))
                     : client->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void**>(&render));
        }
        if (SUCCEEDED(hr)) {
            // Voice must not make Windows turn the game down ("communications" ducking).
            IAudioSessionControl* session = nullptr;
            if (SUCCEEDED(client->GetService(__uuidof(IAudioSessionControl), reinterpret_cast<void**>(&session)))) {
                IAudioSessionControl2* session2 = nullptr;
                if (SUCCEEDED(session->QueryInterface(__uuidof(IAudioSessionControl2), reinterpret_cast<void**>(&session2))))
                    session2->SetDuckingPreference(TRUE);
                release(session2);
            }
            release(session);
            hr = client->Start();
        }
        if (FAILED(hr)) {
            last_error = hr;
            stop();
            return false;
        }
        open = true;
        return true;
    }

    void stop() {
        if (client) client->Stop();
        release(capture);
        release(render);
        release(client);
        if (event) CloseHandle(event);
        event = nullptr;
        open = false;
    }

    HRESULT last_error = S_OK;
};

void boost_thread() {
    DWORD task = 0;
    AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
}

// ---------------------------------------------------------------- capture

class Capture {
public:
    void run() {
        set_thread_name("mic");
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        boost_thread();
        int err = 0;
        enc_ = opus_encoder_create(kSampleRate, 1, OPUS_APPLICATION_VOIP, &err);
        if (!enc_) {
            log("opus_encoder_create failed %d", err);
            return;
        }
        bitrate_ = shared().bitrate;
        opus_encoder_ctl(enc_, OPUS_SET_BITRATE(bitrate_));
        opus_encoder_ctl(enc_, OPUS_SET_COMPLEXITY(8));
        opus_encoder_ctl(enc_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
        opus_encoder_ctl(enc_, OPUS_SET_INBAND_FEC(1));
        opus_encoder_ctl(enc_, OPUS_SET_PACKET_LOSS_PERC(10));
        gate_.set_threshold(config().vad_threshold_db);
        const auto& cfg = config();
        if (cfg.tone_input) log("test tone instead of the microphone");
        if (cfg.no_input) log("no microphone (test)");
        auto& s = shared();
        for (;;) {
            const std::int64_t now = now_ms();
            const bool want = s.mic_open && s.may_send;
            if (want) linger_until_ = now + kLingerMs;
            log_stats(now);
            const bool need = !cfg.no_input && !cfg.tone_input && (want || now < linger_until_);
            if (s.capture_device_changed.exchange(false) && dev_.open) {
                log("default microphone changed");
                dev_.stop();
                retry_at_ = 0;
            }
            if (cfg.tone_input) {
                tone(want);
                continue;
            }
            if (need && !dev_.open && now >= retry_at_) {
                if (dev_.start(eCapture)) {
                    log("microphone open");
                    failed_logged_ = false;
                    fill_ = 0;
                } else {
                    if (!failed_logged_) log("no microphone (0x%08lx); trying again", static_cast<unsigned long>(dev_.last_error));
                    failed_logged_ = true;
                    retry_at_ = now + kRetryMs;
                }
            }
            if (!need && dev_.open) {
                dev_.stop();
                log("microphone closed");
            }
            if (!dev_.open) {
                if (!want) s.mic_level = 0;
                WaitForSingleObject(s.capture_wake, 100);
                continue;
            }
            HANDLE waits[2] = {dev_.event, s.capture_wake};
            WaitForMultipleObjects(2, waits, FALSE, 100);
            read_device();
        }
    }

private:
    void read_device() {
        for (;;) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            const HRESULT hr = dev_.capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (hr == AUDCLNT_S_BUFFER_EMPTY) return;
            if (FAILED(hr)) {
                log("microphone lost (0x%08lx)", static_cast<unsigned long>(hr));
                dev_.stop();
                retry_at_ = now_ms() + 500;
                return;
            }
            const auto* pcm = reinterpret_cast<const std::int16_t*>(data);
            const float gain = volume_gain(shared().mic_volume) / 32768.0f;
            const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            for (UINT32 i = 0; i < frames; ++i) {
                frame_[fill_++] = silent ? 0.0f : soft_clip(static_cast<float>(pcm[i]) * gain);
                if (fill_ == kFrameSamples) {
                    process();
                    fill_ = 0;
                }
            }
            dev_.capture->ReleaseBuffer(frames);
        }
    }

    // Real-time 440 Hz tone for tests, 20 ms frames by the clock.
    void tone(bool want) {
        const std::int64_t now = now_us();
        if (!want) {
            shared().mic_level = 0;
            next_tone_ = 0;
            WaitForSingleObject(shared().capture_wake, 20);
            return;
        }
        if (next_tone_ == 0) next_tone_ = now;
        if (now < next_tone_) {
            Sleep(static_cast<DWORD>(std::max<std::int64_t>(1, (next_tone_ - now) / 1000)));
            return;
        }
        next_tone_ += kFrameMs * 1000;
        for (auto& v : frame_) {
            v = 0.2f * std::sin(phase_);
            phase_ += 2.0f * 3.14159265f * 440.0f / kSampleRate;
            if (phase_ > 6.2831853f) phase_ -= 6.2831853f;
        }
        process();
    }

    void process() {
        auto& s = shared();
        const float level = rms(frame_);
        gate_.update(to_dbfs(level));
        const bool sending = s.mic_open && s.may_send && gate_.open();
        s.mic_level = sending ? std::clamp(static_cast<int>(level * 65535.0f * 4.0f), 1, 65535) : 0;
        const std::uint16_t seq = sequence_++;  // counts every frame, sent or not
        if (sending) {
            if (!was_sending_) opus_encoder_ctl(enc_, OPUS_RESET_STATE);
            if (const int b = s.bitrate; b != bitrate_) {
                bitrate_ = b;
                opus_encoder_ctl(enc_, OPUS_SET_BITRATE(b));
            }
            if (EncodedFrame* e = s.to_network.claim()) {
                const opus_int32 n = opus_encode_float(enc_, frame_.data(), kFrameSamples, e->data.data(),
                                                       static_cast<opus_int32>(e->data.size()));
                if (n > 0) {
                    e->sequence = seq;
                    e->size = static_cast<std::uint16_t>(n);
                    s.to_network.commit();
                    SetEvent(s.network_wake);
                    ++sent_;
                }
            } else {
                ++queue_full_;
            }
        } else if (s.mic_open && s.may_send) {
            ++gated_;
        }
        ++frames_;
        was_sending_ = sending;
    }

    Stream dev_;
    OpusEncoder* enc_ = nullptr;
    int bitrate_ = 0;
    TalkGate gate_;
    std::array<float, kFrameSamples> frame_{};
    int fill_ = 0;
    std::uint16_t sequence_ = 0;
    bool was_sending_ = false;
    bool failed_logged_ = false;
    std::int64_t linger_until_ = 0, retry_at_ = 0, next_tone_ = 0;
    float phase_ = 0.0f;
    std::uint64_t frames_ = 0, sent_ = 0, gated_ = 0, queue_full_ = 0, logged_frames_ = 0;
    std::int64_t stats_at_ = 0;

    void log_stats(std::int64_t now) {
        if (now < stats_at_) return;
        stats_at_ = now + config().stats_ms;
        if (sent_ == logged_frames_) return;
        logged_frames_ = sent_;
        log("audio in: %llu frames, %llu sent, %llu below the talk threshold, %llu dropped (queue full)",
            static_cast<unsigned long long>(frames_), static_cast<unsigned long long>(sent_),
            static_cast<unsigned long long>(gated_), static_cast<unsigned long long>(queue_full_));
    }
};

// ---------------------------------------------------------------- render

class Render {
public:
    void run() {
        set_thread_name("spk");
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        boost_thread();
        IMMDeviceEnumerator* en = nullptr;
        if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                       reinterpret_cast<void**>(&en))))
            en->RegisterEndpointNotificationCallback(&g_watcher);  // kept for the life of the process
        for (auto& v : voices_) {
            int err = 0;
            v.dec = opus_decoder_create(kSampleRate, 1, &err);
        }
        const auto& cfg = config();
        if (cfg.no_output) log("output off (test)");
        auto& s = shared();
        std::int64_t stats_at = now_ms() + cfg.stats_ms;
        for (;;) {
            const std::int64_t now = now_ms();
            const bool want = s.rooms > 0 && s.speaker_open;
            if (want) linger_until_ = now + kLingerMs;
            const bool need = !cfg.no_output && (want || now < linger_until_);
            if (s.render_device_changed.exchange(false) && dev_.open) {
                log("default speaker changed");
                dev_.stop();
                retry_at_ = 0;
            }
            if (need && !dev_.open && now >= retry_at_) {
                if (dev_.start(eRender)) {
                    log("speaker open (%u frames buffer)", dev_.buffer_frames);
                    failed_logged_ = false;
                } else {
                    if (!failed_logged_) log("no speaker (0x%08lx); trying again", static_cast<unsigned long>(dev_.last_error));
                    failed_logged_ = true;
                    retry_at_ = now + kRetryMs;
                }
            }
            if (!need && dev_.open) {
                dev_.stop();
                log("speaker closed");
            }
            if (dev_.open) {
                HANDLE waits[2] = {dev_.event, s.render_wake};
                WaitForMultipleObjects(2, waits, FALSE, 100);
                write_device();
                clock_next_ = 0;
            } else {
                null_clock();
            }
            if (now >= stats_at) {
                stats_at = now + cfg.stats_ms;
                log_stats();
            }
        }
    }

private:
    struct Voice {
        JitterBuffer jitter;
        OpusDecoder* dec = nullptr;
    };

    void write_device() {
        UINT32 padding = 0;
        HRESULT hr = dev_.client->GetCurrentPadding(&padding);  // also reports a lost device
        const UINT32 target = std::min<UINT32>(dev_.buffer_frames, static_cast<UINT32>(kSampleRate * 30 / 1000));
        if (SUCCEEDED(hr) && padding < target) {
            const UINT32 n = target - padding;
            BYTE* data = nullptr;
            hr = dev_.render->GetBuffer(n, &data);
            if (SUCCEEDED(hr)) {
                auto* out = reinterpret_cast<std::int16_t*>(data);
                for (UINT32 i = 0; i < n; ++i) {
                    if (pos_ == kFrameSamples) {
                        mix_frame();
                        pos_ = 0;
                    }
                    out[i] = out_[pos_++];
                }
                hr = dev_.render->ReleaseBuffer(n, 0);
            }
        }
        if (FAILED(hr)) {
            log("speaker lost (0x%08lx)", static_cast<unsigned long>(hr));
            dev_.stop();
            retry_at_ = now_ms() + 500;
        }
    }

    // No device: mix by the clock anyway, so the queue drains and buffers stay in time.
    void null_clock() {
        const std::int64_t now = now_us();
        if (clock_next_ == 0) clock_next_ = now;
        if (now < clock_next_) {
            WaitForSingleObject(shared().render_wake, static_cast<DWORD>(std::max<std::int64_t>(1, (clock_next_ - now) / 1000)));
            return;
        }
        clock_next_ += kFrameMs * 1000;
        if (now - clock_next_ > 200000) clock_next_ = now;  // fell far behind: do not catch up
        mix_frame();
    }

    void drain_queue() {
        auto& q = shared().to_render;
        while (VoiceItem* item = q.front()) {
            if (item->stream >= 0 && item->stream < Client::kMaxStreams) {
                Voice& v = voices_[static_cast<std::size_t>(item->stream)];
                if (item->reset) {
                    v.jitter.reset();
                    if (v.dec) opus_decoder_ctl(v.dec, OPUS_RESET_STATE);
                } else {
                    v.jitter.push(item->sequence, std::span<const std::uint8_t>(item->data.data(), item->size));
                }
            }
            q.release();
        }
    }

    void mix_frame() {
        drain_queue();
        mixer_.begin();
        for (auto& v : voices_) {
            if (!v.dec) continue;
            std::span<const std::uint8_t> packet;
            const auto what = v.jitter.pop(packet);
            int n = 0;
            if (what == JitterBuffer::Out::Packet) {
                n = opus_decode_float(v.dec, packet.data(), static_cast<opus_int32>(packet.size()), pcm_.data(), kFrameSamples, 0);
            } else if (what == JitterBuffer::Out::Conceal) {
                n = packet.empty()
                        ? opus_decode_float(v.dec, nullptr, 0, pcm_.data(), kFrameSamples, 0)
                        : opus_decode_float(v.dec, packet.data(), static_cast<opus_int32>(packet.size()), pcm_.data(), kFrameSamples, 1);
            }
            if (n == kFrameSamples) mixer_.add(pcm_);
        }
        ++frames_;
        if (mixer_.voices() > 0) ++voiced_frames_;
        mixer_.finish(volume_gain(shared().speaker_volume), out_);
    }

    void log_stats() {
        JitterBuffer::Stats sum;
        for (const auto& v : voices_) {
            const auto& st = v.jitter.stats();
            sum.played += st.played;
            sum.concealed += st.concealed;
            sum.late += st.late;
            sum.trimmed += st.trimmed;
            sum.underruns += st.underruns;
        }
        if (sum.played == last_played_ && sum.concealed == last_concealed_) return;
        last_played_ = sum.played;
        last_concealed_ = sum.concealed;
        log("audio out: %llu frames played, %llu concealed, %llu late, %llu trimmed, %llu underruns, %llu voiced of %llu mixed",
            static_cast<unsigned long long>(sum.played), static_cast<unsigned long long>(sum.concealed),
            static_cast<unsigned long long>(sum.late), static_cast<unsigned long long>(sum.trimmed),
            static_cast<unsigned long long>(sum.underruns), static_cast<unsigned long long>(voiced_frames_),
            static_cast<unsigned long long>(frames_));
    }

    Stream dev_;
    std::array<Voice, Client::kMaxStreams> voices_{};
    Mixer mixer_;
    std::array<float, kFrameSamples> pcm_{};
    std::array<std::int16_t, kFrameSamples> out_{};
    int pos_ = kFrameSamples;
    bool failed_logged_ = false;
    std::int64_t linger_until_ = 0, retry_at_ = 0, clock_next_ = 0;
    std::uint64_t frames_ = 0, voiced_frames_ = 0, last_played_ = 0, last_concealed_ = 0;
};

bool g_audio_started = false;

}  // namespace

void audio_start() {
    if (g_audio_started) return;  // game thread only
    g_audio_started = true;
    auto& s = shared();
    s.capture_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    s.render_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    // Never destroyed: the threads run until the process ends.
    auto* capture = new Capture();
    auto* render = new Render();
    std::thread([capture] { capture->run(); }).detach();
    std::thread([render] { render->run(); }).detach();
}

}  // namespace roe::voice::dll
