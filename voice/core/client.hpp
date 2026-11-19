// Client side of the voice protocol (docs/VOICE-PROTOCOL.md), without sockets or threads: the
// DLL's network thread feeds it datagrams, game commands and the clock, and it answers with
// datagrams to send, game callbacks and voice frames. Everything runs on that one thread.
#pragma once
#include <array>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "audio.hpp"
#include "protocol.hpp"

namespace roe::voice {

// GCloudVoiceCompleteCode values the game reacts to.
inline constexpr int kJoinSucceeded = 1;
inline constexpr int kJoinTimeout = 2;
inline constexpr int kJoinServerError = 3;
inline constexpr int kQuitSucceeded = 6;
inline constexpr int kRoomOffline = 22;

struct ClientEvent {
    enum class Type : std::uint8_t { JoinRoom, StatusUpdate, QuitRoom, MemberVoice };
    Type type{};
    int code = 0;  // completion code, or the speaking status for MemberVoice
    std::string room;
    int member = 0;
};

class Client {
public:
    static constexpr int kMaxStreams = 24;  // remote members heard at once
    static constexpr std::int64_t kPingMs = 2000;
    static constexpr std::int64_t kLostMs = 6000;
    static constexpr std::int64_t kJoinRetryMs = 1000;
    static constexpr std::int64_t kStateRepeatMs = 2000;
    static constexpr std::int64_t kRefusedRetryMs = 3000;
    static constexpr std::int64_t kStreamIdleMs = 15000;
    static constexpr std::int64_t kSpeakingTimeoutMs = 300;

    struct Callbacks {
        virtual ~Callbacks() = default;
        virtual void send(std::span<const std::uint8_t> datagram) = 0;
        virtual void event(ClientEvent&& e) = 0;
        // A stream slot starts (or ends) belonging to a member: reset its decoder and buffer.
        virtual void stream_reset(int stream) = 0;
        virtual void voice(int stream, std::uint16_t sequence, std::span<const std::uint8_t> packet) = 0;
        virtual void log(std::string_view line) = 0;
        // Before each HELLO; attempt 0 is the first after a start or a loss.
        virtual void hello(int attempt) { (void)attempt; }
    };

    struct Stats {
        std::uint64_t sent = 0, received = 0, audio_sent = 0, voice_received = 0, voice_dropped = 0, losses = 0;
        std::int64_t rtt_ms = -1;
    };

    explicit Client(Callbacks& cb) : cb_(cb) {}

    void set_identity(std::string_view ticket, std::string_view open_id);
    // Starts saying HELLO (again after stop()).
    void start(std::int64_t now);
    // Ends the session (BYE) and forgets the rooms, without callbacks.
    void stop();
    bool connected() const { return session_ != 0; }
    bool started() const { return started_; }

    // Game commands. They return false for a room name the protocol cannot carry.
    bool join(std::string_view room, bool range, int timeout_ms, std::int64_t now);
    void quit(std::string_view room);
    bool coord(std::string_view room, std::int64_t x, std::int64_t y, std::int64_t z, std::int64_t radius);
    bool room_mic(std::string_view room, bool on);
    bool room_speaker(std::string_view room, bool on);
    void speaker_open(bool on);

    // True when AUDIO would go anywhere: connected and in a room with the mic enabled.
    bool wants_audio() const;
    // Sends one AUDIO datagram; false when it would go nowhere.
    bool send_audio(const Frames& frames);

    void on_datagram(std::span<const std::uint8_t> datagram, std::int64_t now);
    void tick(std::int64_t now);

    const Stats& stats() const { return stats_; }
    std::size_t room_count() const { return rooms_.size(); }

private:
    struct Room {
        std::string name;
        std::uint32_t key = 0;  // unique per room record (speaking tracker, streams)
        bool range = false;
        bool in = false;
        std::uint32_t request = 0;
        std::int64_t join_deadline = 0, join_sent = -1;
        std::int32_t member = 0;
        bool mic = true, speaker = true;
        bool coord_known = false;
        Coord coord;
        std::int64_t state_sent = 0;
    };
    struct Stream {
        bool used = false;
        std::uint32_t room_key = 0;
        std::int32_t member = 0;
        std::int64_t last_ms = 0;
    };

    Room* find(std::string_view name);
    Room* find_key(std::uint32_t key);
    void send(std::size_t n);
    void send_hello(std::int64_t now);
    void send_join(Room& r, std::int64_t now);
    void send_state(Room& r, std::int64_t now);
    void send_coord(Room& r);
    void lose(std::int64_t now, const char* why);
    void leave_room_streams(std::uint32_t room_key, std::int32_t member, const std::string& room_name);
    int stream_for(std::uint32_t room_key, std::int32_t member, std::int64_t now);
    void on_voice(const Voice& v, std::int64_t now);
    void on_members(Members& m);

    Callbacks& cb_;
    std::string ticket_, open_id_;
    bool started_ = false;
    std::uint32_t session_ = 0;
    int hello_attempt_ = 0;
    std::int64_t next_hello_ = 0, last_rx_ = 0, next_ping_ = 0;
    bool refused_logged_ = false;
    std::uint32_t next_request_ = 1, next_key_ = 1;
    std::vector<Room> rooms_;
    std::array<Stream, kMaxStreams> streams_{};
    SpeakingTracker speaking_{kSpeakingTimeoutMs};
    std::array<std::uint8_t, kMaxDatagram> buf_{};
    bool speaker_open_ = false;  // the game opens it (OpenSpeaker)
    Stats stats_;
};

}  // namespace roe::voice
