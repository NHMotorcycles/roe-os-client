#include "protocol.hpp"

#include <cstring>

namespace roe::voice {

bool Writer::room(std::size_t n) {
    if (!ok_ || out_.size() - at_ < n) ok_ = false;
    return ok_;
}

Writer& Writer::u8(std::uint8_t v) {
    if (room(1)) out_[at_++] = v;
    return *this;
}

Writer& Writer::u16(std::uint16_t v) {
    if (room(2)) {
        out_[at_++] = static_cast<std::uint8_t>(v >> 8);
        out_[at_++] = static_cast<std::uint8_t>(v);
    }
    return *this;
}

Writer& Writer::u32(std::uint32_t v) {
    if (room(4))
        for (int shift = 24; shift >= 0; shift -= 8) out_[at_++] = static_cast<std::uint8_t>(v >> shift);
    return *this;
}

Writer& Writer::i64(std::int64_t v) {
    const auto u = static_cast<std::uint64_t>(v);
    if (room(8))
        for (int shift = 56; shift >= 0; shift -= 8) out_[at_++] = static_cast<std::uint8_t>(u >> shift);
    return *this;
}

Writer& Writer::str(std::string_view s) {
    if (s.size() > 0xffff) {
        ok_ = false;
        return *this;
    }
    u16(static_cast<std::uint16_t>(s.size()));
    if (room(s.size()) && !s.empty()) {
        std::memcpy(out_.data() + at_, s.data(), s.size());
        at_ += s.size();
    }
    return *this;
}

Writer& Writer::bytes(std::span<const std::uint8_t> b) {
    if (room(b.size()) && !b.empty()) {
        std::memcpy(out_.data() + at_, b.data(), b.size());
        at_ += b.size();
    }
    return *this;
}

bool Reader::need(std::size_t n) {
    if (!ok_ || in_.size() - at_ < n) ok_ = false;
    return ok_;
}

std::uint8_t Reader::u8() { return need(1) ? in_[at_++] : 0; }

std::uint16_t Reader::u16() {
    if (!need(2)) return 0;
    const auto v = static_cast<std::uint16_t>((in_[at_] << 8) | in_[at_ + 1]);
    at_ += 2;
    return v;
}

std::uint32_t Reader::u32() {
    if (!need(4)) return 0;
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) v = (v << 8) | in_[at_++];
    return v;
}

std::int64_t Reader::i64() {
    if (!need(8)) return 0;
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | in_[at_++];
    return static_cast<std::int64_t>(v);
}

std::string_view Reader::str() {
    const std::uint16_t n = u16();
    if (!need(n)) return {};
    std::string_view s(reinterpret_cast<const char*>(in_.data() + at_), n);
    at_ += n;
    return s;
}

std::span<const std::uint8_t> Reader::bytes(std::size_t n) {
    if (!need(n)) return {};
    auto b = in_.subspan(at_, n);
    at_ += n;
    return b;
}

namespace {

Writer head(std::span<std::uint8_t> out, Kind kind, std::uint32_t session) {
    Writer w(out);
    w.u8(static_cast<std::uint8_t>(kind)).u32(session);
    return w;
}

void put_frames(Writer& w, const Frames& f) {
    w.u16(f.sequence).u8(f.count);
    for (std::size_t i = 0; i < f.count && i < kMaxFramesPerDatagram; ++i) {
        w.u16(static_cast<std::uint16_t>(f.packet[i].size())).bytes(f.packet[i]);
    }
}

bool get_frames(Reader& r, Frames& f) {
    f.sequence = r.u16();
    f.count = r.u8();
    if (!r.ok() || f.count == 0 || f.count > kMaxFramesPerDatagram) return false;
    for (std::size_t i = 0; i < f.count; ++i) {
        const std::uint16_t n = r.u16();
        if (n == 0 || n > kMaxOpusPacket) return false;
        f.packet[i] = r.bytes(n);
    }
    return r.ok();
}

bool room_ok(std::string_view room) { return !room.empty() && room.size() <= kMaxRoomName; }

}  // namespace

std::size_t encode_hello(std::span<std::uint8_t> out, std::string_view ticket, std::string_view open_id) {
    return head(out, Kind::Hello, 0).u8(kProtocolVersion).str(ticket).str(open_id).size();
}

std::size_t encode_welcome(std::span<std::uint8_t> out, std::uint32_t session) {
    return head(out, Kind::Welcome, session).u32(session).size();
}

std::size_t encode_join(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t request,
                        std::string_view room, bool range) {
    return head(out, Kind::Join, session).u32(request).str(room).u8(range ? 1 : 0).size();
}

std::size_t encode_joined(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t request,
                          std::string_view room, std::int32_t member_id) {
    return head(out, Kind::Joined, session).u32(request).str(room).i32(member_id).size();
}

std::size_t encode_quit(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room) {
    return head(out, Kind::Quit, session).str(room).size();
}

std::size_t encode_coord(std::span<std::uint8_t> out, std::uint32_t session, const Coord& c) {
    return head(out, Kind::Coord, session).str(c.room).i64(c.x).i64(c.y).i64(c.z).i64(c.radius).size();
}

std::size_t encode_state(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room, bool mic,
                         bool speaker) {
    return head(out, Kind::State, session).str(room).u8(mic ? 1 : 0).u8(speaker ? 1 : 0).size();
}

std::size_t encode_audio(std::span<std::uint8_t> out, std::uint32_t session, const Frames& f) {
    Writer w = head(out, Kind::Audio, session);
    put_frames(w, f);
    return w.size();
}

std::size_t encode_voice(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room,
                         std::int32_t member_id, const Frames& f) {
    Writer w = head(out, Kind::Voice, session);
    w.str(room).i32(member_id);
    put_frames(w, f);
    return w.size();
}

std::size_t encode_ping(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t time) {
    return head(out, Kind::Ping, session).u32(time).size();
}

std::size_t encode_pong(std::span<std::uint8_t> out, std::uint32_t session, std::uint32_t time) {
    return head(out, Kind::Pong, session).u32(time).size();
}

std::size_t encode_members(std::span<std::uint8_t> out, std::uint32_t session, std::string_view room,
                           std::span<const std::int32_t> ids, std::span<const std::string_view> open_ids) {
    if (ids.size() != open_ids.size() || ids.size() > 0xffff) return 0;
    Writer w = head(out, Kind::Members, session);
    w.str(room).u16(static_cast<std::uint16_t>(ids.size()));
    for (std::size_t i = 0; i < ids.size(); ++i) w.i32(ids[i]).str(open_ids[i]);
    return w.size();
}

std::size_t encode_bye(std::span<std::uint8_t> out, std::uint32_t session) {
    return head(out, Kind::Bye, session).size();
}

std::size_t encode_reset(std::span<std::uint8_t> out) { return head(out, Kind::Reset, 0).size(); }

bool decode_header(std::span<const std::uint8_t> in, Header& h, Reader& body) {
    Reader r(in);
    h.kind = static_cast<Kind>(r.u8());
    h.session = r.u32();
    if (!r.ok()) return false;
    body = Reader(in.subspan(5));
    return true;
}

bool decode_hello(Reader r, Hello& out) {
    out.version = r.u8();
    out.ticket = r.str();
    out.open_id = r.str();
    return r.ok() && !out.ticket.empty() && out.ticket.size() <= kMaxIdentity && out.open_id.size() <= kMaxIdentity;
}

bool decode_welcome(Reader r, std::uint32_t& session) {
    session = r.u32();
    return r.ok();
}

bool decode_join(Reader r, Join& out) {
    out.request = r.u32();
    out.room = r.str();
    out.range = r.u8();
    return r.ok() && room_ok(out.room);
}

bool decode_joined(Reader r, Joined& out) {
    out.request = r.u32();
    out.room = r.str();
    out.member_id = r.i32();
    return r.ok() && room_ok(out.room);
}

bool decode_quit(Reader r, std::string_view& room) {
    room = r.str();
    return r.ok() && room_ok(room);
}

bool decode_coord(Reader r, Coord& out) {
    out.room = r.str();
    out.x = r.i64();
    out.y = r.i64();
    out.z = r.i64();
    out.radius = r.i64();
    return r.ok() && room_ok(out.room);
}

bool decode_state(Reader r, State& out) {
    out.room = r.str();
    out.mic = r.u8() != 0;
    out.speaker = r.u8() != 0;
    return r.ok() && room_ok(out.room);
}

bool decode_audio(Reader r, Frames& out) { return get_frames(r, out); }

bool decode_voice(Reader r, Voice& out) {
    out.room = r.str();
    out.member_id = r.i32();
    return r.ok() && room_ok(out.room) && get_frames(r, out.frames);
}

bool decode_time(Reader r, std::uint32_t& time) {
    time = r.u32();
    return r.ok();
}

bool decode_members(Reader r, Members& out) {
    out.room = r.str();
    out.count = r.u16();
    out.rest = r;
    return r.ok() && room_ok(out.room);
}

bool Members::next(std::int32_t& member_id, std::string_view& open_id) {
    if (count == 0) return false;
    member_id = rest.i32();
    open_id = rest.str();
    if (!rest.ok()) {
        count = 0;
        return false;
    }
    --count;
    return true;
}

}  // namespace roe::voice
