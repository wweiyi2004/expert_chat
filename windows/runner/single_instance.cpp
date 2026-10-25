#include "single_instance.h"

namespace {
constexpr wchar_t kIdentity[] = L"com.wweiyi.expert_chat";
constexpr wchar_t kActivateSuffix[] = L".activate.v1";
constexpr wchar_t kTuiEnableSuffix[] = L".enable-tui.v1";

bool IsLegacyAppWindow(HWND window) {
  wchar_t class_name[128]{};
  wchar_t title[128]{};
  if (!GetClassNameW(window, class_name, 128) ||
      wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0 ||
      !GetWindowTextW(window, title, 128) ||
      wcscmp(title, L"Expert Chat") != 0) {
    return false;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  wchar_t path[32768]{};
  DWORD length = 32768;
  const bool queried = QueryFullProcessImageNameW(process, 0, path, &length);
  CloseHandle(process);
  if (!queried) return false;
  const wchar_t* base = wcsrchr(path, L'\\');
  return _wcsicmp(base ? base + 1 : path, L"expert_chat.exe") == 0;
}
}  // namespace

SingleInstance::SingleInstance() : SingleInstance(kIdentity, true) {}

SingleInstance::SingleInstance(std::wstring identity, bool detect_legacy)
    : mutex_name_(L"Local\\" + identity + L".single-instance.v1"),
      property_name_(identity + L".main-window.v1"),
      detect_legacy_(detect_legacy),
      activation_message_(RegisterWindowMessageW(
          (identity + kActivateSuffix).c_str())),
      tui_enable_message_(RegisterWindowMessageW(
          (identity + kTuiEnableSuffix).c_str())) {}

SingleInstance::~SingleInstance() {
  if (window_ && IsWindow(window_)) {
    RemovePropW(window_, property_name_.c_str());
  }
  if (mutex_) CloseHandle(mutex_);
}

UINT SingleInstance::DefaultActivationMessage() {
  static const UINT message = RegisterWindowMessageW(
      (std::wstring(kIdentity) + kActivateSuffix).c_str());
  return message;
}

UINT SingleInstance::DefaultTuiEnableMessage() {
  static const UINT message = RegisterWindowMessageW(
      (std::wstring(kIdentity) + kTuiEnableSuffix).c_str());
  return message;
}

HWND SingleInstance::FindExistingWindow() {
  struct Search {
    const wchar_t* property;
    bool legacy;
    HWND found = nullptr;
  } search{property_name_.c_str(), detect_legacy_};
  EnumWindows(
      [](HWND candidate, LPARAM data) -> BOOL {
        auto* state = reinterpret_cast<Search*>(data);
        DWORD pid = 0;
        GetWindowThreadProcessId(candidate, &pid);
        if (pid == GetCurrentProcessId()) return TRUE;
        if (GetPropW(candidate, state->property) ||
            (state->legacy && IsLegacyAppWindow(candidate))) {
          state->found = candidate;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

void SingleInstance::Activate(HWND window) {
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  AllowSetForegroundWindow(pid);
  // This also supports older releases without the registered message handler.
  ShowWindowAsync(window, SW_RESTORE);
  DWORD_PTR ignored = 0;
  SendMessageTimeoutW(window, activation_message_, 0, 0,
                      SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &ignored);
  SetForegroundWindow(window);
}

void SingleInstance::EnableTui(HWND window) {
  // A fixed, argument-free request: it cannot execute a command or grant a
  // workspace. Authentication is established separately by the Dart bridge.
  DWORD_PTR ignored = 0;
  SendMessageTimeoutW(window, tui_enable_message_, 0, 0,
                      SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &ignored);
}

SingleInstance::Result SingleInstance::Acquire(DWORD startup_wait_ms,
                                              bool enable_tui) {
  if (!activation_message_ || !tui_enable_message_) {
    error_ = GetLastError();
    return Result::error;
  }
  mutex_ = CreateMutexW(nullptr, FALSE, mutex_name_.c_str());
  const DWORD create_error = GetLastError();
  if (!mutex_) {
    error_ = create_error;
    return Result::error;  // Never continue into Flutter without the guard.
  }
  const auto secondary = [this](Result result) {
    CloseHandle(mutex_);
    mutex_ = nullptr;
    return result;
  };
  if (HWND existing = FindExistingWindow()) {
    if (enable_tui) EnableTui(existing);
    else Activate(existing);
    return secondary(Result::activated_existing);
  }
  if (create_error != ERROR_ALREADY_EXISTS) return Result::primary;

  // The first process may still be creating its Flutter window. An eventual
  // timeout exits this process; it never becomes another UI owner.
  const ULONGLONG deadline = GetTickCount64() + startup_wait_ms;
  do {
    Sleep(25);
    if (HWND existing = FindExistingWindow()) {
      if (enable_tui) EnableTui(existing);
      else Activate(existing);
      return secondary(Result::activated_existing);
    }
  } while (GetTickCount64() < deadline);
  return secondary(Result::starting_existing);
}

bool SingleInstance::AttachWindow(HWND window) {
  if (!mutex_ || !window ||
      !SetPropW(window, property_name_.c_str(), reinterpret_cast<HANDLE>(1))) {
    error_ = GetLastError();
    return false;
  }
  window_ = window;
  return true;
}
