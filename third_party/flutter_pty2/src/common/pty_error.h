#ifndef FLUTTER_PTY_ERROR_H_
#define FLUTTER_PTY_ERROR_H_

#include "../flutter_pty.h"

void pty_error_clear(PtyError *error);
void pty_error_set(PtyError *error,
                   PtyErrorDomain domain,
                   PtyErrorKind kind,
                   int64_t os_code,
                   const char *message);
void pty_error_set_errno(PtyError *error,
                         PtyErrorKind kind,
                         int error_number,
                         const char *message);
int pty_size_is_valid(PtySize size);

#endif
