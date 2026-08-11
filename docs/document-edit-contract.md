# 文档编辑契约 v1

App 与 Expert Chat Gateway 的文档能力共用。`schema_version` 必须为 `1`。

## 1. LLM Tool：`edit_document`

模型通过 function calling 产出补丁；**App 校验后**再上传服务器。模型不得直接请求服务器 URL。

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `attachment_name` | string | 建议 | 本轮用户附件文件名（精确匹配优先） |
| `patch` | object | 是 | 完整 [DocumentPatch](#2-documentpatch) |
| `output_filename` | string | 否 | 覆盖 patch 内同名字段 |

Tool 名：`edit_document`（见 `lib/domain/document/document_edit_tools.dart`）。

可选预检 Tool：`inspect_document`（P0 可仅本地实现）。

## 2. DocumentPatch

```json
{
  "schema_version": 1,
  "format": "xlsx",
  "ops": [ /* DocumentOp */ ],
  "output_filename": "optional.xlsx"
}
```

### 2.1 通用限制（App + 服务端双端校验）

| 项 | 上限 |
|----|------|
| `ops` 条数 | 200 |
| 单 op 单元格映射数（`set_cells`） | 5000 |
| 单 op 二维表单元格数（`set_range`） | 5000 |
| `output_filename` 长度 | 180（禁止路径分隔符） |
| `format` | `xlsx` / `docx` / `pptx` / `txt` / `md` / `csv` / `tsv` |
| 单 op `set_text` 字符数 | 2 097 152（2 MiB） |
| patch JSON 体积 | 4 MiB（服务端在 `json.loads` 前拒绝） |
| 文本结果总长（`replace_text` / `set_text` 后） | 2 MiB 字符 |
| 客户端附件抽文本 | 前 60 000 字；截断时**禁止** `set_text` |

未知 `op`：**整单失败**（不半成功）。

损坏/不可解析的源文件（如伪 `.xlsx`）：服务端返回 400，**禁止**静默新建空工作簿后“成功”改稿。

客户端对响应 `Content-Disposition` 文件名做 basename 消毒（拒绝路径分隔、控制字符、`..`），非法时回退到本地推导名。

### 2.2 xlsx ops（P0）

#### `set_cells`

```json
{
  "op": "set_cells",
  "sheet": "Sheet1",
  "cells": { "B2": 110, "C2": "=B2*1.1", "A1": "标题" }
}
```

- `sheet`：工作表名；缺省则用活动表 / 第一张（实现约定：缺省 = 第一张）
- `cells`：A1 样式地址 → 值（number / string / bool / null 清空）
- 字符串以 `=` 开头时按**公式字符串**写入（由 Excel 打开时计算）

#### `set_range`

```json
{
  "op": "set_range",
  "sheet": "Sheet1",
  "start": "A1",
  "values": [["姓名", "金额"], ["张三", 100]]
}
```

- 从 `start` 起按行写入二维数组；行可变长

#### `add_sheet`

```json
{ "op": "add_sheet", "name": "汇总" }
```

- 已存在同名表：服务端返回 `patch_invalid`（或 no-op 策略在实现中写死为 **报错**）

#### `ensure_sheet`（可选便利）

```json
{ "op": "ensure_sheet", "name": "汇总" }
```

- 不存在则创建；已存在则跳过

### 2.3 docx ops

#### `replace_text`

```json
{ "op": "replace_text", "find": "旧文", "replace": "新文", "all": true }
```

### 2.4 pptx ops

#### `set_shape_text`

```json
{ "op": "set_shape_text", "slide": 1, "shape": 0, "text": "新标题" }
```

- `slide`：从 1 起  
- `shape`：该页带文本框的 shape 从 0 起  

### 2.5 txt / md / csv / tsv ops

纯文本族（UTF-8 读写；读入时兼容 BOM / 尽力 GB18030）。

#### `replace_text`

```json
{ "op": "replace_text", "find": "旧文", "replace": "新文", "all": true }
```

- 对**整文件字符串**做查找替换（csv/tsv 也按纯文本处理，不做表格语义）

#### `set_text`

```json
{ "op": "set_text", "text": "完整新内容…" }
```

- 用 `text` **整文件覆写**（适合重写 markdown / 整表 csv）
- `text` 可为 `""`；不可为 JSON `null`

## 3. HTTP API

### `GET /v1/capabilities`

```json
{
  "protocol_version": 1,
  "gateway_version": "0.2.0",
  "capabilities": {
    "document_edit": {
      "version": 1,
      "formats": ["xlsx", "docx", "pptx", "txt", "md", "csv", "tsv"]
    },
    "document_convert": {"version": 1, "conversions": {}}
  }
}
```

### `POST /v1/documents/edit`

- Header: `Authorization: Bearer <token>`
- multipart:
  - `file`：原文件
  - `patch`：UTF-8 JSON 字符串（DocumentPatch）
  - `filename`：可选原名

成功：`200` + 文件流 + `Content-Disposition: attachment`

### `POST /v1/documents/convert`

跨格式转换（**不**改内容语义，只换容器/导出）。

- Header: `Authorization: Bearer <token>`
- multipart:
  - `file`：原文件
  - `target_format`：`xlsx` / `docx` / `pptx` / `txt` / `md` / `csv` / `tsv`
  - `filename`：可选原名
  - `output_filename`：可选输出名

支持矩阵（与 `lib/domain/document/document_convert.dart` 一致）：

| 源 | 可转为 |
|----|--------|
| txt | txt, md, docx, csv, tsv |
| md | md, txt, docx |
| csv | csv, tsv, txt, md, xlsx |
| tsv | tsv, csv, txt, md, xlsx |
| xlsx | xlsx, csv, tsv, txt, md |
| docx | docx, txt, md |
| pptx | pptx, txt, md |

LLM Tool：`convert_document`（`attachment_name?`, `target_format`, `output_filename?`）。

失败 JSON：

```json
{
  "error": {
    "code": "unauthorized|file_too_large|unsupported_format|patch_invalid|internal",
    "message": "中文说明",
    "details": {}
  }
}
```

## 4. 源码位置

| 内容 | 路径 |
|------|------|
| Patch 模型与校验 | `lib/domain/document/document_patch.dart` |
| ToolSpec | `lib/domain/document/document_edit_tools.dart` |
| 统一 Gateway | `server/gateway/` |
| 文档能力模块 | `server/doc_edit/` |
