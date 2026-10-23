#include "../pty_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void mutex_init(PtyMutex *mutex)
{
#if defined(_WIN32)
    InitializeCriticalSection(mutex);
#else
    pthread_mutex_init(mutex, NULL);
#endif
}

static void mutex_lock(PtyMutex *mutex)
{
#if defined(_WIN32)
    EnterCriticalSection(mutex);
#else
    pthread_mutex_lock(mutex);
#endif
}

static void mutex_unlock(PtyMutex *mutex)
{
#if defined(_WIN32)
    LeaveCriticalSection(mutex);
#else
    pthread_mutex_unlock(mutex);
#endif
}

static void mutex_dispose(PtyMutex *mutex)
{
#if defined(_WIN32)
    DeleteCriticalSection(mutex);
#else
    pthread_mutex_destroy(mutex);
#endif
}

void pty_write_queue_init(PtyWriteQueue *queue, uint64_t limit)
{
    if (queue == NULL) return;
    queue->head = NULL;
    queue->tail = NULL;
    queue->limit = limit;
    queue->queued_bytes = 0;
    queue->inflight_bytes = 0;
    queue->initialized = 0;
    mutex_init(&queue->mutex);
    queue->initialized = 1;
}

void pty_write_chunk_free(PtyWriteChunk *chunk)
{
    if (chunk == NULL) return;
    free(chunk->bytes);
    free(chunk);
}

void pty_write_queue_dispose(PtyWriteQueue *queue)
{
    if (queue == NULL || !queue->initialized) return;
    mutex_lock(&queue->mutex);
    PtyWriteChunk *chunk = queue->head;
    queue->head = NULL;
    queue->tail = NULL;
    queue->queued_bytes = 0;
    mutex_unlock(&queue->mutex);
    while (chunk != NULL) {
        PtyWriteChunk *next = chunk->next;
        pty_debug_pending_write_discarded(chunk->length - chunk->offset);
        pty_write_chunk_free(chunk);
        chunk = next;
    }
    mutex_dispose(&queue->mutex);
    queue->initialized = 0;
}

int pty_write_queue_try_enqueue(PtyWriteQueue *queue,
                                 const uint8_t *bytes,
                                 uint64_t length,
                                 uint64_t request_id)
{
    if (queue == NULL || !queue->initialized || (length != 0 && bytes == NULL)) {
        return PTY_WRITE_ERROR;
    }
    if (length == 0) return PTY_WRITE_ACCEPTED;
    if (length > SIZE_MAX || length > queue->limit) {
        return PTY_WRITE_BACKPRESSURED;
    }

    PtyWriteChunk *chunk = malloc(sizeof(*chunk));
    if (chunk == NULL) return PTY_WRITE_ERROR;
    chunk->bytes = malloc((size_t)length);
    if (chunk->bytes == NULL) {
        free(chunk);
        return PTY_WRITE_ERROR;
    }
    memcpy(chunk->bytes, bytes, (size_t)length);
    chunk->next = NULL;
    chunk->length = length;
    chunk->offset = 0;
    chunk->request_id = request_id;
    chunk->accounted_bytes = 0;

    mutex_lock(&queue->mutex);
    if (queue->queued_bytes > queue->limit ||
        queue->inflight_bytes > queue->limit - queue->queued_bytes ||
        length > queue->limit - queue->queued_bytes - queue->inflight_bytes) {
        mutex_unlock(&queue->mutex);
        pty_write_chunk_free(chunk);
        return PTY_WRITE_BACKPRESSURED;
    }
    if (queue->tail == NULL) {
        queue->head = chunk;
    } else {
        queue->tail->next = chunk;
    }
    queue->tail = chunk;
    queue->queued_bytes += length;
    pty_debug_pending_write_enqueued(length);
    mutex_unlock(&queue->mutex);
    return PTY_WRITE_ACCEPTED;
}

PtyWriteChunk *pty_write_queue_dequeue(PtyWriteQueue *queue)
{
    if (queue == NULL || !queue->initialized) return NULL;
    mutex_lock(&queue->mutex);
    PtyWriteChunk *chunk = queue->head;
    if (chunk != NULL) {
        queue->head = chunk->next;
        if (queue->head == NULL) queue->tail = NULL;
        const uint64_t remaining = chunk->length - chunk->offset;
        queue->queued_bytes -= remaining;
        queue->inflight_bytes += remaining;
        chunk->accounted_bytes = remaining;
        pty_debug_pending_write_started(remaining);
        chunk->next = NULL;
    }
    mutex_unlock(&queue->mutex);
    return chunk;
}

int pty_write_queue_requeue_front(PtyWriteQueue *queue, PtyWriteChunk *chunk)
{
    if (queue == NULL || !queue->initialized || chunk == NULL) {
        return PTY_WRITE_ERROR;
    }
    if (chunk->offset > chunk->length) return PTY_WRITE_ERROR;
    const uint64_t remaining = chunk->length - chunk->offset;
    mutex_lock(&queue->mutex);
    if (chunk->accounted_bytes < remaining ||
        queue->inflight_bytes < chunk->accounted_bytes) {
        mutex_unlock(&queue->mutex);
        return PTY_WRITE_BACKPRESSURED;
    }
    chunk->next = queue->head;
    queue->head = chunk;
    if (queue->tail == NULL) queue->tail = chunk;
    queue->inflight_bytes -= chunk->accounted_bytes;
    queue->queued_bytes += remaining;
    pty_debug_pending_write_requeued(chunk->accounted_bytes, remaining);
    chunk->accounted_bytes = remaining;
    mutex_unlock(&queue->mutex);
    return PTY_WRITE_ACCEPTED;
}

void pty_write_queue_complete_chunk(PtyWriteQueue *queue,
                                     PtyWriteChunk *chunk)
{
    if (chunk == NULL) return;
    uint64_t accounted_bytes = chunk->accounted_bytes;
    if (queue != NULL && queue->initialized) {
        mutex_lock(&queue->mutex);
        if (accounted_bytes > queue->inflight_bytes) {
            accounted_bytes = queue->inflight_bytes;
        }
        queue->inflight_bytes -= accounted_bytes;
        chunk->accounted_bytes = 0;
        mutex_unlock(&queue->mutex);
    }
    pty_debug_pending_write_completed(accounted_bytes);
    pty_write_chunk_free(chunk);
}

uint64_t pty_write_queue_pending_bytes(PtyWriteQueue *queue)
{
    if (queue == NULL || !queue->initialized) return 0;
    mutex_lock(&queue->mutex);
    const uint64_t pending = queue->queued_bytes + queue->inflight_bytes;
    mutex_unlock(&queue->mutex);
    return pending;
}

uint64_t pty_write_queue_queued_bytes(PtyWriteQueue *queue)
{
    if (queue == NULL || !queue->initialized) return 0;
    mutex_lock(&queue->mutex);
    const uint64_t queued = queue->queued_bytes;
    mutex_unlock(&queue->mutex);
    return queued;
}

uint64_t pty_write_queue_inflight_bytes(PtyWriteQueue *queue)
{
    if (queue == NULL || !queue->initialized) return 0;
    mutex_lock(&queue->mutex);
    const uint64_t inflight = queue->inflight_bytes;
    mutex_unlock(&queue->mutex);
    return inflight;
}
