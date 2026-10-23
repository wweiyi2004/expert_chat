#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "../common/pty_error.h"
#include "../common/pty_event.h"
#include "../pty_internal.h"
#include "pty_windows_spawn.h"

#define PTY_WINDOWS_IO_BUFFER_SIZE (64 * 1024)

typedef HRESULT(WINAPI *PtyReleasePseudoConsoleFn)(HPCON pseudo_console);

typedef enum PtyPseudoConsoleState {
    PTY_PSEUDO_CONSOLE_OWNED = 0,
    PTY_PSEUDO_CONSOLE_RELEASED = 1,
    PTY_PSEUDO_CONSOLE_RELEASING = 2,
    PTY_PSEUDO_CONSOLE_CLOSING = 3,
    PTY_PSEUDO_CONSOLE_CLOSED = 4
} PtyPseudoConsoleState;

/*
 * The platform mutex guards stop/termination state, worker completion flags,
 * backpressure flags, input/output closure flags, and the closed-event guard.
 * The process, ConPTY, pipe, job, and process-id handles are initialized by
 * bootstrap before publication and remain stable until final teardown. Worker
 * handles and started flags are bootstrap-owned and are read during teardown
 * only after the corresponding worker has stopped. The write queue owns its
 * own mutex for chunk links and byte counts; whenever both mutexes are needed,
 * the platform mutex is acquired first. session->output_credit is protected
 * by this platform mutex. No platform mutex is held while a Dart event is
 * posted.
 */
typedef struct PtyWindowsPlatform {
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE condition;
    HANDLE input_write;
    HANDLE output_read;
    HPCON pseudo_console;
    PtyReleasePseudoConsoleFn release_pseudo_console;
    PtyPseudoConsoleState pseudo_console_state;
    HANDLE process;
    HANDLE job;
    DWORD process_id;
    HANDLE reader_thread;
    HANDLE writer_thread;
    HANDLE waiter_thread;
    HANDLE close_thread;
    HANDLE pseudo_console_close_thread;
    int reader_started;
    int writer_started;
    int waiter_started;
    int reader_done;
    int writer_done;
    int waiter_done;
    int close_started;
    int close_done;
    int pseudo_console_close_started;
    int pseudo_console_close_done;
    int stopping;
    int termination_requested;
    int write_backpressured;
    int discard_output;
    int output_closed;
    int input_closed;
    int session_closed_posted;
    PtyWriteQueue write_queue;
} PtyWindowsPlatform;

typedef struct PtyWindowsBootstrap {
    PtySession *session;
    PtyWindowsOwnedOptions options;
} PtyWindowsBootstrap;

static DWORD WINAPI windows_pseudo_console_close_worker(void *argument);
static void windows_start_pseudo_console_close_worker(PtySession *session);
static void windows_wait_for_pseudo_console_close(PtySession *session);

static PtyWindowsPlatform *windows_platform(PtySession *session)
{
    return (PtyWindowsPlatform *)pty_session_platform_load(session);
}

static PtyReleasePseudoConsoleFn lookup_release_pseudo_console(void)
{
    const HMODULE module = GetModuleHandleW(L"kernel32.dll");
    if (module == NULL) return NULL;
    const FARPROC address = GetProcAddress(module, "ReleasePseudoConsole");
    PtyReleasePseudoConsoleFn release_pseudo_console = NULL;
    memcpy(&release_pseudo_console,
           &address,
           sizeof(release_pseudo_console));
    return release_pseudo_console;
}

static int force_pseudo_console_close_worker(void)
{
    const char *value = getenv("PTY_TEST_FORCE_PSEUDO_CONSOLE_CLOSE_WORKER");
    return value != NULL && value[0] != '\0' && value[0] != '0';
}

static int force_close_worker_failure(void)
{
    const char *value = getenv("PTY_TEST_FORCE_CLOSE_THREAD_FAILURE");
    return value != NULL && value[0] != '\0' && value[0] != '0';
}

static void windows_mark_pseudo_console_closed(PtyWindowsPlatform *platform)
{
    EnterCriticalSection(&platform->mutex);
    platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_CLOSED;
    platform->pseudo_console_close_done = 1;
    WakeAllConditionVariable(&platform->condition);
    LeaveCriticalSection(&platform->mutex);
}

static void windows_close_pseudo_console_now(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL || platform->pseudo_console == NULL) return;

    HPCON pseudo_console = NULL;
    EnterCriticalSection(&platform->mutex);
    while (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_RELEASING) {
        SleepConditionVariableCS(&platform->condition,
                                 &platform->mutex,
                                 INFINITE);
    }
    if (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSED) {
        LeaveCriticalSection(&platform->mutex);
        return;
    }
    if (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSING) {
        LeaveCriticalSection(&platform->mutex);
        windows_wait_for_pseudo_console_close(session);
        return;
    }
    platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_CLOSING;
    platform->pseudo_console_close_started = 1;
    pseudo_console = platform->pseudo_console;
    LeaveCriticalSection(&platform->mutex);

    pty_debug_pseudo_console_close();
    ClosePseudoConsole(pseudo_console);
    windows_mark_pseudo_console_closed(platform);
}

static void windows_release_pseudo_console_ownership(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL || platform->pseudo_console == NULL) return;

    PtyReleasePseudoConsoleFn release_pseudo_console = NULL;
    HPCON pseudo_console = NULL;
    EnterCriticalSection(&platform->mutex);
    if (platform->pseudo_console_state != PTY_PSEUDO_CONSOLE_OWNED) {
        LeaveCriticalSection(&platform->mutex);
        return;
    }
    release_pseudo_console = platform->release_pseudo_console;
    pseudo_console = platform->pseudo_console;
    if (release_pseudo_console != NULL) {
        platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_RELEASING;
    }
    LeaveCriticalSection(&platform->mutex);

    if (release_pseudo_console != NULL) {
        const HRESULT result = release_pseudo_console(pseudo_console);
        EnterCriticalSection(&platform->mutex);
        if (SUCCEEDED(result)) {
            pty_debug_pseudo_console_release();
            platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_RELEASED;
            WakeAllConditionVariable(&platform->condition);
            LeaveCriticalSection(&platform->mutex);
            return;
        }
        platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_OWNED;
        WakeAllConditionVariable(&platform->condition);
        LeaveCriticalSection(&platform->mutex);
    }

    // On older Windows, or when the dynamic release call fails, the blocking
    // ownership release must run away from the output reader.
    windows_start_pseudo_console_close_worker(session);
}

static int handle_posted_session_event(PtySession *session, int posted)
{
    if (!posted) pty_session_abandon(session);
    return posted;
}

#define post_session_event(session, event) \
    (pty_session_is_abandoned(session) \
         ? 0 \
         : handle_posted_session_event((session), (event)))

static void windows_post_error(PtySession *session,
                               PtyErrorKind kind,
                               DWORD error_code,
                               const char *operation)
{
    PtyError error;
    pty_error_set(&error,
                  PTY_ERROR_DOMAIN_WIN32,
                  kind,
                  error_code,
                  operation);
    post_session_event(session, pty_post_error(session->event_port, &error));
}

static DWORD WINAPI windows_pseudo_console_close_worker(void *argument)
{
    PtySession *session = argument;
    PtyWindowsPlatform *platform = windows_platform(session);
    pty_debug_pseudo_console_close_worker();
    if (platform != NULL && platform->pseudo_console != NULL) {
        pty_debug_pseudo_console_close();
        ClosePseudoConsole(platform->pseudo_console);
        windows_mark_pseudo_console_closed(platform);
    }
    pty_debug_worker_finished(PTY_DEBUG_WORKER_PSEUDO_CONSOLE);
    pty_session_release(session);
    return 0;
}

static void windows_start_pseudo_console_close_worker(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL || platform->pseudo_console == NULL) return;

    EnterCriticalSection(&platform->mutex);
    while (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_RELEASING) {
        SleepConditionVariableCS(&platform->condition,
                                 &platform->mutex,
                                 INFINITE);
    }
    if (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSED ||
        platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSING) {
        LeaveCriticalSection(&platform->mutex);
        return;
    }
    platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_CLOSING;
    platform->pseudo_console_close_started = 1;
    LeaveCriticalSection(&platform->mutex);

    pty_debug_worker_started(PTY_DEBUG_WORKER_PSEUDO_CONSOLE);
    pty_session_retain(session);
    HANDLE thread = CreateThread(NULL,
                                 0,
                                 windows_pseudo_console_close_worker,
                                 session,
                                 0,
                                 NULL);
    if (thread != NULL) {
        EnterCriticalSection(&platform->mutex);
        platform->pseudo_console_close_thread = thread;
        LeaveCriticalSection(&platform->mutex);
        return;
    }

    // A thread allocation failure must not leave the HPCON in CLOSING forever.
    // This caller is never the output reader, so the blocking fallback is
    // safe and preserves exactly-once close semantics.
    pty_debug_worker_finished(PTY_DEBUG_WORKER_PSEUDO_CONSOLE);
    pty_session_release(session);
    pty_debug_pseudo_console_close();
    ClosePseudoConsole(platform->pseudo_console);
    windows_mark_pseudo_console_closed(platform);
}

static void windows_wait_for_pseudo_console_close(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;
    EnterCriticalSection(&platform->mutex);
    while (platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSING &&
           !platform->pseudo_console_close_done) {
        SleepConditionVariableCS(&platform->condition,
                                 &platform->mutex,
                                 INFINITE);
    }
    LeaveCriticalSection(&platform->mutex);
}

static void windows_mark_output_closed(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    int should_post = 0;
    EnterCriticalSection(&platform->mutex);
    if (!platform->output_closed) {
        platform->output_closed = 1;
        should_post = 1;
    }
    LeaveCriticalSection(&platform->mutex);
    if (should_post) {
        InterlockedExchange(&session->output_closed, 1);
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
    }
}

static void windows_mark_input_closed(PtySession *session,
                                      const PtyError *error)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    int should_post = 0;
    EnterCriticalSection(&platform->mutex);
    if (!platform->input_closed) {
        platform->input_closed = 1;
        should_post = 1;
    }
    LeaveCriticalSection(&platform->mutex);
    if (!should_post) return;
    InterlockedExchange(&session->input_closed, 1);
    if (error == NULL) {
        PtyError closed_error;
        pty_error_set(&closed_error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_CLOSED,
                      ERROR_BROKEN_PIPE,
                      "PTY input closed");
        post_session_event(
            session,
            pty_post_input_closed(session->event_port, &closed_error));
        return;
    }
    post_session_event(session,
                       pty_post_input_closed(session->event_port, error));
}

static void windows_discard_pending_writes(PtyWindowsPlatform *platform)
{
    if (platform == NULL) return;
    EnterCriticalSection(&platform->mutex);
    while (true) {
        PtyWriteChunk *chunk = pty_write_queue_dequeue(&platform->write_queue);
        if (chunk == NULL) break;
        pty_write_queue_complete_chunk(&platform->write_queue, chunk);
    }
    platform->write_backpressured = 0;
    LeaveCriticalSection(&platform->mutex);
}

static void windows_maybe_post_writable(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    int should_post = 0;
    EnterCriticalSection(&platform->mutex);
    if (platform->write_backpressured &&
        pty_write_queue_pending_bytes(&platform->write_queue) <=
            session->input_buffer_limit / 2) {
        platform->write_backpressured = 0;
        should_post = 1;
    }
    LeaveCriticalSection(&platform->mutex);
    if (!should_post) return;
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_WRITABLE));
}

static void windows_maybe_post_closed(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    int should_post = 0;
    EnterCriticalSection(&platform->mutex);
    if (platform->stopping && platform->reader_done && platform->writer_done &&
        platform->waiter_done && platform->close_done &&
        platform->pseudo_console_state == PTY_PSEUDO_CONSOLE_CLOSED &&
        !platform->session_closed_posted) {
        platform->session_closed_posted = 1;
        should_post = 1;
    }
    LeaveCriticalSection(&platform->mutex);
    if (!should_post) return;
    pty_session_mark_closed(session);
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
}

static DWORD WINAPI windows_reader(void *argument)
{
    PtySession *session = argument;
    PtyWindowsPlatform *platform = windows_platform(session);
    uint8_t buffer[PTY_WINDOWS_IO_BUFFER_SIZE];
    while (true) {
        EnterCriticalSection(&platform->mutex);
        while (session->output_credit == 0 && !platform->discard_output &&
               !platform->stopping) {
            SleepConditionVariableCS(&platform->condition,
                                     &platform->mutex,
                                     INFINITE);
        }
        const int stopping = platform->stopping;
        const int discard = platform->discard_output;
        const DWORD capacity = discard
                                   ? sizeof(buffer)
                                   : (DWORD)(session->output_credit <
                                                 sizeof(buffer)
                                             ? session->output_credit
                                             : sizeof(buffer));
        LeaveCriticalSection(&platform->mutex);
        if (stopping) break;

        DWORD length = 0;
        const BOOL read_succeeded = ReadFile(platform->output_read,
                                             buffer,
                                             capacity,
                                             &length,
                                             NULL);
        if (!read_succeeded || length == 0) {
            const DWORD read_error = read_succeeded ? ERROR_NO_DATA :
                                                       GetLastError();
            EnterCriticalSection(&platform->mutex);
            const int closing = platform->stopping;
            const int termination_requested = platform->termination_requested;
            LeaveCriticalSection(&platform->mutex);
            const int process_exited =
                InterlockedCompareExchange(&session->process_exited,
                                           0,
                                           0) != 0 ||
                WaitForSingleObject(platform->process, 0) == WAIT_OBJECT_0;
            if (!closing && !termination_requested && !process_exited) {
                windows_post_error(session,
                                   PTY_ERROR_IO,
                                   read_error,
                                   "reading ConPTY output failed");
            }
            break;
        }

        EnterCriticalSection(&platform->mutex);
        const int discard_after_read = platform->discard_output;
        if (!discard_after_read) {
            if (session->output_credit >= length) {
                session->output_credit -= length;
            } else {
                session->output_credit = 0;
            }
        }
        LeaveCriticalSection(&platform->mutex);
        if (discard_after_read) continue;
        if (!post_session_event(
                session,
                pty_post_output(session->event_port, buffer, length))) {
            break;
        }
    }
    windows_mark_output_closed(session);
    EnterCriticalSection(&platform->mutex);
    platform->reader_done = 1;
    LeaveCriticalSection(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_READ);
    windows_maybe_post_closed(session);
    pty_session_release(session);
    return 0;
}

static DWORD WINAPI windows_writer(void *argument)
{
    PtySession *session = argument;
    PtyWindowsPlatform *platform = windows_platform(session);
    while (true) {
        EnterCriticalSection(&platform->mutex);
        while (!platform->stopping &&
               InterlockedCompareExchange(&session->process_exited, 0, 0) ==
                   0 &&
               pty_write_queue_queued_bytes(&platform->write_queue) == 0) {
            SleepConditionVariableCS(&platform->condition,
                                     &platform->mutex,
                                     INFINITE);
        }
        const int stopping = platform->stopping;
        const int process_exited =
            InterlockedCompareExchange(&session->process_exited, 0, 0) != 0;
        const int queue_empty =
            pty_write_queue_queued_bytes(&platform->write_queue) == 0;
        LeaveCriticalSection(&platform->mutex);
        if (stopping || (process_exited && queue_empty)) break;

        PtyWriteChunk *chunk =
            pty_write_queue_dequeue(&platform->write_queue);
        if (chunk == NULL) continue;
        windows_maybe_post_writable(session);
        uint64_t offset = 0;
        int succeeded = 1;
        DWORD failure_error = ERROR_WRITE_FAULT;
        while (offset < chunk->length) {
            DWORD written = 0;
            const uint64_t remaining = chunk->length - offset;
            const DWORD requested = remaining > UINT32_MAX
                                        ? UINT32_MAX
                                        : (DWORD)remaining;
            const BOOL write_succeeded = WriteFile(platform->input_write,
                                                   chunk->bytes + offset,
                                                   requested,
                                                   &written,
                                                   NULL);
            if (!write_succeeded) {
                failure_error = GetLastError();
                succeeded = 0;
                break;
            }
            if (written == 0) {
                succeeded = 0;
                break;
            }
            offset += written;
        }
        if (succeeded) {
            post_session_event(
                session,
                pty_post_write_complete(session->event_port, chunk->request_id));
        } else {
            PtyError error;
            pty_error_set(&error,
                          PTY_ERROR_DOMAIN_WIN32,
                          PTY_ERROR_IO,
                          failure_error,
                          "writing ConPTY input failed");
            windows_mark_input_closed(session, &error);
            windows_discard_pending_writes(platform);
        }
        pty_write_queue_complete_chunk(&platform->write_queue, chunk);
        if (succeeded) windows_maybe_post_writable(session);
        if (!succeeded) break;
    }
    windows_mark_input_closed(session, NULL);
    EnterCriticalSection(&platform->mutex);
    platform->writer_done = 1;
    LeaveCriticalSection(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_WRITE);
    windows_maybe_post_closed(session);
    pty_session_release(session);
    return 0;
}

static DWORD WINAPI windows_waiter(void *argument)
{
    PtySession *session = argument;
    PtyWindowsPlatform *platform = windows_platform(session);
    const DWORD wait_result = WaitForSingleObject(platform->process, INFINITE);
    if (wait_result == WAIT_OBJECT_0) {
        InterlockedExchange(&session->process_exited, 1);
        EnterCriticalSection(&platform->mutex);
        WakeAllConditionVariable(&platform->condition);
        LeaveCriticalSection(&platform->mutex);
        DWORD exit_code = 1;
        if (GetExitCodeProcess(platform->process, &exit_code)) {
            post_session_event(
                session,
                pty_post_process_exit(session->event_port, false, exit_code));
        } else {
            windows_post_error(session,
                               PTY_ERROR_IO,
                               GetLastError(),
                               "reading ConPTY process exit failed");
        }
        windows_release_pseudo_console_ownership(session);
    } else if (wait_result == WAIT_FAILED) {
        windows_post_error(session,
                           PTY_ERROR_IO,
                           GetLastError(),
                           "waiting for ConPTY process failed");
    } else {
        windows_post_error(session,
                           PTY_ERROR_IO,
                           ERROR_INVALID_DATA,
                           "waiting for ConPTY process returned an invalid status");
    }
    if (wait_result != WAIT_OBJECT_0) {
        InterlockedExchange(&session->process_exited, 1);
    }
    EnterCriticalSection(&platform->mutex);
    WakeAllConditionVariable(&platform->condition);
    platform->waiter_done = 1;
    LeaveCriticalSection(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_WAIT);
    windows_maybe_post_closed(session);
    pty_session_release(session);
    return 0;
}

static void windows_stop_process(PtyWindowsPlatform *platform)
{
    if (platform == NULL) return;
    HANDLE reader_thread = NULL;
    HANDLE writer_thread = NULL;
    EnterCriticalSection(&platform->mutex);
    platform->stopping = 1;
    WakeAllConditionVariable(&platform->condition);
    if (platform->reader_started) reader_thread = platform->reader_thread;
    if (platform->writer_started) writer_thread = platform->writer_thread;
    LeaveCriticalSection(&platform->mutex);
    BOOL terminated = FALSE;
    if (platform->job != NULL) {
        terminated = TerminateJobObject(platform->job, 1);
    }
    if (!terminated && platform->process != NULL) {
        // Closing must not strand the waiter if Job Object termination is
        // unavailable or fails after the process has been created.
        TerminateProcess(platform->process, 1);
    }
    if (reader_thread != NULL) CancelSynchronousIo(reader_thread);
    if (writer_thread != NULL) CancelSynchronousIo(writer_thread);
}

static void windows_post_startup_cancelled(PtySession *session)
{
    PtyError error;
    pty_error_set(&error,
                  PTY_ERROR_DOMAIN_INTERNAL,
                  PTY_ERROR_CLOSED,
                  ERROR_OPERATION_ABORTED,
                  "PTY session closed during startup");
    post_session_event(session,
                       pty_post_spawn_failed(session->event_port, &error));
}

static void windows_finish_unstarted_close(PtySession *session,
                                           HANDLE process_thread)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;

    windows_stop_process(platform);
    WaitForSingleObject(platform->process, INFINITE);
    if (process_thread != NULL) CloseHandle(process_thread);
    windows_start_pseudo_console_close_worker(session);
    windows_wait_for_pseudo_console_close(session);

    EnterCriticalSection(&platform->mutex);
    platform->reader_done = 1;
    platform->writer_done = 1;
    platform->waiter_done = 1;
    platform->close_done = 1;
    platform->session_closed_posted = 1;
    LeaveCriticalSection(&platform->mutex);

    windows_post_startup_cancelled(session);
    windows_mark_output_closed(session);
    windows_mark_input_closed(session, NULL);
    pty_session_mark_closed(session);
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
}

static void windows_finish_worker_startup_failure(PtySession *session,
                                                  HANDLE process_thread,
                                                  const PtyError *error)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;

    int synchronous_close = 0;
    EnterCriticalSection(&platform->mutex);
    if (!platform->close_started) {
        // Reserve synchronous cleanup so a concurrent close cannot publish a
        // worker after this bootstrap path begins tearing down the session.
        platform->close_started = 1;
        synchronous_close = 1;
    }
    LeaveCriticalSection(&platform->mutex);

    windows_stop_process(platform);
    if (process_thread != NULL) {
        ResumeThread(process_thread);
        CloseHandle(process_thread);
    }
    if (platform->reader_started) {
        WaitForSingleObject(platform->reader_thread, INFINITE);
    }
    if (platform->writer_started) {
        WaitForSingleObject(platform->writer_thread, INFINITE);
    }
    if (platform->waiter_started) {
        WaitForSingleObject(platform->waiter_thread, INFINITE);
    }
    windows_start_pseudo_console_close_worker(session);
    windows_wait_for_pseudo_console_close(session);
    EnterCriticalSection(&platform->mutex);
    if (!platform->reader_started) platform->reader_done = 1;
    if (!platform->writer_started) platform->writer_done = 1;
    if (!platform->waiter_started) platform->waiter_done = 1;
    if (synchronous_close) platform->close_done = 1;
    LeaveCriticalSection(&platform->mutex);

    pty_session_mark_closing(session);
    post_session_event(session,
                       pty_post_spawn_failed(session->event_port, error));
    windows_mark_output_closed(session);
    windows_mark_input_closed(session, NULL);
    windows_maybe_post_closed(session);
}

static DWORD WINAPI windows_close_worker(void *argument)
{
    PtySession *session = argument;
    PtyWindowsPlatform *platform = windows_platform(session);
    windows_stop_process(platform);
    windows_start_pseudo_console_close_worker(session);
    windows_wait_for_pseudo_console_close(session);
    EnterCriticalSection(&platform->mutex);
    platform->close_done = 1;
    LeaveCriticalSection(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_CLOSE);
    windows_maybe_post_closed(session);
    pty_session_release(session);
    return 0;
}

static void windows_free_session(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform != NULL) {
        if (platform->reader_thread != NULL) CloseHandle(platform->reader_thread);
        if (platform->writer_thread != NULL) CloseHandle(platform->writer_thread);
        if (platform->waiter_thread != NULL) CloseHandle(platform->waiter_thread);
        if (platform->close_thread != NULL) CloseHandle(platform->close_thread);
        if (platform->pseudo_console_close_thread != NULL) {
            CloseHandle(platform->pseudo_console_close_thread);
        }
        if (platform->input_write != NULL) CloseHandle(platform->input_write);
        if (platform->output_read != NULL) CloseHandle(platform->output_read);
        if (platform->process != NULL) CloseHandle(platform->process);
        if (platform->job != NULL) CloseHandle(platform->job);
        windows_close_pseudo_console_now(session);
        pty_write_queue_dispose(&platform->write_queue);
        DeleteCriticalSection(&platform->mutex);
        free(platform);
    }
    free(session);
}

static DWORD WINAPI windows_bootstrap(void *argument)
{
    PtyWindowsBootstrap *bootstrap = argument;
    PtySession *session = bootstrap->session;
    HANDLE input_write = NULL;
    HANDLE output_read = NULL;
    HANDLE process = NULL;
    HANDLE process_thread = NULL;
    HANDLE job = NULL;
    HPCON pseudo_console = NULL;
    DWORD process_id = 0;
    DWORD worker_error = ERROR_NOT_ENOUGH_MEMORY;
    int worker_start_failed = 0;
    PtyError error;
    if (!pty_windows_create_process(&bootstrap->options.options,
                                    &input_write,
                                    &output_read,
                                    &process,
                                    &process_thread,
                                    &job,
                                    &process_id,
                                    &pseudo_console,
                                    &error)) {
        post_session_event(
            session,
            pty_post_spawn_failed(session->event_port, &error));
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
        pty_session_mark_closing(session);
        pty_session_mark_closed(session);
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }

    PtyWindowsPlatform *platform = calloc(1, sizeof(*platform));
    if (platform == NULL) {
        pty_error_set(&error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "allocating Windows PTY session failed");
        TerminateJobObject(job, 1);
        CloseHandle(process);
        CloseHandle(process_thread);
        CloseHandle(job);
        CloseHandle(input_write);
        CloseHandle(output_read);
        pty_debug_pseudo_console_close();
        ClosePseudoConsole(pseudo_console);
        post_session_event(
            session,
            pty_post_spawn_failed(session->event_port, &error));
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
        pty_session_mark_closing(session);
        pty_session_mark_closed(session);
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }
    InitializeCriticalSection(&platform->mutex);
    InitializeConditionVariable(&platform->condition);
    platform->input_write = input_write;
    platform->output_read = output_read;
    platform->pseudo_console = pseudo_console;
    platform->release_pseudo_console = force_pseudo_console_close_worker()
                                           ? NULL
                                           : lookup_release_pseudo_console();
    platform->pseudo_console_state = PTY_PSEUDO_CONSOLE_OWNED;
    platform->process = process;
    platform->job = job;
    platform->process_id = process_id;
    pty_write_queue_init(&platform->write_queue, session->input_buffer_limit);
    pty_session_platform_store(session, platform);

    const int close_requested =
        InterlockedCompareExchange(&session->lifecycle,
                                   PTY_LIFECYCLE_STARTING,
                                   PTY_LIFECYCLE_STARTING) ==
        PTY_LIFECYCLE_CLOSING;
    if (close_requested) {
        windows_finish_unstarted_close(session, process_thread);
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }

    pty_debug_worker_started(PTY_DEBUG_WORKER_READ);
    pty_session_retain(session);
    HANDLE reader_thread = CreateThread(NULL, 0, windows_reader, session, 0, NULL);
    const DWORD reader_error = reader_thread == NULL ? GetLastError() : 0;
    int cancel_reader = 0;
    EnterCriticalSection(&platform->mutex);
    platform->reader_thread = reader_thread;
    if (reader_thread != NULL) {
        platform->reader_started = 1;
        cancel_reader = platform->stopping;
    }
    LeaveCriticalSection(&platform->mutex);
    if (cancel_reader) CancelSynchronousIo(reader_thread);
    if (reader_thread == NULL) {
        worker_error = reader_error;
        worker_start_failed = 1;
        pty_debug_worker_finished(PTY_DEBUG_WORKER_READ);
        pty_session_release(session);
    }
    pty_debug_worker_started(PTY_DEBUG_WORKER_WRITE);
    pty_session_retain(session);
    HANDLE writer_thread = CreateThread(NULL, 0, windows_writer, session, 0, NULL);
    const DWORD writer_error = writer_thread == NULL ? GetLastError() : 0;
    int cancel_writer = 0;
    EnterCriticalSection(&platform->mutex);
    platform->writer_thread = writer_thread;
    if (writer_thread != NULL) {
        platform->writer_started = 1;
        cancel_writer = platform->stopping;
    }
    LeaveCriticalSection(&platform->mutex);
    if (cancel_writer) CancelSynchronousIo(writer_thread);
    if (writer_thread == NULL) {
        if (!worker_start_failed) worker_error = writer_error;
        worker_start_failed = 1;
        pty_debug_worker_finished(PTY_DEBUG_WORKER_WRITE);
        pty_session_release(session);
    }
    pty_debug_worker_started(PTY_DEBUG_WORKER_WAIT);
    pty_session_retain(session);
    HANDLE waiter_thread = CreateThread(NULL, 0, windows_waiter, session, 0, NULL);
    const DWORD waiter_error = waiter_thread == NULL ? GetLastError() : 0;
    EnterCriticalSection(&platform->mutex);
    platform->waiter_thread = waiter_thread;
    if (waiter_thread != NULL) platform->waiter_started = 1;
    LeaveCriticalSection(&platform->mutex);
    if (waiter_thread == NULL) {
        if (!worker_start_failed) worker_error = waiter_error;
        worker_start_failed = 1;
        pty_debug_worker_finished(PTY_DEBUG_WORKER_WAIT);
        pty_session_release(session);
    }
    if (!platform->reader_started || !platform->writer_started ||
        !platform->waiter_started) {
        pty_error_set(&error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INTERNAL,
                      worker_error,
                      "starting Windows PTY workers failed");
        windows_finish_worker_startup_failure(session, process_thread, &error);
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }

    if (InterlockedCompareExchange(&session->lifecycle,
                                   PTY_LIFECYCLE_RUNNING,
                                   PTY_LIFECYCLE_STARTING) !=
        PTY_LIFECYCLE_STARTING) {
        int synchronous_close = 0;
        EnterCriticalSection(&platform->mutex);
        if (!platform->close_started) {
            // Reserve synchronous cleanup so a concurrent close cannot
            // publish a worker after this bootstrap path begins teardown.
            platform->close_started = 1;
            synchronous_close = 1;
        }
        LeaveCriticalSection(&platform->mutex);

        windows_stop_process(platform);
        ResumeThread(process_thread);
        CloseHandle(process_thread);
        if (platform->reader_started) WaitForSingleObject(platform->reader_thread, INFINITE);
        if (platform->writer_started) WaitForSingleObject(platform->writer_thread, INFINITE);
        if (platform->waiter_started) WaitForSingleObject(platform->waiter_thread, INFINITE);
        windows_start_pseudo_console_close_worker(session);
        windows_wait_for_pseudo_console_close(session);
        if (synchronous_close) {
            EnterCriticalSection(&platform->mutex);
            platform->close_done = 1;
            LeaveCriticalSection(&platform->mutex);
        }
        windows_post_startup_cancelled(session);
        windows_maybe_post_closed(session);
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }
    if (ResumeThread(process_thread) == (DWORD)-1) {
        pty_error_set(&error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "resuming ConPTY process failed");
        windows_finish_worker_startup_failure(session, process_thread, &error);
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }
    CloseHandle(process_thread);
    post_session_event(
        session,
        pty_post_spawned(
            session->event_port,
            process_id,
            PTY_CAPABILITY_RELIABLE_PROCESS_TREE_KILL |
                PTY_CAPABILITY_CONPTY));
    pty_windows_free_options(&bootstrap->options);
    free(bootstrap);
    pty_session_release(session);
    return 0;
}

FFI_PLUGIN_EXPORT int32_t pty_session_start(const PtySpawnOptions *options,
                                            PtySession **out_session,
                                            PtyError *out_error)
{
    pty_error_clear(out_error);
    if (out_session != NULL) *out_session = NULL;
    if (Dart_PostCObject_DL == NULL) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INTERNAL,
                      0,
                      "Dart API is unavailable");
        return 0;
    }
    if (options == NULL || out_session == NULL || options->executable == NULL ||
        options->executable[0] == '\0' || options->argument_count < 0 ||
        options->environment_count < 0 || options->input_buffer_bytes == 0 ||
        options->output_window_bytes == 0 || !pty_size_is_valid(options->size)) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      ERROR_INVALID_PARAMETER,
                      "invalid Windows PTY session options");
        return 0;
    }
    PtySession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "allocating PTY session failed");
        return 0;
    }
    pty_session_init(session);
    session->event_port = (Dart_Port_DL)options->event_port;
    session->input_buffer_limit = options->input_buffer_bytes;
    session->output_window_limit = options->output_window_bytes;
    session->output_credit = options->output_window_bytes;
    session->free_function = windows_free_session;
    PtyWindowsBootstrap *bootstrap = calloc(1, sizeof(*bootstrap));
    if (bootstrap == NULL ||
        !pty_windows_clone_options(options, &bootstrap->options, out_error)) {
        if (bootstrap != NULL) pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }
    bootstrap->session = session;
    pty_session_retain(session);
    HANDLE thread = CreateThread(NULL, 0, windows_bootstrap, bootstrap, 0, NULL);
    if (thread == NULL) {
        const DWORD thread_error = GetLastError();
        pty_session_release(session);
        pty_windows_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_INTERNAL,
                      thread_error,
                      "starting PTY bootstrap failed");
        return 0;
    }
    CloseHandle(thread);
    *out_session = session;
    return 1;
}

FFI_PLUGIN_EXPORT int64_t pty_session_pid(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    return platform == NULL ? -1 : (int64_t)platform->process_id;
}

FFI_PLUGIN_EXPORT int32_t pty_session_try_write(PtySession *session,
                                                uint64_t request_id,
                                                const uint8_t *bytes,
                                                uint64_t length,
                                                PtyError *out_error)
{
    pty_error_clear(out_error);
    if (session == NULL || bytes == NULL || length == 0) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      ERROR_INVALID_PARAMETER,
                      "invalid PTY input write");
        return PTY_WRITE_ERROR;
    }
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return PTY_WRITE_CLOSED;
    EnterCriticalSection(&platform->mutex);
    const LONG lifecycle = InterlockedCompareExchange(&session->lifecycle,
                                                      PTY_LIFECYCLE_CLOSING,
                                                      PTY_LIFECYCLE_CLOSING);
    if (platform->stopping || platform->input_closed ||
        lifecycle >= PTY_LIFECYCLE_CLOSING) {
        LeaveCriticalSection(&platform->mutex);
        return PTY_WRITE_CLOSED;
    }
    const int result = pty_write_queue_try_enqueue(&platform->write_queue,
                                                   bytes,
                                                   length,
                                                   request_id);
    if (result == PTY_WRITE_BACKPRESSURED) {
        platform->write_backpressured = 1;
    }
    LeaveCriticalSection(&platform->mutex);
    if (result == PTY_WRITE_ERROR) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "queueing PTY input failed");
        return PTY_WRITE_ERROR;
    }
    if (result == PTY_WRITE_ACCEPTED) {
        EnterCriticalSection(&platform->mutex);
        WakeAllConditionVariable(&platform->condition);
        LeaveCriticalSection(&platform->mutex);
    }
    return result;
}

FFI_PLUGIN_EXPORT void pty_session_ack_output(PtySession *session,
                                              uint64_t byte_count)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;
    EnterCriticalSection(&platform->mutex);
    session->output_credit = pty_output_credit_after_ack(
        session->output_credit, session->output_window_limit, byte_count);
    WakeAllConditionVariable(&platform->condition);
    LeaveCriticalSection(&platform->mutex);
}

FFI_PLUGIN_EXPORT int32_t pty_session_resize(PtySession *session,
                                              PtySize size,
                                              PtyError *out_error)
{
    pty_error_clear(out_error);
    PtyWindowsPlatform *platform = windows_platform(session);
    if (!pty_size_is_valid(size)) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      ERROR_INVALID_PARAMETER,
                      "invalid Windows PTY size");
        return 0;
    }
    if (platform == NULL || platform->pseudo_console == NULL) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_CLOSED,
                      ERROR_INVALID_HANDLE,
                      "PTY session is closed");
        return 0;
    }
    const COORD console_size = {
        .X = (SHORT)size.columns,
        .Y = (SHORT)size.rows,
    };
    EnterCriticalSection(&platform->mutex);
    const LONG lifecycle = InterlockedCompareExchange(&session->lifecycle,
                                                      0,
                                                      0);
    if (platform->stopping || lifecycle >= PTY_LIFECYCLE_CLOSING) {
        LeaveCriticalSection(&platform->mutex);
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_CLOSED,
                      ERROR_OPERATION_ABORTED,
                      "PTY session is closed");
        return 0;
    }
    const HRESULT resize_result =
        ResizePseudoConsole(platform->pseudo_console, console_size);
    LeaveCriticalSection(&platform->mutex);
    if (FAILED(resize_result)) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_HRESULT,
                      PTY_ERROR_IO,
                      resize_result,
                      "resizing ConPTY failed");
        return 0;
    }
    return 1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_kill(PtySession *session,
                                           PtyError *out_error)
{
    pty_error_clear(out_error);
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL || platform->job == NULL) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_CLOSED,
                      ERROR_INVALID_HANDLE,
                      "PTY session is closed");
        return 0;
    }
    EnterCriticalSection(&platform->mutex);
    const LONG lifecycle = InterlockedCompareExchange(&session->lifecycle,
                                                      0,
                                                      0);
    if (platform->stopping || lifecycle >= PTY_LIFECYCLE_CLOSING) {
        LeaveCriticalSection(&platform->mutex);
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_CLOSED,
                      ERROR_OPERATION_ABORTED,
                      "PTY session is closed");
        return 0;
    }
    if (InterlockedCompareExchange(&session->process_exited, 0, 0) != 0) {
        LeaveCriticalSection(&platform->mutex);
        return 1;
    }
    platform->termination_requested = 1;
    const BOOL terminated = TerminateJobObject(platform->job, 1);
    const DWORD error_code = terminated ? ERROR_SUCCESS : GetLastError();
    if (!terminated) {
        const int process_exited =
            WaitForSingleObject(platform->process, 0) == WAIT_OBJECT_0;
        if (process_exited) {
            LeaveCriticalSection(&platform->mutex);
            return 1;
        }
    }
    if (!terminated) {
        platform->termination_requested = 0;
    }
    LeaveCriticalSection(&platform->mutex);
    if (!terminated) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_IO,
                      error_code,
                      "terminating PTY Job Object failed");
        return 0;
    }
    return 1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_send_signal(PtySession *session,
                                                  int32_t signal_number,
                                                  int32_t target,
                                                  PtyError *out_error)
{
    (void)session;
    (void)signal_number;
    (void)target;
    pty_error_set(out_error,
                  PTY_ERROR_DOMAIN_INTERNAL,
                  PTY_ERROR_UNSUPPORTED,
                  ERROR_CALL_NOT_IMPLEMENTED,
                  "POSIX signals are unsupported on Windows");
    return 0;
}

FFI_PLUGIN_EXPORT void pty_session_discard_output(PtySession *session)
{
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;
    EnterCriticalSection(&platform->mutex);
    platform->discard_output = 1;
    session->output_credit = session->output_window_limit;
    WakeAllConditionVariable(&platform->condition);
    LeaveCriticalSection(&platform->mutex);
}

static void windows_begin_close(PtySession *session,
                                int allow_blocking_fallback)
{
    if (session == NULL) return;
    while (true) {
        const LONG lifecycle = InterlockedCompareExchange(&session->lifecycle,
                                                          0,
                                                          0);
        if (lifecycle == PTY_LIFECYCLE_STARTING) {
            if (InterlockedCompareExchange(&session->lifecycle,
                                           PTY_LIFECYCLE_CLOSING,
                                           PTY_LIFECYCLE_STARTING) ==
                PTY_LIFECYCLE_STARTING) {
                return;
            }
            continue;
        }
        if (lifecycle != PTY_LIFECYCLE_RUNNING &&
            lifecycle != PTY_LIFECYCLE_CLOSING) {
            return;
        }
        if (lifecycle == PTY_LIFECYCLE_CLOSING) break;
        if (InterlockedCompareExchange(&session->lifecycle,
                                       PTY_LIFECYCLE_CLOSING,
                                       PTY_LIFECYCLE_RUNNING) ==
            PTY_LIFECYCLE_RUNNING) {
            break;
        }
    }
    PtyWindowsPlatform *platform = windows_platform(session);
    if (platform == NULL) return;
    EnterCriticalSection(&platform->mutex);
    if (platform->close_started || platform->close_done) {
        LeaveCriticalSection(&platform->mutex);
        return;
    }
    platform->close_started = 1;
    LeaveCriticalSection(&platform->mutex);
    pty_debug_worker_started(PTY_DEBUG_WORKER_CLOSE);
    // Keep the platform alive until the creator has published the worker
    // handle. The worker can finish immediately, and a failed Dart event
    // post may release the Dart-owned reference before this function returns.
    pty_session_retain(session);
    pty_session_retain(session);
    platform->close_thread = force_close_worker_failure()
                                 ? NULL
                                 : CreateThread(NULL,
                                                0,
                                                windows_close_worker,
                                                session,
                                                0,
                                                NULL);
    if (platform->close_thread != NULL) {
        pty_session_release(session);
        return;
    }

    pty_debug_worker_finished(PTY_DEBUG_WORKER_CLOSE);
    pty_session_release(session);
    pty_session_release(session);
    EnterCriticalSection(&platform->mutex);
    platform->stopping = 1;
    platform->close_done = 1;
    LeaveCriticalSection(&platform->mutex);
    windows_stop_process(platform);
    if (!allow_blocking_fallback) {
        // NativeFinalizer must return without waiting for a worker or the
        // potentially blocking ConPTY close. Existing workers retain the
        // session and will release ownership, or final refcount teardown will
        // perform the final close on a native worker thread.
        return;
    }
    windows_start_pseudo_console_close_worker(session);
    windows_wait_for_pseudo_console_close(session);
    windows_maybe_post_closed(session);
}

FFI_PLUGIN_EXPORT void pty_session_begin_close(PtySession *session)
{
    windows_begin_close(session, 1);
}

FFI_PLUGIN_EXPORT void pty_session_abandon(void *opaque_session)
{
    PtySession *session = opaque_session;
    if (session == NULL || !pty_session_mark_abandoned(session)) return;
    windows_begin_close(session, 0);
    pty_session_release(session);
}
