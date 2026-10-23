#include "../pty_internal.h"

#include <stdlib.h>

void pty_session_init(PtySession *session)
{
    if (session == NULL) return;
#if defined(_WIN32)
    session->ref_count = 1;
    session->lifecycle = PTY_LIFECYCLE_STARTING;
    session->process_exited = 0;
    session->output_closed = 0;
    session->input_closed = 0;
    session->abandoned = 0;
#else
    atomic_init(&session->ref_count, 1);
    atomic_init(&session->lifecycle, PTY_LIFECYCLE_STARTING);
    atomic_init(&session->process_exited, 0);
    atomic_init(&session->output_closed, 0);
    atomic_init(&session->input_closed, 0);
    atomic_init(&session->abandoned, 0);
#endif
    session->event_port = 0;
    session->input_buffer_limit = 0;
    session->output_window_limit = 0;
    session->output_credit = 0;
    pty_session_platform_store(session, NULL);
    session->free_function = NULL;
    pty_debug_session_started();
}

void pty_session_retain(PtySession *session)
{
    if (session == NULL) return;
#if defined(_WIN32)
    InterlockedIncrement(&session->ref_count);
#else
    atomic_fetch_add_explicit(&session->ref_count, 1, memory_order_relaxed);
#endif
}

FFI_PLUGIN_EXPORT void pty_session_release(PtySession *session)
{
    if (session == NULL) return;
#if defined(_WIN32)
    const int should_free = InterlockedDecrement(&session->ref_count) == 0;
#else
    const int should_free = atomic_fetch_sub_explicit(
                                &session->ref_count,
                                1,
                                memory_order_acq_rel) == 1;
#endif
    if (!should_free) return;
    pty_debug_session_finished();
    if (session->free_function != NULL) {
        session->free_function(session);
        return;
    }
    free(session);
}

int pty_session_mark_abandoned(PtySession *session)
{
    if (session == NULL) return 0;
#if defined(_WIN32)
    return InterlockedExchange(&session->abandoned, 1) == 0;
#else
    return atomic_exchange_explicit(&session->abandoned,
                                    1,
                                    memory_order_acq_rel) == 0;
#endif
}

int pty_session_is_abandoned(PtySession *session)
{
    if (session == NULL) return 1;
#if defined(_WIN32)
    return InterlockedCompareExchange(&session->abandoned, 0, 0) != 0;
#else
    return atomic_load_explicit(&session->abandoned, memory_order_acquire) != 0;
#endif
}

void pty_session_mark_closing(PtySession *session)
{
    if (session == NULL) return;
#if defined(_WIN32)
    InterlockedExchange(&session->lifecycle, PTY_LIFECYCLE_CLOSING);
#else
    atomic_store_explicit(&session->lifecycle,
                          PTY_LIFECYCLE_CLOSING,
                          memory_order_release);
#endif
}

void pty_session_mark_closed(PtySession *session)
{
    if (session == NULL) return;
#if defined(_WIN32)
    InterlockedExchange(&session->lifecycle, PTY_LIFECYCLE_CLOSED);
#else
    atomic_store_explicit(&session->lifecycle,
                          PTY_LIFECYCLE_CLOSED,
                          memory_order_release);
#endif
}
