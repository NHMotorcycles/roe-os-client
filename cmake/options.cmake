# Common compile options of our targets when the client builds alone (the server defines the
# same roe_options in its cmake/warnings.cmake).
add_library(roe_options INTERFACE)
if(MSVC)
  target_compile_options(roe_options INTERFACE /W4 /permissive- /fp:precise /utf-8 /EHsc)
  target_compile_definitions(roe_options INTERFACE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(roe_options INTERFACE -Wall -Wextra -Wpedantic -Wshadow -Wconversion
    -Wno-sign-conversion -ffp-contract=off -fno-fast-math)
endif()
