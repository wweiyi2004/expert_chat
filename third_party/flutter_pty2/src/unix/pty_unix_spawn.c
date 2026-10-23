#include "pty_unix_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/syscall.h>
#endif

#if defined(__APPLE__)
#include <util.h>
#elif defined(__ANDROID__)
#include <fcntl.h>
#else
#include <pty.h>
#endif

#include "../common/pty_error.h"

#define PTY_CHILD_STATUS_FD 3
#define PTY_DEFAULT_PATH "/usr/local/bin:/usr/bin:/bin"

#if defined(__ANDROID__)
static int pty_open(int *master_fd,
                    int *slave_fd,
                    const struct winsize *window)
{
    *master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (*master_fd < 0) return -1;
    if (grantpt(*master_fd) != 0 || unlockpt(*master_fd) != 0) {
        const int error_number = errno;
        close(*master_fd);
        *master_fd = -1;
        errno = error_number;
        return -1;
    }
    char *slave_name = ptsname(*master_fd);
    if (slave_name == NULL) {
        const int error_number = errno;
        close(*master_fd);
        *master_fd = -1;
        errno = error_number;
        return -1;
    }
    *slave_fd = open(slave_name, O_RDWR | O_NOCTTY);
    if (*slave_fd < 0) {
        const int error_number = errno;
        close(*master_fd);
        *master_fd = -1;
        errno = error_number;
        return -1;
    }
    if (ioctl(*slave_fd, TIOCSWINSZ, window) != 0) {
        const int error_number = errno;
        close(*slave_fd);
        close(*master_fd);
        *slave_fd = -1;
        *master_fd = -1;
        errno = error_number;
        return -1;
    }
    return 0;
}
#else
static int pty_open(int *master_fd,
                    int *slave_fd,
                    const struct winsize *window)
{
    struct winsize mutable_window = *window;
    return openpty(master_fd, slave_fd, NULL, NULL, &mutable_window);
}
#endif

static pthread_mutex_t pty_open_mutex = PTHREAD_MUTEX_INITIALIZER;

static int pty_open_serialized(int *master_fd,
                               int *slave_fd,
                               const struct winsize *window,
                               int *error_number)
{
    pthread_mutex_lock(&pty_open_mutex);
    const int result = pty_open(master_fd, slave_fd, window);
    if (error_number != NULL) *error_number = errno;
    pthread_mutex_unlock(&pty_open_mutex);
    return result;
}

static char *copy_string(const char *value)
{
    if (value == NULL) return NULL;
    const size_t length = strlen(value) + 1;
    char *copy = malloc(length);
    if (copy == NULL) return NULL;
    memcpy(copy, value, length);
    return copy;
}

static void free_string_vector(char **values, int32_t count)
{
    if (values == NULL) return;
    for (int32_t index = 0; index < count; index++) free(values[index]);
    free(values);
}

static char **copy_string_vector(const char *const *values,
                                 int32_t count,
                                 int32_t extra,
                                 PtyError *error)
{
    if (count < 0 || extra < 0 || count > INT32_MAX - extra) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      EINVAL,
                      "invalid string vector length");
        return NULL;
    }
    char **result = calloc((size_t)count + (size_t)extra, sizeof(*result));
    if (result == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "allocating spawn string vector failed");
        return NULL;
    }
    for (int32_t index = 0; index < count; index++) {
        if (values == NULL || values[index] == NULL) {
            free_string_vector(result, index);
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_INVALID_ARGUMENT,
                          EINVAL,
                          "spawn string vector contains a null entry");
            return NULL;
        }
        result[index] = copy_string(values[index]);
        if (result[index] == NULL) {
            free_string_vector(result, index);
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_OUT_OF_MEMORY,
                          ENOMEM,
                          "copying spawn string failed");
            return NULL;
        }
    }
    return result;
}

int pty_unix_clone_options(const PtySpawnOptions *source,
                           PtyUnixOwnedOptions *destination,
                           PtyError *error)
{
    if (source == NULL || destination == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      EINVAL,
                      "invalid options clone arguments");
        return 0;
    }
    memset(destination, 0, sizeof(*destination));
    destination->options = *source;
    destination->executable = copy_string(source->executable);
    if (source->executable != NULL && destination->executable == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "copying executable failed");
        return 0;
    }
    destination->arguments = copy_string_vector(source->arguments,
                                                source->argument_count,
                                                1,
                                                error);
    if (destination->arguments == NULL) {
        pty_unix_free_options(destination);
        return 0;
    }
    destination->environment = copy_string_vector(source->environment,
                                                  source->environment_count,
                                                  1,
                                                  error);
    if (destination->environment == NULL) {
        pty_unix_free_options(destination);
        return 0;
    }
    destination->working_directory = copy_string(source->working_directory);
    if (source->working_directory != NULL &&
        destination->working_directory == NULL) {
        pty_unix_free_options(destination);
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "copying working directory failed");
        return 0;
    }
    destination->options.executable = destination->executable;
    destination->options.arguments =
        (const char *const *)destination->arguments;
    destination->options.environment =
        (const char *const *)destination->environment;
    destination->options.working_directory = destination->working_directory;
    return 1;
}

void pty_unix_free_options(PtyUnixOwnedOptions *options)
{
    if (options == NULL) return;
    free(options->executable);
    free_string_vector(options->arguments, options->options.argument_count);
    free_string_vector(options->environment, options->options.environment_count);
    free(options->working_directory);
    memset(options, 0, sizeof(*options));
}

static const char *environment_value(const char *const *environment,
                                     int32_t count,
                                     const char *key)
{
    const size_t key_length = strlen(key);
    for (int32_t index = 0; index < count; index++) {
        const char *entry = environment[index];
        if (entry == NULL || strncmp(entry, key, key_length) != 0) continue;
        if (entry[key_length] == '=') return entry + key_length + 1;
    }
    return NULL;
}

static int is_absolute_path(const char *path)
{
    return path != NULL && path[0] == '/';
}

static char *join_path(const char *directory, const char *name)
{
    const size_t directory_length = strlen(directory);
    const size_t name_length = strlen(name);
    const int needs_separator = directory_length != 0 &&
                                directory[directory_length - 1] != '/';
    if (directory_length > SIZE_MAX - name_length - (size_t)needs_separator - 1) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    const size_t length = directory_length + name_length +
                          (size_t)needs_separator + 1;
    char *result = malloc(length);
    if (result == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    memcpy(result, directory, directory_length);
    size_t offset = directory_length;
    if (needs_separator) result[offset++] = '/';
    memcpy(result + offset, name, name_length);
    result[offset + name_length] = '\0';
    return result;
}

static int access_path(const char *path, const char *working_directory)
{
    if (is_absolute_path(path) || working_directory == NULL ||
        working_directory[0] == '\0') {
        return access(path, X_OK);
    }
    char *absolute_path = join_path(working_directory, path);
    if (absolute_path == NULL) {
        if (errno == 0) errno = ENOMEM;
        return -1;
    }
    const int result = access(absolute_path, X_OK);
    const int error_number = errno;
    free(absolute_path);
    errno = error_number;
    return result;
}

static int validate_working_directory(const char *path, PtyError *error)
{
    if (path == NULL || path[0] == '\0') return 1;
    struct stat status;
    if (stat(path, &status) != 0) {
        pty_error_set_errno(error,
                            PTY_ERROR_WORKING_DIRECTORY,
                            errno,
                            "checking working directory failed");
        return 0;
    }
    if (!S_ISDIR(status.st_mode)) {
        pty_error_set_errno(error,
                            PTY_ERROR_WORKING_DIRECTORY,
                            ENOTDIR,
                            "working directory is not a directory");
        return 0;
    }
    return 1;
}

static char *resolve_executable(const PtySpawnOptions *options,
                                PtyError *error)
{
    const char *executable = options->executable;
    if (strchr(executable, '/') != NULL) {
        if (access_path(executable, options->working_directory) != 0) {
            const int error_number = errno;
            pty_error_set_errno(error,
                                error_number == EACCES
                                    ? PTY_ERROR_PERMISSION_DENIED
                                    : PTY_ERROR_NOT_FOUND,
                                error_number,
                                "checking executable failed");
            return NULL;
        }
        char *resolved = copy_string(executable);
        if (resolved == NULL) {
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_OUT_OF_MEMORY,
                          ENOMEM,
                          "copying executable path failed");
            return NULL;
        }
        return resolved;
    }

    const char *path = environment_value(
        options->environment,
        options->environment_count,
        "PATH");
    if (path == NULL) path = PTY_DEFAULT_PATH;

    const char *start = path;
    int saw_permission_denied = 0;
    while (true) {
        const char *separator = strchr(start, ':');
        const size_t length = separator == NULL
                                  ? strlen(start)
                                  : (size_t)(separator - start);
        char *directory = malloc(length + 1);
        if (directory == NULL) {
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_OUT_OF_MEMORY,
                          ENOMEM,
                          "allocating PATH entry failed");
            return NULL;
        }
        memcpy(directory, start, length);
        directory[length] = '\0';
        if (directory[0] == '\0') {
            free(directory);
            directory = copy_string(".");
            if (directory == NULL) {
                pty_error_set(error,
                              PTY_ERROR_DOMAIN_INTERNAL,
                              PTY_ERROR_OUT_OF_MEMORY,
                              ENOMEM,
                              "allocating empty PATH entry failed");
                return NULL;
            }
        }
        char *candidate = join_path(directory, executable);
        if (candidate == NULL) {
            const int error_number = errno == 0 ? ENOMEM : errno;
            free(directory);
            pty_error_set_errno(
                error,
                error_number == ENAMETOOLONG ? PTY_ERROR_NOT_FOUND
                                               : PTY_ERROR_OUT_OF_MEMORY,
                error_number,
                "building executable PATH candidate failed");
            return NULL;
        }
        const int executable_exists =
            access_path(candidate, options->working_directory) == 0;
        const int access_error = errno;
        if (!executable_exists && access_error == EACCES) {
            saw_permission_denied = 1;
        }
        free(directory);
        if (executable_exists) return candidate;
        free(candidate);
        errno = access_error;
        if (separator == NULL) break;
        start = separator + 1;
    }

    const int error_number = saw_permission_denied
                                 ? EACCES
                                 : (errno == 0 ? ENOENT : errno);
    pty_error_set_errno(error,
                        error_number == EACCES
                            ? PTY_ERROR_PERMISSION_DENIED
                            : PTY_ERROR_NOT_FOUND,
                        error_number,
                        "resolving executable failed");
    return NULL;
}

static int move_fd_above(int fd, int minimum, int *error_number)
{
    if (fd >= minimum) return fd;
    const int moved = fcntl(fd, F_DUPFD_CLOEXEC, minimum);
    if (moved < 0) {
        if (error_number != NULL) *error_number = errno;
        close(fd);
        return -1;
    }
    close(fd);
    return moved;
}

static int set_close_on_exec(int fd)
{
    const int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int max_open_fd(void)
{
    long value = sysconf(_SC_OPEN_MAX);
    if (value < 0) value = 1024;
    if (value > 1024 * 1024) value = 1024 * 1024;
    return (int)value;
}

static void child_report_error(int fd, PtyChildStage stage, int error_number)
{
    const PtyChildError error = {
        .stage = (int32_t)stage,
        .error_number = error_number,
    };
    const uint8_t *data = (const uint8_t *)&error;
    size_t remaining = sizeof(error);
    while (remaining > 0) {
        const ssize_t written = write(fd, data, remaining);
        if (written > 0) {
            data += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        break;
    }
}

static int pty_unix_reset_child_signals(
    const struct sigaction *default_signal_action)
{
#if defined(NSIG)
    const int signal_count = NSIG;
#elif defined(__DARWIN_NSIG)
    const int signal_count = __DARWIN_NSIG;
#else
    const int signal_count = 64;
#endif
    for (int signal_number = 1; signal_number < signal_count; signal_number++) {
        if (signal_number == SIGKILL || signal_number == SIGSTOP) continue;
        if (sigaction(signal_number, default_signal_action, NULL) == 0) {
            continue;
        }
        if (errno == EINVAL) continue;
        return -1;
    }
    return 0;
}

static void close_extra_fds(int status_fd, int maximum_fd)
{
#if defined(__linux__) && defined(SYS_close_range)
    if (status_fd == PTY_CHILD_STATUS_FD &&
        syscall(SYS_close_range,
                (unsigned int)(PTY_CHILD_STATUS_FD + 1),
                UINT_MAX,
                0) == 0) {
        return;
    }
#endif
    for (int fd = PTY_CHILD_STATUS_FD; fd < maximum_fd; fd++) {
        if (fd == status_fd) continue;
        close(fd);
    }
}

static int read_child_error(int fd, PtyChildError *error)
{
    uint8_t *data = (uint8_t *)error;
    size_t received = 0;
    while (received < sizeof(*error)) {
        const ssize_t result = read(fd, data + received,
                                    sizeof(*error) - received);
        if (result > 0) {
            received += (size_t)result;
            continue;
        }
        if (result < 0 && errno == EINTR) continue;
        if (result == 0) return received == 0 ? 0 : -1;
        return -1;
    }
    return 1;
}

static void cleanup_failed_child(pid_t process_id, int master_fd)
{
    if (master_fd >= 0) close(master_fd);
    if (process_id <= 0) return;
    kill(-process_id, SIGKILL);
    kill(process_id, SIGKILL);
    while (waitpid(process_id, NULL, 0) < 0 && errno == EINTR) {}
}

int pty_unix_spawn(const PtySpawnOptions *options,
                   int *master_fd,
                   int *slave_fd,
                   pid_t *process_id,
                   PtyError *error)
{
    if (master_fd != NULL) *master_fd = -1;
    if (slave_fd != NULL) *slave_fd = -1;
    if (process_id != NULL) *process_id = -1;
    pty_error_clear(error);
    if (options == NULL || master_fd == NULL || slave_fd == NULL ||
        process_id == NULL ||
        options->executable == NULL || options->executable[0] == '\0') {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      EINVAL,
                      "invalid Unix spawn options");
        return 0;
    }

    if (!pty_size_is_valid(options->size)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      EINVAL,
                      "invalid Unix PTY size");
        return 0;
    }
    if (!validate_working_directory(options->working_directory, error)) {
        return 0;
    }

    char *resolved_executable = resolve_executable(options, error);
    if (resolved_executable == NULL) return 0;
    char **argv = copy_string_vector(options->arguments,
                                     options->argument_count,
                                     2,
                                     error);
    if (argv == NULL) {
        free(resolved_executable);
        return 0;
    }
    for (int32_t index = options->argument_count; index > 0; index--) {
        argv[index] = argv[index - 1];
    }
    argv[0] = copy_string(options->executable);
    argv[options->argument_count + 1] = NULL;
    if (argv[0] == NULL) {
        free_string_vector(argv, options->argument_count + 1);
        free(resolved_executable);
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ENOMEM,
                      "copying argv[0] failed");
        return 0;
    }
    char **envp = copy_string_vector(options->environment,
                                     options->environment_count,
                                     1,
                                     error);
    if (envp == NULL) {
        free_string_vector(argv, options->argument_count + 1);
        free(resolved_executable);
        return 0;
    }

    struct winsize window = {
        .ws_row = (unsigned short)options->size.rows,
        .ws_col = (unsigned short)options->size.columns,
        .ws_xpixel = (unsigned short)options->size.pixel_width,
        .ws_ypixel = (unsigned short)options->size.pixel_height,
    };
    int master = -1;
    int slave = -1;
    int open_error = 0;
    if (pty_open_serialized(&master, &slave, &window, &open_error) != 0) {
        pty_error_set_errno(error,
                            PTY_ERROR_SPAWN_FAILED,
                            open_error,
                            "openpty failed");
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        return 0;
    }
#ifdef IUTF8
    struct termios attributes;
    if (tcgetattr(slave, &attributes) != 0) {
        const int error_number = errno;
        close(master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error,
                            PTY_ERROR_SPAWN_FAILED,
                            error_number,
                            "reading PTY terminal attributes failed");
        return 0;
    }
    attributes.c_iflag |= IUTF8;
    if (tcsetattr(slave, TCSANOW, &attributes) != 0) {
        const int error_number = errno;
        close(master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error,
                            PTY_ERROR_SPAWN_FAILED,
                            error_number,
                            "setting PTY terminal attributes failed");
        return 0;
    }
#endif

    int descriptor_error = 0;
    master = move_fd_above(master, PTY_CHILD_STATUS_FD + 1, &descriptor_error);
    slave = move_fd_above(slave, PTY_CHILD_STATUS_FD + 1, &descriptor_error);
    if (master < 0 || slave < 0) {
        const int error_number = descriptor_error == 0 ? EIO : descriptor_error;
        if (master >= 0) close(master);
        if (slave >= 0) close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "preparing PTY descriptors failed");
        return 0;
    }

    int status_pipe[2] = {-1, -1};
    if (pipe(status_pipe) != 0) {
        const int error_number = errno;
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "creating exec status pipe failed");
        return 0;
    }
    if (set_close_on_exec(status_pipe[0]) != 0 ||
        set_close_on_exec(status_pipe[1]) != 0) {
        const int error_number = errno;
        close(status_pipe[0]);
        close(status_pipe[1]);
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "configuring exec status pipe failed");
        return 0;
    }
    descriptor_error = 0;
    status_pipe[0] = move_fd_above(status_pipe[0],
                                   PTY_CHILD_STATUS_FD + 1,
                                   &descriptor_error);
    if (status_pipe[0] < 0) {
        const int error_number = descriptor_error == 0 ? EIO : descriptor_error;
        close(status_pipe[1]);
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "moving exec status pipe failed");
        return 0;
    }
    const int status_fd = fcntl(status_pipe[1], F_DUPFD_CLOEXEC,
                                PTY_CHILD_STATUS_FD);
    if (status_fd < 0 || set_close_on_exec(status_fd) != 0) {
        const int error_number = errno;
        close(status_pipe[0]);
        close(status_pipe[1]);
        if (status_fd >= 0) close(status_fd);
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "placing exec status pipe failed");
        return 0;
    }
    close(status_pipe[1]);

    const int maximum_fd = max_open_fd();
    struct sigaction default_signal_action = {
        .sa_handler = SIG_DFL,
    };
    sigemptyset(&default_signal_action.sa_mask);
    sigset_t empty_signal_mask;
    if (sigemptyset(&empty_signal_mask) != 0) {
        const int error_number = errno;
        close(status_pipe[0]);
        close(status_fd);
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error,
                            PTY_ERROR_SPAWN_FAILED,
                            error_number,
                            "preparing child signal mask failed");
        return 0;
    }
    const pid_t child = fork();
    if (child < 0) {
        const int error_number = errno;
        close(status_pipe[0]);
        close(status_fd);
        cleanup_failed_child(-1, master);
        close(slave);
        free_string_vector(argv, options->argument_count + 1);
        free_string_vector(envp, options->environment_count);
        free(resolved_executable);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "fork failed");
        return 0;
    }
    if (child == 0) {
        if (sigprocmask(SIG_SETMASK, &empty_signal_mask, NULL) != 0) {
            child_report_error(status_fd, PTY_CHILD_STAGE_SIGNAL_MASK, errno);
            _exit(126);
        }
        if (pty_unix_reset_child_signals(&default_signal_action) != 0) {
            child_report_error(
                status_fd,
                PTY_CHILD_STAGE_SIGNAL_DISPOSITION,
                errno);
            _exit(126);
        }
        close(master);
        close(status_pipe[0]);
        if (setsid() < 0) {
            child_report_error(status_fd, PTY_CHILD_STAGE_SETSID, errno);
            _exit(126);
        }
        if (ioctl(slave, TIOCSCTTY, 0) < 0) {
            child_report_error(status_fd,
                               PTY_CHILD_STAGE_CONTROLLING_TTY,
                               errno);
            _exit(126);
        }
        if (dup2(slave, STDIN_FILENO) < 0 ||
            dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) {
            child_report_error(status_fd, PTY_CHILD_STAGE_DUP2, errno);
            _exit(126);
        }
        if (slave > STDERR_FILENO && slave != status_fd) close(slave);
        close_extra_fds(status_fd, maximum_fd);
        if (options->working_directory != NULL &&
            options->working_directory[0] != '\0' &&
            chdir(options->working_directory) != 0) {
            child_report_error(status_fd, PTY_CHILD_STAGE_CHDIR, errno);
            _exit(126);
        }
        execve(resolved_executable, argv, envp);
        child_report_error(status_fd, PTY_CHILD_STAGE_EXEC, errno);
        _exit(127);
    }

    close(status_fd);
    PtyChildError child_error;
    const int status_result = read_child_error(status_pipe[0], &child_error);
    close(status_pipe[0]);
    free_string_vector(argv, options->argument_count + 1);
    free_string_vector(envp, options->environment_count);
    free(resolved_executable);
    if (status_result != 0) {
        cleanup_failed_child(child, master);
        close(slave);
        if (status_result < 0) {
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_SPAWN_FAILED,
                          EIO,
                          "invalid exec status response");
        } else {
            PtyErrorKind kind = PTY_ERROR_SPAWN_FAILED;
            if (child_error.stage == PTY_CHILD_STAGE_CHDIR) {
                kind = PTY_ERROR_WORKING_DIRECTORY;
            } else if (child_error.error_number == EACCES) {
                kind = PTY_ERROR_PERMISSION_DENIED;
            } else if (child_error.error_number == ENOENT) {
                kind = PTY_ERROR_NOT_FOUND;
            }
            pty_error_set_errno(error,
                                kind,
                                child_error.error_number,
                                "Unix child setup failed");
        }
        return 0;
    }

    const int flags = fcntl(master, F_GETFL);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) != 0) {
        const int error_number = errno;
        cleanup_failed_child(child, master);
        close(slave);
        pty_error_set_errno(error, PTY_ERROR_SPAWN_FAILED, error_number,
                            "configuring PTY master failed");
        return 0;
    }
    *master_fd = master;
    *slave_fd = slave;
    *process_id = child;
    return 1;
}
