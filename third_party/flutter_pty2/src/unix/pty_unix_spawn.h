#ifndef FLUTTER_PTY_UNIX_SPAWN_H_
#define FLUTTER_PTY_UNIX_SPAWN_H_

#include <sys/types.h>

#include "../flutter_pty.h"

typedef enum PtyChildStage {
    PTY_CHILD_STAGE_NONE = 0,
    PTY_CHILD_STAGE_SIGNAL_MASK = 1,
    PTY_CHILD_STAGE_SIGNAL_DISPOSITION = 2,
    PTY_CHILD_STAGE_SETSID = 3,
    PTY_CHILD_STAGE_CONTROLLING_TTY = 4,
    PTY_CHILD_STAGE_DUP2 = 5,
    PTY_CHILD_STAGE_CHDIR = 6,
    PTY_CHILD_STAGE_EXEC = 7
} PtyChildStage;

typedef struct PtyChildError {
    int32_t stage;
    int32_t error_number;
} PtyChildError;

typedef struct PtyUnixOwnedOptions {
    PtySpawnOptions options;
    char *executable;
    char **arguments;
    char **environment;
    char *working_directory;
} PtyUnixOwnedOptions;

int pty_unix_clone_options(const PtySpawnOptions *source,
                           PtyUnixOwnedOptions *destination,
                           PtyError *error);
void pty_unix_free_options(PtyUnixOwnedOptions *options);

int pty_unix_spawn(const PtySpawnOptions *options,
                   int *master_fd,
                   int *slave_fd,
                   pid_t *process_id,
                   PtyError *error);

#endif
