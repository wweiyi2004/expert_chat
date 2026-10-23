#ifndef FLUTTER_PTY_H_
#define FLUTTER_PTY_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FFI_PLUGIN_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PtySession PtySession;

typedef enum PtyErrorDomain {
    PTY_ERROR_DOMAIN_NONE = 0,
    PTY_ERROR_DOMAIN_POSIX = 1,
    PTY_ERROR_DOMAIN_WIN32 = 2,
    PTY_ERROR_DOMAIN_HRESULT = 3,
    PTY_ERROR_DOMAIN_INTERNAL = 4
} PtyErrorDomain;

typedef enum PtyErrorKind {
    PTY_ERROR_NONE = 0,
    PTY_ERROR_INVALID_ARGUMENT = 1,
    PTY_ERROR_NOT_FOUND = 2,
    PTY_ERROR_PERMISSION_DENIED = 3,
    PTY_ERROR_SPAWN_FAILED = 4,
    PTY_ERROR_WORKING_DIRECTORY = 5,
    PTY_ERROR_IO = 6,
    PTY_ERROR_CLOSED = 7,
    PTY_ERROR_UNSUPPORTED = 8,
    PTY_ERROR_OUT_OF_MEMORY = 9,
    PTY_ERROR_INTERNAL = 10
} PtyErrorKind;

typedef struct PtyError {
    int32_t domain;
    int32_t kind;
    int64_t os_code;
    char message[256];
} PtyError;

/* Test/debug diagnostics; not part of the public Dart API. */
typedef struct PtyDebugStats {
    uint64_t live_sessions;
    uint64_t live_read_workers;
    uint64_t live_write_workers;
    uint64_t live_wait_workers;
    uint64_t live_close_workers;
    uint64_t live_pseudo_console_workers;
    uint64_t pending_write_chunks;
    uint64_t pending_write_bytes;
    uint64_t inflight_write_bytes;
    uint64_t pseudo_console_close_calls;
    uint64_t pseudo_console_release_calls;
    uint64_t pseudo_console_close_worker_calls;
} PtyDebugStats;

typedef struct PtySize {
    int32_t rows;
    int32_t columns;
    int32_t pixel_width;
    int32_t pixel_height;
} PtySize;

typedef struct PtySpawnOptions {
    const char *executable;
    const char *const *arguments;
    int32_t argument_count;
    const char *const *environment;
    int32_t environment_count;
    const char *working_directory;
    PtySize size;
    uint64_t input_buffer_bytes;
    uint64_t output_window_bytes;
    int64_t event_port;
} PtySpawnOptions;

typedef enum PtyTryWriteResult {
    PTY_WRITE_ACCEPTED = 0,
    PTY_WRITE_BACKPRESSURED = 1,
    PTY_WRITE_CLOSED = 2,
    PTY_WRITE_ERROR = 3
} PtyTryWriteResult;

typedef enum PtyCapability {
    PTY_CAPABILITY_POSIX_SIGNALS = 1,
    PTY_CAPABILITY_FOREGROUND_PROCESS_GROUPS = 2,
    PTY_CAPABILITY_PIXEL_DIMENSIONS = 4,
    PTY_CAPABILITY_RELIABLE_PROCESS_TREE_KILL = 8,
    PTY_CAPABILITY_CONPTY = 16
} PtyCapability;

typedef enum PtyEventType {
    PTY_EVENT_SPAWNED = 1,
    PTY_EVENT_SPAWN_FAILED = 2,
    PTY_EVENT_OUTPUT = 3,
    PTY_EVENT_OUTPUT_CLOSED = 4,
    PTY_EVENT_WRITE_COMPLETE = 5,
    PTY_EVENT_WRITABLE = 6,
    PTY_EVENT_INPUT_CLOSED = 7,
    PTY_EVENT_PROCESS_EXIT = 8,
    PTY_EVENT_ASYNC_ERROR = 9,
    PTY_EVENT_SESSION_CLOSED = 10
} PtyEventType;

FFI_PLUGIN_EXPORT int32_t pty_session_start(
    const PtySpawnOptions *options,
    PtySession **out_session,
    PtyError *out_error);
FFI_PLUGIN_EXPORT int64_t pty_session_pid(PtySession *session);
FFI_PLUGIN_EXPORT int32_t pty_session_try_write(
    PtySession *session,
    uint64_t request_id,
    const uint8_t *bytes,
    uint64_t length,
    PtyError *out_error);
FFI_PLUGIN_EXPORT void pty_session_ack_output(
    PtySession *session,
    uint64_t byte_count);
FFI_PLUGIN_EXPORT int32_t pty_session_resize(
    PtySession *session,
    PtySize size,
    PtyError *out_error);
FFI_PLUGIN_EXPORT int32_t pty_session_kill(
    PtySession *session,
    PtyError *out_error);
FFI_PLUGIN_EXPORT int32_t pty_session_send_signal(
    PtySession *session,
    int32_t signal_number,
    int32_t target,
    PtyError *out_error);
FFI_PLUGIN_EXPORT void pty_session_discard_output(PtySession *session);
FFI_PLUGIN_EXPORT void pty_session_begin_close(PtySession *session);
FFI_PLUGIN_EXPORT void pty_session_release(PtySession *session);
FFI_PLUGIN_EXPORT void pty_session_abandon(void *session);
FFI_PLUGIN_EXPORT void pty_debug_get_stats(PtyDebugStats *out_stats);

#ifdef __cplusplus
}
#endif

#endif
