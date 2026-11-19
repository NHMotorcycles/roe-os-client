// Network thread: the UDP socket, name lookup and the protocol client. The game thread only
// queues commands here (a short lock) and takes the finished events in Poll.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mstcpip.h>
#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

#include <cstring>
#include <thread>

#include "dll.hpp"

namespace roe::voice::dll {

namespace {

constexpr std::size_t kMaxEvents = 512;

class Network final : public Client::Callbacks {
public:
    void start() {
        auto& s = shared();
        s.network_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        socket_event_ = WSACreateEvent();
        std::thread([this] { run(); }).detach();
    }

    void post(Command&& c) {
        {
            std::lock_guard lock(commands_mutex_);
            commands_.push_back(std::move(c));
        }
        SetEvent(shared().network_wake);
    }

    void take_events(std::vector<ClientEvent>& out) {
        std::lock_guard lock(events_mutex_);
        out.swap(events_);
        events_.clear();
    }

    // Client::Callbacks
    void send(std::span<const std::uint8_t> d) override {
        if (sock_ == INVALID_SOCKET || addr_len_ == 0) return;
        sendto(sock_, reinterpret_cast<const char*>(d.data()), static_cast<int>(d.size()), 0,
               reinterpret_cast<const sockaddr*>(&addr_), addr_len_);
    }
    void event(ClientEvent&& e) override {
        std::lock_guard lock(events_mutex_);
        // Bounded: without Poll (the game hangs) speaking changes are dropped; the rare room
        // events are kept, up to twice as many.
        if (events_.size() >= kMaxEvents &&
            (e.type == ClientEvent::Type::MemberVoice || events_.size() >= 2 * kMaxEvents)) {
            if (!events_full_logged_) log("event queue full (the game does not call Poll?); dropping events");
            events_full_logged_ = true;
            return;
        }
        events_.push_back(std::move(e));
    }
    void stream_reset(int stream) override {
        VoiceItem* item = shared().to_render.claim();
        if (!item) {
            ++render_drops_;
            return;
        }
        item->stream = static_cast<std::int16_t>(stream);
        item->reset = true;
        shared().to_render.commit();
    }
    void voice(int stream, std::uint16_t sequence, std::span<const std::uint8_t> packet) override {
        VoiceItem* item = shared().to_render.claim();
        if (!item) {
            ++render_drops_;
            return;
        }
        item->stream = static_cast<std::int16_t>(stream);
        item->reset = false;
        item->sequence = sequence;
        item->size = static_cast<std::uint16_t>(packet.size());
        std::memcpy(item->data.data(), packet.data(), packet.size());
        shared().to_render.commit();
    }
    void log(std::string_view line) override { dll::log("%.*s", static_cast<int>(line.size()), line.data()); }
    void hello(int attempt) override {
        // Look the name up again now and then: the address may have changed.
        if (attempt % 5 == 0) resolve();
    }

private:
    void run() {
        set_thread_name("net");
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            dll::log("WSAStartup failed");
            return;
        }
        HANDLE waits[2] = {shared().network_wake, socket_event_};
        std::vector<Command> batch;
        std::int64_t stats_at = now_ms() + config().stats_ms * 3;
        for (;;) {
            WaitForMultipleObjects(2, waits, FALSE, 20);
            const std::int64_t now = now_ms();
            {
                std::lock_guard lock(commands_mutex_);
                batch.swap(commands_);
            }
            for (auto& c : batch) handle(c, now);
            batch.clear();
            log_flush();
            receive(now);
            send_audio();
            client_.tick(now);
            shared().rooms = static_cast<int>(client_.room_count());
            shared().may_send = client_.wants_audio();
            if (now >= stats_at) {
                stats_at = now + config().stats_ms * 3;
                const auto& st = client_.stats();
                if (st.audio_sent || st.voice_received)
                    dll::log("net: %llu audio sent, %llu voice received, %llu dropped, rtt %lld ms, %llu to render dropped",
                             static_cast<unsigned long long>(st.audio_sent),
                             static_cast<unsigned long long>(st.voice_received),
                             static_cast<unsigned long long>(st.voice_dropped), static_cast<long long>(st.rtt_ms),
                             static_cast<unsigned long long>(render_drops_));
            }
        }
    }

    void handle(Command& c, std::int64_t now) {
        switch (c.type) {
        case Command::Type::Start: {
            // Sent at Init and again for each later SetServerInfo / SetAppInfo.
            const std::string& url = config().server.empty() ? c.url : config().server;
            std::string host;
            std::uint16_t port = 0;
            if (!parse_server_url(url, host, port)) {
                if (!url.empty()) dll::log("voice server url not usable: \"%s\"", url.c_str());
                else if (!client_.started()) dll::log("no voice server url yet, waiting for SetServerInfo");
                return;
            }
            if (client_.started() && host == host_ && port == port_ && c.ticket == ticket_ && c.open_id == open_id_)
                return;
            if (client_.started()) {
                dll::log("voice server or identity changed: connecting again");
                client_.stop();
            }
            host_ = host;
            port_ = port;
            ticket_ = c.ticket;
            open_id_ = c.open_id;
            dll::log("voice server %s port %u%s", host_.c_str(), port_, config().server.empty() ? "" : " (GCloudVoice.ini)");
            client_.set_identity(ticket_, open_id_);
            client_.start(now);
            return;
        }
        case Command::Type::Join:
            client_.join(c.room, c.flag, c.value, now);
            return;
        case Command::Type::Quit:
            client_.quit(c.room);
            return;
        case Command::Type::Coord:
            client_.coord(c.room, c.x, c.y, c.z, c.radius);
            return;
        case Command::Type::RoomMic:
            client_.room_mic(c.room, c.flag);
            return;
        case Command::Type::RoomSpeaker:
            client_.room_speaker(c.room, c.flag);
            return;
        case Command::Type::Speaker:
            client_.speaker_open(c.flag);
            return;
        }
    }

    void resolve() {
        if (host_.empty()) return;
        addrinfo hints{};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;
        hints.ai_protocol = IPPROTO_UDP;
        addrinfo* res = nullptr;
        const std::string port = std::to_string(port_);
        if (getaddrinfo(host_.c_str(), port.c_str(), &hints, &res) != 0 || !res) {
            dll::log("cannot resolve %s", host_.c_str());
            return;
        }
        // Prefer IPv4 (the relay listens there for sure).
        const addrinfo* pick = res;
        for (const addrinfo* a = res; a; a = a->ai_next)
            if (a->ai_family == AF_INET) {
                pick = a;
                break;
            }
        const bool same_family = sock_ != INVALID_SOCKET && family_ == pick->ai_family;
        std::memcpy(&addr_, pick->ai_addr, pick->ai_addrlen);
        addr_len_ = static_cast<int>(pick->ai_addrlen);
        const int family = pick->ai_family;
        freeaddrinfo(res);
        if (!same_family) open_socket(family);
    }

    void open_socket(int family) {
        if (sock_ != INVALID_SOCKET) closesocket(sock_);
        sock_ = socket(family, SOCK_DGRAM, IPPROTO_UDP);
        family_ = family;
        if (sock_ == INVALID_SOCKET) {
            dll::log("socket() failed: %d", WSAGetLastError());
            return;
        }
        sockaddr_storage any{};
        any.ss_family = static_cast<ADDRESS_FAMILY>(family);
        bind(sock_, reinterpret_cast<const sockaddr*>(&any),
             family == AF_INET6 ? static_cast<int>(sizeof(sockaddr_in6)) : static_cast<int>(sizeof(sockaddr_in)));
        // An ICMP "port unreachable" must not break the socket (the relay may restart).
        BOOL off = FALSE;
        DWORD ret = 0;
        WSAIoctl(sock_, SIO_UDP_CONNRESET, &off, sizeof off, nullptr, 0, &ret, nullptr, nullptr);
        int rcvbuf = 256 * 1024;
        setsockopt(sock_, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&rcvbuf), sizeof rcvbuf);
        WSAEventSelect(sock_, socket_event_, FD_READ);  // also makes the socket non-blocking
    }

    bool from_relay(const sockaddr_storage& from) const {
        if (from.ss_family != addr_.ss_family) return false;
        if (from.ss_family == AF_INET) {
            const auto& a = reinterpret_cast<const sockaddr_in&>(from);
            const auto& b = reinterpret_cast<const sockaddr_in&>(addr_);
            return a.sin_port == b.sin_port && a.sin_addr.s_addr == b.sin_addr.s_addr;
        }
        const auto& a = reinterpret_cast<const sockaddr_in6&>(from);
        const auto& b = reinterpret_cast<const sockaddr_in6&>(addr_);
        return a.sin6_port == b.sin6_port && std::memcmp(&a.sin6_addr, &b.sin6_addr, sizeof a.sin6_addr) == 0;
    }

    void receive(std::int64_t now) {
        if (sock_ == INVALID_SOCKET) return;
        WSAResetEvent(socket_event_);
        for (int i = 0; i < 256; ++i) {
            sockaddr_storage from{};
            int from_len = sizeof from;
            const int n = recvfrom(sock_, reinterpret_cast<char*>(rx_.data()), static_cast<int>(rx_.size()), 0,
                                   reinterpret_cast<sockaddr*>(&from), &from_len);
            if (n <= 0) break;
            if (!from_relay(from)) continue;
            client_.on_datagram(std::span<const std::uint8_t>(rx_.data(), static_cast<std::size_t>(n)), now);
        }
    }

    void send_audio() {
        auto& q = shared().to_network;
        // Frames waiting (normally one): up to 3 per datagram, consecutive sequences only.
        while (EncodedFrame* first = q.front()) {
            Frames f;
            f.sequence = first->sequence;
            std::array<EncodedFrame, kMaxFramesPerDatagram> held;
            while (f.count < kMaxFramesPerDatagram) {
                EncodedFrame* e = q.front();
                if (!e || e->sequence != static_cast<std::uint16_t>(f.sequence + f.count)) break;
                held[f.count] = *e;
                f.packet[f.count] = std::span<const std::uint8_t>(held[f.count].data.data(), held[f.count].size);
                ++f.count;
                q.release();
            }
            client_.send_audio(f);
        }
    }

    Client client_{*this};
    std::string ticket_, open_id_;  // the identity the client started with
    std::mutex commands_mutex_;
    std::vector<Command> commands_;
    std::mutex events_mutex_;
    std::vector<ClientEvent> events_;
    bool events_full_logged_ = false;
    SOCKET sock_ = INVALID_SOCKET;
    int family_ = 0;
    sockaddr_storage addr_{};
    int addr_len_ = 0;
    WSAEVENT socket_event_ = WSA_INVALID_EVENT;
    std::string host_;
    std::uint16_t port_ = kDefaultPort;
    std::array<std::uint8_t, 2048> rx_{};
    std::uint64_t render_drops_ = 0;
};

Network* g_network = nullptr;

}  // namespace

void network_start() {
    if (g_network) return;
    g_network = new Network();  // never destroyed, like the threads
    g_network->start();
}

void network_post(Command&& c) {
    if (g_network) g_network->post(std::move(c));
}

void network_take_events(std::vector<ClientEvent>& out) {
    if (g_network) g_network->take_events(out);
}

}  // namespace roe::voice::dll
