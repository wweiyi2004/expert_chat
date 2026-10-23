#ifndef FLUTTER_PTY_WINDOWS_COMMANDLINE_H_
#define FLUTTER_PTY_WINDOWS_COMMANDLINE_H_

#include <wchar.h>

wchar_t *pty_windows_build_command_line(
    const char *executable,
    const char *const *arguments,
    int argument_count);

#endif
