import 'dart:convert';
import 'package:expert_chat/data/prompt_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy prompt is preserved without overriding automatic routing', () {
    final p = PromptPresets.decode(null, legacyPrompt: 'my original prompt');
    expect(p.items.first.prompt, 'my original prompt');
    expect(p.active, isNull);
  });
  test('selection, ownership and updates survive a portable round trip', () {
    const original = PromptPresets(
      activeId: 'one',
      items: [
        PromptPreset(
          id: 'one',
          name: 'first',
          prompt: 'first prompt',
          ownerId: 'account-a',
          updatedAt: 42,
        ),
        PromptPreset(id: 'two', name: 'second', prompt: 'second prompt'),
      ],
    );
    final restored = PromptPresets.decode(jsonEncode(original.toJson()));
    expect(restored.active?.prompt, 'first prompt');
    expect(restored.active?.ownerId, 'account-a');
    expect(restored.active?.updatedAt, 42);
    expect(
      PromptPresets(items: restored.items, activeId: 'two').active?.prompt,
      'second prompt',
    );
    expect(restored.items.first.prompt, 'first prompt');
  });
  test('removed and invalid selection returns to automatic routing', () {
    final p = PromptPresets.decode('{"items":[],"activeId":"missing"}');
    expect(p.activeId, isNull);
    expect(p.items, isEmpty);
  });
}
