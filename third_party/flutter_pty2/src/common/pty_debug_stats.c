#include "../pty_internal.h"

#include <string.h>

#if defined(_WIN32)
static volatile LONG64 live_sessions;
static volatile LONG64 live_read_workers;
static volatile LONG64 live_write_workers;
static volatile LONG64 live_wait_workers;
static volatile LONG64 live_close_workers;
static volatile LONG64 live_pseudo_console_workers;
static volatile LONG64 pending_write_chunks;
static volatile LONG64 pending_write_bytes;
static volatile LONG64 inflight_write_bytes;
static volatile LONG64 pseudo_console_close_calls;
static volatile LONG64 pseudo_console_release_calls;
static volatile LONG64 pseudo_console_close_worker_calls;

static volatile LONG64 *worker_counter(PtyDebugWorkerKind kind)
{
    switch (kind) {
        case PTY_DEBUG_WORKER_READ:
            return &live_read_workers;
        case PTY_DEBUG_WORKER_WRITE:
            return &live_write_workers;
        case PTY_DEBUG_WORKER_WAIT:
            return &live_wait_workers;
        case PTY_DEBUG_WORKER_CLOSE:
            return &live_close_workers;
        case PTY_DEBUG_WORKER_PSEUDO_CONSOLE:
            return &live_pseudo_console_workers;
    }
    return NULL;
}

static void add_counter(volatile LONG64 *counter, uint64_t amount)
{
    if (counter == NULL) return;
    InterlockedAdd64(counter, (LONG64)amount);
}

static uint64_t read_counter(volatile LONG64 *counter)
{
    return counter == NULL ? 0 : (uint64_t)InterlockedCompareExchange64(
                                      counter, 0, 0);
}
#else
static _Atomic uint64_t live_sessions;
static _Atomic uint64_t live_read_workers;
static _Atomic uint64_t live_write_workers;
static _Atomic uint64_t live_wait_workers;
static _Atomic uint64_t live_close_workers;
static _Atomic uint64_t live_pseudo_console_workers;
static _Atomic uint64_t pending_write_chunks;
static _Atomic uint64_t pending_write_bytes;
static _Atomic uint64_t inflight_write_bytes;
static _Atomic uint64_t pseudo_console_close_calls;
static _Atomic uint64_t pseudo_console_release_calls;
static _Atomic uint64_t pseudo_console_close_worker_calls;

static _Atomic uint64_t *worker_counter(PtyDebugWorkerKind kind)
{
    switch (kind) {
        case PTY_DEBUG_WORKER_READ:
            return &live_read_workers;
        case PTY_DEBUG_WORKER_WRITE:
            return &live_write_workers;
        case PTY_DEBUG_WORKER_WAIT:
            return &live_wait_workers;
        case PTY_DEBUG_WORKER_CLOSE:
            return &live_close_workers;
        case PTY_DEBUG_WORKER_PSEUDO_CONSOLE:
            return &live_pseudo_console_workers;
    }
    return NULL;
}

static void add_counter(_Atomic uint64_t *counter, uint64_t amount)
{
    if (counter == NULL) return;
    atomic_fetch_add_explicit(counter, amount, memory_order_relaxed);
}

static uint64_t read_counter(_Atomic uint64_t *counter)
{
    return counter == NULL
               ? 0
               : atomic_load_explicit(counter, memory_order_acquire);
}
#endif

void pty_debug_worker_started(PtyDebugWorkerKind kind)
{
    add_counter(worker_counter(kind), 1);
}

void pty_debug_worker_finished(PtyDebugWorkerKind kind)
{
    add_counter(worker_counter(kind), (uint64_t)-1);
}

void pty_debug_session_started(void)
{
    add_counter(&live_sessions, 1);
}

void pty_debug_session_finished(void)
{
    add_counter(&live_sessions, (uint64_t)-1);
}

void pty_debug_pending_write_enqueued(uint64_t bytes)
{
    add_counter(&pending_write_chunks, 1);
    add_counter(&pending_write_bytes, bytes);
}

void pty_debug_pending_write_started(uint64_t bytes)
{
    add_counter(&pending_write_bytes, (uint64_t)-bytes);
    add_counter(&inflight_write_bytes, bytes);
}

void pty_debug_pending_write_requeued(uint64_t inflight_bytes,
                                      uint64_t queued_bytes)
{
    add_counter(&inflight_write_bytes, (uint64_t)-inflight_bytes);
    add_counter(&pending_write_bytes, queued_bytes);
}

void pty_debug_pending_write_completed(uint64_t bytes)
{
    add_counter(&pending_write_chunks, (uint64_t)-1);
    add_counter(&inflight_write_bytes, (uint64_t)-bytes);
}

void pty_debug_pending_write_discarded(uint64_t bytes)
{
    add_counter(&pending_write_chunks, (uint64_t)-1);
    add_counter(&pending_write_bytes, (uint64_t)-bytes);
}

void pty_debug_pseudo_console_close(void)
{
    add_counter(&pseudo_console_close_calls, 1);
}

void pty_debug_pseudo_console_release(void)
{
    add_counter(&pseudo_console_release_calls, 1);
}

void pty_debug_pseudo_console_close_worker(void)
{
    add_counter(&pseudo_console_close_worker_calls, 1);
}

FFI_PLUGIN_EXPORT void pty_debug_get_stats(PtyDebugStats *out_stats)
{
    if (out_stats == NULL) return;
    memset(out_stats, 0, sizeof(*out_stats));
    out_stats->live_sessions = read_counter(&live_sessions);
    out_stats->live_read_workers = read_counter(&live_read_workers);
    out_stats->live_write_workers = read_counter(&live_write_workers);
    out_stats->live_wait_workers = read_counter(&live_wait_workers);
    out_stats->live_close_workers = read_counter(&live_close_workers);
    out_stats->live_pseudo_console_workers =
        read_counter(&live_pseudo_console_workers);
    out_stats->pending_write_chunks = read_counter(&pending_write_chunks);
    out_stats->pending_write_bytes = read_counter(&pending_write_bytes);
    out_stats->inflight_write_bytes = read_counter(&inflight_write_bytes);
    out_stats->pseudo_console_close_calls =
        read_counter(&pseudo_console_close_calls);
    out_stats->pseudo_console_release_calls =
        read_counter(&pseudo_console_release_calls);
    out_stats->pseudo_console_close_worker_calls =
        read_counter(&pseudo_console_close_worker_calls);
}
