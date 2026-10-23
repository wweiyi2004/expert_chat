#ifndef FLUTTER_PTY_EVENT_H_
#define FLUTTER_PTY_EVENT_H_

#include <stdbool.h>
#include <stdint.h>

#include "../flutter_pty.h"
#include "../include/dart_api_dl.h"

bool pty_post_simple_event(Dart_Port_DL port, PtyEventType event_type);
bool pty_post_spawned(Dart_Port_DL port, int64_t pid, uint64_t capabilities);
bool pty_post_spawn_failed(Dart_Port_DL port, const PtyError *error);
bool pty_post_output(Dart_Port_DL port, const uint8_t *bytes, intptr_t length);
bool pty_post_write_complete(Dart_Port_DL port, uint64_t request_id);
bool pty_post_input_closed(Dart_Port_DL port, const PtyError *error);
bool pty_post_process_exit(Dart_Port_DL port, bool signal_exit, int64_t value);
bool pty_post_error(Dart_Port_DL port, const PtyError *error);

#endif
