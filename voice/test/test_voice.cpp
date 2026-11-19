// The platform-independent part of the voice DLL (voice/core): protocol, URL, jitter buffer,
// mixer, talk gate, speaking indicator, client state machine, log rotation.
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "core/audio.hpp"
#include "core/client.hpp"
#include "core/jitter.hpp"
#include "core/protocol.hpp"
#include "core/util.hpp"

using namespace roe::voice;

namespace {

std::vector<std::uint8_t> bytes(std::span<const std::uint8_t> s) { return {s.begin(), s.end()}; }

std::array<std::uint8_t, 4> packet_of(std::uint16_t seq) {
    return {static_cast<std::uint8_t>(seq >> 8), static_cast<std::uint8_t>(seq), 0xab, 0xcd};
}

std::uint16_t seq_of(std::span<const std::uint8_t> p) {
    return static_cast<std::uint16_t>((p[0] << 8) | p[1]);
}

}  // namespace

// ---------------------------------------------------------------- protocol

TEST(VoiceProtocol, HelloBytesAreBigEndianWithU16Strings) {
    std::array<std::uint8_t, kMaxDatagram> buf{};
    const auto n = encode_hello(buf, "abc", "42");
    const std::vector<std::uint8_t> want{1, 0, 0, 0, 0, kProtocolVersion, 0, 3, 'a', 'b', 'c', 0, 2, '4', '2'};
    ASSERT_EQ(n, want.size());
    EXPECT_EQ(bytes(std::span(buf.data(), n)), want);

    Header h;
    Reader body({});
    ASSERT_TRUE(decode_header(std::span(buf.data(), n), h, body));
    EXPECT_EQ(h.kind, Kind::Hello);
    EXPECT_EQ(h.session, 0u);
    Hello hello;
    ASSERT_TRUE(decode_hello(body, hello));
    EXPECT_EQ(hello.version, kProtocolVersion);
    EXPECT_EQ(hello.ticket, "abc");
    EXPECT_EQ(hello.open_id, "42");
}

TEST(VoiceProtocol, RoundTripsEveryKind) {
    std::array<std::uint8_t, kMaxDatagram> buf{};
    Header h;
    Reader body({});
    auto decode = [&](std::size_t n, Kind kind, std::uint32_t session) {
        ASSERT_GT(n, 0u);
        ASSERT_TRUE(decode_header(std::span(buf.data(), n), h, body));
        EXPECT_EQ(h.kind, kind);
        EXPECT_EQ(h.session, session);
    };

    decode(encode_welcome(buf, 0x01020304), Kind::Welcome, 0x01020304);
    std::uint32_t session = 0;
    ASSERT_TRUE(decode_welcome(body, session));
    EXPECT_EQ(session, 0x01020304u);

    decode(encode_join(buf, 7, 99, "W0T5_roe", true), Kind::Join, 7);
    Join join;
    ASSERT_TRUE(decode_join(body, join));
    EXPECT_EQ(join.request, 99u);
    EXPECT_EQ(join.room, "W0T5_roe");
    EXPECT_EQ(join.range, 1);

    decode(encode_joined(buf, 7, 99, "W0T5_roe", -1), Kind::Joined, 7);
    Joined joined;
    ASSERT_TRUE(decode_joined(body, joined));
    EXPECT_EQ(joined.member_id, -1);

    decode(encode_quit(buf, 7, "W3_roe"), Kind::Quit, 7);
    std::string_view room;
    ASSERT_TRUE(decode_quit(body, room));
    EXPECT_EQ(room, "W3_roe");

    decode(encode_coord(buf, 7, Coord{"W3_roe", -1, 2, -300000000000LL, 5000}), Kind::Coord, 7);
    Coord c;
    ASSERT_TRUE(decode_coord(body, c));
    EXPECT_EQ(c.x, -1);
    EXPECT_EQ(c.z, -300000000000LL);
    EXPECT_EQ(c.radius, 5000);

    decode(encode_state(buf, 7, "W3_roe", false, true), Kind::State, 7);
    State st;
    ASSERT_TRUE(decode_state(body, st));
    EXPECT_FALSE(st.mic);
    EXPECT_TRUE(st.speaker);

    const std::array<std::uint8_t, 3> p0{1, 2, 3};
    const std::array<std::uint8_t, 2> p1{4, 5};
    Frames f;
    f.sequence = 65535;
    f.count = 2;
    f.packet[0] = p0;
    f.packet[1] = p1;
    decode(encode_audio(buf, 7, f), Kind::Audio, 7);
    Frames got;
    ASSERT_TRUE(decode_audio(body, got));
    EXPECT_EQ(got.sequence, 65535);
    ASSERT_EQ(got.count, 2);
    EXPECT_EQ(bytes(got.packet[0]), bytes(p0));
    EXPECT_EQ(bytes(got.packet[1]), bytes(p1));

    decode(encode_voice(buf, 8, "W0T5_roe", 3, f), Kind::Voice, 8);
    Voice v;
    ASSERT_TRUE(decode_voice(body, v));
    EXPECT_EQ(v.room, "W0T5_roe");
    EXPECT_EQ(v.member_id, 3);
    EXPECT_EQ(v.frames.count, 2);

    decode(encode_ping(buf, 8, 123456), Kind::Ping, 8);
    std::uint32_t t = 0;
    ASSERT_TRUE(decode_time(body, t));
    EXPECT_EQ(t, 123456u);
    decode(encode_pong(buf, 8, 5), Kind::Pong, 8);

    const std::array<std::int32_t, 2> ids{1, 2};
    const std::array<std::string_view, 2> names{"1001", "1002"};
    decode(encode_members(buf, 8, "W0T5_roe", ids, names), Kind::Members, 8);
    Members m;
    ASSERT_TRUE(decode_members(body, m));
    EXPECT_EQ(m.count, 2);
    std::int32_t id = 0;
    std::string_view open_id;
    ASSERT_TRUE(m.next(id, open_id));
    EXPECT_EQ(id, 1);
    EXPECT_EQ(open_id, "1001");
    ASSERT_TRUE(m.next(id, open_id));
    EXPECT_EQ(open_id, "1002");
    EXPECT_FALSE(m.next(id, open_id));

    decode(encode_bye(buf, 8), Kind::Bye, 8);
    decode(encode_reset(buf), Kind::Reset, 0);
}

TEST(VoiceProtocol, RejectsShortAndBadBodies) {
    std::array<std::uint8_t, kMaxDatagram> buf{};
    Header h;
    Reader body({});
    EXPECT_FALSE(decode_header(std::span(buf.data(), 4), h, body));

    // Truncated JOINED.
    const auto n = encode_joined(buf, 1, 2, "room", 3);
    ASSERT_TRUE(decode_header(std::span(buf.data(), n - 1), h, body));
    Joined j;
    EXPECT_FALSE(decode_joined(body, j));

    // AUDIO with 0 or 4 frames, or an empty packet.
    std::array<std::uint8_t, 16> bad{8, 0, 0, 0, 1, 0, 1, 0};
    ASSERT_TRUE(decode_header(std::span(bad.data(), 8), h, body));
    Frames f;
    EXPECT_FALSE(decode_audio(body, f));
    bad[7] = 4;
    ASSERT_TRUE(decode_header(std::span(bad.data(), 8), h, body));
    EXPECT_FALSE(decode_audio(body, f));
    const std::array<std::uint8_t, 10> empty_packet{8, 0, 0, 0, 1, 0, 1, 1, 0, 0};
    ASSERT_TRUE(decode_header(empty_packet, h, body));
    EXPECT_FALSE(decode_audio(body, f));

    // A room name longer than the protocol allows is not encoded into a valid JOIN.
    const std::string long_room(kMaxRoomName + 1, 'x');
    const auto jn = encode_join(buf, 1, 1, long_room, false);
    ASSERT_TRUE(decode_header(std::span(buf.data(), jn), h, body));
    Join join;
    EXPECT_FALSE(decode_join(body, join));

    // Too small an output buffer: nothing.
    std::array<std::uint8_t, 6> tiny{};
    EXPECT_EQ(encode_hello(tiny, "ticket", "1"), 0u);
}

// ---------------------------------------------------------------- URL

TEST(VoiceUrl, ParsesTheFormsTheServerSends) {
    std::string host;
    std::uint16_t port = 0;
    ASSERT_TRUE(parse_server_url("udp://203.0.113.5:10101", host, port));
    EXPECT_EQ(host, "203.0.113.5");
    EXPECT_EQ(port, 10101);
    ASSERT_TRUE(parse_server_url(" voice.example.org:2000/path\r\n", host, port));
    EXPECT_EQ(host, "voice.example.org");
    EXPECT_EQ(port, 2000);
    ASSERT_TRUE(parse_server_url("localhost", host, port));
    EXPECT_EQ(host, "localhost");
    EXPECT_EQ(port, kDefaultPort);
    ASSERT_TRUE(parse_server_url("udp://[::1]:7000", host, port));
    EXPECT_EQ(host, "::1");
    EXPECT_EQ(port, 7000);
    ASSERT_TRUE(parse_server_url("fe80::1", host, port));
    EXPECT_EQ(host, "fe80::1");
    EXPECT_EQ(port, kDefaultPort);
}

TEST(VoiceUrl, RejectsBadOnes) {
    std::string host = "keep";
    std::uint16_t port = 1;
    EXPECT_FALSE(parse_server_url("", host, port));
    EXPECT_FALSE(parse_server_url("udp://", host, port));
    EXPECT_FALSE(parse_server_url("tcp://host:1", host, port));
    EXPECT_FALSE(parse_server_url("host:0", host, port));
    EXPECT_FALSE(parse_server_url("host:65536", host, port));
    EXPECT_FALSE(parse_server_url("host:12a", host, port));
    EXPECT_FALSE(parse_server_url("[::1", host, port));
    EXPECT_EQ(host, "keep");
    EXPECT_EQ(port, 1);
}

// ---------------------------------------------------------------- jitter buffer

namespace {

// Pops one frame; returns the sequence of the played packet, -1 for conceal, -2 for silence.
int pop_seq(JitterBuffer& jb, int* fec = nullptr) {
    std::span<const std::uint8_t> p;
    switch (jb.pop(p)) {
    case JitterBuffer::Out::Packet: return seq_of(p);
    case JitterBuffer::Out::Conceal:
        if (fec) *fec = p.empty() ? -1 : seq_of(p);
        return -1;
    case JitterBuffer::Out::Silence: return -2;
    }
    return -3;
}

void push(JitterBuffer& jb, std::uint16_t seq) {
    const auto p = packet_of(seq);
    jb.push(seq, p);
}

void push_all(JitterBuffer& jb, std::initializer_list<int> seqs) {
    for (int s : seqs) push(jb, static_cast<std::uint16_t>(s));
}

}  // namespace

TEST(VoiceJitter, BuffersThenPlaysInOrder) {
    JitterBuffer jb;
    EXPECT_EQ(pop_seq(jb), -2);
    push(jb, 100);
    EXPECT_EQ(pop_seq(jb), -2);  // buffering (depth 3)
    push(jb, 101);
    push(jb, 102);
    EXPECT_EQ(pop_seq(jb), 100);
    push(jb, 103);
    EXPECT_EQ(pop_seq(jb), 101);
    EXPECT_EQ(pop_seq(jb), 102);
    EXPECT_EQ(pop_seq(jb), 103);
}

TEST(VoiceJitter, ReordersAndDropsLateAndDuplicates) {
    JitterBuffer jb;
    push(jb, 11);
    push(jb, 10);  // older one first in line
    push(jb, 12);
    EXPECT_FALSE(jb.push(12, packet_of(12)));
    EXPECT_EQ(jb.stats().duplicate, 1u);
    EXPECT_EQ(pop_seq(jb), 10);
    EXPECT_EQ(pop_seq(jb), 11);
    EXPECT_EQ(pop_seq(jb), 12);
    EXPECT_FALSE(jb.push(11, packet_of(11)));  // already played
    EXPECT_EQ(jb.stats().late, 1u);
}

TEST(VoiceJitter, ConcealsALostFrameWithTheNextOneForFec) {
    JitterBuffer jb;
    push_all(jb, {1, 2, 3, 5, 6});
    EXPECT_EQ(pop_seq(jb), 1);
    EXPECT_EQ(pop_seq(jb), 2);
    EXPECT_EQ(pop_seq(jb), 3);
    int fec = 0;
    EXPECT_EQ(pop_seq(jb, &fec), -1);
    EXPECT_EQ(fec, 5);
    EXPECT_EQ(pop_seq(jb), 5);
    EXPECT_EQ(pop_seq(jb), 6);
    EXPECT_EQ(jb.stats().concealed, 1u);
}

TEST(VoiceJitter, UnderrunConcealsAFewFramesThenStopsAndALateFrameGrowsTheDepth) {
    JitterBuffer jb;
    push_all(jb, {1, 2, 3});
    for (int s = 1; s <= 3; ++s) EXPECT_EQ(pop_seq(jb), s);
    const int depth = jb.depth();
    int fec = 0;
    EXPECT_EQ(pop_seq(jb, &fec), -1);  // 4 is missing, nothing after it
    EXPECT_EQ(fec, -1);
    push(jb, 4);  // arrives too late
    EXPECT_EQ(jb.depth(), depth + 1);
    for (int i = 1; i < JitterBuffer::kMaxConceal; ++i) EXPECT_EQ(pop_seq(jb), -1);
    EXPECT_EQ(pop_seq(jb), -2);
    EXPECT_FALSE(jb.playing());
    EXPECT_EQ(jb.stats().underruns, 1u);
}

TEST(VoiceJitter, APauseOfTheSenderIsNotConcealed) {
    JitterBuffer jb;
    push_all(jb, {1, 2, 3});
    for (int s = 1; s <= 3; ++s) EXPECT_EQ(pop_seq(jb), s);
    // The sender was silent for 10 frames (frame counter went on), then talks again.
    push_all(jb, {14, 15, 16});
    EXPECT_EQ(pop_seq(jb), -2);
    EXPECT_EQ(pop_seq(jb), 14);
    EXPECT_EQ(pop_seq(jb), 15);
    EXPECT_EQ(pop_seq(jb), 16);
    EXPECT_EQ(jb.stats().concealed, 0u);
}

TEST(VoiceJitter, SequenceWrapsAround) {
    JitterBuffer jb;
    push_all(jb, {65534, 65535, 0, 1});
    EXPECT_EQ(pop_seq(jb), 65534);
    EXPECT_EQ(pop_seq(jb), 65535);
    EXPECT_EQ(pop_seq(jb), 0);
    EXPECT_EQ(pop_seq(jb), 1);
}

TEST(VoiceJitter, TrimsLatencyAfterABurst) {
    JitterBuffer jb;
    for (std::uint16_t s = 0; s < 12; ++s) push(jb, s);
    std::vector<int> played;
    for (int i = 0; i < 12; ++i) {
        const int s = pop_seq(jb);
        if (s >= 0) played.push_back(s);
    }
    EXPECT_GT(jb.stats().trimmed, 0u);
    EXPECT_LE(played.size(), 12u - jb.stats().trimmed);
    EXPECT_TRUE(std::is_sorted(played.begin(), played.end()));
}

TEST(VoiceJitter, ANewStreamFarAheadStartsOver) {
    JitterBuffer jb;
    push_all(jb, {1, 2, 3});
    EXPECT_EQ(pop_seq(jb), 1);
    push_all(jb, {5000, 5001, 5002});
    std::vector<int> played;
    for (int i = 0; i < 8; ++i)
        if (const int s = pop_seq(jb); s >= 0) played.push_back(s);
    EXPECT_EQ(played, (std::vector<int>{5000, 5001, 5002}));
}

TEST(VoiceJitter, RefusesOversizedPackets) {
    JitterBuffer jb;
    std::vector<std::uint8_t> big(kMaxOpusPacket + 1, 1);
    EXPECT_FALSE(jb.push(1, big));
    EXPECT_FALSE(jb.push(1, {}));
    EXPECT_EQ(jb.buffered(), 0);
}

// ---------------------------------------------------------------- mixer, gate, speaking

TEST(VoiceMixer, SumsAndNeverClips) {
    Mixer m;
    std::array<float, kFrameSamples> loud{}, quiet{};
    loud.fill(0.9f);
    quiet.fill(0.1f);
    m.begin();
    m.add(loud);
    m.add(loud);
    m.add(loud, 2.0f);
    std::array<std::int16_t, kFrameSamples> out{};
    m.finish(1.0f, out);
    EXPECT_EQ(m.voices(), 3);
    EXPECT_LE(out[0], 32767);
    EXPECT_GT(out[0], 32000);

    m.begin();
    m.add(quiet);
    m.add(quiet);
    m.finish(0.5f, out);
    EXPECT_NEAR(out[0], 0.1f * 32767, 2);  // below the knee: linear
}

TEST(VoiceMixer, SoftClipIsMonotonicAndBounded) {
    float last = -2.0f;
    for (float x = -4.0f; x <= 4.0f; x += 0.01f) {
        const float y = soft_clip(x);
        EXPECT_GE(y, last);
        EXPECT_LE(std::fabs(y), 1.0f);
        last = y;
    }
    EXPECT_FLOAT_EQ(soft_clip(0.5f), 0.5f);
    EXPECT_EQ(to_pcm16(10.0f), 32767);
    EXPECT_EQ(to_pcm16(-10.0f), -32767);
}

TEST(VoiceGate, OpensOnSpeechAndHoldsForTheHangover) {
    std::array<float, kFrameSamples> tone{};
    for (int i = 0; i < kFrameSamples; ++i) tone[static_cast<std::size_t>(i)] = 0.1f * std::sin(0.05f * static_cast<float>(i));
    const float speech = to_dbfs(rms(tone));
    EXPECT_NEAR(speech, -23.0f, 1.0f);
    EXPECT_LE(to_dbfs(0.0f), -100.0f);

    TalkGate gate(-42.0f, 15);
    EXPECT_FALSE(gate.update(-60.0f));
    EXPECT_TRUE(gate.update(speech));
    for (int i = 0; i < 15; ++i) EXPECT_TRUE(gate.update(-60.0f)) << i;
    EXPECT_FALSE(gate.update(-60.0f));
}

TEST(VoiceSpeaking, StartsOnTheFirstFrameAndStopsAfter300Ms) {
    SpeakingTracker t(300);
    std::vector<std::int32_t> stopped;
    auto collect = [&](const SpeakingTracker::Key& k) { stopped.push_back(k.member); };
    EXPECT_TRUE(t.on_voice({1, 5}, 0));
    EXPECT_FALSE(t.on_voice({1, 5}, 20));
    EXPECT_TRUE(t.on_voice({1, 6}, 20));
    t.expire(310, collect);
    EXPECT_TRUE(stopped.empty());
    t.expire(320, collect);
    EXPECT_EQ(stopped, (std::vector<std::int32_t>{5, 6}));
    EXPECT_FALSE(t.speaking({1, 5}));
    EXPECT_TRUE(t.on_voice({1, 5}, 400));
}

// ---------------------------------------------------------------- client

namespace {

struct FakeGame : Client::Callbacks {
    std::vector<std::vector<std::uint8_t>> sent;
    std::vector<ClientEvent> events;
    std::vector<int> resets;
    std::vector<std::pair<int, std::uint16_t>> frames;
    std::vector<std::string> logs;
    int hellos = 0;
    void send(std::span<const std::uint8_t> d) override { sent.emplace_back(d.begin(), d.end()); }
    void event(ClientEvent&& e) override { events.push_back(std::move(e)); }
    void stream_reset(int s) override { resets.push_back(s); }
    void voice(int s, std::uint16_t seq, std::span<const std::uint8_t>) override { frames.emplace_back(s, seq); }
    void log(std::string_view l) override { logs.emplace_back(l); }
    void hello(int) override { ++hellos; }

    Kind last_kind() const { return sent.empty() ? Kind{} : static_cast<Kind>(sent.back()[0]); }
    std::size_t count(Kind k) const {
        std::size_t n = 0;
        for (const auto& d : sent) n += static_cast<Kind>(d[0]) == k;
        return n;
    }
    const std::vector<std::uint8_t>* find_last(Kind k) const {
        for (auto it = sent.rbegin(); it != sent.rend(); ++it)
            if (static_cast<Kind>((*it)[0]) == k) return &*it;
        return nullptr;
    }
};

struct VoiceClient : ::testing::Test {
    FakeGame game;
    Client client{game};
    std::array<std::uint8_t, kMaxDatagram> buf{};
    std::int64_t now = 1000;

    void deliver(std::size_t n) { client.on_datagram(std::span(buf.data(), n), now); }
    void connect(std::uint32_t session = 77) {
        client.set_identity("secret-ticket-0123456789abcdef", "1001");
        client.start(now);
        deliver(encode_welcome(buf, session));
    }
    std::uint32_t join_request(const std::string& room) {
        for (auto it = game.sent.rbegin(); it != game.sent.rend(); ++it) {
            if (static_cast<Kind>((*it)[0]) != Kind::Join) continue;
            Header h;
            Reader body({});
            decode_header(*it, h, body);
            Join j;
            if (decode_join(body, j) && j.room == room) return j.request;
        }
        return 0;
    }
    void joined(const std::string& room, std::int32_t member, std::uint32_t session = 77) {
        deliver(encode_joined(buf, session, join_request(room), room, member));
    }
    void voice(const std::string& room, std::int32_t member, std::uint16_t seq, std::uint32_t session = 77) {
        const auto p = packet_of(seq);
        Frames f;
        f.sequence = seq;
        f.count = 1;
        f.packet[0] = p;
        deliver(encode_voice(buf, session, room, member, f));
    }
};

}  // namespace

TEST_F(VoiceClient, HelloRepeatsUntilWelcomeThenJoinsWaitingRooms) {
    client.set_identity("secret-ticket-0123456789abcdef", "1001");
    client.start(now);
    EXPECT_EQ(game.last_kind(), Kind::Hello);
    ASSERT_TRUE(client.join("W0T1_roe", false, 10000, now));
    EXPECT_EQ(game.count(Kind::Join), 0u);  // not connected yet
    now += 1000;
    client.tick(now);
    EXPECT_EQ(game.count(Kind::Hello), 2u);
    deliver(encode_welcome(buf, 77));
    EXPECT_TRUE(client.connected());
    EXPECT_EQ(game.count(Kind::Join), 1u);
    joined("W0T1_roe", 4);
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].type, ClientEvent::Type::JoinRoom);
    EXPECT_EQ(game.events[0].code, kJoinSucceeded);
    EXPECT_EQ(game.events[0].room, "W0T1_roe");
    EXPECT_EQ(game.events[0].member, 4);
    // STATE right after JOINED: mic on, speaker closed (the game has not opened it).
    const auto* st = game.find_last(Kind::State);
    ASSERT_NE(st, nullptr);
    Header h;
    Reader body({});
    decode_header(*st, h, body);
    State s;
    ASSERT_TRUE(decode_state(body, s));
    EXPECT_TRUE(s.mic);
    EXPECT_FALSE(s.speaker);
    // The ticket never reaches the log.
    for (const auto& l : game.logs) EXPECT_EQ(l.find("secret-ticket"), std::string::npos) << l;
}

TEST_F(VoiceClient, JoinIsRetriedWithTheSameRequestAndTimesOut) {
    connect();
    client.join("W9_roe", true, 3000, now);
    const auto req = join_request("W9_roe");
    now += 1000;
    client.tick(now);
    EXPECT_EQ(game.count(Kind::Join), 2u);
    EXPECT_EQ(join_request("W9_roe"), req);
    now += 2000;
    deliver(encode_pong(buf, 77, 0));  // the relay is alive, only the join is not answered
    client.tick(now);
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].code, kJoinTimeout);
    EXPECT_EQ(client.room_count(), 0u);
}

TEST_F(VoiceClient, RefusedJoinReportsAServerError) {
    connect();
    client.join("W0T2_roe", false, 10000, now);
    joined("W0T2_roe", -1);
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].code, kJoinServerError);
    EXPECT_EQ(client.room_count(), 0u);
}

TEST_F(VoiceClient, VoiceStartsAndStopsTheSpeakingIndicator) {
    connect();
    client.speaker_open(true);
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1);
    game.events.clear();
    voice("W0T1_roe", 2, 10);
    now += 20;
    voice("W0T1_roe", 2, 11);
    voice("W0T1_roe", 1, 50);  // our own: ignored
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].type, ClientEvent::Type::MemberVoice);
    EXPECT_EQ(game.events[0].member, 2);
    EXPECT_EQ(game.events[0].code, 1);
    ASSERT_EQ(game.frames.size(), 2u);
    EXPECT_EQ(game.frames[1].second, 11);
    ASSERT_EQ(game.resets.size(), 1u);  // a stream slot was taken
    now += 290;
    client.tick(now);
    EXPECT_EQ(game.events.size(), 1u);
    now += 20;
    client.tick(now);
    ASSERT_EQ(game.events.size(), 2u);
    EXPECT_EQ(game.events[1].code, 0);
}

TEST_F(VoiceClient, ClosedSpeakerDropsVoice) {
    connect();
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1);
    voice("W0T1_roe", 2, 10);
    EXPECT_TRUE(game.frames.empty());
    client.speaker_open(true);
    client.room_speaker("W0T1_roe", false);
    voice("W0T1_roe", 2, 11);
    EXPECT_TRUE(game.frames.empty());
    client.room_speaker("W0T1_roe", true);
    voice("W0T1_roe", 2, 12);
    EXPECT_EQ(game.frames.size(), 1u);
}

TEST_F(VoiceClient, AudioGoesOutOnlyWithARoomWhoseMicIsOn) {
    const std::array<std::uint8_t, 3> p{1, 2, 3};
    Frames f;
    f.count = 1;
    f.packet[0] = p;
    EXPECT_FALSE(client.send_audio(f));
    connect();
    EXPECT_FALSE(client.wants_audio());
    client.join("W0T1_roe", false, 10000, now);
    EXPECT_FALSE(client.wants_audio());
    joined("W0T1_roe", 1);
    EXPECT_TRUE(client.wants_audio());
    EXPECT_TRUE(client.send_audio(f));
    EXPECT_EQ(game.last_kind(), Kind::Audio);
    client.room_mic("W0T1_roe", false);
    EXPECT_EQ(game.last_kind(), Kind::State);
    EXPECT_FALSE(client.send_audio(f));
}

TEST_F(VoiceClient, LossTakesRoomsOfflineAndReconnects) {
    connect();
    client.speaker_open(true);
    client.join("W0T1_roe", false, 10000, now);
    client.join("W5_roe", true, 10000, now);
    joined("W0T1_roe", 1);
    joined("W5_roe", 3);
    voice("W0T1_roe", 2, 1);
    game.events.clear();
    const auto hellos = game.count(Kind::Hello);
    now += 2000;
    client.tick(now);
    EXPECT_EQ(game.count(Kind::Ping), 1u);
    now += Client::kLostMs + 1;
    client.tick(now);
    EXPECT_FALSE(client.connected());
    EXPECT_EQ(game.count(Kind::Hello), hellos + 1);
    int offline = 0, silent = 0;
    for (const auto& e : game.events) {
        offline += e.type == ClientEvent::Type::StatusUpdate && e.code == kRoomOffline;
        silent += e.type == ClientEvent::Type::MemberVoice && e.code == 0;
    }
    EXPECT_EQ(offline, 2);
    EXPECT_EQ(silent, 1);
    EXPECT_EQ(client.room_count(), 0u);
    // A new session: the game joins again.
    deliver(encode_welcome(buf, 78));
    EXPECT_TRUE(client.connected());
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1, 78);
    EXPECT_EQ(game.events.back().code, kJoinSucceeded);
}

TEST_F(VoiceClient, ResetFromTheRelayReconnectsAtOnce) {
    connect();
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1);
    deliver(encode_reset(buf));
    EXPECT_FALSE(client.connected());
    EXPECT_EQ(game.events.back().code, kRoomOffline);
    client.tick(now);
    EXPECT_EQ(game.last_kind(), Kind::Hello);
}

TEST_F(VoiceClient, RefusedTicketWaitsLongerAndIsLoggedOnce) {
    client.set_identity("bad", "1001");
    client.start(now);
    deliver(encode_welcome(buf, 0));
    deliver(encode_welcome(buf, 0));
    EXPECT_FALSE(client.connected());
    const auto hellos = game.count(Kind::Hello);
    now += 1500;
    client.tick(now);
    EXPECT_EQ(game.count(Kind::Hello), hellos);
    now += Client::kRefusedRetryMs;
    client.tick(now);
    EXPECT_EQ(game.count(Kind::Hello), hellos + 1);
    int refused = 0;
    for (const auto& l : game.logs) refused += l.find("refused") != std::string::npos;
    EXPECT_EQ(refused, 1);
}

TEST_F(VoiceClient, DatagramsOfAnotherSessionAreIgnored) {
    connect(77);
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1, 99);
    EXPECT_TRUE(game.events.empty());
}

TEST_F(VoiceClient, QuitSendsQuitAndConfirms) {
    connect();
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1);
    game.events.clear();
    client.quit("W0T1_roe");
    EXPECT_EQ(game.last_kind(), Kind::Quit);
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].type, ClientEvent::Type::QuitRoom);
    EXPECT_EQ(game.events[0].code, kQuitSucceeded);
    EXPECT_FALSE(client.wants_audio());
}

TEST_F(VoiceClient, MembersEndStreamsOfThoseWhoLeft) {
    connect();
    client.speaker_open(true);
    client.join("W0T1_roe", false, 10000, now);
    joined("W0T1_roe", 1);
    voice("W0T1_roe", 2, 1);
    voice("W0T1_roe", 3, 1);
    game.resets.clear();
    game.events.clear();
    const std::array<std::int32_t, 2> ids{1, 3};
    const std::array<std::string_view, 2> names{"1001", "1003"};
    deliver(encode_members(buf, 77, "W0T1_roe", ids, names));
    ASSERT_EQ(game.resets.size(), 1u);
    ASSERT_EQ(game.events.size(), 1u);
    EXPECT_EQ(game.events[0].member, 2);
    EXPECT_EQ(game.events[0].code, 0);
}

TEST_F(VoiceClient, StateAndCoordAreSentAndStateRepeats) {
    connect();
    client.join("W5_roe", true, 10000, now);
    EXPECT_TRUE(client.coord("W5_roe", 1, 2, 3, 5000));
    EXPECT_EQ(game.count(Kind::Coord), 0u);  // sent once joined
    joined("W5_roe", 2);
    EXPECT_EQ(game.count(Kind::Coord), 1u);
    const auto states = game.count(Kind::State);
    now += Client::kStateRepeatMs;
    deliver(encode_pong(buf, 77, 0));
    client.tick(now);
    EXPECT_EQ(game.count(Kind::State), states + 1);
    EXPECT_FALSE(client.coord("unknown", 1, 2, 3, 4));
    EXPECT_FALSE(client.join("", false, 10000, now));
}

// ---------------------------------------------------------------- queue, log

TEST(VoiceQueue, KeepsOrderAndRefusesWhenFull) {
    SpscQueue<int, 4> q;
    for (int i = 0; i < 4; ++i) {
        int* slot = q.claim();
        ASSERT_NE(slot, nullptr);
        *slot = i;
        q.commit();
    }
    EXPECT_EQ(q.claim(), nullptr);
    for (int i = 0; i < 4; ++i) {
        int* front = q.front();
        ASSERT_NE(front, nullptr);
        EXPECT_EQ(*front, i);
        q.release();
    }
    EXPECT_EQ(q.front(), nullptr);
}

// A temporary folder of this test, unique per test run (ctest runs tests in parallel).
struct TempDir {
    std::filesystem::path path;
    TempDir() {
        const auto* info = ::testing::UnitTest::GetInstance()->current_test_info();
        path = std::filesystem::temp_directory_path() /
               ("roe-voice-" + std::to_string(std::random_device{}()) + "-" + (info ? info->name() : "test"));
        std::error_code ignored;
        std::filesystem::remove_all(path, ignored);
        std::filesystem::create_directories(path, ignored);
    }
    ~TempDir() {
        std::error_code ignored;
        std::filesystem::remove_all(path, ignored);
    }
};

TEST(VoiceLog, RotatesAtTheCapAndKeepsTheOlderFiles) {
    TempDir dir;
    const auto path = dir.path / "GCloudVoice.log";
    {
        std::ofstream(path) << "previous run\n";
        LogFile log;
        ASSERT_TRUE(log.open(path, 100, 2));
        EXPECT_TRUE(std::filesystem::exists(LogFile::rotated(path, 1)));
        for (int i = 0; i < 30; ++i) log.write("0123456789");  // 11 bytes a line
    }
    EXPECT_EQ(LogFile::rotated(path, 1).filename(), "GCloudVoice.1.log");
    EXPECT_LE(std::filesystem::file_size(path), 100u);
    EXPECT_TRUE(std::filesystem::exists(LogFile::rotated(path, 2)));
    EXPECT_FALSE(std::filesystem::exists(LogFile::rotated(path, 3)));
    std::uintmax_t total = 0;
    for (const auto& e : std::filesystem::directory_iterator(dir.path)) total += e.file_size();
    EXPECT_LE(total, 300u);  // bounded: at most keep + 1 files of the cap
}
