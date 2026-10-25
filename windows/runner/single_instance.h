#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>
#include <string>

// A session-wide application identity, independent of the release directory.
// Keep this object alive until the UI process exits.
class SingleInstance {
 public:
  enum class Result { primary, activated_existing, starting_existing, error };
  SingleInstance();
  // Isolated identities allow native process tests without touching the app.
  explicit SingleInstance(std::wstring identity, bool detect_legacy = false);
  ~SingleInstance();
  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  Result Acquire(DWORD startup_wait_ms = 5000, bool enable_tui = false);
  bool AttachWindow(HWND window);
  UINT activation_message() const { return activation_message_; }
  DWORD error() const { return error_; }
  static UINT DefaultActivationMessage();
  static UINT DefaultTuiEnableMessage();

 private:
  HWND FindExistingWindow();
  void Activate(HWND window);
  void EnableTui(HWND window);
  std::wstring mutex_name_;
  std::wstring property_name_;
  bool detect_legacy_;
  UINT activation_message_ = 0;
  UINT tui_enable_message_ = 0;
  HANDLE mutex_ = nullptr;
  HWND window_ = nullptr;
  DWORD error_ = ERROR_SUCCESS;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
