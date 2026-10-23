#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "../common/pty_error.h"
#include "../pty_internal.h"
#include "pty_windows_commandline.h"
#include "pty_windows_environment.h"
#include "pty_windows_spawn.h"

static char *windows_copy_string(const char *value)
{
    if (value == NULL) return NULL;
    const size_t length = strlen(value) + 1;
    char *copy = malloc(length);
    if (copy == NULL) return NULL;
    memcpy(copy, value, length);
    return copy;
}

static void windows_free_vector(char **values, int32_t count)
{
    if (values == NULL) return;
    for (int32_t index = 0; index < count; index++) free(values[index]);
    free(values);
}

static char **windows_copy_vector(const char *const *values,
                                  int32_t count,
                                  PtyError *error)
{
    if (count < 0) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_INVALID_ARGUMENT,
                      ERROR_INVALID_PARAMETER,
                      "invalid Windows string vector length");
        return NULL;
    }
    char **result = calloc((size_t)count + 1, sizeof(*result));
    if (result == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "allocating Windows string vector failed");
        return NULL;
    }
    for (int32_t index = 0; index < count; index++) {
        if (values == NULL || values[index] == NULL) {
            windows_free_vector(result, index);
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_INVALID_ARGUMENT,
                          ERROR_INVALID_PARAMETER,
                          "Windows string vector contains a null entry");
            return NULL;
        }
        result[index] = windows_copy_string(values[index]);
        if (result[index] == NULL) {
            windows_free_vector(result, index);
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_INTERNAL,
                          PTY_ERROR_OUT_OF_MEMORY,
                          ERROR_NOT_ENOUGH_MEMORY,
                          "copying Windows spawn string failed");
            return NULL;
        }
    }
    return result;
}

int pty_windows_clone_options(const PtySpawnOptions *source,
                              PtyWindowsOwnedOptions *destination,
                              PtyError *error)
{
    memset(destination, 0, sizeof(*destination));
    destination->options = *source;
    destination->executable = windows_copy_string(source->executable);
    if (destination->executable == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "copying Windows executable failed");
        return 0;
    }
    destination->arguments = windows_copy_vector(source->arguments,
                                                 source->argument_count,
                                                 error);
    if (destination->arguments == NULL) return 0;
    destination->environment = windows_copy_vector(source->environment,
                                                   source->environment_count,
                                                   error);
    if (destination->environment == NULL) return 0;
    destination->working_directory =
        windows_copy_string(source->working_directory);
    if (source->working_directory != NULL &&
        destination->working_directory == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "copying Windows working directory failed");
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

void pty_windows_free_options(PtyWindowsOwnedOptions *options)
{
    if (options == NULL) return;
    free(options->executable);
    windows_free_vector(options->arguments, options->options.argument_count);
    windows_free_vector(options->environment,
                        options->options.environment_count);
    free(options->working_directory);
    memset(options, 0, sizeof(*options));
}

static wchar_t *windows_spawn_utf8_to_wide(const char *value)
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

static PtyErrorKind windows_spawn_error_kind(DWORD error_code)
{
    switch (error_code) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
            return PTY_ERROR_NOT_FOUND;
        case ERROR_ACCESS_DENIED:
            return PTY_ERROR_PERMISSION_DENIED;
        default:
            return PTY_ERROR_SPAWN_FAILED;
    }
}

int pty_windows_create_process(const PtySpawnOptions *options,
                               HANDLE *input_write,
                               HANDLE *output_read,
                               HANDLE *process,
                               HANDLE *process_thread,
                               HANDLE *job,
                               DWORD *process_id,
                               HPCON *pseudo_console,
                               PtyError *error)
{
    HANDLE input_read = NULL;
    HANDLE output_write = NULL;
    STARTUPINFOEXW startup_info;
    PROCESS_INFORMATION process_info;
    SIZE_T attribute_size = 0;
    PPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    LPWSTR command = NULL;
    LPWSTR environment = NULL;
    LPWSTR working_directory = NULL;
    int attributes_initialized = 0;
    memset(&startup_info, 0, sizeof(startup_info));
    memset(&process_info, 0, sizeof(process_info));

    if (!CreatePipe(&input_read, input_write, NULL, 0) ||
        !CreatePipe(output_read, &output_write, NULL, 0)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_IO,
                      GetLastError(),
                      "creating ConPTY pipes failed");
        goto failure;
    }
    const COORD size = {
        .X = (SHORT)options->size.columns,
        .Y = (SHORT)options->size.rows,
    };
    const HRESULT create_console_result = CreatePseudoConsole(size,
                                                              input_read,
                                                              output_write,
                                                              0,
                                                              pseudo_console);
    if (FAILED(create_console_result)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_HRESULT,
                      PTY_ERROR_SPAWN_FAILED,
                      create_console_result,
                      "creating ConPTY failed");
        goto failure;
    }
    *job = CreateJobObjectW(NULL, NULL);
    if (*job == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "creating process Job Object failed");
        goto failure;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_info;
    memset(&job_info, 0, sizeof(job_info));
    job_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(*job,
                                 JobObjectExtendedLimitInformation,
                                 &job_info,
                                 sizeof(job_info))) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "configuring process Job Object failed");
        goto failure;
    }
    CloseHandle(input_read);
    input_read = NULL;
    CloseHandle(output_write);
    output_write = NULL;

    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    attributes = malloc(attribute_size);
    if (attributes == NULL) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_INTERNAL,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "allocating ConPTY process attributes failed");
        goto failure;
    }
    if (!InitializeProcThreadAttributeList(attributes,
                                           1,
                                           0,
                                           &attribute_size)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "initializing ConPTY process attributes failed");
        goto failure;
    }
    attributes_initialized = 1;
    if (!UpdateProcThreadAttribute(attributes,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   *pseudo_console,
                                   sizeof(*pseudo_console),
                                   NULL,
                                   NULL)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "configuring ConPTY process attributes failed");
        goto failure;
    }

    command = pty_windows_build_command_line(options->executable,
                                             options->arguments,
                                             options->argument_count);
    environment = pty_windows_build_environment(options->environment,
                                                options->environment_count);
    if (options->working_directory != NULL &&
        options->working_directory[0] != '\0') {
        working_directory =
            windows_spawn_utf8_to_wide(options->working_directory);
    }
    if (command == NULL || environment == NULL ||
        (options->working_directory != NULL &&
         options->working_directory[0] != '\0' &&
         working_directory == NULL)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_OUT_OF_MEMORY,
                      ERROR_NOT_ENOUGH_MEMORY,
                      "building Windows process arguments failed");
        goto failure;
    }
    if (options->working_directory != NULL &&
        options->working_directory[0] != '\0') {
        const DWORD working_directory_attributes =
            GetFileAttributesW(working_directory);
        if (working_directory_attributes == INVALID_FILE_ATTRIBUTES) {
            const DWORD error_code = GetLastError();
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_WIN32,
                          PTY_ERROR_WORKING_DIRECTORY,
                          error_code,
                          "checking Windows working directory failed");
            goto failure;
        }
        if ((working_directory_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            pty_error_set(error,
                          PTY_ERROR_DOMAIN_WIN32,
                          PTY_ERROR_WORKING_DIRECTORY,
                          ERROR_DIRECTORY,
                          "Windows working directory is not a directory");
            goto failure;
        }
    }
    startup_info.StartupInfo.cb = sizeof(startup_info);
    // Do not copy the Flutter host's redirected standard handles into CMD.
    // Null handles are replaced with the attached pseudoconsole's handles.
    startup_info.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup_info.StartupInfo.hStdInput = NULL;
    startup_info.StartupInfo.hStdOutput = NULL;
    startup_info.StartupInfo.hStdError = NULL;
    startup_info.lpAttributeList = attributes;
    if (!CreateProcessW(NULL,
                        command,
                        NULL,
                        NULL,
                        FALSE,
                        EXTENDED_STARTUPINFO_PRESENT |
                            CREATE_UNICODE_ENVIRONMENT |
                            CREATE_SUSPENDED,
                        environment,
                        working_directory,
                        &startup_info.StartupInfo,
                        &process_info)) {
        const DWORD error_code = GetLastError();
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      windows_spawn_error_kind(error_code),
                      error_code,
                      "creating ConPTY process failed");
        goto failure;
    }
    if (!AssignProcessToJobObject(*job, process_info.hProcess)) {
        pty_error_set(error,
                      PTY_ERROR_DOMAIN_WIN32,
                      PTY_ERROR_SPAWN_FAILED,
                      GetLastError(),
                      "assigning process to Job Object failed");
        goto process_failure;
    }
    *process = process_info.hProcess;
    *process_thread = process_info.hThread;
    *process_id = process_info.dwProcessId;
    if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    free(command);
    free(environment);
    free(working_directory);
    return 1;

process_failure:
    TerminateProcess(process_info.hProcess, 1);
    WaitForSingleObject(process_info.hProcess, INFINITE);
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
failure:
    if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    free(command);
    free(environment);
    free(working_directory);
    if (*job != NULL) {
        CloseHandle(*job);
        *job = NULL;
    }
    if (*pseudo_console != NULL) {
        pty_debug_pseudo_console_close();
        ClosePseudoConsole(*pseudo_console);
        *pseudo_console = NULL;
    }
    if (input_read != NULL) CloseHandle(input_read);
    if (output_write != NULL) CloseHandle(output_write);
    if (*input_write != NULL) {
        CloseHandle(*input_write);
        *input_write = NULL;
    }
    if (*output_read != NULL) {
        CloseHandle(*output_read);
        *output_read = NULL;
    }
    return 0;
}
