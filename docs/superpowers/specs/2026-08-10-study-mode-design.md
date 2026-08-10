# 学习模式（Study Mode）设计规格

**日期**：2026-08-10  
**状态**：已与用户对齐（方案 A + 首版四路径完整）  
**产品**：Expert Chat  
**目标版本**：v3.1（可按 S1–S4 小版本发布）

---

## 1. 背景与目标

### 1.1 问题

Expert Chat 已有普通对话、创作（故事/乱斗）、科研终端，但缺少面向「学懂 → 练会 → 记住」的结构化学习能力。用户希望在 App 内拥有可自选的学习路径，而不是仅靠普通聊天临场发挥。

### 1.2 产品定位

在 Expert Chat 内增加 **「学习」模式**（独立 Shell Tab + 中枢页），用户可自主选择：

| 路径 | 定位 |
|------|------|
| **导师** | 苏格拉底追问、费曼讲解、混合；边聊边学 |
| **课程** | 主题/资料 → 知识点树 → 关卡讲解与检查 → 进度 |
| **刷题** | 出题、作答、批改、错题本 |
| **复习** | 卡片 + 间隔重复（SRS） |

四条路径共享主题、资料摘要、知识点、错题与复习卡。纯本地、复用现有 LLM Provider，不做账号/云同步。

### 1.3 成功标准（首版）

用户从零开始任选一条路径，完成至少一轮有效学习后，留下可继续的痕迹（小结 / 课程进度 / 错题 / 复习卡）。四个入口均为真实闭环，不是空壳。

### 1.4 非目标（首版明确不做）

- 本地 RAG / OCR
- 账号系统、云同步、排行榜
- 题库市场；Anki `.apkg` 全量导入（可后期）
- 语音跟读评分、手写识别
- 代码沙箱判题
- 自建 embedding / 向量库

---

## 2. 导航与信息架构

### 2.1 Shell

新增 `ShellTab.study`（标签「学习」）。

可见 Tab 规则（在现有 research × creation 组合上扩展）：

```text
会话
[+ 终端]     // researchModeEnabled
[+ 学习]     // studyModeEnabled
[+ 创作]     // creationModeEnabled
设置
```

- 设置项：`studyModeEnabled`（建议默认 **true**）
- 位置：设置 → 能力（与创作/科研模式卡片并列）
- 关闭时：隐藏学习 Tab；若当前在学习页，先切到设置再卸载学习页（对齐科研/创作生命周期）

### 2.2 学习中枢页

对标 `StudioPage`，作为学习模式首页。

| 分区 | 内容 |
|------|------|
| 顶部摘要 | 今日待复习数、进行中课程数、错题数 |
| 四入口 | 导师 · 课程 · 刷题 · 复习（大卡片） |
| 继续学习 | 最近学习会话、未完成课程、逾期复习 |
| 库入口 | 知识点/课程库 · 错题本 · 卡片库 |

### 2.3 对话承载方式

- 新增 `ConversationMode.study`
- **首版推荐：学习流程页内嵌对话区**，避免与普通会话列表强耦合
- 学习会话仍写入现有 `conversations` / `messages`，列表中带「学习」标记，可从会话 Tab 打开
- `StudySessionMeta` 将 `conversationId` 与路径类型、课程/节点等关联

### 2.4 视觉

- 沿用纸感 + Material 3；学习强调色建议 **靛蓝/青绿**，区别故事橙、乱斗紫、会话墨青
- 扩展 `ModeStyle`（或并列 `StudyStyle`）提供 color / icon / label
- 窄屏：中枢 → 全屏子页；宽屏：左树/列表 + 右内容（课程、刷题、复习）

---

## 3. 四条路径规格

### 3.1 导师（Tutor）

**开场**

- 输入主题，或粘贴笔记，或选择已有知识点 / 课程节点
- 模式芯片：`苏格拉底` | `费曼` | `混合`（默认混合）

**行为**

| 模式 | 行为约束 |
|------|----------|
| 苏格拉底 | 优先追问、少直接给完整答案；暴露思维缺口 |
| 费曼 | 用简单语言讲解，再要求用户复述；纠正复述中的错误 |
| 混合 | 先简短讲解要点，再追问检查理解 |

**求助分级（避免劝退）**

1. 给提示（hint）
2. 给完整讲解（full explain）

**轮次动作（一键）**

- 本轮小结（3～5 条要点）→ 可写入课程节点备注或生成卡片
- 出 3 题自测 → 跳转刷题流程（预填主题）
- 生成复习卡 → 写入卡片库并进入 SRS

**System prompt 要点**

- 明确当前模式与求助级别
- 绑定课程/知识点上下文（若有）
- 默认不联网；用户可在该会话临时打开联网

### 3.2 课程（Course）

**新建**

- 方式 A：仅主题描述
- 方式 B：上传资料（复用现有 `file_parser`；长文截断 + 分章/分段摘要，**不做 RAG**）

**知识点树**

- AI 生成章 → 节 → 叶子节点；用户可增删改、拖拽排序（首版至少：编辑标题/删除/添加子节点）
- 每个叶子节点为一关，状态：`locked | available | in_progress | done`
- 掌握度：`weak | familiar | mastered`（检查通过后可调）

**关卡流程**

1. **精讲**：短文 + 例子（可缓存，避免每次重生成；支持「换一种讲法」）
2. **检查**：1～3 题（选择/简答）；批改逻辑复用刷题模块
3. **通过**：更新节点状态与掌握度；解锁下一关（默认按树序）

**联动**

- 关卡内可打开「导师」子会话，注入当前节点上下文
- 关卡完成后可生成复习卡

**进度**

- 课程级进度条 = done 叶子数 / 总叶子数
- 中枢「继续学习」跳到最近 `in_progress` 节点

### 3.3 刷题（Quiz）

**出题来源**

- 自由主题
- 指定课程节点
- 错题本加练
- 自定义：题型、难度、数量（默认 5，上限建议 20/次）

**题型（首版）**

- 选择（单选）
- 判断
- 填空
- 简答  

（代码题、多选、阅读理解大题 → 后续）

**流程**

```text
配置 → 生成题目 JSON → 逐题作答 → 批改 → 解析 → 可选入错题本
```

**批改**

- 选择/判断：本地比对标准答案（模型仍可提供解析）
- 填空/简答：模型结构化批改（正确/部分正确/错误 + 解析 + 得分建议）
- JSON 解析失败：展示原文并重试一次；仍失败则人工对照解析文本

**错题本**

- 错题自动收录（可设置「答错才收录」默认开）
- 字段：题目快照、用户答案、正确要点、知识点标签、错误次数、状态（`open` / `resolved`）
- 支持重做、标记已会、按知识点筛选
- 一键「请导师讲这题」

### 3.4 复习（Review / SRS）

**卡片来源**

- 导师「生成复习卡」
- 课程关卡完成
- 刷题错题转化
- 手动新建

**卡片结构**

- `front` / `back`
- 可选 `hint`
- 可选关联 `nodeId` / `courseId` / `quizItemId`
- SRS：`ease`、`intervalDays`、`repetitions`、`dueAt`、`lastReviewedAt`

**算法**

- 轻量 SM-2 变体
- 用户按钮：`Again` | `Hard` | `Good` | `Easy`
- 逾期卡片优先进入今日队列
- 具体参数实现时固定为可单测的纯函数（见 §6）

**复习会话 UI**

- 一屏一卡；先显示正面，再翻面
- 答错可：加入错题本 / 请导师讲解
- 空队列：引导去导师/课程/刷题生成卡片

---

## 4. 数据模型

### 4.1 存储选型

- **推荐 Drift（SQLite）**，与对话仓库一致
- Web：沿用现有 Drift/Web 策略或等价本地存储；学习大数据量以原生端为验收重点

### 4.2 实体

#### StudyCourse

| 字段 | 说明 |
|------|------|
| id | UUID |
| title | 标题 |
| sourceType | `topic` / `attachment` |
| sourceSummary | 资料摘要文本（可截断） |
| status | `active` / `archived` |
| createdAt / updatedAt | |

#### StudyNode

| 字段 | 说明 |
|------|------|
| id | UUID |
| courseId | |
| parentId | nullable |
| title | |
| orderIndex | |
| kind | `section` / `leaf` |
| explainCache | 精讲缓存 markdown |
| mastery | `weak` / `familiar` / `mastered` / null |
| progress | `locked` / `available` / `in_progress` / `done` |

#### StudyQuizItem

| 字段 | 说明 |
|------|------|
| id | UUID |
| stem | 题干 |
| type | `single` / `bool` / `cloze` / `short` |
| optionsJson | 选项（选择/判断） |
| answerJson | 标准答案结构 |
| explanation | 解析 |
| difficulty | 1–5 |
| nodeId / courseId | 可选关联 |
| createdAt | |

#### StudyWrongItem

| 字段 | 说明 |
|------|------|
| id | UUID |
| quizItemId | 或内联快照 JSON（防止原题被删） |
| userAnswer | |
| missCount | |
| status | `open` / `resolved` |
| lastMissedAt | |

#### StudyCard

| 字段 | 说明 |
|------|------|
| id | UUID |
| front / back / hint | |
| ease | double，默认 2.5 |
| intervalDays | int |
| repetitions | int |
| dueAt | DateTime |
| lastReviewedAt | nullable |
| courseId / nodeId / quizItemId | 可选 |
| suspended | bool，默认 false |

#### StudySessionMeta

| 字段 | 说明 |
|------|------|
| conversationId | 关联现有会话 |
| path | `tutor` / `course` / `quiz` / `review` |
| courseId / nodeId | 可选 |
| tutorStyle | `socratic` / `feynman` / `mixed` |
| createdAt | |

### 4.3 对话模式

- `ConversationMode.study` 写入 `conversations.mode`
- 迁移：未知 mode 回退 `chat`（与现有 fromWire 模式一致）
- 导出 Markdown 时可标注「学习会话」

### 4.4 与长期记忆

- 学习小结/卡片**默认不写入** global memory
- 用户可在消息上继续用现有「记住」；记忆安全规则不变

---

## 5. AI 编排

### 5.1 复用

- `LlmProvider` / active provider profile / 流式输出
- 学习专用 prompt 模板放在 `domain/study/prompts/`（或等价位置）

### 5.2 结构化输出

以下能力优先要求模型返回 JSON（附 schema 说明 + 解析器）：

- 课程知识点树
- 题目列表
- 简答批改结果
- 复习卡批量生成
- 本轮小结

解析失败：重试 1 次（更严的 schema 提示）；仍失败则降级为可读 Markdown，并禁用依赖结构的自动入库按钮（或改为「从文本手动确认」）。

### 5.3 联网与工具

- 学习请求默认 `web_search` 关闭
- 会话级可打开联网（设置或聊天内开关，与现有能力对齐）
- 不在学习路径自动调用文档改稿等无关 tool

### 5.4 上下文窗口

- 复用 `ContextWindowManager`
- 课程精讲缓存、节点标题路径、最近错题摘要按优先级注入
- 大附件仅用 `sourceSummary`，不整文重复塞入每一关

---

## 6. SRS 算法（可测试纯函数）

输入：`card` + `rating`（again/hard/good/easy）  
输出：新的 `ease`、`intervalDays`、`repetitions`、`dueAt`

约定（实现时锁定，单测对照）：

| Rating | 行为概要 |
|--------|----------|
| Again | repetitions → 0；interval → 0 或 1 天内（如 10 分钟～1 天，产品取「次日或今日稍后」需在实现计划钉死一种）；ease 降低，下限 1.3 |
| Hard | interval 小幅增加；ease 略降 |
| Good | 标准 SM-2 递进 |
| Easy | interval 更大增幅；ease 略升 |

今日队列：`dueAt <= endOfToday && !suspended`，按 `dueAt` 升序。

---

## 7. UI 页面清单

| 页面/组件 | 说明 |
|-----------|------|
| `StudyHubPage` | 中枢 |
| `TutorSessionPage` | 导师：模式芯片 + 内嵌聊天 + 轮次动作 |
| `CourseListPage` / `CourseDetailPage` | 课程列表与树 |
| `CourseNodePlayerPage` | 关卡：精讲 → 检查 → 结果 |
| `QuizSetupPage` / `QuizPlayerPage` | 出题配置与答题 |
| `WrongBookPage` | 错题本 |
| `CardLibraryPage` | 卡片库 CRUD |
| `ReviewSessionPage` | 今日复习 |
| 设置卡片 | 学习模式开关 |

聊天列表：`mode == study` 显示学习徽章；可「在学习中打开」深链到对应 path（若 meta 存在）。

---

## 8. 设置与开关

```text
studyModeEnabled: bool  // 默认 true
```

可选后续（非首版必须）：

- 答错自动进错题本
- 每日复习目标数量
- 导师默认风格

---

## 9. 实现分期（完整首版内）

| 迭代 | 交付 | 可演示出口 |
|------|------|------------|
| **S1** | Shell Tab + 开关 + 中枢骨架 + `ConversationMode.study` + 导师全流程（小结/出题入口/生成卡） | 学一个主题并留下小结与卡片 |
| **S2** | 课程树生成/编辑 + 关卡讲解/检查 + 进度 + 继续学习 | 迷你课学完 |
| **S3** | 刷题全流程 + 错题本 + 与导师/课程联动 | 一套卷 + 错题重做 |
| **S4** | SRS 队列打通全来源 + 中枢统计 + 窄/宽布局打磨 + 回归测试 | 四入口均为真功能 |

对外可合并为 **v3.1 学习模式**，或按 S1–S4 灰度。

---

## 10. 测试计划

### 10.1 单元测试

- `ConversationMode.study` 序列化/迁移
- 知识点树解析与编辑归约
- 题目 JSON 解析与选择/判断本地判分
- 简答批改 JSON 解析降级
- SRS 状态转移表（各 rating × 边界 ease）
- 今日队列排序与空队列
- `ShellTab.visible` 含 study 标志组合

### 10.2 Widget / 流程测试

- 中枢四入口可进
- 关闭 `studyModeEnabled` 后 Tab 消失且无 index 越界
- 导师轮次动作按钮在流式生成中的禁用态
- 刷题答错进入错题本
- 复习翻面与 rating 后 dueAt 更新

### 10.3 验收清单

- [ ] 新装默认可见或按默认开关策略正确
- [ ] 四路径均可独立完成一轮
- [ ] 导师三种风格 system 行为可区分（抽检 prompt 组装单测）
- [ ] 课程进度与继续学习正确
- [ ] 错题本与卡片库数据在重启后仍在
- [ ] 学习会话出现在会话列表且带标记
- [ ] `flutter analyze` + 相关 `flutter test` 通过
- [ ] Android / Windows 至少一端手测中枢与复习

---

## 11. 风险与对策

| 风险 | 对策 |
|------|------|
| 模型 JSON 不稳定 | 严格 schema + 重试 + 降级；关键入库需可解析结构 |
| 课程树过大 | 限制生成深度/节点数；摘要截断 |
| 学习会话污染普通列表 | 徽章 + 筛选（首版至少徽章；筛选可 S4） |
| 四路径首版工作量大 | 严格按 S1→S4；共享批改/卡片/节点上下文模块，避免复制逻辑 |
| 与创作/科研 Tab 过多 | 学习默认开、科研默认关；创作可关；小屏 NavigationBar 目视不超过 5 项常见组合 |

---

## 12. 目录建议（实现时）

```text
lib/
  data/
    study_models.dart
    study_repository.dart
    db/  # Drift tables for study_*
  domain/study/
    study_prompt_assembler.dart
    quiz_codec.dart
    srs_scheduler.dart
    course_tree.dart
    tutor_style.dart
  features/study/
    study_hub_page.dart
    tutor_session_page.dart
    course_*.dart
    quiz_*.dart
    review_*.dart
    wrong_book_page.dart
    card_library_page.dart
  state/
    study_controller.dart
    ...
```

---

## 13. 已确认的产品决策

| 项 | 决策 |
|----|------|
| 形态 | App 内学习模式（Shell Tab + 中枢），非独立安装包 |
| 范围 | 四路径都要，且首版都做完整（非空壳） |
| 路径选择 | 用户自主选择，不锁死单一玩法 |
| 实现策略 | 方案 A；分期 S1–S4 仍属同一完整首版 |
| 对话 UI | 学习页内嵌对话为主 |
| RAG/OCR | 不做 |
| 开关默认 | `studyModeEnabled = true` |
| 资料 | 课程支持主题或上传；解析 + 截断摘要，无向量检索 |

---

## 14. 下一步

1. 用户审阅本规格，确认或修订  
2. 通过后按 `writing-plans` 产出实现计划（建议按 S1–S4 拆任务与测试 dual）  
3. 再开始编码
