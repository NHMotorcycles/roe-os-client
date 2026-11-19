# Third-party dependencies of the client, pinned and fetched; no system packages required.
include(FetchContent)
set(FETCHCONTENT_QUIET ON)

# --- Opus (voice codec of GCloudVoice.dll; Windows only, the official release tarball) ---
if(WIN32 AND ROE_BUILD_VOICE_DLL AND CMAKE_SIZEOF_VOID_P EQUAL 8)
  FetchContent_Declare(opus
    URL https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
    URL_HASH SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
  set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
  set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
  set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(opus)
endif()

# --- GoogleTest (the voice core's tests; the server build fetches it already) ---
if(ROE_BUILD_TESTS AND NOT TARGET GTest::gtest_main)
  FetchContent_Declare(googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.15.2
    GIT_SHALLOW TRUE)
  set(gtest_force_shared_crt OFF CACHE BOOL "" FORCE)  # the static runtime, as everything else
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
endif()
