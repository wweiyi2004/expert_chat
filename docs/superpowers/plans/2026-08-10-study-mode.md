# Study Mode Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship in-app 学习模式 with hub + tutor / course / quiz / review paths (full first version per design spec).

**Architecture:** New `ShellTab.study` hub (like Studio). Study data in JSON repository (SharedPreferences / file). Study chats use `ConversationMode.study` with prompt injection via `StudyPromptAssembler`. Shared quiz/SRS/card modules across paths.

**Tech Stack:** Flutter, Riverpod, existing LlmProvider, SharedPreferences-backed StudyRepository (no Drift schema bump in v1).

**Spec:** `docs/superpowers/specs/2026-08-10-study-mode-design.md`

## Global Constraints

- No RAG/OCR; no cloud sync
- `studyModeEnabled` default **true**
- Learning conversations: `mode = study`; list badge + hub “继续学习”
- Reuse active LLM provider; study prompts default no web search force
- Four paths must be real loops, not empty stubs

---

### Task 1: Domain models + SRS + quiz codec + prompts

**Files:**
- Create: `lib/data/study_models.dart`
- Create: `lib/domain/study/srs_scheduler.dart`
- Create: `lib/domain/study/quiz_codec.dart`
- Create: `lib/domain/study/study_prompt_assembler.dart`
- Create: `lib/domain/study/tutor_style.dart`
- Create: `lib/domain/study/course_tree.dart`
- Test: `test/study_mode_test.dart`

- [ ] Models: StudyCourse, StudyNode, StudyQuizItem, StudyWrongItem, StudyCard, StudySessionMeta, enums
- [ ] `SrsScheduler.apply(card, rating)` pure function + tests
- [ ] `QuizCodec` parse/generate grade for single/bool + tests
- [ ] `StudyPromptAssembler.tutorSystem(...)` + course/quiz prompts
- [ ] `CourseTreeCodec` parse AI JSON outline

### Task 2: StudyRepository + ConversationMode.study

**Files:**
- Create: `lib/data/study_repository.dart`
- Modify: `lib/data/story_models.dart` — add `study` mode
- Modify: `lib/core/mode_style.dart` — study color/icon/label
- Modify: `lib/data/models.dart` — `isStudy`
- Modify: `lib/core/providers.dart` — studyRepositoryProvider
- Modify: `lib/state/chat_controller.dart` — `newStudyConversation`, study system prefix

- [ ] JSON persist load/save all study entities
- [ ] `ConversationMode.study` wire round-trip
- [ ] Chat injects study system prompt from session meta / authorNote

### Task 3: Shell tab + settings switch

**Files:**
- Modify: `lib/features/shell/shell_tab.dart`
- Modify: `lib/features/shell/app_shell.dart`
- Modify: `lib/state/settings_controller.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Test: extend `test/research_mode_test.dart` or `test/study_shell_test.dart`

- [ ] `ShellTab.study` in visible() order: chat → terminal? → study? → studio? → settings
- [ ] `studyModeEnabled` default true
- [ ] Settings card 学习模式
- [ ] Hide tab safely when disabled

### Task 4: Hub + Tutor path

**Files:**
- Create: `lib/features/study/study_hub_page.dart`
- Create: `lib/features/study/tutor_setup_page.dart`
- Create: `lib/features/study/study_session_actions.dart`
- Modify: `lib/features/chat/chat_page.dart` — study badge + action chips when isStudy
- Create: `lib/state/study_controller.dart`

- [ ] Hub with four entries + stats + continue
- [ ] Tutor setup: topic + style → new study convo → chat tab
- [ ] Actions: 本轮小结 / 出3题 / 生成复习卡 (LLM structured or text parse)

### Task 5: Course path

**Files:**
- Create: `lib/features/study/course_list_page.dart`
- Create: `lib/features/study/course_detail_page.dart`
- Create: `lib/features/study/course_node_player_page.dart`

- [ ] Create course from topic (AI tree) or manual single-node fallback
- [ ] Tree edit: rename/delete/add leaf
- [ ] Node player: explain → check quiz → mastery + unlock next
- [ ] Optional open tutor with node context

### Task 6: Quiz + wrong book

**Files:**
- Create: `lib/features/study/quiz_setup_page.dart`
- Create: `lib/features/study/quiz_player_page.dart`
- Create: `lib/features/study/wrong_book_page.dart`

- [ ] Setup: topic/count/types → generate items via LLM JSON
- [ ] Player + local grade + wrong book insert
- [ ] Wrong book redo / resolve / open tutor

### Task 7: Review (SRS) + card library

**Files:**
- Create: `lib/features/study/review_session_page.dart`
- Create: `lib/features/study/card_library_page.dart`

- [ ] Today queue from due cards
- [ ] Flip + Again/Hard/Good/Easy
- [ ] Card library CRUD
- [ ] Hub stats wire-up

### Task 8: Polish + regression

- [ ] Chat list study badge
- [ ] `flutter analyze` on touched files
- [ ] `flutter test test/study_mode_test.dart` (+ shell tests)
- [ ] Commit

---

## Execution note

Implement inline in order Task 1 → 8. Prefer working vertical slices over perfect UI.
