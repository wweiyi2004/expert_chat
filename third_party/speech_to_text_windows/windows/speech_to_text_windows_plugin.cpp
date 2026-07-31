#include "speech_to_text_windows_plugin.h"

#include <flutter/encodable_value.h>

#include <algorithm>
#include <cctype>
#include <cwchar>
#include <set>
#include <string>
#include <utility>

#include <sphelper.h>

namespace speech_to_text_windows {

namespace {

constexpr UINT kSpeechCallbackMessage = WM_APP + 0x5A;
constexpr int kPartialResult = 0;
constexpr int kFinalResult = 2;

using EncodableVariant = flutter::internal::EncodableValueVariant;

std::string WideToUtf8(const wchar_t* text) {
  if (!text) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, text, -1, utf8.data(), size, nullptr, nullptr);
  utf8.pop_back();
  return utf8;
}

std::string EscapeJsonString(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 8);
  for (unsigned char c : input) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[7];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  return out;
}

std::string NormalizeLocale(std::string locale) {
  std::transform(
      locale.begin(), locale.end(), locale.begin(), [](unsigned char c) {
        if (c == '_') return '-';
        return static_cast<char>(std::tolower(c));
      });
  if (locale.rfind("cmn", 0) == 0) {
    locale.replace(0, 3, "zh");
  }
  return locale;
}

std::string PrimaryLanguage(const std::string& locale) {
  const auto normalized = NormalizeLocale(locale);
  const auto separator = normalized.find('-');
  return separator == std::string::npos
             ? normalized
             : normalized.substr(0, separator);
}

bool LocaleMatches(const std::string& requested, const std::string& available) {
  const auto normalized_requested = NormalizeLocale(requested);
  const auto normalized_available = NormalizeLocale(available);
  if (normalized_requested.empty()) return true;
  if (normalized_requested == normalized_available) return true;
  return normalized_requested.find('-') == std::string::npos &&
         PrimaryLanguage(normalized_requested) ==
             PrimaryLanguage(normalized_available);
}

std::string LocaleIdFromLangid(LANGID langid) {
  WCHAR locale_name[LOCALE_NAME_MAX_LENGTH] = {0};
  if (LCIDToLocaleName(
          MAKELCID(langid, SORT_DEFAULT), locale_name,
          LOCALE_NAME_MAX_LENGTH, 0) == 0) {
    return {};
  }
  return WideToUtf8(locale_name);
}

std::string DisplayNameForLocale(const std::string& locale_id) {
  if (locale_id.empty()) return "System default";
  const int wide_len = MultiByteToWideChar(
      CP_UTF8, 0, locale_id.c_str(), -1, nullptr, 0);
  if (wide_len <= 0) return locale_id;
  std::wstring wide(static_cast<size_t>(wide_len), L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, locale_id.c_str(), -1, wide.data(), wide_len);
  if (!wide.empty() && wide.back() == L'\0') wide.pop_back();

  WCHAR display[256] = {0};
  if (GetLocaleInfoEx(
          wide.c_str(), LOCALE_SENGLISHDISPLAYNAME, display, 256) > 0) {
    return WideToUtf8(display);
  }
  return locale_id;
}

std::string LocaleForToken(ISpObjectToken* token) {
  if (!token) return {};
  LPWSTR language = nullptr;
  std::string locale;
  if (SUCCEEDED(token->GetStringValue(L"Language", &language)) && language) {
    const auto langid = wcstoul(language, nullptr, 16);
    locale = LocaleIdFromLangid(static_cast<LANGID>(langid));
    CoTaskMemFree(language);
  }
  return locale;
}

std::string StringArgument(
    const flutter::EncodableValue* arguments,
    const char* key) {
  if (!arguments) return {};
  const auto& variant = static_cast<const EncodableVariant&>(*arguments);
  const auto* map = std::get_if<flutter::EncodableMap>(&variant);
  if (!map) return {};

  const auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return {};
  const auto& value = static_cast<const EncodableVariant&>(it->second);
  const auto* string = std::get_if<std::string>(&value);
  return string ? *string : std::string();
}

}  // namespace

void SpeechToTextWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "speech_to_text_windows",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<SpeechToTextWindowsPlugin>();
  plugin->m_channel = std::move(channel);
  plugin->m_registrar = registrar;
  if (auto* view = registrar->GetView()) {
    plugin->m_window_handle = view->GetNativeWindow();
  }
  plugin->m_window_delegate_id = registrar->RegisterTopLevelWindowProcDelegate(
      [plugin_pointer = plugin.get()](HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
        return plugin_pointer->HandleWindowMessage(
            hwnd, message, wparam, lparam);
      });
  plugin->m_accept_callbacks.store(true, std::memory_order_release);
  registrar->AddPlugin(std::move(plugin));
}

SpeechToTextWindowsPlugin::SpeechToTextWindowsPlugin()
    : m_worker_thread(&SpeechToTextWindowsPlugin::WorkerMain, this) {}

SpeechToTextWindowsPlugin::~SpeechToTextWindowsPlugin() {
  // Stop accepting callbacks before unregistering the window delegate. The
  // worker is joined before the channel and SAPI state are destroyed.
  m_accept_callbacks.store(false, std::memory_order_release);
  if (m_registrar && m_window_delegate_id >= 0) {
    m_registrar->UnregisterTopLevelWindowProcDelegate(m_window_delegate_id);
    m_window_delegate_id = -1;
  }

  {
    std::lock_guard<std::mutex> lock(m_worker_mutex);
    m_worker_stopping = true;
  }
  m_worker_cv.notify_all();
  if (m_worker_thread.joinable()) {
    m_worker_thread.join();
  }

  std::lock_guard<std::mutex> lock(m_callback_mutex);
  m_pending_callbacks.clear();
}

void SpeechToTextWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method_name = method_call.method_name();

  if (method_name == "hasPermission") {
    // Desktop mic access is governed by OS privacy settings; SAPI does not
    // expose a promptable permission API comparable to mobile.
    result->Success(flutter::EncodableValue(true));
  } else if (method_name == "initialize") {
    Initialize(method_call, std::move(result));
  } else if (method_name == "listen") {
    Listen(method_call, std::move(result));
  } else if (method_name == "stop") {
    Stop(std::move(result));
  } else if (method_name == "cancel") {
    Cancel(std::move(result));
  } else if (method_name == "locales") {
    GetLocales(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void SpeechToTextWindowsPlugin::Initialize(
    const flutter::MethodCall<flutter::EncodableValue>& /*method_call*/,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  result->Success(flutter::EncodableValue(RunOnWorkerBool([this]() {
    return InitializeOnWorker();
  })));
}

void SpeechToTextWindowsPlugin::Listen(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string locale_id = StringArgument(
      method_call.arguments(), "localeId");
  const bool started = RunOnWorkerBool([this, locale_id]() {
    return ListenOnWorker(locale_id);
  });
  result->Success(flutter::EncodableValue(started));
}

void SpeechToTextWindowsPlugin::Stop(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  RunOnWorkerVoid([this]() { StopOnWorker(); });
  if (result) {
    result->Success(flutter::EncodableValue(nullptr));
  }
}

void SpeechToTextWindowsPlugin::Cancel(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Stop(std::move(result));
}

void SpeechToTextWindowsPlugin::GetLocales(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto locales = RunOnWorkerLocales();
  flutter::EncodableList encoded;
  encoded.reserve(locales.size());
  for (const auto& locale : locales) {
    encoded.emplace_back(locale);
  }
  result->Success(flutter::EncodableValue(encoded));
}

bool SpeechToTextWindowsPlugin::PostWorkerCommand(WorkerCommand command) {
  {
    std::lock_guard<std::mutex> lock(m_worker_mutex);
    if (m_worker_stopping) return false;
    m_worker_commands.push_back(std::move(command));
  }
  m_worker_cv.notify_one();
  return true;
}

bool SpeechToTextWindowsPlugin::RunOnWorkerBool(
    std::function<bool()> operation) {
  auto promise = std::make_shared<std::promise<bool>>();
  auto future = promise->get_future();
  if (!PostWorkerCommand([promise, operation = std::move(operation)]() mutable {
        try {
          promise->set_value(operation());
        } catch (...) {
          promise->set_value(false);
        }
      })) {
    return false;
  }
  return future.get();
}

void SpeechToTextWindowsPlugin::RunOnWorkerVoid(
    std::function<void()> operation) {
  auto promise = std::make_shared<std::promise<void>>();
  auto future = promise->get_future();
  if (!PostWorkerCommand([promise, operation = std::move(operation)]() mutable {
        try {
          operation();
        } catch (...) {
        }
        promise->set_value();
      })) {
    return;
  }
  future.get();
}

std::vector<std::string> SpeechToTextWindowsPlugin::RunOnWorkerLocales() {
  auto promise = std::make_shared<std::promise<std::vector<std::string>>>();
  auto future = promise->get_future();
  if (!PostWorkerCommand([this, promise]() {
        try {
          promise->set_value(EnumerateLocalesOnWorker());
        } catch (...) {
          promise->set_value({});
        }
      })) {
    return {};
  }
  return future.get();
}

void SpeechToTextWindowsPlugin::WorkerMain() {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  m_worker_com_ready = SUCCEEDED(com_result);

  for (;;) {
    WorkerCommand command;
    {
      std::unique_lock<std::mutex> lock(m_worker_mutex);
      if (!m_worker_commands.empty()) {
        command = std::move(m_worker_commands.front());
        m_worker_commands.pop_front();
      } else if (m_worker_stopping) {
        break;
      } else if (!m_worker_listening) {
        m_worker_cv.wait(lock, [this]() {
          return m_worker_stopping || !m_worker_commands.empty() ||
                 m_worker_listening;
        });
        continue;
      }
    }

    if (command) {
      command();
      continue;
    }

    if (!m_worker_listening || !m_cpRecoContext) continue;
    const HRESULT wait_result = m_cpRecoContext->WaitForNotifyEvent(50);
    if (wait_result == S_OK && m_worker_listening) {
      DrainRecognitionEventsOnWorker();
    }
  }

  StopOnWorker();
  if (SUCCEEDED(com_result)) {
    CoUninitialize();
  }
}

bool SpeechToTextWindowsPlugin::InitializeOnWorker() {
  if (!m_worker_com_ready) return false;
  if (m_worker_initialized) return true;

  const auto locales = EnumerateLocalesOnWorker();
  if (locales.empty()) return false;
  m_worker_initialized = true;
  return true;
}

bool SpeechToTextWindowsPlugin::ListenOnWorker(const std::string& locale_id) {
  if (!m_worker_initialized) {
    SendError("start_failed");
    return false;
  }
  if (m_worker_listening) return true;

  std::string error_code;
  if (!ConfigureRecognizerOnWorker(locale_id, &error_code)) {
    SendError(error_code.empty() ? "start_failed" : error_code,
              error_code == "error_language_unavailable");
    return false;
  }

  const HRESULT hr = m_cpRecoGrammar->SetDictationState(SPRS_ACTIVE);
  if (FAILED(hr)) {
    ReleaseRecognizerOnWorker();
    SendError("listen_failed");
    return false;
  }

  m_worker_listening = true;
  SendStatus("listening");
  return true;
}

bool SpeechToTextWindowsPlugin::ConfigureRecognizerOnWorker(
    const std::string& locale_id,
    std::string* error_code) {
  ReleaseRecognizerOnWorker();

  HRESULT hr = S_OK;
  ISpObjectToken* token = nullptr;
  if (!locale_id.empty()) {
    hr = FindRecognizerToken(locale_id, &token);
    if (FAILED(hr)) {
      if (error_code) *error_code = "error_language_unavailable";
      return false;
    }
    hr = SpCreateObjectFromToken(token, &m_cpRecognizer);
    token->Release();
  } else {
    hr = SpCreateDefaultObjectFromCategoryId(
        SPCAT_RECOGNIZERS, &m_cpRecognizer);
  }
  if (FAILED(hr) || !m_cpRecognizer) {
    if (error_code) *error_code = "recognizer_disabled";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = CoCreateInstance(
      CLSID_SpMMAudioIn, nullptr, CLSCTX_INPROC_SERVER, IID_ISpAudio,
      reinterpret_cast<void**>(&m_cpAudio));
  if (FAILED(hr) || !m_cpAudio) {
    if (error_code) *error_code = "error_audio";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = m_cpRecognizer->SetInput(m_cpAudio, TRUE);
  if (FAILED(hr)) {
    if (error_code) *error_code = "error_audio";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = m_cpRecognizer->CreateRecoContext(&m_cpRecoContext);
  if (FAILED(hr) || !m_cpRecoContext) {
    if (error_code) *error_code = "start_failed";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = m_cpRecoContext->SetNotifyWin32Event();
  if (FAILED(hr)) {
    if (error_code) *error_code = "start_failed";
    ReleaseRecognizerOnWorker();
    return false;
  }

  const ULONGLONG interest =
      SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_HYPOTHESIS) |
      SPFEI(SPEI_SOUND_START) | SPFEI(SPEI_SOUND_END) |
      SPFEI(SPEI_START_SR_STREAM) | SPFEI(SPEI_END_SR_STREAM);
  hr = m_cpRecoContext->SetInterest(interest, interest);
  if (FAILED(hr)) {
    if (error_code) *error_code = "start_failed";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = m_cpRecoContext->CreateGrammar(0, &m_cpRecoGrammar);
  if (FAILED(hr) || !m_cpRecoGrammar) {
    if (error_code) *error_code = "start_failed";
    ReleaseRecognizerOnWorker();
    return false;
  }

  hr = m_cpRecoGrammar->LoadDictation(nullptr, SPLO_STATIC);
  if (FAILED(hr)) {
    if (error_code) *error_code = "language_unavailable";
    ReleaseRecognizerOnWorker();
    return false;
  }
  return true;
}

void SpeechToTextWindowsPlugin::StopOnWorker() {
  const bool was_listening = m_worker_listening;
  if (was_listening && m_cpRecoGrammar) {
    m_cpRecoGrammar->SetDictationState(SPRS_INACTIVE);
  }
  m_worker_listening = false;
  if (was_listening) {
    SendStatus("notListening");
    SendStatus("done");
  }
  ReleaseRecognizerOnWorker();
}

void SpeechToTextWindowsPlugin::ReleaseRecognizerOnWorker() {
  if (m_cpRecoGrammar) {
    m_cpRecoGrammar->Release();
    m_cpRecoGrammar = nullptr;
  }
  if (m_cpRecoContext) {
    m_cpRecoContext->Release();
    m_cpRecoContext = nullptr;
  }
  if (m_cpRecognizer) {
    m_cpRecognizer->Release();
    m_cpRecognizer = nullptr;
  }
  if (m_cpAudio) {
    m_cpAudio->Release();
    m_cpAudio = nullptr;
  }
}

void SpeechToTextWindowsPlugin::DrainRecognitionEventsOnWorker() {
  if (!m_cpRecoContext) return;
  for (;;) {
    SPEVENT event = {};
    ULONG fetched = 0;
    const HRESULT hr = m_cpRecoContext->GetEvents(1, &event, &fetched);
    if (hr != S_OK || fetched == 0) break;

    switch (event.eEventId) {
      case SPEI_RECOGNITION:
      case SPEI_HYPOTHESIS: {
        auto* result = reinterpret_cast<ISpRecoResult*>(event.lParam);
        if (result) {
          LPWSTR text = nullptr;
          if (SUCCEEDED(result->GetText(
                  SP_GETWHOLEPHRASE, SP_GETWHOLEPHRASE, TRUE, &text,
                  nullptr)) &&
              text) {
            const std::string utf8 = WideToUtf8(text);
            if (!utf8.empty()) {
              SendTextRecognition(
                  utf8, event.eEventId == SPEI_RECOGNITION);
            }
            CoTaskMemFree(text);
          }
        }
        break;
      }
      case SPEI_SOUND_START:
        SendStatus("soundDetected");
        break;
      case SPEI_SOUND_END:
        SendStatus("soundEnded");
        break;
      default:
        break;
    }

    SpClearEvent(&event);
  }
}

std::vector<std::string> SpeechToTextWindowsPlugin::EnumerateLocalesOnWorker() {
  std::vector<std::string> locales;
  if (!m_worker_com_ready) return locales;

  IEnumSpObjectTokens* enumerator = nullptr;
  if (FAILED(SpEnumTokens(
          SPCAT_RECOGNIZERS, nullptr, nullptr, &enumerator)) ||
      !enumerator) {
    return locales;
  }

  std::set<std::string> seen;
  ISpObjectToken* token = nullptr;
  ULONG fetched = 0;
  while (enumerator->Next(1, &token, &fetched) == S_OK && token) {
    const auto locale_id = LocaleForToken(token);
    if (!locale_id.empty() && seen.insert(locale_id).second) {
      locales.push_back(
          locale_id + ":" + DisplayNameForLocale(locale_id));
    }
    token->Release();
    token = nullptr;
    fetched = 0;
  }
  enumerator->Release();
  return locales;
}

HRESULT SpeechToTextWindowsPlugin::FindRecognizerToken(
    const std::string& locale_id,
    ISpObjectToken** token) {
  if (!token) return E_POINTER;
  *token = nullptr;
  if (!m_worker_com_ready) return CO_E_NOTINITIALIZED;

  IEnumSpObjectTokens* enumerator = nullptr;
  HRESULT hr = SpEnumTokens(
      SPCAT_RECOGNIZERS, nullptr, nullptr, &enumerator);
  if (FAILED(hr) || !enumerator) return hr;

  ISpObjectToken* candidate = nullptr;
  ULONG fetched = 0;
  while (enumerator->Next(1, &candidate, &fetched) == S_OK && candidate) {
    if (LocaleMatches(locale_id, LocaleForToken(candidate))) {
      *token = candidate;
      enumerator->Release();
      return S_OK;
    }
    candidate->Release();
    candidate = nullptr;
    fetched = 0;
  }
  enumerator->Release();
  return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

std::optional<LRESULT> SpeechToTextWindowsPlugin::HandleWindowMessage(
    HWND /*hwnd*/, UINT message, WPARAM /*wparam*/, LPARAM /*lparam*/) {
  if (message != kSpeechCallbackMessage) return std::nullopt;
  DrainCallbacksOnPlatformThread();
  return static_cast<LRESULT>(0);
}

void SpeechToTextWindowsPlugin::QueueCallback(
    const std::string& method,
    const std::string& payload) {
  if (!m_accept_callbacks.load(std::memory_order_acquire)) return;
  {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    if (!m_accept_callbacks.load(std::memory_order_relaxed)) return;
    m_pending_callbacks.push_back(PendingCallback{method, payload});
  }
  if (m_window_handle) {
    PostMessage(m_window_handle, kSpeechCallbackMessage, 0, 0);
  }
}

void SpeechToTextWindowsPlugin::DrainCallbacksOnPlatformThread() {
  std::deque<PendingCallback> callbacks;
  {
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    callbacks.swap(m_pending_callbacks);
  }
  if (!m_channel) return;
  for (const auto& callback : callbacks) {
    m_channel->InvokeMethod(
        callback.method,
        std::make_unique<flutter::EncodableValue>(callback.payload));
  }
}

void SpeechToTextWindowsPlugin::SendTextRecognition(
    const std::string& text,
    bool is_final) {
  const std::string escaped = EscapeJsonString(text);
  const std::string json_result =
      std::string("{\"recognizedWords\":\"") + escaped +
      "\",\"finalResult\":" + (is_final ? "true" : "false") +
      ",\"alternates\":[{\"recognizedWords\":\"" + escaped +
      "\",\"confidence\":0.85}],\"resultType\":" +
      std::to_string(is_final ? kFinalResult : kPartialResult) + "}";
  QueueCallback("textRecognition", json_result);
}

void SpeechToTextWindowsPlugin::SendError(
    const std::string& error,
    bool permanent) {
  const std::string json =
      std::string("{\"errorMsg\":\"") + EscapeJsonString(error) +
      "\",\"permanent\":" + (permanent ? "true" : "false") + "}";
  QueueCallback("notifyError", json);
}

void SpeechToTextWindowsPlugin::SendStatus(const std::string& status) {
  QueueCallback("notifyStatus", status);
}

}  // namespace speech_to_text_windows

extern "C" __declspec(dllexport) void
SpeechToTextWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  speech_to_text_windows::SpeechToTextWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
