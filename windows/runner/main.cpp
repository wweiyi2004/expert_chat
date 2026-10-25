#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "single_instance.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const auto has_argument = [&](const std::string& flag) {
    return std::find(command_line_arguments.begin(), command_line_arguments.end(),
                     flag) != command_line_arguments.end();
  };
  const bool tui_enabled = has_argument("--tui-bridge");
  const bool background = tui_enabled && has_argument("--background");
  SingleInstance single_instance;
  const auto instance_result = single_instance.Acquire(5000, tui_enabled);
  if (instance_result != SingleInstance::Result::primary) {
    if (instance_result == SingleInstance::Result::error) {
      MessageBoxW(nullptr, L"无法建立单实例保护，程序未启动。请稍后重试。",
                  L"Expert Chat", MB_OK | MB_ICONERROR);
      return EXIT_FAILURE;
    }
    if (instance_result == SingleInstance::Result::starting_existing &&
        !background) {
      MessageBoxW(nullptr, L"Expert Chat 已在启动中，请稍候。未打开第二个实例。",
                  L"Expert Chat", MB_OK | MB_ICONINFORMATION);
    }
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!background && !::AttachConsole(ATTACH_PARENT_PROCESS) &&
      ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, tui_enabled, background);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Expert Chat", origin, size)) {
    return EXIT_FAILURE;
  }
  if (!single_instance.AttachWindow(window.GetHandle())) return EXIT_FAILURE;
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
