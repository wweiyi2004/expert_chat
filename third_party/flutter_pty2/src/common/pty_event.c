#include "pty_event.h"

static void set_int32(Dart_CObject *object, int32_t value)
{
    object->type = Dart_CObject_kInt32;
    object->value.as_int32 = value;
}

static void set_int64(Dart_CObject *object, int64_t value)
{
    object->type = Dart_CObject_kInt64;
    object->value.as_int64 = value;
}

static void set_string(Dart_CObject *object, const char *value)
{
    object->type = Dart_CObject_kString;
    object->value.as_string = (char *)value;
}

static bool post_array(Dart_Port_DL port, Dart_CObject **values, intptr_t length)
{
    Dart_CObject message;
    message.type = Dart_CObject_kArray;
    message.value.as_array.length = length;
    message.value.as_array.values = values;
    return Dart_PostCObject_DL(port, &message);
}

bool pty_post_simple_event(Dart_Port_DL port, PtyEventType event_type)
{
    Dart_CObject type;
    set_int32(&type, (int32_t)event_type);
    Dart_CObject *values[] = {&type};
    return post_array(port, values, 1);
}

bool pty_post_spawned(Dart_Port_DL port, int64_t pid, uint64_t capabilities)
{
    Dart_CObject type;
    Dart_CObject pid_value;
    Dart_CObject capability_value;
    set_int32(&type, PTY_EVENT_SPAWNED);
    set_int64(&pid_value, pid);
    set_int64(&capability_value, (int64_t)capabilities);
    Dart_CObject *values[] = {&type, &pid_value, &capability_value};
    return post_array(port, values, 3);
}

bool pty_post_spawn_failed(Dart_Port_DL port, const PtyError *error)
{
    Dart_CObject type;
    Dart_CObject domain;
    Dart_CObject kind;
    Dart_CObject code;
    Dart_CObject message;
    set_int32(&type, PTY_EVENT_SPAWN_FAILED);
    set_int32(&domain, error == NULL ? 0 : error->domain);
    set_int32(&kind, error == NULL ? 0 : error->kind);
    set_int64(&code, error == NULL ? 0 : error->os_code);
    set_string(&message, error == NULL ? "" : error->message);
    Dart_CObject *values[] = {&type, &domain, &kind, &code, &message};
    return post_array(port, values, 5);
}

bool pty_post_output(Dart_Port_DL port, const uint8_t *bytes, intptr_t length)
{
    Dart_CObject type;
    Dart_CObject payload;
    set_int32(&type, PTY_EVENT_OUTPUT);
    payload.type = Dart_CObject_kTypedData;
    payload.value.as_typed_data.type = Dart_TypedData_kUint8;
    payload.value.as_typed_data.length = length;
    payload.value.as_typed_data.values = (uint8_t *)bytes;
    Dart_CObject *values[] = {&type, &payload};
    return post_array(port, values, 2);
}

bool pty_post_write_complete(Dart_Port_DL port, uint64_t request_id)
{
    Dart_CObject type;
    Dart_CObject request;
    set_int32(&type, PTY_EVENT_WRITE_COMPLETE);
    set_int64(&request, (int64_t)request_id);
    Dart_CObject *values[] = {&type, &request};
    return post_array(port, values, 2);
}

bool pty_post_input_closed(Dart_Port_DL port, const PtyError *error)
{
    Dart_CObject type;
    Dart_CObject domain;
    Dart_CObject kind;
    Dart_CObject code;
    Dart_CObject message;
    set_int32(&type, PTY_EVENT_INPUT_CLOSED);
    set_int32(&domain, error == NULL ? 0 : error->domain);
    set_int32(&kind, error == NULL ? 0 : error->kind);
    set_int64(&code, error == NULL ? 0 : error->os_code);
    set_string(&message, error == NULL ? "" : error->message);
    Dart_CObject *values[] = {&type, &domain, &kind, &code, &message};
    return post_array(port, values, 5);
}

bool pty_post_process_exit(Dart_Port_DL port, bool signal_exit, int64_t value)
{
    Dart_CObject type;
    Dart_CObject exit_kind;
    Dart_CObject exit_value;
    set_int32(&type, PTY_EVENT_PROCESS_EXIT);
    set_int32(&exit_kind, signal_exit ? 1 : 0);
    set_int64(&exit_value, value);
    Dart_CObject *values[] = {&type, &exit_kind, &exit_value};
    return post_array(port, values, 3);
}

bool pty_post_error(Dart_Port_DL port, const PtyError *error)
{
    Dart_CObject type;
    Dart_CObject domain;
    Dart_CObject kind;
    Dart_CObject code;
    Dart_CObject message;
    set_int32(&type, PTY_EVENT_ASYNC_ERROR);
    set_int32(&domain, error == NULL ? 0 : error->domain);
    set_int32(&kind, error == NULL ? 0 : error->kind);
    set_int64(&code, error == NULL ? 0 : error->os_code);
    set_string(&message, error == NULL ? "" : error->message);
    Dart_CObject *values[] = {&type, &domain, &kind, &code, &message};
    return post_array(port, values, 5);
}
