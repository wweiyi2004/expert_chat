# Bundle the permission authority with the UI; never resolve it from a project.
find_program(EXPERT_CARGO_EXECUTABLE cargo)
if(NOT EXPERT_CARGO_EXECUTABLE)
  message(FATAL_ERROR "Rust cargo is required to build the desktop workspace service")
endif()
set(EXPERT_RUST_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/../next/Cargo.toml")
set(EXPERT_RUST_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/desktop-agent")
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(EXPERT_RUST_TARGET "aarch64-pc-windows-msvc")
else()
  set(EXPERT_RUST_TARGET "x86_64-pc-windows-msvc")
endif()
set(EXPERT_RUST_PROFILE "$<IF:$<CONFIG:Debug>,dev,release>")
set(EXPERT_RUST_OUTPUT "$<IF:$<CONFIG:Debug>,debug,release>")
add_custom_target(expert_desktop_service
  COMMAND "${EXPERT_CARGO_EXECUTABLE}" build --manifest-path "${EXPERT_RUST_MANIFEST}"
    --locked --target "${EXPERT_RUST_TARGET}" --target-dir "${EXPERT_RUST_TARGET_DIR}"
    --profile "${EXPERT_RUST_PROFILE}" -p expert-desktop -p expert-tui
  COMMENT "Building the desktop workspace service"
  VERBATIM
)
add_dependencies(${BINARY_NAME} expert_desktop_service)
install(FILES "${EXPERT_RUST_TARGET_DIR}/${EXPERT_RUST_TARGET}/${EXPERT_RUST_OUTPUT}/expert-desktop.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${EXPERT_RUST_TARGET_DIR}/${EXPERT_RUST_TARGET}/${EXPERT_RUST_OUTPUT}/expert-tui.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

find_program(EXPERT_POWERSHELL_EXECUTABLE NAMES pwsh powershell REQUIRED)
find_program(EXPERT_DART_EXECUTABLE NAMES dart.exe dart.bat dart
  HINTS "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin" "$ENV{FLUTTER_ROOT}/bin/cache/dart-sdk/bin" REQUIRED)
set(EXPERT_HOST_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/independent-host/$<CONFIG>")
add_custom_target(expert_shared_host
  COMMAND "${EXPERT_POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File
    "${CMAKE_CURRENT_SOURCE_DIR}/../tool/build_desktop_host.ps1"
    -Destination "${EXPERT_HOST_OUTPUT}"
    -DartExecutable "${EXPERT_DART_EXECUTABLE}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
  COMMENT "Building the independent Dart host and bounded media worker"
  VERBATIM
)
add_dependencies(${BINARY_NAME} expert_shared_host)
install(DIRECTORY "${EXPERT_HOST_OUTPUT}/host"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(DIRECTORY "${EXPERT_HOST_OUTPUT}/expert-media-worker"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/expert.cmd"
  "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/expert.ps1"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
