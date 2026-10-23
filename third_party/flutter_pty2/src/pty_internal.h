#ifndef FLUTTER_PTY_INTERNAL_H_
#define FLUTTER_PTY_INTERNAL_H_

#include <stdint.h>

#include "flutter_pty.h"
#include "include/dart_api_dl.h"

#if defined(_WIN32)
#include <windows.h>
typedef CRITICAL_SECTION PtyMutex;
#define PTY_MUTEX_INITIALIZER {0}
#else
#include <pthread.h>
#include <stdatomic.h>
typedef pthread_mutex_t PtyMutex;
#define PTY_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#endif

typedef enum PtyLifecycle {
    PTY_LIFECYCLE_STARTING = 0,
    PTY_LIFECYCLE_RUNNING = 1,
    PTY_LIFECYCLE_CLOSING = 2,
    PTY_LIFECYCLE_CLOSED = 3
} PtyLifecycle;

typedef void (*PtySessionFreeFunction)(PtySession *session);

/*
 * Ownership and synchronization:
 *
 * - The lifecycle, process/output/input state, and abandoned flag are atomic.
 * - event_port, the buffer limits, and free_function are immutable after
 *   pty_session_start initializes the session and publishes it to workers.
 * - output_credit is guarded by the platform mutex after platform publication;
 *   bootstrap initialization happens before any worker can observe it.
 * - platform is atomically published once during bootstrap and cleared only on
 *   a startup failure before the session can be released by a worker. Readers
 *   use acquire semantics so startup-close races never access a torn pointer.
 * - ref_count is atomic and owns the session allocation across all workers.
 */
struct PtySession {
#if defined(_WIN32)
    volatile LONG ref_count;
    volatile LONG lifecycle;
    volatile LONG process_exited;
    volatile LONG output_closed;
    volatile LONG input_closed;
    volatile LONG abandoned;
#else
    _Atomic uint32_t ref_count;
    _Atomic int lifecycle;
    _Atomic int process_exited;
    _Atomic int output_closed;
    _Atomic int input_closed;
    _Atomic int abandoned;
#endif

    Dart_Port_DL event_port;
    uint64_t input_buffer_limit;
    uint64_t output_window_limit;
    uint64_t output_credit;
#if defined(_WIN32)
    void *volatile platform;
#else
    _Atomic(void *) platform;
#endif
    PtySessionFreeFunction free_function;
};

static inline uint64_t pty_output_credit_after_ack(uint64_t credit,
                                                   uint64_t limit,
                                                   uint64_t byte_count)
{
    if (credit >= limit || byte_count > limit - credit) return limit;
    return credit + byte_count;
}

static inline void *pty_session_platform_load(PtySession *session)
{
    if (session == NULL) return NULL;
#if defined(_WIN32)
    return InterlockedCompareExchangePointer(
        (PVOID volatile *)&session->platform,
        NULL,
        NULL);
#else
    return atomic_load_explicit(&session->platform, memory_order_acquire);
#endif
}

static inline void pty_session_platform_store(PtySession *session,
                                               void *platform)
{
    if (session == NULL) return;
#if defined(_WIN32)
    InterlockedExchangePointer((PVOID volatile *)&session->platform, platform);
#else
    atomic_store_explicit(&session->platform, platform, memory_order_release);
#endif
}

void pty_session_init(PtySession *session);
void pty_session_retain(PtySession *session);
void pty_session_release(PtySession *session);
int pty_session_mark_abandoned(PtySession *session);
int pty_session_is_abandoned(PtySession *session);
void pty_session_mark_closing(PtySession *session);
void pty_session_mark_closed(PtySession *session);

typedef enum PtyDebugWorkerKind {
    PTY_DEBUG_WORKER_READ = 0,
    PTY_DEBUG_WORKER_WRITE = 1,
    PTY_DEBUG_WORKER_WAIT = 2,
    PTY_DEBUG_WORKER_CLOSE = 3,
    PTY_DEBUG_WORKER_PSEUDO_CONSOLE = 4
} PtyDebugWorkerKind;

void pty_debug_worker_started(PtyDebugWorkerKind kind);
void pty_debug_worker_finished(PtyDebugWorkerKind kind);
void pty_debug_session_started(void);
void pty_debug_session_finished(void);
void pty_debug_pending_write_enqueued(uint64_t bytes);
void pty_debug_pending_write_started(uint64_t bytes);
void pty_debug_pending_write_requeued(uint64_t inflight_bytes,
                                      uint64_t queued_bytes);
void pty_debug_pending_write_completed(uint64_t bytes);
void pty_debug_pending_write_discarded(uint64_t bytes);
void pty_debug_pseudo_console_close(void);
void pty_debug_pseudo_console_release(void);
void pty_debug_pseudo_console_close_worker(void);
void pty_debug_get_stats(PtyDebugStats *out_stats);

typedef struct PtyWriteChunk {
    struct PtyWriteChunk *next;
    uint8_t *bytes;
    uint64_t length;
    uint64_t offset;
    uint64_t request_id;
    uint64_t accounted_bytes;
} PtyWriteChunk;

typedef struct PtyWriteQueue {
    /*
     * mutex guards head, tail, queued_bytes, and inflight_bytes. limit is
     * immutable after initialization. initialized changes only during setup
     * and final disposal, after all queue users have stopped. A write chunk is
     * owned by either this queue or the caller that dequeued it, never both.
     */
    PtyMutex mutex;
    PtyWriteChunk *head;
    PtyWriteChunk *tail;
    uint64_t limit;
    uint64_t queued_bytes;
    uint64_t inflight_bytes;
    int initialized;
} PtyWriteQueue;

void pty_write_queue_init(PtyWriteQueue *queue, uint64_t limit);
void pty_write_queue_dispose(PtyWriteQueue *queue);
int pty_write_queue_try_enqueue(PtyWriteQueue *queue,
                                 const uint8_t *bytes,
                                 uint64_t length,
                                 uint64_t request_id);
PtyWriteChunk *pty_write_queue_dequeue(PtyWriteQueue *queue);
int pty_write_queue_requeue_front(PtyWriteQueue *queue, PtyWriteChunk *chunk);
void pty_write_queue_complete_chunk(PtyWriteQueue *queue,
                                     PtyWriteChunk *chunk);
void pty_write_chunk_free(PtyWriteChunk *chunk);
uint64_t pty_write_queue_pending_bytes(PtyWriteQueue *queue);
uint64_t pty_write_queue_queued_bytes(PtyWriteQueue *queue);
uint64_t pty_write_queue_inflight_bytes(PtyWriteQueue *queue);

#endif
