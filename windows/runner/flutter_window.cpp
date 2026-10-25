#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"
#include "single_instance.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kTrayId = 1;
constexpr UINT kTrayOpen = 1001;
constexpr UINT kTrayExit = 1002;
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool tui_enabled, bool background)
    : project_(project), tui_enabled_(tui_enabled), background_(background) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AddTrayIcon();
  tui_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "expert_chat/tui_bridge",
          &flutter::StandardMethodCodec::GetInstance());
  tui_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "getLaunchOptions") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("enabled"),
               flutter::EncodableValue(tui_enabled_)},
              {flutter::EncodableValue("background"),
               flutter::EncodableValue(background_)}}));
        } else if (call.method_name() == "show") {
          RestoreFromTray();
          result->Success();
        } else if (call.method_name() == "disabled") {
          tui_enabled_ = false;
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  generation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "expert_chat/generation",
          &flutter::StandardMethodCodec::GetInstance());
  generation_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "start") {
          SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
          result->Success();
        } else if (call.method_name() == "stop") {
          SetThreadExecutionState(ES_CONTINUOUS);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Remain reachable if the taskbar is unavailable; otherwise TUI launch
    // does not flash or steal focus from the terminal.
    if (!background_ || !tray_available_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  SetThreadExecutionState(ES_CONTINUOUS);
  generation_channel_ = nullptr;
  tui_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = kTrayId;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Expert Chat");
  tray_available_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_available_) return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_available_ = false;
}

void FlutterWindow::RestoreFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == SingleInstance::DefaultTuiEnableMessage()) {
    // Retain this flag even before Dart registers its handler. Its initial
    // getLaunchOptions query closes the startup race.
    tui_enabled_ = true;
    if (tui_channel_) tui_channel_->InvokeMethod("enable", nullptr);
    return 0;
  }
  if (message == SingleInstance::DefaultActivationMessage()) {
    RestoreFromTray();
    return 0;
  }
  if (message == RegisterWindowMessageW(L"TaskbarCreated")) {
    AddTrayIcon();
    // If Explorer cannot restore the tray, keep the app reachable.
    if (!tray_available_) RestoreFromTray();
    return 0;
  }
  if (message == WM_CLOSE && tray_available_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      RestoreFromTray();
    } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kTrayOpen, L"打开 Expert Chat");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kTrayExit, L"退出");
      POINT point{};
      GetCursorPos(&point);
      SetForegroundWindow(hwnd);
      const UINT command = TrackPopupMenu(menu,
          TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
          point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (command == kTrayOpen) RestoreFromTray();
      if (command == kTrayExit) DestroyWindow(hwnd);
      PostMessage(hwnd, WM_NULL, 0, 0);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
