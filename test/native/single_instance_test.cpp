#include <windows.h>
#include <iostream>
#include <string>
#include "single_instance.h"

namespace {
UINT activation = 0;
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM w, LPARAM l) {
  if (message == activation) {
    ShowWindow(window, SW_RESTORE);
    std::cout << "activated" << std::endl;
    return 0;
  }
  return DefWindowProcW(window, message, w, l);
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 3) return 90;
  const std::wstring mode = argv[1];
  const std::wstring identity = argv[2];
  HANDLE collision = nullptr;
  if (mode == L"collision") {
    collision = CreateEventW(nullptr, FALSE, FALSE,
        (L"Local\\" + identity + L".single-instance.v1").c_str());
    if (!collision) return 91;
  }
  SingleInstance guard(identity);
  const auto result = guard.Acquire(argc > 3 ? _wtoi(argv[3]) : 2000);
  if (mode == L"collision") {
    CloseHandle(collision);
    return result == SingleInstance::Result::error ? 0 : 92;
  }
  if (result != SingleInstance::Result::primary) {
    if (mode == L"secondary_hold") {
      std::cout << "secondary_done" << std::endl;
      Sleep(30000);  // Simulate a timeout information dialog left open.
    }
    return result == SingleInstance::Result::activated_existing ? 11 :
           result == SingleInstance::Result::starting_existing ? 12 : 13;
  }
  std::cout << "primary" << std::endl;
  if (mode == L"secondary") return 10;
  if (mode == L"hold") {
    Sleep(30000);
    return 0;
  }
  if (argc > 4) Sleep(_wtoi(argv[4]));
  activation = guard.activation_message();
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"EXPERT_CHAT_SINGLE_INSTANCE_TEST";
  if (!RegisterClassW(&window_class)) return 93;
  HWND window = CreateWindowExW(WS_EX_TOOLWINDOW, window_class.lpszClassName,
      L"Expert Chat", WS_OVERLAPPEDWINDOW, -10000, -10000, 100, 100,
      nullptr, nullptr, window_class.hInstance, nullptr);
  if (!window || !guard.AttachWindow(window)) return 94;
  std::cout << reinterpret_cast<UINT_PTR>(window) << std::endl;
  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return 0;
}
