// Voice protocol (docs/VOICE-PROTOCOL.md): encoders and decoders for both directions.
// Big-endian, strings u16 length + bytes. No allocation: encoders write into a caller buffer,
// decoded strings and packets point into the datagram.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace roe::voice {

inline constexpr std::uint8_t kProtocolVersion = 1;
inline constexpr std::uint16_t kDefaultPort = 10101;
inline constexpr std::size_t kMaxDatagram = 1200;
inline constexpr std::size_t kMaxOpusPacket = 400;  // one 20 ms frame
inline constexpr std::size_t kMaxFramesPerDatagram = 3;
inline constexpr std::size_t kMaxRoomName = 128;
inline constexpr std::size_t kMaxIdentity = 64;  // ticket and openId

enum class Kind : std::uint8_t {
    Hello = 1,
    Welcome = 2,
    Join = 3,
    Joined = 4,
    Quit = 5,
    Coord = 6,
    State = 7,
    Audio = 8,
    Voice = 9,
    Ping = 10,
    Pong = 11,
    Members = 12,
    Bye = 13,
    Reset = 14,
};

class Writer {
public:
    explicit Writer(std::span<std::uint8_t> out) : out_(out) {}
    Writer& u8(std::uint8_t v);
    Writer& u16(std::uint16_t v);
    Writer& u32(std::uint32_t v);
    Writer& i32(std::int32_t v) { return u32(static_cast<std::uint32_t>(v)); }
    Writer& i64(std::int64_t v);
    Writer& str(std::string_view s);
    Writer& bytes(std::span<const std::uint8_t> b);
    // Bytes written, 0 when the buffer was too small.
    std::size_t size() const { return ok_ ? at_ : 0; }

private:
    bool room(std::size_t n);
    std::span<std::uint8_t> out_;
    std::size_t at_ = 0;
    bool ok_ = true;
};

class Reader {
public:
    explicit Reader(std::span<const std::uint8_t> in) : in_(in) {}
    std::uint8_t u8();
    std::uint16_t u16();
    std::uint32_t u32();
    std::int32_t i32() { return static_cast<std::int32_t>(u32()); }
    std::int64_t i64();
    std::string_view str();
    std::span<const std::uint8_t> bytes(std::size_t n);
    bool ok() const { return ok_; }
    std::size_t left() const { return ok_ ? in_.size() - at_ : 0; }

private:
    bool need(std::size_t n);
    std::span<const std::uint8_t> in_;
    std::size_t at_ = 0;
    bool ok_ = true;
};

// Opus packets of one AUDIO or VOICE datagram.
struct Frames {
    std::uint16_t sequence = 0;  // of the first frame; frame i has sequence + i
    std::uint8_t count = 0;
    std::array<std::span<const std::uint8_t>, kMaxFramesPerDatagram> packet{};
};

struct Header {
    Kind kind{};
    std::uint32_t session = 0;
};

struct Hello {
    std::uint8_t version = 0;
    std::string_view ticket, open_id;
};
struct Join {
    std::uint32_t request = 0;
    std::string_view room;
    std::uint8_t range = 0;
};
struct Joined {
    std::uint32_t request = 0;
    std::string_view room;
    std::int32_t member_id = 0;
};
struct Coord {
    std::string_view room;
    std::int64_t x = 0, y = 0, z = 0, radius = 0;
};
struct State {
    std::string_view room;
    bool mic = false, speaker = false;
};
struct Voice {
    std::string_view room;
    std::int32_t member_id = 0;
    Frames frames;
};
// MEMBERS: the list is read with next().
struct Members {
    std::string_view room;
    std::uint16_t count = 0;
    Reader rest{{}};
    bool next(std::int32_t& member_id, std::string_view& open_id);
};

// Encoders return the datagram size, 0 when it does not fit.
std::size_t encode_hello(std::span<std::uint8_t> out, std::string_view ticket, std::string_view open_id);
std::size_t encode_welcome(std::span<std::uint8_t> out, std::uint32_t session);
std::size_t encode_join(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t request,
                        std::string_view room, bool range);
std::size_t encode_joined(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t request,
                          std::string_view room, std::int32_t member_id);
std::size_t encode_quit(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room);
std::size_t encode_coord(std::span<std::uint8_t> out, std::uint32_t session, const Coord& c);
std::size_t encode_state(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room, bool mic,
                         bool speaker);
std::size_t encode_audio(std::span<std::uint8_t> out, std::uint32_t session, const Frames& f);
std::size_t encode_voice(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room,
                         std::int32_t member_id, const Frames& f);
std::size_t encode_ping(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t time);
std::size_t encode_pong(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t time);
// MEMBERS: ids and openIds side by side.
std::size_t encode_members(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room,
                           std::span<const std::int32_t> ids, std::span<const std::string_view> open_ids);
std::size_t encode_bye(std::span<std::uint8_t> out, std::uint32_t session);
std::size_t encode_reset(std::span<std::uint8_t> out);

// Decoders: false on a short or malformed body (trailing bytes are allowed: later versions may
// append fields).
bool decode_header(std::span<const std::uint8_t> in, Header& h, Reader& body);
bool decode_hello(Reader body, Hello& out);
bool decode_welcome(Reader body, std::uint32_t& session);
bool decode_join(Reader body, Join& out);
bool decode_joined(Reader body, Joined& out);
bool decode_quit(Reader body, std::string_view& room);
bool decode_coord(Reader body, Coord& out);
bool decode_state(Reader body, State& out);
bool decode_audio(Reader body, Frames& out);
bool decode_voice(Reader body, Voice& out);
bool decode_time(Reader body, std::uint32_t& time);  // PING and PONG
bool decode_members(Reader body, Members& out);

}  // namespace roe::voice
