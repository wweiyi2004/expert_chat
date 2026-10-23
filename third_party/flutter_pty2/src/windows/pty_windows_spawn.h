#ifndef FLUTTER_PTY2_WINDOWS_SPAWN_H_
#define FLUTTER_PTY2_WINDOWS_SPAWN_H_

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>

#include "../flutter_pty.h"

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE \
    ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)
typedef HANDLE HPCON;
HRESULT WINAPI CreatePseudoConsole(COORD size,
                                   HANDLE input,
                                   HANDLE output,
                                   DWORD flags,
                                   HPCON *pseudo_console);
HRESULT WINAPI ResizePseudoConsole(HPCON pseudo_console, COORD size);
void WINAPI ClosePseudoConsole(HPCON pseudo_console);
#endif

typedef struct PtyWindowsOwnedOptions {
    PtySpawnOptions options;
    char *executable;
    char **arguments;
    char **environment;
    char *working_directory;
} PtyWindowsOwnedOptions;

int pty_windows_clone_options(const PtySpawnOptions *source,
                              PtyWindowsOwnedOptions *destination,
                              PtyError *error);
void pty_windows_free_options(PtyWindowsOwnedOptions *options);
int pty_windows_create_process(const PtySpawnOptions *options,
                               HANDLE *input_write,
                               HANDLE *output_read,
                               HANDLE *process,
                               HANDLE *process_thread,
                               HANDLE *job,
                               DWORD *process_id,
                               HPCON *pseudo_console,
                               PtyError *error);

#endif
