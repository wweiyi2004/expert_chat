#include "pty_error.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

void pty_error_clear(PtyError *error)
{
    if (error == NULL) return;
    error->domain = PTY_ERROR_DOMAIN_NONE;
    error->kind = PTY_ERROR_NONE;
    error->os_code = 0;
    error->message[0] = '\0';
}

void pty_error_set(PtyError *error,
                   PtyErrorDomain domain,
                   PtyErrorKind kind,
                   int64_t os_code,
                   const char *message)
{
    if (error == NULL) return;
    error->domain = (int32_t)domain;
    error->kind = (int32_t)kind;
    error->os_code = os_code;
    if (message == NULL) {
        error->message[0] = '\0';
        return;
    }
    snprintf(error->message, sizeof(error->message), "%s", message);
}

void pty_error_set_errno(PtyError *error,
                         PtyErrorKind kind,
                         int error_number,
                         const char *message)
{
    char detail[256];
    const char *system_message = strerror(error_number);
    if (message == NULL || message[0] == '\0') {
        snprintf(detail, sizeof(detail), "%s", system_message);
    } else {
        snprintf(detail, sizeof(detail), "%s: %s", message, system_message);
    }
    pty_error_set(error,
                  PTY_ERROR_DOMAIN_POSIX,
                  kind,
                  error_number,
                  detail);
}

int pty_size_is_valid(PtySize size)
{
    return size.rows >= 1 && size.rows <= 0x7fff &&
           size.columns >= 1 && size.columns <= 0x7fff &&
           size.pixel_width >= 0 && size.pixel_width <= 0xffff &&
           size.pixel_height >= 0 && size.pixel_height <= 0xffff;
}
