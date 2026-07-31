# speech_to_text_windows (Expert Chat patch)

Patched fork of `speech_to_text_windows` 1.0.1.

## Why

Upstream never calls SAPI `SetInterest` / `SetNotifyWin32Event`, so
`listen()` reports success but recognition events are never delivered.
This copy:

- Subscribes to recognition / hypothesis / sound events
- Prefers the shared desktop recognizer (language packs)
- Enumerates installed recognizer locales (including Chinese packs)
- JSON-escapes recognized text before sending to Dart

Used via `dependency_overrides` in the app `pubspec.yaml`.
