# 已同意功能落地顺序

按对话中用户明确同意 / 推进的顺序执行。一项完成后再做下一项。

| 序号 | 项 | 状态 |
|------|----|------|
| 0 | DeepSeek Responses 官方联网（`web_search`） | ✅ 已完成 |
| 1 | 文档改稿契约：`DocumentPatch` v1 + `edit_document` ToolSpec | ✅ 已完成 |
| 2 | 文档 P0：Linux 最小服务（xlsx）+ App Client / 设置 | ✅ 已完成（聊天回传见 3） |
| 3 | 文档 P0：聊天触发改稿并回传下载 | ✅ 已完成 |
| 4 | `gpt-image-2` 多参考图 `/images/edits` | ✅ 已完成 |
| 5 | 选图 UX：横滑预览 + 勾选 + 确认 | ✅ 已完成 |

## 契约与实现分界

- **App**：LLM tools、校验 patch、调文档服务、展示下载
- **Linux**：无状态执行 patch、返回文件；不持有模型 Key（默认）

## 文档范围（已扩展）

- 格式：**xlsx / docx / pptx**
- 触发：聊天「改文档」按钮（强制 tool）+ 模型 `edit_document`
- 传输：`POST /v1/documents/edit`（multipart: file + patch JSON）
- 选图：系统选择器确认条 + 移动端最近相册（可选入口）
