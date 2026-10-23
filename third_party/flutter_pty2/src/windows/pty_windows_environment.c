#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "pty_windows_environment.h"

#include <windows.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static wchar_t *utf8_to_wide(const char *value)
{
    if (value == NULL) return NULL;
    const int length = MultiByteToWideChar(CP_UTF8,
                                           MB_ERR_INVALID_CHARS,
                                           value,
                                           -1,
                                           NULL,
                                           0);
    if (length <= 0) return NULL;
    wchar_t *converted = malloc((size_t)length * sizeof(*converted));
    if (converted == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8,
                            MB_ERR_INVALID_CHARS,
                            value,
                            -1,
                            converted,
                            length) <= 0) {
        free(converted);
        return NULL;
    }
    return converted;
}

wchar_t *pty_windows_build_environment(const char *const *environment,
                                        int environment_count)
{
    if (environment_count < 0 ||
        (environment_count != 0 && environment == NULL)) {
        return NULL;
    }
    size_t length = 1;
    for (int index = 0; index < environment_count; index++) {
        wchar_t *converted = utf8_to_wide(environment[index]);
        if (converted == NULL) return NULL;
        const size_t entry_length = wcslen(converted) + 1;
        free(converted);
        if (entry_length > SIZE_MAX - length - 1) return NULL;
        length += entry_length;
    }
    wchar_t *block = calloc(length + 1, sizeof(*block));
    if (block == NULL) return NULL;

    size_t offset = 0;
    for (int index = 0; index < environment_count; index++) {
        wchar_t *converted = utf8_to_wide(environment[index]);
        if (converted == NULL) {
            free(block);
            return NULL;
        }
        const size_t entry_length = wcslen(converted) + 1;
        memcpy(block + offset,
               converted,
               entry_length * sizeof(*converted));
        offset += entry_length;
        free(converted);
    }
    block[offset] = L'\0';
    return block;
}
