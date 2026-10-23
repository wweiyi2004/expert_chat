#include "pty_unix_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include "../common/pty_error.h"
#include "../common/pty_event.h"
#include "../pty_internal.h"

#define PTY_REACTOR_BUFFER_SIZE (16 * 1024)
#define PTY_WAKE_BUFFER_SIZE 64
#define PTY_WAITER_POLL_TIMEOUT_MS 10

typedef enum PtyReadResult {
    PTY_READ_CLOSED = 0,
    PTY_READ_EMPTY = 1,
    PTY_READ_DATA = 2,
    PTY_READ_CREDIT_EXHAUSTED = 3,
} PtyReadResult;

/*
 * The platform mutex guards all mutable session state in this structure:
 * descriptors that can be closed, stop/close flags, worker completion flags,
 * backpressure flags, output/input closure flags, and the closed-event guard.
 * process_id and the wake descriptors are immutable after bootstrap setup.
 * Worker handles and their started flags are bootstrap-owned and are read only
 * during teardown after the corresponding worker has stopped. The write queue
 * owns its own mutex for chunk links and byte counts. session->output_credit is
 * protected by this same platform mutex. No platform mutex is held while a
 * Dart event is posted.
 */
typedef struct PtyUnixPlatform {
    pthread_mutex_t mutex;
    int master_fd;
    int slave_fd;
    pid_t process_id;
    int wake_pipe[2];
    pthread_t reactor_thread;
    pthread_t waiter_thread;
    pthread_t close_thread;
    int reactor_started;
    int waiter_started;
    int reactor_done;
    int waiter_done;
    int close_started;
    int close_done;
    int stopping;
    int write_backpressured;
    int discard_output;
    int output_hung_up;
    int output_closed;
    int input_closed;
    int session_closed_posted;
    PtyWriteQueue write_queue;
} PtyUnixPlatform;

typedef struct PtyUnixBootstrap {
    PtySession *session;
    PtyUnixOwnedOptions options;
} PtyUnixBootstrap;

static PtyUnixPlatform *platform_for(PtySession *session)
{
    return (PtyUnixPlatform *)pty_session_platform_load(session);
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

static int create_detached_worker(pthread_t *thread,
                                  void *(*worker)(void *),
                                  void *argument)
{
    pthread_attr_t attributes;
    int result = pthread_attr_init(&attributes);
    if (result != 0) return result;
    result = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (result == 0) result = pthread_create(thread, &attributes, worker, argument);
    pthread_attr_destroy(&attributes);
    return result;
}

static void wake_reactor(PtyUnixPlatform *platform)
{
    const uint8_t marker = 1;
    while (true) {
        const ssize_t result = write(platform->wake_pipe[1], &marker, 1);
        if (result >= 0) return;
        if (errno == EINTR) continue;
        return;
    }
}

static void pty_unix_drain_wake_pipe(PtyUnixPlatform *platform)
{
    uint8_t buffer[PTY_WAKE_BUFFER_SIZE];
    while (true) {
        const ssize_t result = read(platform->wake_pipe[0], buffer, sizeof(buffer));
        if (result > 0) continue;
        if (result < 0 && errno == EINTR) continue;
        return;
    }
}

static int set_nonblocking_cloexec(int fd)
{
    const int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    const int descriptor_flags = fcntl(fd, F_GETFD);
    if (descriptor_flags < 0) return -1;
    return fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC);
}

static int create_wake_pipe(PtyUnixPlatform *platform)
{
    platform->wake_pipe[0] = -1;
    platform->wake_pipe[1] = -1;
    if (pipe(platform->wake_pipe) != 0) return -1;
    if (set_nonblocking_cloexec(platform->wake_pipe[0]) == 0 &&
        set_nonblocking_cloexec(platform->wake_pipe[1]) == 0) {
        return 0;
    }
    const int error_number = errno;
    close(platform->wake_pipe[0]);
    close(platform->wake_pipe[1]);
    platform->wake_pipe[0] = -1;
    platform->wake_pipe[1] = -1;
    errno = error_number;
    return -1;
}

static void post_child_error(PtySession *session,
                             PtyErrorKind kind,
                             int error_number,
                             const char *operation)
{
    PtyError error;
    pty_error_set_errno(&error, kind, error_number, operation);
    post_session_event(session, pty_post_error(session->event_port, &error));
}

static void maybe_post_session_closed(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    int should_post = 0;
    pthread_mutex_lock(&platform->mutex);
    if (platform->stopping && platform->reactor_done && platform->waiter_done &&
        platform->close_done &&
        !platform->session_closed_posted) {
        platform->session_closed_posted = 1;
        should_post = 1;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (!should_post) return;
    pty_session_mark_closed(session);
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
}

static void mark_output_closed(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    int should_post = 0;
    pthread_mutex_lock(&platform->mutex);
    if (!platform->output_closed) {
        platform->output_closed = 1;
        should_post = 1;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (!should_post) return;
    atomic_store_explicit(&session->output_closed, 1, memory_order_release);
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
}

static void mark_input_closed(PtySession *session, const PtyError *error)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    int should_post = 0;
    pthread_mutex_lock(&platform->mutex);
    if (!platform->input_closed) {
        platform->input_closed = 1;
        should_post = 1;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (!should_post) return;
    atomic_store_explicit(&session->input_closed, 1, memory_order_release);
    if (error == NULL) {
        PtyError closed_error;
        pty_error_set_errno(&closed_error,
                            PTY_ERROR_CLOSED,
                            EPIPE,
                            "PTY input closed");
        post_session_event(
            session,
            pty_post_input_closed(session->event_port, &closed_error));
        return;
    }
    post_session_event(session,
                       pty_post_input_closed(session->event_port, error));
}

static void discard_pending_writes(PtyUnixPlatform *platform)
{
    while (true) {
        PtyWriteChunk *chunk = pty_write_queue_dequeue(&platform->write_queue);
        if (chunk == NULL) return;
        pty_write_queue_complete_chunk(&platform->write_queue, chunk);
    }
}

static void maybe_post_writable(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    int should_post = 0;
    pthread_mutex_lock(&platform->mutex);
    if (platform->write_backpressured &&
        pty_write_queue_pending_bytes(&platform->write_queue) <=
            session->input_buffer_limit / 2) {
        platform->write_backpressured = 0;
        should_post = 1;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (!should_post) return;
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_WRITABLE));
}

static void close_slave(PtyUnixPlatform *platform)
{
    if (platform == NULL) return;
    pthread_mutex_lock(&platform->mutex);
    const int slave_fd = platform->slave_fd;
    platform->slave_fd = -1;
    pthread_mutex_unlock(&platform->mutex);
    if (slave_fd >= 0) close(slave_fd);
}

static int pty_unix_flush_write_queue(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return 0;
    pthread_mutex_lock(&platform->mutex);
    const int master_fd = platform->master_fd;
    pthread_mutex_unlock(&platform->mutex);
    if (master_fd < 0) return 0;
    while (true) {
        PtyWriteChunk *chunk = pty_write_queue_dequeue(&platform->write_queue);
        if (chunk == NULL) return 1;
        while (chunk->offset < chunk->length) {
            const ssize_t result = write(master_fd,
                                         chunk->bytes + chunk->offset,
                                         chunk->length - chunk->offset);
            if (result > 0) {
                chunk->offset += (uint64_t)result;
                continue;
            }
            if (result < 0 && errno == EINTR) continue;
            if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (pty_write_queue_requeue_front(&platform->write_queue,
                                                  chunk) != PTY_WRITE_ACCEPTED) {
                    pty_write_queue_complete_chunk(&platform->write_queue,
                                                   chunk);
                    PtyError error;
                    pty_error_set_errno(&error,
                                        PTY_ERROR_IO,
                                        ENOBUFS,
                                        "requeuing partial write failed");
                    mark_input_closed(session, &error);
                    return 0;
                }
                maybe_post_writable(session);
                return 1;
            }
            const int error_number = errno;
            pty_write_queue_complete_chunk(&platform->write_queue, chunk);
            PtyError error;
            pty_error_set_errno(&error, PTY_ERROR_IO, error_number,
                                "writing PTY input failed");
            mark_input_closed(session, &error);
            return 0;
        }
        post_session_event(
            session,
            pty_post_write_complete(session->event_port, chunk->request_id));
        pty_write_queue_complete_chunk(&platform->write_queue, chunk);
        maybe_post_writable(session);
    }
}

static int read_output(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return 0;
    uint8_t buffer[PTY_REACTOR_BUFFER_SIZE];
    pthread_mutex_lock(&platform->mutex);
    const int discard = platform->discard_output;
    const int master_fd = platform->master_fd;
    uint64_t credit = session->output_credit;
    if (master_fd < 0) {
        pthread_mutex_unlock(&platform->mutex);
        return PTY_READ_CLOSED;
    }
    if (!discard && credit == 0) {
        pthread_mutex_unlock(&platform->mutex);
        return PTY_READ_CREDIT_EXHAUSTED;
    }
    size_t capacity = sizeof(buffer);
    if (!discard && credit < capacity) {
        capacity = (size_t)credit;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (capacity == 0) return PTY_READ_CREDIT_EXHAUSTED;

    ssize_t result;
    do {
        result = read(master_fd, buffer, capacity);
    } while (result < 0 && errno == EINTR);
    if (result > 0) {
        if (!discard) {
            pthread_mutex_lock(&platform->mutex);
            const int discard_after_read = platform->discard_output;
            if (!discard_after_read) {
                if (session->output_credit >= (uint64_t)result) {
                    session->output_credit -= (uint64_t)result;
                } else {
                    session->output_credit = 0;
                }
            }
            pthread_mutex_unlock(&platform->mutex);
            if (discard_after_read) return PTY_READ_DATA;
            if (!post_session_event(
                    session,
                    pty_post_output(session->event_port, buffer, result))) {
                pthread_mutex_lock(&platform->mutex);
                platform->discard_output = 1;
                pthread_mutex_unlock(&platform->mutex);
                return PTY_READ_CLOSED;
            }
        }
        return PTY_READ_DATA;
    }
    if (result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
        return PTY_READ_EMPTY;
    }
    if (result == 0 || (result < 0 && errno == EIO)) return PTY_READ_CLOSED;
    if (result < 0) {
        post_child_error(session, PTY_ERROR_IO, errno, "reading PTY output failed");
    }
    return PTY_READ_CLOSED;
}

static void *reactor_worker(void *argument)
{
    PtySession *session = argument;
    PtyUnixPlatform *platform = platform_for(session);
    while (true) {
        pthread_mutex_lock(&platform->mutex);
        const int stopping = platform->stopping;
        const int discard = platform->discard_output;
        const int output_hung_up = platform->output_hung_up;
        const int has_writes =
            pty_write_queue_queued_bytes(&platform->write_queue) != 0;
        const uint64_t credit = session->output_credit;
        const int master_fd = platform->master_fd;
        const int wake_fd = platform->wake_pipe[0];
        pthread_mutex_unlock(&platform->mutex);
        if (stopping || master_fd < 0) break;

        short events = 0;
        if (discard || credit > 0) events |= POLLIN;
        if (has_writes && !output_hung_up) events |= POLLOUT;
        const int monitor_master = output_hung_up && events == 0 ? -1 : master_fd;
        struct pollfd descriptors[2] = {
            {.fd = monitor_master, .events = events},
            {.fd = wake_fd, .events = POLLIN},
        };
        int poll_result;
        do {
            poll_result = poll(descriptors, 2, -1);
        } while (poll_result < 0 && errno == EINTR);
        if (poll_result < 0) {
            post_child_error(session, PTY_ERROR_IO, errno, "polling PTY failed");
            break;
        }
        const int wake_ready = (descriptors[1].revents & POLLIN) != 0;
        if (wake_ready) {
            pty_unix_drain_wake_pipe(platform);
        }
        pthread_mutex_lock(&platform->mutex);
        const int stopping_after_wake = platform->stopping;
        pthread_mutex_unlock(&platform->mutex);
        if (stopping_after_wake) break;
        if (wake_ready && atomic_load_explicit(&session->process_exited,
                                               memory_order_acquire) &&
            (discard || credit > 0)) {
            while (true) {
                const int read_result = read_output(session);
                if (read_result == PTY_READ_DATA) continue;
                if (read_result == PTY_READ_EMPTY) close_slave(platform);
                if (read_result == PTY_READ_CLOSED) goto reactor_done;
                break;
            }
        }
        if ((descriptors[0].revents & POLLOUT) != 0 &&
            !pty_unix_flush_write_queue(session)) {
            discard_pending_writes(platform);
            pthread_mutex_lock(&platform->mutex);
            const int stopping_after_write_failure = platform->stopping;
            pthread_mutex_unlock(&platform->mutex);
            if (stopping_after_write_failure) break;
            continue;
        }
        int read_result = PTY_READ_EMPTY;
        int attempted_read = 0;
        if ((descriptors[0].revents & POLLIN) != 0) {
            attempted_read = 1;
            read_result = read_output(session);
            if (read_result == PTY_READ_CLOSED) break;
        }
        if ((descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            pthread_mutex_lock(&platform->mutex);
            platform->output_hung_up = 1;
            pthread_mutex_unlock(&platform->mutex);
            mark_input_closed(session, NULL);
            discard_pending_writes(platform);
            if (read_result != PTY_READ_DATA &&
                read_result != PTY_READ_CREDIT_EXHAUSTED) {
                read_result = read_output(session);
            }
            if (read_result == PTY_READ_CLOSED || read_result == PTY_READ_EMPTY) {
                break;
            }
            continue;
        }
        if (attempted_read && read_result == PTY_READ_EMPTY &&
            atomic_load_explicit(&session->process_exited, memory_order_acquire)) {
            close_slave(platform);
        }
    }
reactor_done:
    mark_output_closed(session);
    mark_input_closed(session, NULL);
    pthread_mutex_lock(&platform->mutex);
    const int master_fd = platform->master_fd;
    platform->master_fd = -1;
    platform->reactor_done = 1;
    pthread_mutex_unlock(&platform->mutex);
    if (master_fd >= 0) close(master_fd);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_READ);
    maybe_post_session_closed(session);
    pty_session_release(session);
    return NULL;
}

static void *waiter_worker(void *argument)
{
    PtySession *session = argument;
    PtyUnixPlatform *platform = platform_for(session);
    int status = 0;
    pid_t result = 0;
    int wait_error = 0;
    while (true) {
        pthread_mutex_lock(&platform->mutex);
        result = waitpid(platform->process_id, &status, WNOHANG);
        const int wait_errno = errno;
        const int reactor_done = platform->reactor_done;
        const int wake_fd = platform->wake_pipe[0];
        if (result == platform->process_id) {
            atomic_store_explicit(&session->process_exited,
                                  1,
                                  memory_order_release);
        }
        pthread_mutex_unlock(&platform->mutex);
        if (result == platform->process_id) break;
        if (result < 0 && wait_errno != EINTR) {
            wait_error = wait_errno;
            break;
        }

        struct pollfd descriptor = {
            .fd = reactor_done ? -1 : wake_fd,
            .events = POLLIN,
        };
        int poll_result;
        do {
            poll_result = poll(&descriptor,
                               1,
                               PTY_WAITER_POLL_TIMEOUT_MS);
        } while (poll_result < 0 && errno == EINTR);
        if (poll_result < 0) {
            wait_error = errno;
            break;
        }
    }
    if (result == platform->process_id) {
        wake_reactor(platform);
        if (WIFEXITED(status)) {
            post_session_event(
                session,
                pty_post_process_exit(session->event_port,
                                      false,
                                      WEXITSTATUS(status)));
        } else if (WIFSIGNALED(status)) {
            post_session_event(
                session,
                pty_post_process_exit(session->event_port,
                                      true,
                                      WTERMSIG(status)));
        }
    } else if (wait_error != 0) {
        post_child_error(session,
                         PTY_ERROR_IO,
                         wait_error,
                         "waiting for PTY process failed");
        atomic_store_explicit(&session->process_exited, 1, memory_order_release);
        wake_reactor(platform);
    }
    pthread_mutex_lock(&platform->mutex);
    platform->waiter_done = 1;
    pthread_mutex_unlock(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_WAIT);
    maybe_post_session_closed(session);
    pty_session_release(session);
    return NULL;
}

static void free_unix_session(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform != NULL) {
        if (platform->master_fd >= 0) close(platform->master_fd);
        if (platform->slave_fd >= 0) close(platform->slave_fd);
        if (platform->wake_pipe[0] >= 0) close(platform->wake_pipe[0]);
        if (platform->wake_pipe[1] >= 0) close(platform->wake_pipe[1]);
        pty_write_queue_dispose(&platform->write_queue);
        pthread_mutex_destroy(&platform->mutex);
        free(platform);
    }
    free(session);
}

static void stop_process(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL || platform->process_id <= 0) return;
    pthread_mutex_lock(&platform->mutex);
    if (atomic_load_explicit(&session->process_exited, memory_order_acquire)) {
        pthread_mutex_unlock(&platform->mutex);
        return;
    }
    const int master_fd = platform->master_fd;
    const pid_t process_id = platform->process_id;
    const pid_t foreground = master_fd >= 0 ? tcgetpgrp(master_fd) : -1;
    if (foreground > 0) kill(-foreground, SIGKILL);
    kill(-process_id, SIGKILL);
    kill(process_id, SIGKILL);
    pthread_mutex_unlock(&platform->mutex);
}

static void cleanup_spawned_process(pid_t process_id)
{
    if (process_id <= 0) return;
    kill(-process_id, SIGKILL);
    kill(process_id, SIGKILL);
    while (waitpid(process_id, NULL, 0) < 0 && errno == EINTR) {}
}

static void post_startup_cancelled(PtySession *session)
{
    PtyError error;
    pty_error_set(&error,
                  PTY_ERROR_DOMAIN_INTERNAL,
                  PTY_ERROR_CLOSED,
                  EPIPE,
                  "PTY session closed during startup");
    post_session_event(session,
                       pty_post_spawn_failed(session->event_port, &error));
}

static void finish_unstarted_close(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;

    stop_process(session);

    pthread_mutex_lock(&platform->mutex);
    const int master_fd = platform->master_fd;
    const int slave_fd = platform->slave_fd;
    platform->master_fd = -1;
    platform->slave_fd = -1;
    platform->stopping = 1;
    platform->reactor_done = 1;
    platform->waiter_done = 1;
    platform->close_done = 1;
    platform->output_closed = 1;
    platform->session_closed_posted = 1;
    pthread_mutex_unlock(&platform->mutex);

    if (master_fd >= 0) close(master_fd);
    if (slave_fd >= 0) close(slave_fd);
    while (waitpid(platform->process_id, NULL, 0) < 0 && errno == EINTR) {}

    post_startup_cancelled(session);
    atomic_store_explicit(&session->output_closed, 1, memory_order_release);
    pty_session_mark_closed(session);
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
    post_session_event(
        session,
        pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
}

static void *close_worker(void *argument)
{
    PtySession *session = argument;
    PtyUnixPlatform *platform = platform_for(session);
    pthread_mutex_lock(&platform->mutex);
    platform->stopping = 1;
    pthread_mutex_unlock(&platform->mutex);
    stop_process(session);
    wake_reactor(platform);
    pthread_mutex_lock(&platform->mutex);
    platform->close_done = 1;
    pthread_mutex_unlock(&platform->mutex);
    pty_debug_worker_finished(PTY_DEBUG_WORKER_CLOSE);
    maybe_post_session_closed(session);
    pty_session_release(session);
    return NULL;
}

static void *bootstrap_worker(void *argument)
{
    PtyUnixBootstrap *bootstrap = argument;
    PtySession *session = bootstrap->session;
    int master_fd = -1;
    int slave_fd = -1;
    pid_t process_id = -1;
    PtyError error;
    if (!pty_unix_spawn(&bootstrap->options.options,
                        &master_fd,
                        &slave_fd,
                        &process_id,
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
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }

    PtyUnixPlatform *platform = calloc(1, sizeof(*platform));
    int setup_error = ENOMEM;
    int mutex_initialized = 0;
    if (platform != NULL) {
        platform->master_fd = -1;
        platform->slave_fd = -1;
        platform->wake_pipe[0] = -1;
        platform->wake_pipe[1] = -1;
        const int mutex_result = pthread_mutex_init(&platform->mutex, NULL);
        if (mutex_result == 0) {
            mutex_initialized = 1;
        } else {
            setup_error = mutex_result;
        }
    }
    int retained_slave_fd = -1;
    if (platform != NULL && mutex_initialized) {
        if (create_wake_pipe(platform) == 0) {
            retained_slave_fd = fcntl(slave_fd, F_DUPFD_CLOEXEC, 4);
            if (retained_slave_fd >= 0) {
                close(slave_fd);
                slave_fd = retained_slave_fd;
            } else {
                setup_error = errno;
            }
        } else {
            setup_error = errno;
        }
    }
    if (platform == NULL || !mutex_initialized || retained_slave_fd < 0) {
        if (platform != NULL) {
            if (platform->wake_pipe[0] >= 0) close(platform->wake_pipe[0]);
            if (platform->wake_pipe[1] >= 0) close(platform->wake_pipe[1]);
            if (mutex_initialized) pthread_mutex_destroy(&platform->mutex);
            free(platform);
        }
        close(master_fd);
        close(slave_fd);
        cleanup_spawned_process(process_id);
        pty_error_set_errno(&error, PTY_ERROR_OUT_OF_MEMORY, setup_error,
                            "allocating Unix PTY session failed");
        post_session_event(session,
                           pty_post_spawn_failed(session->event_port, &error));
        pty_session_mark_closing(session);
        pty_session_mark_closed(session);
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_SESSION_CLOSED));
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }
    platform->master_fd = master_fd;
    platform->slave_fd = slave_fd;
    platform->process_id = process_id;
    pty_write_queue_init(&platform->write_queue,
                         session->input_buffer_limit);
    pty_session_platform_store(session, platform);

    pthread_mutex_lock(&platform->mutex);
    const int closing = platform->stopping ||
                        atomic_load_explicit(&session->lifecycle,
                                             memory_order_acquire) ==
                            PTY_LIFECYCLE_CLOSING;
    pthread_mutex_unlock(&platform->mutex);
    if (closing) {
        finish_unstarted_close(session);
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }

    pty_debug_worker_started(PTY_DEBUG_WORKER_READ);
    pty_session_retain(session);
    const int reactor_result = create_detached_worker(&platform->reactor_thread,
                                                      reactor_worker,
                                                      session);
    if (reactor_result != 0) {
        pty_debug_worker_finished(PTY_DEBUG_WORKER_READ);
        pty_session_release(session);
        pty_session_mark_closing(session);
        stop_process(session);
        while (waitpid(process_id, NULL, 0) < 0 && errno == EINTR) {}

        int post_session_closed = 0;
        pthread_mutex_lock(&platform->mutex);
        platform->stopping = 1;
        platform->reactor_done = 1;
        platform->waiter_done = 1;
        platform->output_closed = 1;
        if (!platform->close_started) {
            // Reserve the synchronous cleanup path so a concurrent close
            // cannot start a worker after this bootstrap worker returns.
            platform->close_started = 1;
            platform->close_done = 1;
            platform->session_closed_posted = 1;
            post_session_closed = 1;
        }
        pthread_mutex_unlock(&platform->mutex);

        pty_error_set_errno(&error, PTY_ERROR_INTERNAL, reactor_result,
                            "starting PTY reactor failed");
        post_session_event(
            session,
            pty_post_spawn_failed(session->event_port, &error));
        atomic_store_explicit(&session->output_closed, 1, memory_order_release);
        post_session_event(
            session,
            pty_post_simple_event(session->event_port, PTY_EVENT_OUTPUT_CLOSED));
        if (post_session_closed) {
            pty_session_mark_closed(session);
            post_session_event(
                session,
                pty_post_simple_event(session->event_port,
                                      PTY_EVENT_SESSION_CLOSED));
        } else {
            maybe_post_session_closed(session);
        }
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }
    platform->reactor_started = 1;
    pty_debug_worker_started(PTY_DEBUG_WORKER_WAIT);
    pty_session_retain(session);
    const int waiter_result = create_detached_worker(&platform->waiter_thread,
                                                     waiter_worker,
                                                     session);
    if (waiter_result != 0) {
        pty_debug_worker_finished(PTY_DEBUG_WORKER_WAIT);
        pty_session_release(session);
        pthread_mutex_lock(&platform->mutex);
        platform->stopping = 1;
        platform->waiter_done = 1;
        if (!platform->close_started) {
            // Reserve synchronous cleanup so a concurrent close cannot start
            // a worker after this bootstrap worker returns.
            platform->close_started = 1;
            platform->close_done = 1;
        }
        pthread_mutex_unlock(&platform->mutex);
        stop_process(session);
        wake_reactor(platform);
        while (waitpid(process_id, NULL, 0) < 0 && errno == EINTR) {}
        pty_error_set_errno(&error, PTY_ERROR_INTERNAL, waiter_result,
                            "starting PTY waiter failed");
        pty_session_mark_closing(session);
        post_session_event(session,
                           pty_post_spawn_failed(session->event_port, &error));
        maybe_post_session_closed(session);
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }
    platform->waiter_started = 1;
    int expected_lifecycle = PTY_LIFECYCLE_STARTING;
    if (!atomic_compare_exchange_strong_explicit(&session->lifecycle,
                                                 &expected_lifecycle,
                                                 PTY_LIFECYCLE_RUNNING,
                                                 memory_order_acq_rel,
                                                 memory_order_acquire)) {
        pthread_mutex_lock(&platform->mutex);
        platform->stopping = 1;
        if (!platform->close_started) {
            // The lifecycle transition can race close() before the close
            // worker is published. Reserve cleanup for this bootstrap path.
            platform->close_started = 1;
            platform->close_done = 1;
        }
        pthread_mutex_unlock(&platform->mutex);
        stop_process(session);
        wake_reactor(platform);
        post_startup_cancelled(session);
        maybe_post_session_closed(session);
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return NULL;
    }
    post_session_event(
        session,
        pty_post_spawned(
            session->event_port,
            process_id,
            PTY_CAPABILITY_POSIX_SIGNALS |
                PTY_CAPABILITY_FOREGROUND_PROCESS_GROUPS |
                PTY_CAPABILITY_PIXEL_DIMENSIONS));
    pty_unix_free_options(&bootstrap->options);
    free(bootstrap);
    pty_session_release(session);
    return NULL;
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
                      EINVAL,
                      "invalid PTY session options");
        return 0;
    }
    PtySession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "allocating PTY session failed");
        return 0;
    }
    pty_session_init(session);
    session->event_port = (Dart_Port_DL)options->event_port;
    session->input_buffer_limit = options->input_buffer_bytes;
    session->output_window_limit = options->output_window_bytes;
    session->output_credit = options->output_window_bytes;
    session->free_function = free_unix_session;

    PtyUnixBootstrap *bootstrap = calloc(1, sizeof(*bootstrap));
    if (bootstrap == NULL) {
        pty_session_release(session);
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "allocating PTY bootstrap failed");
        return 0;
    }
    if (!pty_unix_clone_options(options, &bootstrap->options, out_error)) {
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        return 0;
    }
    bootstrap->session = session;
    pty_session_retain(session);
    pthread_t bootstrap_thread;
    const int bootstrap_result = pthread_create(&bootstrap_thread,
                                                NULL,
                                                bootstrap_worker,
                                                bootstrap);
    if (bootstrap_result != 0) {
        pty_session_release(session);
        pty_unix_free_options(&bootstrap->options);
        free(bootstrap);
        pty_session_release(session);
        pty_error_set_errno(out_error, PTY_ERROR_INTERNAL, bootstrap_result,
                            "starting PTY bootstrap failed");
        return 0;
    }
    pthread_detach(bootstrap_thread);
    *out_session = session;
    return 1;
}

FFI_PLUGIN_EXPORT int64_t pty_session_pid(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    return platform == NULL ? -1 : platform->process_id;
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
                      EINVAL,
                      "invalid PTY input write");
        return PTY_WRITE_ERROR;
    }
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return PTY_WRITE_CLOSED;
    pthread_mutex_lock(&platform->mutex);
    if (platform->stopping || platform->input_closed ||
        atomic_load_explicit(&session->lifecycle, memory_order_acquire) >=
            PTY_LIFECYCLE_CLOSING) {
        pthread_mutex_unlock(&platform->mutex);
        return PTY_WRITE_CLOSED;
    }
    const int result = pty_write_queue_try_enqueue(&platform->write_queue,
                                                   bytes,
                                                   length,
                                                   request_id);
    if (result == PTY_WRITE_BACKPRESSURED) {
        platform->write_backpressured = 1;
    }
    pthread_mutex_unlock(&platform->mutex);
    if (result == PTY_WRITE_ERROR) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "queueing PTY input failed");
        return PTY_WRITE_ERROR;
    }
    if (result == PTY_WRITE_ACCEPTED) wake_reactor(platform);
    return result;
}

FFI_PLUGIN_EXPORT void pty_session_ack_output(PtySession *session,
                                              uint64_t byte_count)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    pthread_mutex_lock(&platform->mutex);
    session->output_credit = pty_output_credit_after_ack(
        session->output_credit, session->output_window_limit, byte_count);
    pthread_mutex_unlock(&platform->mutex);
    wake_reactor(platform);
}

FFI_PLUGIN_EXPORT int32_t pty_session_resize(PtySession *session,
                                              PtySize size,
                                              PtyError *out_error)
{
    pty_error_clear(out_error);
    PtyUnixPlatform *platform = platform_for(session);
    if (!pty_size_is_valid(size)) {
        pty_error_set(out_error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      EINVAL,
                      "invalid Unix PTY size");
        return 0;
    }
    if (platform == NULL) {
        pty_error_set(out_error, PTY_ERROR_DOMAIN_INTERNAL, PTY_ERROR_CLOSED,
                      EPIPE, "PTY session is closed");
        return 0;
    }
    struct winsize window = {
        .ws_row = (unsigned short)size.rows,
        .ws_col = (unsigned short)size.columns,
        .ws_xpixel = (unsigned short)size.pixel_width,
        .ws_ypixel = (unsigned short)size.pixel_height,
    };
    pthread_mutex_lock(&platform->mutex);
    const int master_fd = platform->master_fd;
    const int result = master_fd >= 0 ? ioctl(master_fd, TIOCSWINSZ, &window) : -1;
    const int error_number = errno;
    pthread_mutex_unlock(&platform->mutex);
    if (result != 0) {
        if (master_fd < 0) {
            pty_error_set(out_error, PTY_ERROR_DOMAIN_INTERNAL, PTY_ERROR_CLOSED,
                          EPIPE, "PTY session is closed");
            return 0;
        }
        pty_error_set_errno(out_error, PTY_ERROR_IO, error_number,
                            "resizing PTY failed");
        return 0;
    }
    return 1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_kill(PtySession *session,
                                           PtyError *out_error)
{
    pty_error_clear(out_error);
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) {
        pty_error_set(out_error, PTY_ERROR_DOMAIN_INTERNAL, PTY_ERROR_CLOSED,
                      EPIPE, "PTY session is closed");
        return 0;
    }
    stop_process(session);
    wake_reactor(platform);
    return 1;
}

FFI_PLUGIN_EXPORT int32_t pty_session_send_signal(PtySession *session,
                                                  int32_t signal_number,
                                                  int32_t target,
                                                  PtyError *out_error)
{
    pty_error_clear(out_error);
    if (signal_number <= 0 || signal_number > 64 || target < 0 || target > 2) {
        pty_error_set(out_error, PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT, EINVAL,
                      "invalid POSIX signal target");
        return 0;
    }
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) {
        pty_error_set(out_error, PTY_ERROR_DOMAIN_INTERNAL, PTY_ERROR_CLOSED,
                      EPIPE, "PTY session is closed");
        return 0;
    }
    pthread_mutex_lock(&platform->mutex);
    if (atomic_load_explicit(&session->process_exited, memory_order_acquire)) {
        pthread_mutex_unlock(&platform->mutex);
        return 1;
    }
    const pid_t process_id = platform->process_id;
    pid_t target_pid = process_id;
    if (target == 1) target_pid = -process_id;
    if (target == 2) {
        const int master_fd = platform->master_fd;
        const pid_t foreground = master_fd >= 0 ? tcgetpgrp(master_fd) : -1;
        if (foreground <= 0) {
            pthread_mutex_unlock(&platform->mutex);
            pty_error_set_errno(out_error, PTY_ERROR_IO, errno,
                                "finding foreground process group failed");
            return 0;
        }
        target_pid = -foreground;
    }
    const int result = kill(target_pid, signal_number);
    const int error_number = errno;
    pthread_mutex_unlock(&platform->mutex);
    if (result != 0 && error_number != ESRCH) {
        pty_error_set_errno(out_error, PTY_ERROR_IO, error_number,
                            "sending POSIX signal failed");
        return 0;
    }
    return 1;
}

FFI_PLUGIN_EXPORT void pty_session_discard_output(PtySession *session)
{
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    pthread_mutex_lock(&platform->mutex);
    platform->discard_output = 1;
    pthread_mutex_unlock(&platform->mutex);
    wake_reactor(platform);
}

FFI_PLUGIN_EXPORT void pty_session_begin_close(PtySession *session)
{
    if (session == NULL) return;
    while (true) {
        const int lifecycle = atomic_load_explicit(&session->lifecycle,
                                                   memory_order_acquire);
        if (lifecycle == PTY_LIFECYCLE_STARTING) {
            int expected_lifecycle = PTY_LIFECYCLE_STARTING;
            if (atomic_compare_exchange_strong_explicit(
                    &session->lifecycle,
                    &expected_lifecycle,
                    PTY_LIFECYCLE_CLOSING,
                    memory_order_acq_rel,
                    memory_order_acquire)) {
                return;
            }
            continue;
        }
        if (lifecycle != PTY_LIFECYCLE_RUNNING &&
            lifecycle != PTY_LIFECYCLE_CLOSING) {
            return;
        }
        if (lifecycle == PTY_LIFECYCLE_CLOSING) break;
        int expected_lifecycle = PTY_LIFECYCLE_RUNNING;
        if (!atomic_compare_exchange_strong_explicit(
                &session->lifecycle,
                &expected_lifecycle,
                PTY_LIFECYCLE_CLOSING,
                memory_order_acq_rel,
                memory_order_acquire)) {
            continue;
        }
        break;
    }
    PtyUnixPlatform *platform = platform_for(session);
    if (platform == NULL) return;
    pthread_mutex_lock(&platform->mutex);
    if (platform->close_started || platform->close_done) {
        pthread_mutex_unlock(&platform->mutex);
        return;
    }
    platform->close_started = 1;
    pthread_mutex_unlock(&platform->mutex);
    pty_debug_worker_started(PTY_DEBUG_WORKER_CLOSE);
    // Keep the platform alive until the creator has published the detached
    // worker handle. The worker can finish immediately, and a failed Dart
    // event post may release the Dart-owned reference before this function
    // returns.
    pty_session_retain(session);
    pty_session_retain(session);
    const int result = create_detached_worker(&platform->close_thread,
                                              close_worker,
                                              session);
    if (result == 0) {
        pty_session_release(session);
        return;
    }

    pty_debug_worker_finished(PTY_DEBUG_WORKER_CLOSE);
    pty_session_release(session);
    pty_session_release(session);
    pthread_mutex_lock(&platform->mutex);
    platform->stopping = 1;
    platform->close_done = 1;
    pthread_mutex_unlock(&platform->mutex);
    stop_process(session);
    wake_reactor(platform);
    maybe_post_session_closed(session);
}

FFI_PLUGIN_EXPORT void pty_session_abandon(void *opaque_session)
{
    PtySession *session = opaque_session;
    if (session == NULL || !pty_session_mark_abandoned(session)) return;
    pty_session_begin_close(session);
    pty_session_release(session);
}
