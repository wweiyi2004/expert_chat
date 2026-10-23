# Turn Skill Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In ordinary chat only, classify each turn into a user-editable skill catalog and inject that skill's prompt before generation.

**Architecture:** A JSON skill catalog lives in settings. `ChatSkillRouter` either matches a prefix or asks the current chat model for `{"skill","confidence"}`, then `ChatController` injects only that skill's `prompt`. Adding a skill is appending a catalog entry; the classifier prompt is rebuilt from the enabled list.

**Tech Stack:** Flutter, Riverpod, existing `LlmProvider.streamChat`, SharedPreferences, Drift schema v12 for per-message route metadata.

**Spec:** `docs/superpowers/specs/2026-08-16-turn-skill-router-design.md`

## Global Constraints

- Only `ConversationMode.chat`; story / ensemble / study skip the router
- Per-turn only; do not persist a conversation-level skill
- Classifier uses the active profile chat model (not reasoner), `thinking: false`, 10s timeout
- Classifier output is JSON only: `{"skill":"<id>","confidence":0.0}`
- `confidence < 0.6`, bad JSON, unknown id, timeout → fallback skill; never block generation
- Prefix on an enabled skill beats the classifier
- Catalog always has exactly one enabled `fallback: true` skill
- Existing `settings.systemPrompt` migrates into `general.prompt`
- Do not dump every skill prompt into the main system message

## File map

- Create `lib/data/chat_skill.dart` — `ChatSkill`, `ChatSkillCatalog`, factory defaults, sanitize, codec
- Create `lib/domain/chat/chat_skill_router.dart` — prefix, classifier prompts, JSON parse, `route()`
- Create `test/chat_skill_test.dart`
- Create `test/chat_skill_router_test.dart`
- Modify `lib/state/settings_controller.dart` — persist catalog, migrate, `setChatSkills`
- Modify `test/settings_migration_test.dart` — migration cases
- Modify `lib/data/models.dart` — `turnSkill` on `ChatMessage`
- Modify `lib/data/db/app_database.dart` — schema 12 `turnSkillJson`
- Modify `lib/data/drift_conversation_repository.dart` — map the new field
- Modify `lib/state/chat_controller.dart` — route then inject
- Modify `lib/features/settings/settings_page.dart` — catalog editor
- Modify `lib/features/chat/widgets/message_bubble.dart` — 本轮 skill chip
- Modify `test/widget_test.dart` / `test/message_bubble_test.dart` as needed

---

### Task 1: Catalog model, factory defaults, sanitize

**Files:**
- Create: `lib/data/chat_skill.dart`
- Test: `test/chat_skill_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `class ChatSkill` with `id`, `name`, `when`, `prompt`, `prefix`, `enabled`, `fallback`, `builtIn`
  - `class ChatSkillCatalog` wrapping `List<ChatSkill> skills`
  - `ChatSkillCatalog.factory()` — five built-ins
  - `ChatSkillCatalog.decode(String? raw, {String legacySystemPrompt = ''})`
  - `String ChatSkillCatalog.encode()`
  - `ChatSkillCatalog ChatSkillCatalog.sanitize()`
  - `ChatSkill? enabledById(String id)`
  - `ChatSkill get fallback`
  - `List<ChatSkill> get enabled`
  - `ChatSkill? matchPrefix(String userText)`
  - `kChatSkillMinConfidence = 0.6`

- [ ] **Step 1: Write the failing test**

```dart
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
    expect(catalog.matchPrefix('重构这段'), isNull);
  });

  test('disabled skill prefix does not match', () {
    final catalog = ChatSkillCatalog.factory()
        .update((s) => s.id == 'code' ? s.copyWith(enabled: false) : s);
    expect(catalog.matchPrefix('/代码 重构这段'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/chat_skill_test.dart`

Expected: FAIL compiling (`chat_skill.dart` not found)

- [ ] **Step 3: Write minimal implementation**

`lib/data/chat_skill.dart`:

```dart
import 'dart:convert';

const kChatSkillMinConfidence = 0.6;

class ChatSkill {
  const ChatSkill({
    required this.id,
    required this.name,
    required this.when,
    required this.prompt,
    this.prefix = '',
    this.enabled = true,
    this.fallback = false,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String when;
  final String prompt;
  final String prefix;
  final bool enabled;
  final bool fallback;
  final bool builtIn;

  ChatSkill copyWith({
    String? name,
    String? when,
    String? prompt,
    String? prefix,
    bool? enabled,
    bool? fallback,
  }) => ChatSkill(
    id: id,
    name: name ?? this.name,
    when: when ?? this.when,
    prompt: prompt ?? this.prompt,
    prefix: prefix ?? this.prefix,
    enabled: enabled ?? this.enabled,
    fallback: fallback ?? this.fallback,
    builtIn: builtIn,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'when': when,
    'prompt': prompt,
    'prefix': prefix,
    'enabled': enabled,
    'fallback': fallback,
    'builtIn': builtIn,
  };

  factory ChatSkill.fromJson(Map<String, dynamic> json) => ChatSkill(
    id: (json['id'] as String? ?? '').trim(),
    name: (json['name'] as String? ?? '').trim(),
    when: (json['when'] as String? ?? '').trim(),
    prompt: json['prompt'] as String? ?? '',
    prefix: (json['prefix'] as String? ?? '').trim(),
    enabled: json['enabled'] as bool? ?? true,
    fallback: json['fallback'] as bool? ?? false,
    builtIn: json['builtIn'] as bool? ?? false,
  );
}

class ChatSkillCatalog {
  const ChatSkillCatalog(this.skills);
  final List<ChatSkill> skills;

  static ChatSkillCatalog factory({String generalPrompt = ''}) {
    final general = generalPrompt.trim().isEmpty
        ? '用简洁中文直接回答；先给结论；不确定就说明不确定。不要客套。'
        : generalPrompt.trim();
    return ChatSkillCatalog([
      ChatSkill(
        id: 'general',
        name: '通用',
        when: '闲聊、问答、无法归入其它种类时',
        prompt: general,
        prefix: '/通用',
        fallback: true,
        builtIn: true,
      ),
      const ChatSkill(
        id: 'writing',
        name: '写作',
        when: '润色、续写、改文体、写正文',
        prompt: '按用户指定文体改写或续写。未指定则用清晰现代中文。默认只输出正文，除非用户要求对照说明。不要擅自换风格或加标题。',
        prefix: '/写作',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'code',
        name: '代码',
        when: '写代码、改 bug、解释或审查代码',
        prompt: '先定位问题，再给最小改动。说明假设和风险。不要重写无关代码。代码放在带语言标记的 Markdown 围栏里。',
        prefix: '/代码',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'translate',
        name: '翻译',
        when: '翻译、对照译文、保留术语',
        prompt: '忠实原文语气与专有名词。只给译文，除非用户要求对照或注释。拿不准的词语标出来。',
        prefix: '/翻译',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'summarize',
        name: '总结',
        when: '摘要、要点、归纳长文',
        prompt: '用条目列出要点，不扩写、不评价。保留关键数字、名称和结论。',
        prefix: '/总结',
        builtIn: true,
      ),
    ]);
  }

  factory ChatSkillCatalog.decode(
    String? raw, {
    String legacySystemPrompt = '',
  }) {
    if (raw == null || raw.trim().isEmpty) {
      return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
      }
      final skills = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) ChatSkill.fromJson(item),
      ].where((s) => s.id.isNotEmpty).toList();
      return ChatSkillCatalog(skills).sanitize(
        legacySystemPrompt: legacySystemPrompt,
      );
    } catch (_) {
      return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    }
  }

  String encode() => jsonEncode([for (final s in skills) s.toJson()]);

  ChatSkill? skillById(String id) {
    for (final s in skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<ChatSkill> get enabled =>
      [for (final s in skills) if (s.enabled) s];

  ChatSkill get fallback {
    for (final s in skills) {
      if (s.fallback && s.enabled) return s;
    }
    return ChatSkillCatalog.factory().fallback;
  }

  ChatSkill? matchPrefix(String userText) {
    final value = userText.trimLeft();
    ChatSkill? best;
    var bestLen = 0;
    for (final s in enabled) {
      final prefix = s.prefix.trim();
      if (prefix.isEmpty) continue;
      if (value == prefix ||
          value.startsWith('$prefix ') ||
          value.startsWith('$prefix\n')) {
        if (prefix.length > bestLen) {
          best = s;
          bestLen = prefix.length;
        }
      }
    }
    return best;
  }

  ChatSkillCatalog update(ChatSkill Function(ChatSkill skill) map) =>
      ChatSkillCatalog([for (final s in skills) map(s)]);

  ChatSkillCatalog sanitize({String legacySystemPrompt = ''}) {
    final factory = ChatSkillCatalog.factory(
      generalPrompt: legacySystemPrompt,
    );
    if (skills.isEmpty) return factory;
    final byId = <String, ChatSkill>{};
    for (final s in skills) {
      if (s.id.isEmpty) continue;
      byId[s.id] = s;
    }
    var list = byId.values.toList();
    final enabledFallbacks = [
      for (final s in list)
        if (s.fallback && s.enabled) s,
    ];
    if (enabledFallbacks.isEmpty) {
      final general = byId['general'] ?? factory.fallback;
      list = [
        for (final s in list)
          if (s.id == general.id)
            general.copyWith(enabled: true, fallback: true)
          else
            s.copyWith(fallback: false),
        if (!byId.containsKey(general.id))
          general.copyWith(enabled: true, fallback: true),
      ];
    } else if (enabledFallbacks.length > 1) {
      final keep = byId['general']?.fallback == true &&
              (byId['general']?.enabled ?? false)
          ? 'general'
          : enabledFallbacks.first.id;
      list = [
        for (final s in list)
          s.copyWith(fallback: s.id == keep && s.enabled),
      ];
    }
    return ChatSkillCatalog(list);
  }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `flutter test test/chat_skill_test.dart`

Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/data/chat_skill.dart test/chat_skill_test.dart
git commit -m "feat: add editable chat skill catalog model"
```

---

### Task 2: Persist catalog and migrate `systemPrompt`

**Files:**
- Modify: `lib/state/settings_controller.dart`
- Test: `test/settings_migration_test.dart`

**Interfaces:**
- Consumes: `ChatSkillCatalog.decode/encode/sanitize`
- Produces:
  - `SettingsState.chatSkills` (`ChatSkillCatalog`)
  - `SettingsState.systemPrompt` remains a getter: `chatSkills.fallback.prompt` (keep the stored field in sync for `copyWith` callers, or replace field with getter + update every `copyWith` / constructor site)
  - `SettingsController.setChatSkills(ChatSkillCatalog catalog)`
  - `setSystemPrompt` writes into the fallback/`general` prompt then persists the catalog
  - prefs key `_kChatSkills = 'chatSkills'`
  - load: if `chatSkills` missing, `decode(null, legacySystemPrompt: old systemPrompt)`

Preferred compatibility: keep `SettingsState.systemPrompt` as a real field, set it to `catalog.fallback.prompt` on load and whenever the catalog is saved, so existing `copyWith(systemPrompt:)` / widget tests keep compiling. `setSystemPrompt(text)` updates `general` (or current fallback) prompt + `systemPrompt` + catalog JSON.

- [ ] **Step 1: Write the failing test**

Add to `test/settings_migration_test.dart`:

```dart
test('legacy systemPrompt migrates into the general chat skill', () async {
  SharedPreferences.setMockInitialValues({
    'systemPrompt': '你是专业助手',
  });
  FlutterSecureStoragePlatform.instance =
      TestFlutterSecureStoragePlatform({});
  addTearDown(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
    ],
  );
  addTearDown(container.dispose);

  final state = await container.read(settingsControllerProvider.future);
  expect(state.chatSkills.skillById('general')?.prompt, '你是专业助手');
  expect(state.chatSkills.skillById('writing'), isNotNull);
  expect(state.systemPrompt, '你是专业助手');
  expect(prefs.getString('chatSkills'), isNotNull);
});

test('setChatSkills rejects a catalog with no fallback by sanitizing', () async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStoragePlatform.instance =
      TestFlutterSecureStoragePlatform({});
  addTearDown(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsControllerProvider.future);
  final controller = container.read(settingsControllerProvider.notifier);
  await controller.setChatSkills(
    const ChatSkillCatalog([
      ChatSkill(id: 'only', name: '仅此', when: 'x', prompt: 'y'),
    ]),
  );
  final next = container.read(settingsControllerProvider).requireValue;
  expect(next.chatSkills.fallback.enabled, isTrue);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/settings_migration_test.dart`

Expected: FAIL — `chatSkills` / `setChatSkills` missing

- [ ] **Step 3: Write minimal implementation**

In `SettingsState`:
- add `this.chatSkills = const ChatSkillCatalog([])` — actually default to `ChatSkillCatalog.factory()` is safer; empty lists must be sanitized on read
- add `chatSkills` to constructor + `copyWith`
- load: `chatSkills: ChatSkillCatalog.decode(prefs.getString(_kChatSkills), legacySystemPrompt: prefs.getString(_kSystemPrompt) ?? '')`
- after decode, `systemPrompt: catalog.fallback.prompt`
- persist catalog JSON under `_kChatSkills`; keep writing `_kSystemPrompt` as fallback prompt so old readers still see something

```dart
Future<void> setChatSkills(ChatSkillCatalog catalog) async {
  final next = catalog.sanitize(
    legacySystemPrompt: _current.systemPrompt,
  );
  state = AsyncData(
    _current.copyWith(
      chatSkills: next,
      systemPrompt: next.fallback.prompt,
    ),
  );
  final prefs = ref.read(sharedPrefsProvider);
  await prefs.setString(_kChatSkills, next.encode());
  await prefs.setString(_kSystemPrompt, next.fallback.prompt);
}

Future<void> setSystemPrompt(String prompt) async {
  final updated = _current.chatSkills.update(
    (s) => s.id == _current.chatSkills.fallback.id
        ? s.copyWith(prompt: prompt)
        : s,
  );
  await setChatSkills(updated);
}
```

Import `../data/chat_skill.dart`.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `flutter test test/settings_migration_test.dart test/widget_test.dart`

Expected: PASS (widget_test that reads `systemPrompt` after deleteProfile still works)

- [ ] **Step 5: Commit**

```bash
git add lib/state/settings_controller.dart test/settings_migration_test.dart
git commit -m "feat: persist chat skill catalog and migrate systemPrompt"
```

---

### Task 3: Router — prefix, classifier JSON, fake LLM

**Files:**
- Create: `lib/domain/chat/chat_skill_router.dart`
- Test: `test/chat_skill_router_test.dart`

**Interfaces:**
- Consumes: `ChatSkillCatalog`, `LlmProvider.streamChat`, `LlmConfig`, `ChatMessage`
- Produces:

```dart
enum ChatSkillSource { prefix, model, fallback }

class ChatSkillRoute {
  const ChatSkillRoute({
    required this.skill,
    required this.source,
    this.confidence,
  });
  final ChatSkill skill;
  final ChatSkillSource source;
  final double? confidence;
}

class ChatSkillRouter {
  const ChatSkillRouter();

  String classifierSystemPrompt(ChatSkillCatalog catalog);
  String classifierUserPrompt({
    required String userText,
    required List<ChatMessage> recent,
  });

  ChatSkillRoute parseClassifierOutput(
    String raw,
    ChatSkillCatalog catalog,
  );

  Future<ChatSkillRoute> route({
    required String userText,
    required List<ChatMessage> recent,
    required ChatSkillCatalog catalog,
    required LlmProvider llm,
    required LlmConfig config,
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 10),
  });
}
```

`classifierSystemPrompt` lists only enabled `id/name/when` (never `prompt`) and requires a single JSON object. `route()`: prefix → return prefix source without calling `llm`; else `streamChat` with `thinking: false`, join content deltas, parse; any failure → fallback.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:dio/dio.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/chat_skill_router.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.output, {this.onCall});
  final String output;
  int calls = 0;
  void Function(List<LlmRequestMessage> messages)? onCall;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls += 1;
    onCall?.call(messages);
    expect(thinking, isFalse);
    yield ChatChunk(contentDelta: output);
  }
}

void main() {
  final catalog = ChatSkillCatalog.factory();
  const router = ChatSkillRouter();
  const config = LlmConfig(
    baseUrl: 'https://example.com',
    apiKey: 'k',
    model: 'chat',
  );

  test('prefix skips the classifier', () async {
    final llm = _FakeLlm('{"skill":"writing","confidence":0.99}');
    final route = await router.route(
      userText: '/代码 重构这段',
      recent: const [],
      catalog: catalog,
      llm: llm,
      config: config,
    );
    expect(route.skill.id, 'code');
    expect(route.source, ChatSkillSource.prefix);
    expect(llm.calls, 0);
  });

  test('valid classifier json selects that skill', () async {
    final llm = _FakeLlm('{"skill":"writing","confidence":0.9}');
    final route = await router.route(
      userText: '把这段改得更顺',
      recent: const [],
      catalog: catalog,
      llm: llm,
      config: config,
    );
    expect(route.skill.id, 'writing');
    expect(route.source, ChatSkillSource.model);
    expect(llm.calls, 1);
  });

  test('classifier prompt lists a newly added skill id', () {
    final custom = ChatSkillCatalog([
      ...catalog.skills,
      const ChatSkill(
        id: 'legal',
        name: '法务',
        when: '合同、条款、合规',
        prompt: '只指出风险',
      ),
    ]);
    final system = router.classifierSystemPrompt(custom);
    expect(system, contains('legal'));
    expect(system, contains('合同、条款、合规'));
    expect(system, isNot(contains('只指出风险')));
  });

  test('unknown id, low confidence, and bad json fall back', () async {
    for (final raw in [
      '{"skill":"nope","confidence":0.99}',
      '{"skill":"writing","confidence":0.2}',
      'not-json',
    ]) {
      final route = await router.route(
        userText: '你好',
        recent: const [],
        catalog: catalog,
        llm: _FakeLlm(raw),
        config: config,
      );
      expect(route.skill.id, 'general', reason: raw);
      expect(route.source, ChatSkillSource.fallback);
    }
  });

  test('classifier user prompt includes recent turns and strips nothing required', () {
    final text = router.classifierUserPrompt(
      userText: '再短一点',
      recent: [
        ChatMessage(role: MessageRole.user, content: '写一段开场'),
        ChatMessage(role: MessageRole.assistant, content: '很长的开场……'),
      ],
    );
    expect(text, contains('再短一点'));
    expect(text, contains('写一段开场'));
  });
}
```

`ChatChunk` — confirm constructor in `llm_provider.dart`. If the field is `contentDelta` on a different type, match the real class.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/chat_skill_router_test.dart`

Expected: FAIL compiling

- [ ] **Step 3: Write minimal implementation**

`parseClassifierOutput`:
- trim, strip optional ` ```json ` fence
- `jsonDecode`
- read `skill` string + `confidence` num (missing confidence → treat as 0)
- if skill not in `catalog.enabled` ids or confidence < `kChatSkillMinConfidence` → fallback route

`route`:
```dart
final prefixed = catalog.matchPrefix(userText);
if (prefixed != null) {
  return ChatSkillRoute(skill: prefixed, source: ChatSkillSource.prefix);
}
try {
  final buf = StringBuffer();
  await for (final chunk in llm.streamChat(
    config: config,
    thinking: false,
    cancelToken: cancelToken,
    messages: [
      LlmRequestMessage(
        role: MessageRole.system,
        content: classifierSystemPrompt(catalog),
      ),
      LlmRequestMessage(
        role: MessageRole.user,
        content: classifierUserPrompt(userText: userText, recent: recent),
      ),
    ],
  ).timeout(timeout)) {
    if (chunk.contentDelta != null) buf.write(chunk.contentDelta);
  }
  return parseClassifierOutput(buf.toString(), catalog);
} catch (_) {
  return ChatSkillRoute(skill: catalog.fallback, source: ChatSkillSource.fallback);
}
```

Classifier system prompt (fixed Chinese, interpolate enabled rows):

```
你是任务分类器。只根据用户本轮任务，从下列种类中选一个 id。
种类：
- general：闲聊、问答、无法归入其它种类时
...
只输出一个 JSON 对象，不要 Markdown，不要解释：
{"skill":"种类id","confidence":0到1}
skill 必须是上列 id 之一。没有把握时选 fallback 那个 id，并把 confidence 压低。
```

Use the actual fallback id in that last sentence. Do not include `prompt` fields.

Recent history: last 4 messages (2 turns) of user/assistant text, each clipped to 400 chars.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `flutter test test/chat_skill_router_test.dart`

Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/domain/chat/chat_skill_router.dart test/chat_skill_router_test.dart
git commit -m "feat: add JSON chat skill router"
```

---

### Task 4: Persist route on the assistant message (Drift v12)

**Files:**
- Modify: `lib/data/models.dart` — `ChatMessage.turnSkill`
- Modify: `lib/data/db/app_database.dart` — `schemaVersion => 12`, `messages.turnSkillJson`
- Modify: `lib/data/drift_conversation_repository.dart` — encode/decode
- Run: `dart run build_runner build --delete-conflicting-outputs`
- Test: extend `test/drift_conversation_repository_test.dart` or `test/json_conversation_repository_test.dart`

**Interfaces:**
- Consumes: `ChatSkillRoute` / a small `TurnSkillMark`
- Produces:

```dart
class TurnSkillMark {
  const TurnSkillMark({required this.id, required this.name, required this.source});
  final String id;
  final String name;
  final ChatSkillSource source;
  Map<String, dynamic> toJson();
  factory TurnSkillMark.fromJson(Map<String, dynamic> json);
}
```

Put `TurnSkillMark` in `lib/data/chat_skill.dart` to avoid domain→data cycles (`ChatSkillSource` can live in `chat_skill.dart` too; router imports it). If `ChatSkillSource` was defined in the router file in Task 3, move the enum + mark into `chat_skill.dart` in this task and update imports.

- [ ] **Step 1: Write the failing test**

Round-trip a message with `turnSkill: TurnSkillMark(id: 'writing', name: '写作', source: ChatSkillSource.model)` through `ChatMessage.toJson/fromJson`. If the drift test helper already saves/reloads a conversation, assert the mark survives `saveAll`/`loadAll`.

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — field missing

- [ ] **Step 3: Write minimal implementation**

- Add nullable `TurnSkillMark? turnSkill` to `ChatMessage` (constructor, `copyWith` with sentinel, `toJson`/`fromJson`)
- `Messages.turnSkillJson` nullable text; `schemaVersion = 12`; `if (from < 12) await m.addColumn(messages, messages.turnSkillJson);`
- Map in `_toMessage` / companion insert like `longTaskJson`
- Run build_runner so `app_database.g.dart` updates

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `flutter test test/drift_conversation_repository_test.dart test/json_conversation_repository_test.dart`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/data/models.dart lib/data/chat_skill.dart lib/data/db/app_database.dart lib/data/db/app_database.g.dart lib/data/drift_conversation_repository.dart test
git commit -m "feat: persist per-turn skill mark on messages"
```

---

### Task 5: Inject routed prompt in `_generate`

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Test: `test/widget_test.dart` or a focused `test/chat_skill_injection_test.dart`

**Interfaces:**
- Consumes: `ChatSkillRouter.route`, `settings.chatSkills`, `settings.config` (chat model, not `_configFor` reasoner)
- Produces: chat-mode system preset is `route.skill.prompt` (empty prompt → no extra system message). Story/study/ensemble unchanged. Assistant message gets `turnSkill` mark.

In the non-story branch of `_generate` (the block that currently does `final preset = settings.systemPrompt.trim()` around line 3342):

```dart
ChatSkillRoute? skillRoute;
if (cur.mode == ConversationMode.chat) {
  final userText = /* content of the user message that created this turn */;
  final recent = /* last ≤4 user/assistant messages before this turn */;
  skillRoute = await const ChatSkillRouter().route(
    userText: userText,
    recent: recent,
    catalog: settings.chatSkills,
    llm: _llmFor(settings.config), // same provider as chat, chat model
    config: settings.config,        // NOT reasoner
    cancelToken: /* the turn cancel token if available */,
  );
}
final preset = cur.mode == ConversationMode.chat
    ? (skillRoute?.skill.prompt.trim() ?? '')
    : settings.systemPrompt.trim();
```

Study conversations currently also inject `settings.systemPrompt`. After this change they must **not** get the catalog (spec: 学习不注入该目录). So the `preset` insert stays only for `ConversationMode.chat`.

When creating/updating the assistant `ChatMessage`, set `turnSkill` from `skillRoute`.

Resolve the user text from the working conversation: the parent user message of `assistantId`.

Do not call the router if `!settings.config.isReady` — fallback mark, no request.

- [ ] **Step 1: Write the failing test**

Prefer a unit-level test that constructs a `ChatController` with a fake LLM if the existing widget tests already stub the provider. If that is too heavy, add a test around a small extracted helper:

```dart
String presetForTurn({
  required ConversationMode mode,
  required ChatSkillRoute? route,
  required String globalSystemPrompt,
})
```

in `chat_skill_router.dart` or a tiny `chat_skill_injection.dart`:

```dart
String chatPresetPrompt({
  required ConversationMode mode,
  required ChatSkillRoute? route,
  required String fallbackPrompt,
}) {
  if (mode != ConversationMode.chat) return '';
  return route?.skill.prompt.trim() ?? fallbackPrompt;
}
```

Test: story/study → `''`; chat + writing route → writing prompt; chat + null route → fallback prompt.

Also test: after a chat send with fake classifier, the assistant message `turnSkill?.id` is `writing`. Use the existing widget test harness if it already fakes `LlmProvider`.

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Write minimal implementation** in `_generate` as specified. Keep memory/tool hints order unchanged.

- [ ] **Step 4: Run** `flutter test test/chat_skill_router_test.dart test/widget_test.dart test/chat_skill_injection_test.dart`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/state/chat_controller.dart test
git commit -m "feat: inject per-turn skill prompt in chat generate"
```

---

### Task 6: Settings editor + bubble label

**Files:**
- Modify: `lib/features/settings/settings_page.dart` — replace the single `TextField` under `预设提示词` (around lines 607–622)
- Modify: `lib/features/chat/widgets/message_bubble.dart` — chip above content, next to world-info bar
- Test: `test/settings_category_navigation_test.dart` and/or `test/message_bubble_test.dart`

**Interfaces:**
- Consumes: `SettingsController.setChatSkills`, `ChatMessage.turnSkill`
- Produces: list of expansion tiles (name, when, prompt, prefix, enabled switch). Add button appends `ChatSkill(id: uuid, name, when, prompt, prefix)`. Delete hidden for `builtIn`. Cannot turn off the last fallback (switch no-ops / snackbar). Chip text: `本轮：写作` with subtitle `自动` / `已指定` / `回退`.

- [ ] **Step 1: Write the failing widget tests**

```dart
testWidgets('preset prompt section lists factory skill names', (tester) async {
  // pump settings on model category with default settings
  expect(find.text('写作'), findsWidgets);
  expect(find.text('添加任务类型'), findsOneWidget);
});

testWidgets('assistant bubble shows turn skill chip', (tester) async {
  // pump MessageBubble with turnSkill writing / model
  expect(find.textContaining('本轮：写作'), findsOneWidget);
  expect(find.text('自动'), findsOneWidget);
});
```

Follow existing settings / bubble test pump helpers in those files; do not invent a new app shell if a smaller pump already exists.

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement UI**

Settings: `ListView`/`Column` of cards. Each card:
- `TextField` name / when / prefix / prompt (`prompt` 4–8 lines)
- `Switch` enabled
- delete `IconButton` if `!builtIn`
- on change → `setChatSkills(catalog with that item replaced)`

Add: dialog requiring non-empty name and when; `id = 'custom_${uuid}'`; `prefix` default `/${name}`.

Helper under the section: `分类器只根据「何时选用」选择种类；提示词只在选中后注入。`

Bubble: if `m.turnSkill != null`, a small outlined chip. Source labels: `prefix` → `已指定`, `model` → `自动`, `fallback` → `回退`.

Optional light `/` hint: when composer text is exactly `/`, show a one-line wrap of enabled prefixes. Skip if the composer widget has no cheap hook; do not block this task on autocomplete.

- [ ] **Step 4: Run** `flutter test test/message_bubble_test.dart test/settings_category_navigation_test.dart test/chat_skill_test.dart test/chat_skill_router_test.dart test/settings_migration_test.dart`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/features/settings/settings_page.dart lib/features/chat/widgets/message_bubble.dart test
git commit -m "feat: edit chat skills in settings and show turn chip"
```

---

## Spec coverage

| Spec section | Task |
|--------------|------|
| JSON catalog fields | 1 |
| factory five skills + fallback invariant | 1–2 |
| migrate `systemPrompt` | 2 |
| add skill = append category | 1, 6 |
| classifier JSON contract | 3 |
| prefix beats model | 3, 5 |
| chat-only, per-turn | 5 |
| current chat model, not reasoner | 5 |
| 10s timeout / bad JSON / low confidence | 3 |
| inject only selected prompt | 5 |
| study/story skip | 5 |
| persist mark + bubble | 4, 6 |
| settings editor | 6 |

## Type names locked

- `ChatSkill`, `ChatSkillCatalog`, `ChatSkillSource`, `ChatSkillRoute`, `TurnSkillMark`
- `ChatSkillRouter.route`, `classifierSystemPrompt`, `parseClassifierOutput`
- `SettingsState.chatSkills`, `setChatSkills`
- `ChatMessage.turnSkill`
- prefs `chatSkills`; drift `turnSkillJson`; schema 12
