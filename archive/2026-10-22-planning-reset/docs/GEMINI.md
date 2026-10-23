# Gemini 原生协议

设置 → 模型中，新建或编辑服务商，把「API 格式」设为「Gemini 原生」。官方地址可填 `https://generativelanguage.googleapis.com/v1beta`，模型填写账号当前可用的模型 ID，密钥填写 Google AI Studio API Key。点击「测试连接」验证实际模型访问，再保存。

第三方转发服务使用它提供的 Base URL 和密钥，并显式选择原生格式；`/v1` 这类通用路径不能仅靠 URL 判断协议。也可继续选择「OpenAI 兼容」，官方 Google 地址会映射到 `/v1beta/openai`。不要把原生和兼容格式混用。

**支持范围**

- 普通多轮对话、SSE 流式正文、模型提供的思考摘要、用量统计。
- 图片输入：本地图片以带实际 MIME 的 `inlineData` 发送；远程 HTTPS 图片以 `fileData.fileUri` 发送，不猜测 JPEG。远程 URL 支持取决于模型；Gemini 2.0 的外部 URL 限制不由客户端自动下载绕过。
- 本地搜索、文档/MCP 等 function calling，包括并行调用和多步骤续轮。原生 `functionCall` 的 ID 与所在 part 的 `thoughtSignature` 原样回传，JSON Schema 不再被递归删字段。
- Gemini 3 的 MCP 截图观察归入产生它的 `functionResponse.parts`，说明文字也留在工具结果内，不伪装为新的用户指令；Gemini 2.5 沿用普通图片观察消息，不发送其不支持的多模态工具结果字段。
- Gemini 原生图片生成、参考图编辑；Imagen `predict` 保留给支持该接口的服务。具体模型可用性由服务商决定，协议支持不代表已经退役的官方模型仍可调用。
- 模型配置、视觉配置和生图配置的协议选择支持保存、导入导出和模型切换。

**思考与结束状态**

Gemini 2.5 使用 `thinkingBudget`，Gemini 3 系列使用 `thinkingLevel`。关闭界面的深度思考时，对于不能关闭思考的模型只使用其支持的低级别/隐藏摘要，不把这个操作解释成远端绝对不会产生思考 token。高和最大强度在仅有 low/high 的模型上都映射为 high。

收到 `MAX_TOKENS` 时保留已有正文并显示未完成；安全拦截、畸形工具调用及无完成状态的断流不能作为成功。只有正常完成的 function call 才进入执行。末尾单独返回的用量仍会计入；输入计入服务报告的工具提示，输出 token 包含思考 token，思考数是其子集，不额外重复相加。

原始协议 parts 保留在当前任务的工具循环中，保持签名与 part 边界；任务完成后，已有会话存储继续保存正文/思考展示/工具记录，不把瞬态协议对象混入其他模型的历史请求。

**生图与历史记录**

在设置 → 能力的视觉理解/图片生成配置中选择原生格式。`auto` 尺寸省略图片配置；像素尺寸按宽高比转换为支持的比例；分辨率档位按原生模型参数发送。无法映射的尺寸明确报错，不偷偷替换成其他比例。参考图保持输入顺序和 MIME。

数据库结构升为 v17，为生图记录增加可空的 `api_format`。新记录保存实际使用的协议，按原参数再生成会复用它。v16 升级以及 v15/v16 完整备份恢复时，旧记录保留为未知协议，不凭模型名猜测；这类旧记录继续使用当前配置。完整备份容器格式仍为 ECBACKUP v1。

**边界**

本次实现的是 Google API Key 方式的 GenerateContent REST 协议及兼容转发，不包含 Vertex AI OAuth、Interactions/Live API、Gemini 原生语音生成，或 Google Search grounding 专用开关。Gemini 对话中的联网仍使用项目已有的客户端搜索工具。模型列表仍采用预设和手填，不新增远端模型发现请求。

**契约依据与验证**

- [GenerateContent REST 与 UsageMetadata](https://ai.google.dev/api/generate-content)：请求字段、完成状态、原生函数 JSON Schema 与 token 口径。
- [思考签名](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)：保留原始 parts 和签名位置。
- [思考配置](https://ai.google.dev/gemini-api/docs/generate-content/thinking)：不同模型的 budget/level 语义。
- [文件输入](https://ai.google.dev/gemini-api/docs/generate-content/file-input-methods)：HTTPS 文件输入及模型限制。
- [图片生成](https://ai.google.dev/gemini-api/docs/image-generation)：图片输出和参考图参数。

回归覆盖设置保存/迁移、流式事件、并行工具往返、失败不执行工具、看图/生图请求、版本再生成及备份。使用本地 HTTP 替身和临时数据库，不使用用户密钥调用真实服务；日志位于 `output/gemini-2026-10-15/`。

2026-10-15 最终验证：Flutter 全量 **1382 项通过**；仓库策略、479 个 Dart 文件格式检查及 `flutter analyze --no-pub` 均通过（No issues found）。v15/v16 历史 schema 快照保持不变，已新增 v17 快照并重新生成 Drift 代码和迁移辅助代码。真实 Gemini/转发服务的模型授权与可用性仍由设置中的「测试连接」验证。
