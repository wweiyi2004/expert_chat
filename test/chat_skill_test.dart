import 'package:expert_chat/data/chat_skill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory catalog has six enabled skills and one fallback', () {
    final catalog = ChatSkillCatalog.factory();
    expect(catalog.skills.map((s) => s.id).toList(), [
      'general',
      'writing',
      'code',
      'translate',
      'summarize',
      'image-prompt',
    ]);
    expect(catalog.fallback.id, 'general');
    expect(catalog.fallback.fallback, isTrue);
    expect(catalog.enabled, hasLength(6));
    expect(catalog.skillById('image-prompt')?.prefix, '/生图提示');
  });

  test('decode empty uses factory; legacy systemPrompt fills general', () {
    final catalog = ChatSkillCatalog.decode(null, legacySystemPrompt: '你是写作助手');
    expect(catalog.skillById('general')?.prompt, '你是写作助手');
    expect(catalog.skillById('writing'), isNotNull);
  });

  test('decode empty upgrades the previous factory general prompt', () {
    final catalog = ChatSkillCatalog.decode(
      null,
      legacySystemPrompt: '用简洁中文直接回答；先给结论；不确定就说明不确定。不要客套。',
    );

    expect(catalog.fallback.prompt, contains('R18'));
  });

  test('decode upgrades untouched legacy built-in prompts', () {
    const oldGeneral = '用简洁中文直接回答；先给结论；不确定就说明不确定。不要客套。';
    const oldWriting =
        '按用户指定文体改写或续写。未指定则用清晰现代中文。默认只输出正文，除非用户要求对照说明。不要擅自换风格或加标题。';
    final raw = ChatSkillCatalog([
      const ChatSkill(
        id: 'general',
        name: '通用',
        when: '问答',
        prompt: oldGeneral,
        fallback: true,
        builtIn: true,
      ),
      const ChatSkill(
        id: 'writing',
        name: '写作',
        when: '写正文',
        prompt: oldWriting,
        builtIn: true,
      ),
    ]).encode();

    final catalog = ChatSkillCatalog.decode(raw);

    expect(catalog.skillById('general')!.prompt, contains('R18'));
    expect(catalog.skillById('writing')!.prompt, contains('无需自动淡出'));
    expect(catalog.skillById('image-prompt')?.prefix, '/生图提示');
  });

  test('decode of a previous factory catalog adds image-prompt', () {
    final raw = ChatSkillCatalog([
      for (final skill in ChatSkillCatalog.factory().skills)
        if (skill.id != 'image-prompt') skill,
    ]).encode();

    final catalog = ChatSkillCatalog.decode(raw);

    expect(catalog.skillById('image-prompt')?.prefix, '/生图提示');
    expect(catalog.skills.map((s) => s.id).toList(), [
      'general',
      'writing',
      'code',
      'translate',
      'summarize',
      'image-prompt',
    ]);
  });

  test('decode preserves a user-edited built-in prompt', () {
    final raw = ChatSkillCatalog(const [
      ChatSkill(
        id: 'general',
        name: '通用',
        when: '问答',
        prompt: '这是我自己改过的提示词',
        fallback: true,
        builtIn: true,
      ),
    ]).encode();

    final catalog = ChatSkillCatalog.decode(raw);

    expect(catalog.fallback.prompt, '这是我自己改过的提示词');
  });

  test('sanitize restores a single enabled fallback', () {
    final broken = ChatSkillCatalog(const [
      ChatSkill(id: 'writing', name: '写作', when: '润色', prompt: '写'),
    ]);
    final fixed = broken.sanitize();
    expect(fixed.fallback.id, 'general');
    expect(fixed.skills.where((s) => s.fallback).length, 1);
    expect(fixed.skillById('image-prompt'), isNotNull);
  });

  test(
    'sanitize merges missing factory built-ins without overwriting edits',
    () {
      final broken = ChatSkillCatalog([
        for (final skill in ChatSkillCatalog.factory().skills)
          if (skill.id != 'image-prompt')
            skill.id == 'writing' ? skill.copyWith(prompt: '我改过的写作') : skill,
      ]);
      final fixed = broken.sanitize();
      expect(fixed.skillById('writing')!.prompt, '我改过的写作');
      expect(fixed.skillById('image-prompt')!.builtIn, isTrue);
      expect(fixed.skillById('image-prompt')!.prompt, contains('无需自动淡出'));
    },
  );

  test('matchPrefix prefers the longest enabled prefix', () {
    final catalog = ChatSkillCatalog.factory();
    expect(catalog.matchPrefix('/代码 重构这段')?.id, 'code');
    expect(catalog.matchPrefix('/代码重构这段')?.id, 'code');
    expect(catalog.matchPrefix('/代码\r\n重构这段')?.id, 'code');
    expect(catalog.matchPrefix('/生图提示 一只猫')?.id, 'image-prompt');
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
    final catalog = ChatSkillCatalog.factory().update(
      (s) => s.id == 'code' ? s.copyWith(enabled: false) : s,
    );
    expect(catalog.matchPrefix('/代码 重构这段'), isNull);
  });
}
