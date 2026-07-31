#ifndef FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <windows.h>
#include <sapi.h>

namespace speech_to_text_windows {

class SpeechToTextWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  SpeechToTextWindowsPlugin();
  virtual ~SpeechToTextWindowsPlugin();

  SpeechToTextWindowsPlugin(const SpeechToTextWindowsPlugin&) = delete;
  SpeechToTextWindowsPlugin& operator=(const SpeechToTextWindowsPlugin&) = delete;

 private:
  using WorkerCommand = std::function<void()>;

  struct PendingCallback {
    std::string method;
    std::string payload;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Initialize(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Listen(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Stop(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Cancel(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void GetLocales(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // All SAPI objects are created, used, and released on this one COM thread.
  void WorkerMain();
  bool PostWorkerCommand(WorkerCommand command);
  bool RunOnWorkerBool(std::function<bool()> operation);
  void RunOnWorkerVoid(std::function<void()> operation);
  std::vector<std::string> RunOnWorkerLocales();

  bool InitializeOnWorker();
  bool ListenOnWorker(const std::string& locale_id);
  void StopOnWorker();
  bool ConfigureRecognizerOnWorker(
      const std::string& locale_id,
      std::string* error_code);
  void ReleaseRecognizerOnWorker();
  void DrainRecognitionEventsOnWorker();
  std::vector<std::string> EnumerateLocalesOnWorker();
  HRESULT FindRecognizerToken(
      const std::string& locale_id,
      ISpObjectToken** token);

  // Recognition callbacks are posted to the Flutter window and drained by the
  // top-level window delegate, which runs on Flutter's platform thread.
  std::optional<LRESULT> HandleWindowMessage(
      HWND hwnd,
      UINT message,
      WPARAM wparam,
      LPARAM lparam);
  void QueueCallback(const std::string& method, const std::string& payload);
  void DrainCallbacksOnPlatformThread();

  void SendTextRecognition(const std::string& text, bool is_final = false);
  void SendError(const std::string& error, bool permanent = false);
  void SendStatus(const std::string& status);

  // Dedicated worker/COM thread state.
  std::thread m_worker_thread;
  std::mutex m_worker_mutex;
  std::condition_variable m_worker_cv;
  std::deque<WorkerCommand> m_worker_commands;
  bool m_worker_stopping = false;
  bool m_worker_com_ready = false;
  bool m_worker_initialized = false;
  bool m_worker_listening = false;

  ISpRecognizer* m_cpRecognizer = nullptr;
  ISpRecoContext* m_cpRecoContext = nullptr;
  ISpRecoGrammar* m_cpRecoGrammar = nullptr;
  ISpAudio* m_cpAudio = nullptr;

  // Platform-thread callback queue.
  std::mutex m_callback_mutex;
  std::deque<PendingCallback> m_pending_callbacks;
  std::atomic<bool> m_accept_callbacks{false};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> m_channel;
  flutter::PluginRegistrarWindows* m_registrar = nullptr;
  HWND m_window_handle = nullptr;
  int m_window_delegate_id = -1;
};

}  // namespace speech_to_text_windows

// C API for Flutter plugin registration
extern "C" __declspec(dllexport) void SpeechToTextWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
