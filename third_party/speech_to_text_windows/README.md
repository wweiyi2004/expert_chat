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

## Maintenance

Owner: Expert Chat maintainer. Review after every Flutter / speech_to_text upgrade and by 2026-10-22.

Upstream baseline is the published `speech_to_text_windows` 1.0.1 package; this repository does not claim an upstream issue or merged fix that has not been verified. Keep this source and its LICENSE together. To retire the override, compare with the upstream implementation and verify on Windows with a Chinese language pack: permission denial, start/stop/cancel, recognizer events, transcripts, and consecutive sessions. The Dart fake-platform tests alone do not prove native SAPI recognition works.

Do not add unrelated app behavior to this fork. Record any further patch's trigger, changed native behavior and device validation here.
