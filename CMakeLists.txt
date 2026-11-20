# The client side of roe_server: the join scripts (join-roe-os.cmd, join-roe-os.py and their
# tests) and the voice chat DLL (voice/). Builds alone (cmake -S . -B build) or as a
# subdirectory of the server, whose voice relay uses voice/core (the protocol).
cmake_minimum_required(VERSION 3.25)
project(roe_client VERSION 0.9 LANGUAGES C CXX)

if(PROJECT_IS_TOP_LEVEL)
  set(CMAKE_CXX_STANDARD 20)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)
  set(CMAKE_CXX_EXTENSIONS OFF)
  set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
  # Windows: the C/C++ runtime goes into the DLL, so it needs no Visual C++ redistributable.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# In the server build the server sets these (same names, same meaning).
option(ROE_BUILD_TESTS "Build the tests" ON)
option(ROE_BUILD_VOICE_DLL "Build the replacement GCloudVoice.dll (Windows)" ON)

# Compile options of our targets: the server's roe_options, or the same defined here.
if(NOT TARGET roe_options)
  include(cmake/options.cmake)
endif()
include(cmake/deps.cmake)

if(ROE_BUILD_TESTS)
  enable_testing()
endif()

add_subdirectory(voice)

# The join scripts: join-roe-os.py against fake Linux Steam trees; join-roe-os.cmd through
# powershell.exe when run in WSL. The fake Proton is a shell script, so not on Windows.
if(ROE_BUILD_TESTS AND NOT WIN32)
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    add_test(NAME Scripts.Join COMMAND Python3::Interpreter -B ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_join.py)
    set_tests_properties(Scripts.Join PROPERTIES TIMEOUT 60)
  endif()
endif()
