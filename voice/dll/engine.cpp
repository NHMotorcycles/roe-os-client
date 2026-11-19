// GCloudVoice.dll for the 2022 client: the engine object the game gets from GetVoiceEngine()
// (the vtable in the original slot order, voice/engine-vtable.tsv) and the IGCloudVoiceNotify
// base class the game derives its callback object from. Slot facts: rea/VOICE.md.
//
// The game thread never blocks here: engine calls store a value or queue a command for the
// network thread, and Poll() delivers the queued callbacks.
#include <atomic>
#include <cstring>
#include <mutex>
#include <utility>

#include "dll.hpp"

using namespace roe::voice;
using namespace roe::voice::dll;

namespace {

constexpr int kSlots = 94;             // 93 in the original vtable (0x00..0x2e0), one spare
constexpr int kParamNull = 0x1001;     // GCLOUD_VOICE_PARAM_NULL
constexpr int kParamInvalid = 0x1007;  // GCLOUD_VOICE_PARAM_INVALID

// Slot names for the "not implemented" log line, by offset / 8.
const char* const kSlotNames[kSlots] = {
    "ForbidMemberVoice", "EnableLog", "GetMicLevel", "GetSpeakerLevel",                       // 0x00
    "SetSpeakerVolume", "TestMic", "GetFileParam", "CaptureMicrophoneData",                    // 0x20
    "IsSpeaking", "Invoke", "GetDeviceCount", "DescribleDevice",                               // 0x40
    "EnableLoopRender", "SelectDevice", "GetSelDevice", "GetMicVolume",                        // 0x60
    "GetSpeakerVolume", "IsEnableLoopRender", "GetMemVol", "SetMemVol",                        // 0x80
    "SetPlayerVol", "GetPlayerVol", "IsMemberBeForbidVoice", "IsMemberBeForbidVoice",          // 0xa0
    "IsMemberBeForbidVoice", "GetRoomMembers", "SetVadSensitive", "IsMicOpened",               // 0xc0
    "IsSpeakerOpened", "FUN_180013750", "FUN_180013760", "FUN_1800136d0",                      // 0xe0
    "SetRoomOutPutVolume", "EnableVoice3D", "SetPosition3D", "Set3DVoiceVolWithDistance",      // 0x100
    "SetTmwMixEnable", "SetServerInfo", "SetAppInfo", "Init",                                  // 0x120
    "SetNotify", "SetMode", "Poll", "Pause",                                                   // 0x140
    "Resume", "JoinTeamRoom(token)", "JoinTeamRoom", "JoinRangeRoom(token)",                   // 0x160
    "JoinRangeRoom", "UpdateCoordinate", "JoinNationalRoom", "JoinNationalRoom",               // 0x180
    "JoinFMRoom", "QuitRoom", "ChangeRole", "OpenMic",                                         // 0x1a0
    "CloseMic", "OpenSpeaker", "CloseSpeaker", "EnableMultiRoom",                              // 0x1c0
    "EnableRoomMicrophone", "EnableRoomSpeaker", "ApplyMessageKey", "ApplyMessageKey",         // 0x1e0
    "SetMaxMessageLength", "StartRecording", "StopRecording", "UploadRecordedFile",            // 0x200
    "DownloadRecordedFile", "PlayRecordedFile", "StopPlayFile", "EnableSpeakerOn",             // 0x220
    "SpeechToText", "SpeechToText", "StartBlueTooth", "StopBlueTooth",                         // 0x240
    "SetMicVolume", "SetVoiceEffects", "EnableReverb", "SetReverbMode",                        // 0x260
    "GetVoiceIdentify", "SetBGMPath", "StartBGMPlay", "SetBGMVol",                             // 0x280
    "StopBGMPlay", "PauseBGMPlay", "ResumeBGMPlay", "EnableNativeBGMPlay",                     // 0x2a0
    "GetBGMPlayState", "SetBitRate", "GetHwState", "SetDataFree",                              // 0x2c0
    "SetLogCallBack", "(spare)",                                                               // 0x2e0
};

struct State {
    void* notify = nullptr;
    std::string url, app_id, ticket, open_id;
    bool inited = false;
    std::vector<ClientEvent> events;  // Poll's batch
};
State* g = nullptr;  // never destroyed

struct EngineObject {
    void* const* vtable;
};
void* g_vtable[kSlots];
EngineObject g_engine{g_vtable};
std::once_flag g_once;

bool room_ok(const char* room) { return room && room[0] && std::strlen(room) <= kMaxRoomName; }

// ---------------------------------------------------------------- callbacks (Poll only)

template <class F> F notify_slot(void* obj, int offset) {
    return reinterpret_cast<F>((*reinterpret_cast<void***>(obj))[offset / 8]);
}

void deliver(const ClientEvent& e) {
    void* n = g->notify;
    const char* room = e.room.c_str();
    switch (e.type) {
    case ClientEvent::Type::JoinRoom:
        log("-> OnJoinRoom(%d, %s, %d)", e.code, room, e.member);
        if (n) notify_slot<void (*)(void*, int, const char*, int)>(n, 0x08)(n, e.code, room, e.member);
        break;
    case ClientEvent::Type::StatusUpdate:
        log("-> OnStatusUpdate(%d, %s, %d)", e.code, room, e.member);
        if (n) notify_slot<void (*)(void*, int, const char*, int)>(n, 0x10)(n, e.code, room, e.member);
        break;
    case ClientEvent::Type::QuitRoom:
        log("-> OnQuitRoom(%d, %s)", e.code, room);
        if (n) notify_slot<void (*)(void*, int, const char*)>(n, 0x18)(n, e.code, room);
        break;
    case ClientEvent::Type::MemberVoice:
        log("-> OnMemberVoice(%s, %d, %d)", room, e.member, e.code);
        if (n)
            notify_slot<void (*)(void*, const char*, unsigned, int)>(n, 0x20)(n, room, static_cast<unsigned>(e.member),
                                                                            e.code);
        break;
    }
}

// ---------------------------------------------------------------- engine slots

int __cdecl m_EnableLog(void*, bool on) {  // 0x08
    log("EnableLog(%d)", on ? 1 : 0);
    return 0;
}
int __cdecl m_GetMicLevel(void*, bool) {  // 0x10: > 0 only while our voice goes out (own indicator)
    return shared().mic_open ? shared().mic_level.load() : 0;
}
int __cdecl m_GetSpeakerLevel(void*) { return 0; }  // 0x18
int __cdecl m_SetSpeakerVolume(void*, int v) {  // 0x20
    shared().speaker_volume = v;
    log("SetSpeakerVolume(%d)", v);
    return 0;
}
// The game sets the bit rate here or with SetBitRate; GCloudVoice.ini wins over both.
void set_bitrate(const char* from, int bps) {
    if (config().bitrate_ini) {
        log("%s(%d): GCloudVoice.ini keeps %d", from, bps, config().bitrate);
        return;
    }
    const int b = clamp_bitrate(bps);
    shared().bitrate = b;
    log("%s(%d) -> bit rate %d", from, bps, b);
}
int __cdecl m_Invoke(void*, unsigned cmd, unsigned a, unsigned b, unsigned* out) {  // 0x48
    log("Invoke(%u, %u, %u)", cmd, a, b);
    if (cmd == 5004) set_bitrate("Invoke 5004", static_cast<int>(a));  // mBitRate, 64000 in EUVOICECHATTABLE
    if (out) *out = 0;
    return 0;
}
int __cdecl m_GetMicVolume(void*) { return shared().mic_volume; }          // 0x78
int __cdecl m_GetSpeakerVolume(void*) { return shared().speaker_volume; }  // 0x80
bool __cdecl m_IsMicOpened(void*) { return shared().mic_open; }            // 0xd8
bool __cdecl m_IsSpeakerOpened(void*) { return shared().speaker_open; }    // 0xe0

// The connection starts at Init with what the game set so far. The 2022 client calls Init before
// SetServerInfo, so a later SetServerInfo or SetAppInfo starts it again with the new values.
void post_start() {
    if (!g->inited) return;
    Command c;
    c.type = Command::Type::Start;
    c.url = g->url;
    c.ticket = g->ticket;
    c.open_id = g->open_id;
    network_post(std::move(c));
}

int __cdecl m_SetServerInfo(void*, const char* url) {  // 0x128
    if (!url) return kParamNull;
    g->url = url;
    log("SetServerInfo(%s)", url);
    post_start();
    return 0;
}
int __cdecl m_SetAppInfo(void*, const char* app, const char* key, const char* open_id) {  // 0x130
    if (!app || !key || !open_id) return kParamNull;
    g->app_id = app;
    g->ticket = key;
    g->open_id = open_id;
    // The ticket is a login token: only its length goes into the log.
    log("SetAppInfo(%s, <ticket of %zu characters>, %s)", app, g->ticket.size(), open_id);
    post_start();
    return 0;
}
int __cdecl m_Init(void*) {  // 0x138
    log("Init()");
    if (g->inited) return 0;
    g->inited = true;
    post_start();
    return 0;
}
int __cdecl m_SetNotify(void*, void* notify) {  // 0x140
    g->notify = notify;
    log("SetNotify(%p)", notify);
    return 0;
}
int __cdecl m_SetMode(void*, int mode) {  // 0x148
    log("SetMode(%d)", mode);
    return 0;
}
int __cdecl m_Poll(void*) {  // 0x150, every frame
    // Take the batch first: a callback may call back into the engine.
    network_take_events(g->events);
    for (const auto& e : g->events) deliver(e);
    g->events.clear();
    return 0;
}
int __cdecl m_Pause(void*) {  // 0x158
    log("Pause()");
    return 0;
}
int __cdecl m_Resume(void*) {  // 0x160
    log("Resume()");
    return 0;
}

int join(const char* room, int timeout_ms, bool range) {
    if (!room) return kParamNull;
    if (!room_ok(room)) return kParamInvalid;
    log("Join%sRoom(%s, %d)", range ? "Range" : "Team", room, timeout_ms);
    audio_start();
    Command c;
    c.type = Command::Type::Join;
    c.room = room;
    c.flag = range;
    c.value = timeout_ms;
    network_post(std::move(c));
    return 0;
}
int __cdecl m_JoinTeamRoom(void*, const char* room, int timeout_ms) { return join(room, timeout_ms, false); }  // 0x170
int __cdecl m_JoinRangeRoom(void*, const char* room, int timeout_ms) { return join(room, timeout_ms, true); }  // 0x180
int __cdecl m_UpdateCoordinate(void*, const char* room, std::int64_t x, std::int64_t y, std::int64_t z,
                               std::int64_t radius) {  // 0x188, about once a second
    if (!room_ok(room)) return kParamInvalid;
    Command c;
    c.type = Command::Type::Coord;
    c.room = room;
    c.x = x;
    c.y = y;
    c.z = z;
    c.radius = radius;
    network_post(std::move(c));
    return 0;
}
int __cdecl m_QuitRoom(void*, const char* room, int) {  // 0x1a8
    if (!room) return kParamNull;
    log("QuitRoom(%s)", room);
    Command c;
    c.type = Command::Type::Quit;
    c.room = room;
    network_post(std::move(c));
    return 0;
}
void wake_capture() {
    if (shared().capture_wake) SetEvent(shared().capture_wake);
}
int __cdecl m_OpenMic(void*) {  // 0x1b8: free talk, or the push-to-talk key goes down
    if (!shared().mic_open.exchange(true)) log("OpenMic()");
    wake_capture();
    return 0;
}
int __cdecl m_CloseMic(void*) {  // 0x1c0
    if (shared().mic_open.exchange(false)) log("CloseMic()");
    shared().mic_level = 0;
    wake_capture();
    return 0;
}
int speaker(bool on) {
    log(on ? "OpenSpeaker()" : "CloseSpeaker()");
    shared().speaker_open = on;
    Command c;
    c.type = Command::Type::Speaker;
    c.flag = on;
    network_post(std::move(c));
    return 0;
}
int __cdecl m_OpenSpeaker(void*) { return speaker(true); }    // 0x1c8
int __cdecl m_CloseSpeaker(void*) { return speaker(false); }  // 0x1d0
int __cdecl m_EnableMultiRoom(void*, bool on) {  // 0x1d8
    log("EnableMultiRoom(%d)", on ? 1 : 0);
    return 0;
}
int room_flag(const char* room, bool on, Command::Type type) {
    if (!room_ok(room)) return kParamInvalid;
    log("EnableRoom%s(%s, %d)", type == Command::Type::RoomMic ? "Microphone" : "Speaker", room, on ? 1 : 0);
    Command c;
    c.type = type;
    c.room = room;
    c.flag = on;
    network_post(std::move(c));
    return 0;
}
int __cdecl m_EnableRoomMicrophone(void*, const char* room, bool on) {  // 0x1e0
    return room_flag(room, on, Command::Type::RoomMic);
}
int __cdecl m_EnableRoomSpeaker(void*, const char* room, bool on) {  // 0x1e8
    return room_flag(room, on, Command::Type::RoomSpeaker);
}
int __cdecl m_SetMicVolume(void*, int v) {  // 0x260
    shared().mic_volume = v;
    log("SetMicVolume(%d)", v);
    return 0;
}
int __cdecl m_SetBitRate(void*, int bps) {  // 0x2c8
    set_bitrate("SetBitRate", bps);
    return 0;
}
int __cdecl m_SetLogCallBack(void*, void*) { return 0; }  // 0x2e0: our log is the file

// Every other slot: return 0 and log the first call.
template <int Slot> int __cdecl m_unused(void*) {
    static std::atomic<bool> seen{false};
    if (!seen.exchange(true)) log("engine slot 0x%x %s called: not implemented, returns 0", Slot * 8, kSlotNames[Slot]);
    return 0;
}

template <int... I> void fill_unused(std::integer_sequence<int, I...>) {
    ((g_vtable[I] = reinterpret_cast<void*>(&m_unused<I>)), ...);
}

template <class F> void set(int offset, F fn) { g_vtable[offset / 8] = reinterpret_cast<void*>(fn); }

void build_vtable() {
    fill_unused(std::make_integer_sequence<int, kSlots>{});
    set(0x08, m_EnableLog);
    set(0x10, m_GetMicLevel);
    set(0x18, m_GetSpeakerLevel);
    set(0x20, m_SetSpeakerVolume);
    set(0x48, m_Invoke);
    set(0x78, m_GetMicVolume);
    set(0x80, m_GetSpeakerVolume);
    set(0xd8, m_IsMicOpened);
    set(0xe0, m_IsSpeakerOpened);
    set(0x128, m_SetServerInfo);
    set(0x130, m_SetAppInfo);
    set(0x138, m_Init);
    set(0x140, m_SetNotify);
    set(0x148, m_SetMode);
    set(0x150, m_Poll);
    set(0x158, m_Pause);
    set(0x160, m_Resume);
    set(0x170, m_JoinTeamRoom);
    set(0x180, m_JoinRangeRoom);
    set(0x188, m_UpdateCoordinate);
    set(0x1a8, m_QuitRoom);
    set(0x1b8, m_OpenMic);
    set(0x1c0, m_CloseMic);
    set(0x1c8, m_OpenSpeaker);
    set(0x1d0, m_CloseSpeaker);
    set(0x1d8, m_EnableMultiRoom);
    set(0x1e0, m_EnableRoomMicrophone);
    set(0x1e8, m_EnableRoomSpeaker);
    set(0x260, m_SetMicVolume);
    set(0x2c8, m_SetBitRate);
    set(0x2e0, m_SetLogCallBack);
}

void create() {
    // Stay loaded until the process ends: the threads never run unloaded code, and nothing has to
    // be stopped under the loader lock.
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&create), &self);
    load_config();
    log_open();
    g = new State();
    build_vtable();
    log("GCloudVoice (roe_server voice) loaded, pid %lu", GetCurrentProcessId());
    network_start();
}

// ---------------------------------------------------------------- IGCloudVoiceNotify base class

// 17 slots; the game's class overrides some. Slot 0 is the (scalar deleting) destructor, the
// rest are the empty default bodies (exported: the game's vtable points at some of them).
void* __cdecl n_dtor(void* self, unsigned) { return self; }
void __cdecl n_code_room_int(void*, int, const char*, int) {}
void __cdecl n_code_room(void*, int, const char*) {}
void __cdecl n_room_member(void*, const char*, unsigned, int) {}
void __cdecl n_room_members(void*, const char*, const unsigned*, int) {}
void __cdecl n_members(void*, const unsigned*, int) {}
void __cdecl n_code_str_str(void*, int, const char*, const char*) {}
void __cdecl n_code_str(void*, int, const char*) {}
void __cdecl n_code(void*, int) {}
void __cdecl n_bytes(void*, const unsigned char*, unsigned) {}
void __cdecl n_code_int_str_str(void*, int, int, const char*, const char*) {}
void __cdecl n_code_str_int_int(void*, int, const char*, int, int) {}
void __cdecl n_code_int_str(void*, int, int, const char*) {}
void __cdecl n_code_str_int_str(void*, int, const char*, int, const char*) {}

void* const g_notify_vtable[17] = {
    reinterpret_cast<void*>(n_dtor),              // 0x00 ~IGCloudVoiceNotify
    reinterpret_cast<void*>(n_code_room_int),     // 0x08 OnJoinRoom
    reinterpret_cast<void*>(n_code_room_int),     // 0x10 OnStatusUpdate
    reinterpret_cast<void*>(n_code_room),         // 0x18 OnQuitRoom
    reinterpret_cast<void*>(n_room_member),       // 0x20 OnMemberVoice(room, member, status)
    reinterpret_cast<void*>(n_room_members),      // 0x28 OnMemberVoice(room, members, count)
    reinterpret_cast<void*>(n_members),           // 0x30 OnMemberVoice(members, count)
    reinterpret_cast<void*>(n_code_str_str),      // 0x38 OnUploadFile
    reinterpret_cast<void*>(n_code_str_str),      // 0x40 OnDownloadFile
    reinterpret_cast<void*>(n_code_str),          // 0x48 OnPlayRecordedFile
    reinterpret_cast<void*>(n_code),              // 0x50 OnApplyMessageKey
    reinterpret_cast<void*>(n_code_str_str),      // 0x58 OnSpeechToText
    reinterpret_cast<void*>(n_bytes),             // 0x60 OnRecording
    reinterpret_cast<void*>(n_code_int_str_str),  // 0x68 OnStreamSpeechToText
    reinterpret_cast<void*>(n_code_str_int_int),  // 0x70 OnRoleChanged
    reinterpret_cast<void*>(n_code_int_str),      // 0x78 OnDeviceEvent
    reinterpret_cast<void*>(n_code_str_int_str),  // 0x80 OnRoomMemberInfo
};

}  // namespace

// ---------------------------------------------------------------- exports (names: GCloudVoice.def)

extern "C" {

void* __cdecl gv_GetVoiceEngine() {
    std::call_once(g_once, create);
    return &g_engine;
}

void* __cdecl gv_Notify_ctor(void* self) {
    *reinterpret_cast<void* const**>(self) = g_notify_vtable;
    return self;
}
void __cdecl gv_Notify_dtor(void*) {}

void __cdecl gv_OnMemberVoice(void* a, const char* b, const unsigned* c, int d) { n_room_members(a, b, c, d); }
void __cdecl gv_OnUploadFile(void* a, int b, const char* c, const char* d) { n_code_str_str(a, b, c, d); }
void __cdecl gv_OnDownloadFile(void* a, int b, const char* c, const char* d) { n_code_str_str(a, b, c, d); }
void __cdecl gv_OnPlayRecordedFile(void* a, int b, const char* c) { n_code_str(a, b, c); }
void __cdecl gv_OnApplyMessageKey(void* a, int b) { n_code(a, b); }
void __cdecl gv_OnSpeechToText(void* a, int b, const char* c, const char* d) { n_code_str_str(a, b, c, d); }
void __cdecl gv_OnRecording(void* a, const unsigned char* b, unsigned c) { n_bytes(a, b, c); }
void __cdecl gv_OnStreamSpeechToText(void* a, int b, int c, const char* d, const char* e) {
    n_code_int_str_str(a, b, c, d, e);
}
void __cdecl gv_OnRoleChanged(void* a, int b, const char* c, int d, int e) { n_code_str_int_int(a, b, c, d, e); }
void __cdecl gv_OnDeviceEvent(void* a, int b, int c, const char* d) { n_code_int_str(a, b, c, d); }

}  // extern "C"

// Nothing to do at unload: the module is pinned, and at process exit Windows has already ended
// the threads (stopping them here could only hang under the loader lock).
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
