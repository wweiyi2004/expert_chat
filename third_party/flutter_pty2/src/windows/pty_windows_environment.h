#ifndef FLUTTER_PTY_WINDOWS_ENVIRONMENT_H_
#define FLUTTER_PTY_WINDOWS_ENVIRONMENT_H_

#include <wchar.h>

wchar_t *pty_windows_build_environment(
    const char *const *environment,
    int environment_count);

#endif
