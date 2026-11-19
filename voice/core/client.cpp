#include "client.hpp"

#include <algorithm>
#include <cstdio>

namespace roe::voice {

namespace {

bool room_name_ok(std::string_view room) { return !room.empty() && room.size() <= kMaxRoomName; }

}  // namespace

void Client::set_identity(std::string_view ticket, std::string_view open_id) {
    ticket_.assign(ticket.substr(0, kMaxIdentity));
    open_id_.assign(open_id.substr(0, kMaxIdentity));
}

void Client::start(std::int64_t now) {
    if (started_) return;
    started_ = true;
    hello_attempt_ = 0;
    next_hello_ = now;
    tick(now);
}

void Client::stop() {
    if (connected()) send(encode_bye(buf_, session_));
    session_ = 0;
    started_ = false;
    rooms_.clear();
    for (int i = 0; i < kMaxStreams; ++i)
        if (streams_[static_cast<std::size_t>(i)].used) {
            streams_[static_cast<std::size_t>(i)].used = false;
            cb_.stream_reset(i);
        }
    speaking_ = SpeakingTracker{kSpeakingTimeoutMs};
}

Client::Room* Client::find(std::string_view name) {
    for (auto& r : rooms_)
        if (r.name == name) return &r;
    return nullptr;
}

Client::Room* Client::find_key(std::uint32_t key) {
    for (auto& r : rooms_)
        if (r.key == key) return &r;
    return nullptr;
}

void Client::send(std::size_t n) {
    if (n == 0) return;
    ++stats_.sent;
    cb_.send(std::span<const std::uint8_t>(buf_.data(), n));
}

void Client::send_hello(std::int64_t now) {
    cb_.hello(hello_attempt_);
    send(encode_hello(buf_, ticket_, open_id_));
    // 1 s for the first tries, then slower, at most every 5 s.
    const std::int64_t wait = hello_attempt_ < 5 ? 1000 : std::min<std::int64_t>(5000, 1000LL * (hello_attempt_ - 3));
    ++hello_attempt_;
    next_hello_ = now + wait;
}

void Client::send_join(Room& r, std::int64_t now) {
    r.join_sent = now;
    if (connected()) send(encode_join(buf_, session_, r.request, r.name, r.range));
}

void Client::send_state(Room& r, std::int64_t now) {
    r.state_sent = now;
    if (connected() && r.in) send(encode_state(buf_, session_, r.name, r.mic, r.speaker && speaker_open_));
}

void Client::send_coord(Room& r) {
    if (!connected() || !r.in || !r.coord_known) return;
    r.coord.room = r.name;
    send(encode_coord(buf_, session_, r.coord));
}

bool Client::join(std::string_view room, bool range, int timeout_ms, std::int64_t now) {
    if (!room_name_ok(room)) return false;
    if (Room* r = find(room)) {
        // Already in it: confirm again; already joining: the answer comes.
        if (r->in) cb_.event({ClientEvent::Type::JoinRoom, kJoinSucceeded, r->name, r->member});
        return true;
    }
    Room r;
    r.name.assign(room);
    r.key = next_key_++;
    r.range = range;
    r.request = next_request_++;
    r.join_deadline = now + std::clamp(timeout_ms, 1000, 60000);
    rooms_.push_back(std::move(r));
    send_join(rooms_.back(), now);
    return true;
}

void Client::quit(std::string_view room) {
    auto it = std::find_if(rooms_.begin(), rooms_.end(), [&](const Room& r) { return r.name == room; });
    std::string name(room);
    if (it != rooms_.end()) {
        // Also while joining: the relay may have taken us in and the JOINED got lost.
        if (connected()) send(encode_quit(buf_, session_, it->name));
        const std::uint32_t key = it->key;
        leave_room_streams(key, -1, it->name);
        rooms_.erase(it);
        char line[200];
        std::snprintf(line, sizeof line, "quit %s", name.c_str());
        cb_.log(line);
    }
    cb_.event({ClientEvent::Type::QuitRoom, kQuitSucceeded, std::move(name), 0});
}

bool Client::coord(std::string_view room, std::int64_t x, std::int64_t y, std::int64_t z, std::int64_t radius) {
    Room* r = find(room);
    if (!r) return false;
    r->coord_known = true;
    r->coord.x = x;
    r->coord.y = y;
    r->coord.z = z;
    r->coord.radius = radius;
    send_coord(*r);
    return true;
}

bool Client::room_mic(std::string_view room, bool on) {
    Room* r = find(room);
    if (!r) return false;
    if (r->mic != on) {
        r->mic = on;
        send_state(*r, r->state_sent);
    }
    return true;
}

bool Client::room_speaker(std::string_view room, bool on) {
    Room* r = find(room);
    if (!r) return false;
    if (r->speaker != on) {
        r->speaker = on;
        send_state(*r, r->state_sent);
        if (!on) leave_room_streams(r->key, -1, r->name);
    }
    return true;
}

void Client::speaker_open(bool on) {
    if (speaker_open_ == on) return;
    speaker_open_ = on;
    for (auto& r : rooms_) {
        send_state(r, r.state_sent);
        if (!on) leave_room_streams(r.key, -1, r.name);
    }
}

bool Client::wants_audio() const {
    if (!connected()) return false;
    return std::any_of(rooms_.begin(), rooms_.end(), [](const Room& r) { return r.in && r.mic; });
}

bool Client::send_audio(const Frames& frames) {
    if (!wants_audio()) return false;
    const std::size_t n = encode_audio(buf_, session_, frames);
    if (n == 0) return false;
    ++stats_.audio_sent;
    send(n);
    return true;
}

void Client::lose(std::int64_t now, const char* why) {
    char line[160];
    std::snprintf(line, sizeof line, "voice relay lost (%s): rooms offline, reconnecting", why);
    cb_.log(line);
    ++stats_.losses;
    session_ = 0;
    for (auto it = rooms_.begin(); it != rooms_.end();) {
        if (it->in) {
            leave_room_streams(it->key, -1, it->name);
            cb_.event({ClientEvent::Type::StatusUpdate, kRoomOffline, it->name, it->member});
            it = rooms_.erase(it);  // the game joins again
        } else {
            ++it;
        }
    }
    hello_attempt_ = 0;
    next_hello_ = now;
}

void Client::leave_room_streams(std::uint32_t room_key, std::int32_t member, const std::string& room_name) {
    speaking_.forget(room_key, member, [&](const SpeakingTracker::Key& k) {
        cb_.event({ClientEvent::Type::MemberVoice, 0, room_name, k.member});
    });
    for (int i = 0; i < kMaxStreams; ++i) {
        auto& s = streams_[static_cast<std::size_t>(i)];
        if (s.used && s.room_key == room_key && (member < 0 || s.member == member)) {
            s.used = false;
            cb_.stream_reset(i);
        }
    }
}

int Client::stream_for(std::uint32_t room_key, std::int32_t member, std::int64_t now) {
    int free_slot = -1;
    for (int i = 0; i < kMaxStreams; ++i) {
        auto& s = streams_[static_cast<std::size_t>(i)];
        if (s.used && s.room_key == room_key && s.member == member) {
            s.last_ms = now;
            return i;
        }
        if (!s.used && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) return -1;
    auto& s = streams_[static_cast<std::size_t>(free_slot)];
    s.used = true;
    s.room_key = room_key;
    s.member = member;
    s.last_ms = now;
    cb_.stream_reset(free_slot);
    return free_slot;
}

void Client::on_voice(const Voice& v, std::int64_t now) {
    Room* r = find(v.room);
    if (!r || !r->in || v.member_id == r->member || v.member_id < 0 || !r->speaker || !speaker_open_) {
        ++stats_.voice_dropped;
        return;
    }
    if (speaking_.on_voice({r->key, v.member_id}, now))
        cb_.event({ClientEvent::Type::MemberVoice, 1, r->name, v.member_id});
    const int stream = stream_for(r->key, v.member_id, now);
    if (stream < 0) {
        ++stats_.voice_dropped;
        return;
    }
    ++stats_.voice_received;
    for (std::size_t i = 0; i < v.frames.count; ++i)
        cb_.voice(stream, static_cast<std::uint16_t>(v.frames.sequence + i), v.frames.packet[i]);
}

void Client::on_members(Members& m) {
    Room* r = find(m.room);
    if (!r || !r->in) return;
    std::array<std::int32_t, 128> present{};
    std::size_t n = 0;
    const std::uint16_t total = m.count;
    std::int32_t id = 0;
    std::string_view open_id;
    while (m.next(id, open_id))
        if (n < present.size()) present[n++] = id;
    // Members that left: end their streams and indicators.
    for (int i = 0; i < kMaxStreams; ++i) {
        const auto& s = streams_[static_cast<std::size_t>(i)];
        if (!s.used || s.room_key != r->key) continue;
        if (std::find(present.begin(), present.begin() + static_cast<std::ptrdiff_t>(n), s.member) ==
            present.begin() + static_cast<std::ptrdiff_t>(n))
            leave_room_streams(r->key, s.member, r->name);
    }
    char line[200];
    std::snprintf(line, sizeof line, "%s: %u members", r->name.c_str(), static_cast<unsigned>(total));
    cb_.log(line);
}

void Client::on_datagram(std::span<const std::uint8_t> datagram, std::int64_t now) {
    Header h;
    Reader body({});
    if (!started_ || !decode_header(datagram, h, body)) return;
    if (h.kind == Kind::Welcome) {
        std::uint32_t session = 0;
        if (!decode_welcome(body, session) || connected()) return;
        if (session == 0) {
            if (!refused_logged_) cb_.log("voice relay refused the ticket; trying again");
            refused_logged_ = true;
            next_hello_ = std::max(next_hello_, now + kRefusedRetryMs);
            return;
        }
        refused_logged_ = false;
        session_ = session;
        last_rx_ = now;
        next_ping_ = now + kPingMs;
        char line[96];
        std::snprintf(line, sizeof line, "voice relay: session started after %d HELLO", hello_attempt_);
        cb_.log(line);
        for (auto& r : rooms_)
            if (!r.in) send_join(r, now);
        return;
    }
    if (h.kind == Kind::Reset) {
        if (connected()) lose(now, "relay does not know the session");
        return;
    }
    if (!connected() || h.session != session_) return;
    last_rx_ = now;
    ++stats_.received;
    switch (h.kind) {
    case Kind::Joined: {
        Joined j;
        if (!decode_joined(body, j)) return;
        Room* r = find(j.room);
        if (!r || r->in || r->request != j.request) return;
        char line[200];
        if (j.member_id < 0) {
            std::snprintf(line, sizeof line, "join %s refused by the relay", r->name.c_str());
            cb_.log(line);
            std::string name = r->name;
            rooms_.erase(rooms_.begin() + (r - rooms_.data()));
            cb_.event({ClientEvent::Type::JoinRoom, kJoinServerError, std::move(name), 0});
            return;
        }
        r->in = true;
        r->member = j.member_id;
        std::snprintf(line, sizeof line, "joined %s as member %d", r->name.c_str(), r->member);
        cb_.log(line);
        send_state(*r, now);
        send_coord(*r);
        cb_.event({ClientEvent::Type::JoinRoom, kJoinSucceeded, r->name, r->member});
        return;
    }
    case Kind::Voice: {
        Voice v;
        if (decode_voice(body, v)) on_voice(v, now);
        return;
    }
    case Kind::Members: {
        Members m;
        if (decode_members(body, m)) on_members(m);
        return;
    }
    case Kind::Pong: {
        std::uint32_t t = 0;
        if (decode_time(body, t)) stats_.rtt_ms = static_cast<std::uint32_t>(now) - t;
        return;
    }
    default:
        return;  // unknown kinds are ignored
    }
}

void Client::tick(std::int64_t now) {
    if (!started_) return;
    if (!connected()) {
        if (now >= next_hello_) send_hello(now);
    } else if (now - last_rx_ > kLostMs) {
        lose(now, "timeout");
        send_hello(now);
    } else if (now >= next_ping_) {
        next_ping_ = now + kPingMs;
        send(encode_ping(buf_, session_, static_cast<std::uint32_t>(now)));
    }
    for (auto it = rooms_.begin(); it != rooms_.end();) {
        Room& r = *it;
        if (!r.in && now >= r.join_deadline) {
            char line[200];
            std::snprintf(line, sizeof line, "join %s timed out", r.name.c_str());
            cb_.log(line);
            ClientEvent e{ClientEvent::Type::JoinRoom, kJoinTimeout, r.name, 0};
            it = rooms_.erase(it);
            cb_.event(std::move(e));
            continue;
        }
        if (connected()) {
            if (!r.in && now - r.join_sent >= kJoinRetryMs) send_join(r, now);
            // STATE is repeated, since a datagram can get lost.
            if (r.in && now - r.state_sent >= kStateRepeatMs) send_state(r, now);
        }
        ++it;
    }
    speaking_.expire(now, [&](const SpeakingTracker::Key& k) {
        if (Room* r = find_key(k.room)) cb_.event({ClientEvent::Type::MemberVoice, 0, r->name, k.member});
    });
    for (int i = 0; i < kMaxStreams; ++i) {
        auto& s = streams_[static_cast<std::size_t>(i)];
        if (s.used && now - s.last_ms > kStreamIdleMs) {
            s.used = false;
            cb_.stream_reset(i);
        }
    }
}

}  // namespace roe::voice
