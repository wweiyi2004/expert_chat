# 模型 API 协议自动尝试

在首次连接或编辑服务商时，将“接口格式”设为“自动尝试”，填写服务地址、Key 和模型。连接测试与实际对话使用同一个路由器；接口拒绝当前协议时，可自动尝试其它协议，无需另搭转换网关。

| 协议 | 请求入口 | 支持范围 |
| --- | --- | --- |
| OpenAI Chat Completions | `/chat/completions` | 正文、思考字段、工具调用、图片、流式用量 |
| OpenAI Responses | `/responses` | 正文、思考、函数工具、图片、原始 output 往返；独立于联网开关可用 |
| Anthropic Messages | `/messages` | system/messages 转换、图片、思考签名、tool_use/tool_result、流式用量 |
| Gemini 原生 | `/models/{model}:streamGenerateContent` | 原有 Gemini 原生聊天、视觉与工具签名支持 |

## 识别与尝试规则

1. 优先使用完整接口路径或官方域名的提示。例如 `/responses`、`/messages`、Anthropic 官方域名和 Gemini 原生地址。没有提示时先尝试 Chat Completions。
2. 只在收到明确的协议拒绝后继续：404/405/415/501，或者 400/422 中明确缺失顶层协议字段、接口不支持的错误。模型不存在、鉴权、额度、权限、限流、普通参数错误和网络超时不会触发协议重发。
3. 成功结果按地址、模型、凭据和服务端搜索模式隔离缓存，缓存只在当前路由器生命周期内保留，不把 Key 或探测结果写入文件。换模型/Key/地址后重新识别；缓存端点随后明确拒绝协议时可重新尝试。
4. 完整 API URL 会去除动作后缀再拼接，避免出现 `/responses/responses`。仅填写主机根地址时也尝试同一主机的 `/v1`；Gemini 也会尝试将末尾版本段 `/v1` 换为 `/v1beta`，保留代理路径前缀。未知主机根地址最多 7 个候选，已有路径最多 5 个；不切换域名，不轮询无限重试。
5. 一旦协议适配器发出任何响应块，不会改用另一协议重发。工具续轮固定原始协议，保留 Gemini parts、Responses output 或 Anthropic content blocks，避免重放已执行步骤或破坏签名。
6. 显式选择某一协议时不进行协议回退。现有服务商原生搜索路径仍要求 Responses，不能悄悄降级成无搜索的普通聊天。

这是对当前请求的有限尝试，不是每次聊天前额外发送探测消息。设置中的连接测试仍是独立短消息，不带历史、附件或工具。请求是否计费由服务商决定，不能保证拒绝请求一定免费。

## Anthropic 适配

- 官方服务使用 `x-api-key` 和 `anthropic-version: 2023-06-01`；第三方转发同时提供 Bearer 头。
- 连续工具结果合并为 user 消息的 `tool_result` 块；工具截图附加到对应结果。完整的 thinking / redacted_thinking / tool_use 块在本轮续请求中保留。
- 仅在 `message_stop` 且内容块完整结束后释放可执行工具调用。截断、异常、`max_tokens` 等未完成结果不执行工具。
- 按已知 Claude 模型名称区分 adaptive 和传统 thinking budget；强制工具选择时关闭思考，避免不兼容参数组合。匿名模型别名无法可靠推断思考模式时，可先关闭思考测试或使用服务商实际模型名。

## 边界

自动尝试针对模型对话协议，不代表支持任意私有 JSON 协议、WebSocket、Realtime、Vertex OAuth、AWS Bedrock 签名或所有生图/音频协议。第三方服务将所有错误包装成 200、返回非流式对象，或在错误路径先返回鉴权失败时，可能仍需手动指定正确协议与地址。HTTP 200 的空/不可识别结果不会自动重复生成。

代码入口：`routing_llm_provider.dart`、`llm_endpoint.dart`、`llm_http_errors.dart`、`anthropic_messages_provider.dart`。回归覆盖自动路由、缓存隔离、URL、错误与取消边界，以及 Anthropic 签名/工具/图片往返；使用人工数据和 HTTP 替身，不调用用户的真实模型账户。

协议参考：[OpenAI Responses](https://developers.openai.com/api/docs/guides/migrate-to-responses)、[Anthropic 流式事件](https://platform.claude.com/docs/en/build-with-claude/streaming)、[Anthropic 思考配置](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)。
