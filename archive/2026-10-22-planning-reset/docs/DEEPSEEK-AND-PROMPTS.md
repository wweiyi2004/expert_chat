# DeepSeek、提示词与聊天 / 工作

更新日期：2026-10-17。

## DeepSeek 的当前接入

- 新建官方配置默认使用 `deepseek-flash`；支持文字、图片、工具调用和可开关的思考。复杂推理也可选择 `deepseek-v4-pro`，Pro 不接收图片。
- 官方端点上的旧 `deepseek-v4-flash` 和 `deepseek-v4-flash-vision-exp` 配置会统一为 `deepseek-flash`，合并重复选项并迁移已选模型；第三方网关的模型 ID 不改。
- 普通聊天使用 `POST /chat/completions`。深度思考显式发送 `thinking.type=enabled` 与所选 `reasoning_effort`（`low` / `high` / `max`）；关闭时显式发送 `thinking.type=disabled`。
- 官方识图沿用 Files API 上传图片并通过 `file_id` 引用；公网图片链接仍可直接使用。多轮思考与工具调用保留 `reasoning_content`。
- 选择「API 提供商官方联网」且当前连接为官方 DeepSeek 时，搜索使用 `POST https://api.deepseek.com/v1/tools/search`，读网页使用 `/v1/tools/fetch`，二者复用当前 DeepSeek Key。Flash 与 Pro 均可使用，不依赖 Responses 内置搜索。
- 也可单独选择「DeepSeek Search / Fetch」，为其他对话模型提供搜索；此时填写 DeepSeek 搜索 Key。当前连接本身为官方 DeepSeek 时优先复用模型 Key，避免误用旧搜索服务的 Key。
- 搜索保留标题、链接与短摘要，正文为空时采用长摘要。搜索正常无结果时返回空来源，不视为网络故障；搜索词限制为 128 个 Unicode 字符。
- 默认搜索统一使用 DeepSeek Search / Fetch。首次升级自动将原 DuckDuckGo 配置切换到 DeepSeek；已有 Tavily、博查、Exa 等独立服务配置保留。迁移只执行一次。
- Responses 服务端 `web_search` 的能力声明仅保留给 Pro；Flash 的联网统一走上面的独立工具接口。

参考：[模型列表](https://api-docs.deepseek.com/zh-cn/api/list-models/)、[图像理解](https://api-docs.deepseek.com/zh-cn/guides/vision/)、[思考模式](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/)、[Search / Fetch](https://api-docs.deepseek.com/zh-cn/guides/search/)。

## 两套提示词的关系

它们都是应用发给模型的系统指令，不是模型内部不可见的提示词，也不与某个服务商绑定。

| 入口 | 作用 | 何时生效 |
| --- | --- | --- |
| 提示词预设（简洁助手、耐心讲解、科研伙伴等） | 手动固定回答风格或角色 | 选中具体预设后，后续普通聊天与工作直接使用它，暂停自动技能选择 |
| 模型设置 → 自动聊天技能 | 根据当前问题选择一项提示词，如翻译、写作、通用助手 | 「提示词预设」选为「自动选择技能」时参与选择 |
| 通用技能 | 自动路由未匹配或失败时的兜底 | 自动选择模式下使用；原有 `systemPrompt` 与通用技能的编辑内容同步 |
| Jev | 可选的技能选择器 | 自动选择模式下尝试选择技能；不负责最终回答，超时或低置信度按既有路由逻辑回退 |

固定预设与自动选出的技能不会全部叠加。选择固定预设后，修改自动技能仍可保存，但要切回自动选择后才影响路由。正在生成的回复使用发送时的配置快照。

项目要求、长期记忆、工具能力说明、搜索结果等仍会作为上下文加入。学习和创作模式使用各自的专用提示词。DeepSeek 的推理保护也会加入过程控制指令，因此「固定预设」并不等于整个请求只含这一段系统文字。

## 聊天与工作的实际区别

| | 聊天 | 工作 |
| --- | --- | --- |
| 主要目标 | 问答、讨论、按需搜索 | 分步执行、核验并交付结果或文件 |
| 提示与输入引导 | 直接交流问题 | 描述目标、材料和交付要求；复杂任务先简述步骤再执行 |
| 工具循环 | 搜索轮数 + 1，默认最多 4 轮，每轮最多 3 次调用 | 最多 24 轮，每轮最多 8 次调用，仍受用户任务预算限制 |
| 电脑操作 MCP | 不向模型暴露电脑操作工具 | 允许使用用户已配置且本会话选中的电脑操作工具，沿用原有执行策略 |
| 其他能力 | 按需搜索、读图、文件及一般 MCP 工具 | 可组合相同能力完成多步任务 |

切换不会自动开启深度思考、搜索、SSH 或未连接的工具。模式按会话保存；顶部统一显示「聊天 / 工作」，空会话说明和输入占位文字随模式变化。生成期间禁用模式切换，避免本轮行为与界面状态不一致。
