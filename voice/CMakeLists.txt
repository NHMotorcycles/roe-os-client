# Voice chat: the replacement GCloudVoice.dll (Windows only) and its platform-independent core
# (protocol, jitter buffer, mixing, the client state machine), which its tests (and the server's
# voice relay, for the protocol) use too. The core needs no third-party library.
add_library(roe_voice_core STATIC
  core/protocol.cpp
  core/jitter.cpp
  core/audio.cpp
  core/client.cpp
  core/util.cpp)
target_include_directories(roe_voice_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(roe_voice_core PRIVATE roe_options)
set_target_properties(roe_voice_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Where the DLL and its test land: next to roe_server.exe in the server build, else bin/.
if(PROJECT_IS_TOP_LEVEL)
  set(ROE_VOICE_OUTPUT_DIR ${CMAKE_BINARY_DIR}/bin)
else()
  set(ROE_VOICE_OUTPUT_DIR ${CMAKE_BINARY_DIR}/src)
endif()

if(ROE_BUILD_TESTS)
  # The core on every platform: protocol, URL, jitter buffer, mixer, client state machine, log.
  include(GoogleTest)
  add_executable(roe_voice_tests test/test_voice.cpp)
  target_link_libraries(roe_voice_tests PRIVATE roe_voice_core roe_options GTest::gtest_main)
  gtest_discover_tests(roe_voice_tests DISCOVERY_MODE PRE_TEST)
endif()

if(WIN32 AND ROE_BUILD_VOICE_DLL AND CMAKE_SIZEOF_VOID_P EQUAL 8)
  add_library(GCloudVoice SHARED
    dll/engine.cpp
    dll/network.cpp
    dll/audio_io.cpp
    dll/log.cpp
    GCloudVoice.def)
  target_link_libraries(GCloudVoice PRIVATE roe_voice_core roe_options Opus::opus ws2_32 ole32 avrt)
  # The game takes the file by this name.
  set_target_properties(GCloudVoice PROPERTIES
    OUTPUT_NAME GCloudVoice
    RUNTIME_OUTPUT_DIRECTORY ${ROE_VOICE_OUTPUT_DIR})

  # Drives the built DLL the way the game does, against a fake relay in the same process.
  add_executable(voice_dll_test test/voice_dll_test.cpp)
  target_link_libraries(voice_dll_test PRIVATE roe_voice_core roe_options ws2_32)
  add_dependencies(voice_dll_test GCloudVoice)
  set_target_properties(voice_dll_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${ROE_VOICE_OUTPUT_DIR})
  if(ROE_BUILD_TESTS)
    add_test(NAME Voice.Dll COMMAND voice_dll_test $<TARGET_FILE:GCloudVoice>)
    set_tests_properties(Voice.Dll PROPERTIES TIMEOUT 120)
  endif()
endif()
