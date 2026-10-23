# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(flutter_pty2_library VERSION 2.0.0 LANGUAGES C)

find_package(Threads REQUIRED)

set(FLUTTER_PTY2_COMMON_SOURCES
  "include/dart_api_dl.c"
  "common/pty_error.c"
  "common/pty_event.c"
  "common/pty_refcount.c"
  "common/pty_debug_stats.c"
  "common/pty_write_queue.c"
)

if (WIN32)
  set(FLUTTER_PTY2_PLATFORM_SOURCES
    windows/pty_windows_commandline.c
    windows/pty_windows_environment.c
    windows/pty_windows_spawn.c
    windows/pty_windows_session.c
  )
else()
  set(FLUTTER_PTY2_PLATFORM_SOURCES
    unix/pty_unix_spawn.c
    unix/pty_unix_session.c
  )
endif()

add_library(flutter_pty2 SHARED
  ${FLUTTER_PTY2_COMMON_SOURCES}
  ${FLUTTER_PTY2_PLATFORM_SOURCES}
)

target_compile_features(flutter_pty2 PRIVATE c_std_11)

option(FLUTTER_PTY2_BUILD_TESTS "Build native flutter_pty2 tests" OFF)

if (CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(flutter_pty2 PRIVATE util)
endif()

set_target_properties(flutter_pty2 PROPERTIES
  PUBLIC_HEADER flutter_pty.h
  OUTPUT_NAME "flutter_pty2"
)

target_compile_definitions(flutter_pty2 PUBLIC DART_SHARED_LIB)
target_link_libraries(flutter_pty2 PRIVATE Threads::Threads)

if (FLUTTER_PTY2_BUILD_TESTS)
  include(CTest)
  enable_testing()
  add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../test"
    "${CMAKE_CURRENT_BINARY_DIR}/tests"
  )
endif()

if (ANDROID)
  # Support Android 15 16k page size.
  set_target_properties(flutter_pty2 PROPERTIES
    LINK_FLAGS "-Wl,-z,max-page-size=16384"
  )
endif()
