import 'package:expert_chat/data/chat_skill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory catalog has five enabled skills and one fallback', () {
    final catalog = ChatSkillCatalog.factory();
    expect(catalog.skills.map((s) => s.id).toList(), [
      'general',
      'writing',
      'code',
      'translate',
      'summarize',
    ]);
    expect(catalog.fallback.id, 'general');
    expect(catalog.fallback.fallback, isTrue);
    expect(catalog.enabled, hasLength(5));
  });

  test('decode empty uses factory; legacy systemPrompt fills general', () {
    final catalog = ChatSkillCatalog.decode(
      null,
      legacySystemPrompt: '你是写作助手',
    );
    expect(catalog.skillById('general')?.prompt, '你是写作助手');
    expect(catalog.skillById('writing'), isNotNull);
  });

  test('sanitize restores a single enabled fallback', () {
    final broken = ChatSkillCatalog(const [
      ChatSkill(id: 'writing', name: '写作', when: '润色', prompt: '写'),
    ]);
    final fixed = broken.sanitize();
    expect(fixed.fallback.id, 'general');
    expect(fixed.skills.where((s) => s.fallback).length, 1);
  });

  test('matchPrefix prefers the longest enabled prefix', () {
    final catalog = ChatSkillCatalog.factory();
    expect(catalog.matchPrefix('/代码 重构这段')?.id, 'code');
    expect(catalog.matchPrefix('/代码重构这段')?.id, 'code');
    expect(catalog.matchPrefix('/代码\r\n重构这段')?.id, 'code');
    expect(catalog.matchPrefix('重构这段'), isNull);
  });

  test('matchPrefix longest startsWith wins on overlapping prefixes', () {
    final catalog = ChatSkillCatalog([
      ...ChatSkillCatalog.factory().skills,
      const ChatSkill(
        id: 'write-short',
        name: '写',
        when: '短写',
        prompt: '短',
        prefix: '/写',
      ),
    ]);
    expect(catalog.matchPrefix('/写作这段')?.id, 'writing');
    expect(catalog.matchPrefix('/写一段')?.id, 'write-short');
  });

  test('disabled skill prefix does not match', () {
    final catalog = ChatSkillCatalog.factory()
        .update((s) => s.id == 'code' ? s.copyWith(enabled: false) : s);
    expect(catalog.matchPrefix('/代码 重构这段'), isNull);
  });
}
