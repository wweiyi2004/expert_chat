from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass
from typing import Annotated, Any, Literal

from mcp.server import MCPServer
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.mcpserver.exceptions import ResourceError, ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import CallToolResult, ResourceLink, TextContent, ToolAnnotations
from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field


DocumentFormat = Literal["xlsx", "docx", "pptx", "txt", "md", "csv", "tsv"]
CellValue = str | int | float | bool | None


class _DocumentOp(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SetCellsOp(_DocumentOp):
    op: Literal["set_cells"]
    sheet: str | None = None
    cells: dict[str, CellValue] = Field(min_length=1, max_length=5000)


class SetRangeOp(_DocumentOp):
    op: Literal["set_range"]
    sheet: str | None = None
    start: str = Field(description="A1 样式的起始单元格")
    values: list[list[CellValue]] = Field(min_length=1)


class AddSheetOp(_DocumentOp):
    op: Literal["add_sheet"]
    name: str = Field(min_length=1, max_length=31)


class EnsureSheetOp(_DocumentOp):
    op: Literal["ensure_sheet"]
    name: str = Field(min_length=1, max_length=31)


class ReplaceTextOp(_DocumentOp):
    op: Literal["replace_text"]
    find: str = Field(min_length=1)
    replace: str = ""
    all: bool = True


class SetTextOp(_DocumentOp):
    op: Literal["set_text"]
    text: str = Field(max_length=2 * 1024 * 1024)


class SetShapeTextOp(_DocumentOp):
    op: Literal["set_shape_text"]
    slide: int = Field(ge=1)
    shape: int = Field(ge=0)
    text: str


DocumentOperation = Annotated[
    SetCellsOp
    | SetRangeOp
    | AddSheetOp
    | EnsureSheetOp
    | ReplaceTextOp
    | SetTextOp
    | SetShapeTextOp,
    Field(discriminator="op"),
]


class DocumentPatchModel(BaseModel):
    """MCP-facing subset of the shared DocumentPatch v1 contract."""

    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1] = Field(description="固定为 1")
    format: DocumentFormat
    ops: list[DocumentOperation] = Field(min_length=1, max_length=200)
    output_filename: str | None = Field(default=None, max_length=180)


@dataclass(frozen=True)
class McpIdentity:
    subject: str
    display_name: str
    client_id: str
    scopes: tuple[str, ...]
    auth_kind: str


@dataclass(frozen=True)
class StoredDocument:
    file_id: str
    filename: str
    mime_type: str
    size_bytes: int
    created_at: str

    @property
    def binary_resource_uri(self) -> str:
        return f"expert-chat://documents/{self.file_id}/binary"

    @property
    def text_resource_uri(self) -> str:
        return f"expert-chat://documents/{self.file_id}/text"

    @property
    def metadata_resource_uri(self) -> str:
        return f"expert-chat://documents/{self.file_id}/metadata"

    def to_dict(self) -> dict[str, Any]:
        return {
            "file_id": self.file_id,
            "filename": self.filename,
            "mime_type": self.mime_type,
            "size_bytes": self.size_bytes,
            "created_at": self.created_at,
            "resources": {
                "binary": self.binary_resource_uri,
                "text": self.text_resource_uri,
                "metadata": self.metadata_resource_uri,
            },
        }


@dataclass(frozen=True)
class DocumentMcpBackend:
    resolve_token: Callable[[str], McpIdentity | None]
    list_documents: Callable[[str, int], list[StoredDocument]]
    inspect_document: Callable[[str, str, int], dict[str, Any]]
    read_document_metadata: Callable[[str, str], dict[str, Any]]
    read_document_text: Callable[[str, str], str]
    read_document_binary: Callable[[str, str], bytes]
    edit_document: Callable[[str, str, dict[str, Any]], StoredDocument]
    convert_document: Callable[[str, str, str, str | None], StoredDocument]
    begin_upload: Callable[[str, str, str, int], dict[str, Any]] | None = None
    append_upload: Callable[[str, str, str, int], dict[str, Any]] | None = None
    finish_upload: Callable[[str, str], StoredDocument] | None = None
    abort_upload: Callable[[str, str], dict[str, Any]] | None = None
    delete_document: Callable[[str, str], dict[str, Any]] | None = None


class GatewayTokenVerifier(TokenVerifier):
    """Bridge the existing Gateway token validator into MCP OAuth middleware."""

    def __init__(
        self,
        resolve_token: Callable[[str], McpIdentity | None],
        resource_server_url: str,
    ) -> None:
        self._resolve_token = resolve_token
        self._resource_server_url = resource_server_url

    async def verify_token(self, token: str) -> AccessToken | None:
        identity = await asyncio.to_thread(self._resolve_token, token)
        if identity is None:
            return None
        return AccessToken(
            token=token,
            client_id=identity.client_id,
            scopes=list(identity.scopes),
            resource=self._resource_server_url,
            subject=identity.subject,
            claims={
                "display_name": identity.display_name,
                "auth_kind": identity.auth_kind,
            },
        )


def _subject_with_scope(scope: str, *, resource: bool = False) -> str:
    token = get_access_token()
    error_type = ResourceError if resource else ToolError
    if token is None or not token.subject:
        raise error_type("需要有效的 Bearer Token")
    if scope not in token.scopes:
        raise error_type(f"账户缺少权限：{scope}")
    return token.subject


def _document_result(
    document: StoredDocument,
    message: str,
) -> CallToolResult:
    structured = {"message": message, **document.to_dict()}
    return CallToolResult(
        content=[
            TextContent(text=message),
            ResourceLink(
                name=document.filename,
                uri=document.binary_resource_uri,
                description="生成的文档，可通过 resources/read 获取。",
                mimeType=document.mime_type,
                size=document.size_bytes,
            ),
        ],
        structuredContent=structured,
    )


def create_document_mcp_server(
    backend: DocumentMcpBackend,
    *,
    issuer_url: str,
    resource_server_url: str,
    version: str,
) -> MCPServer:
    """Create the standards-facing MCP adapter for the document subsystem."""

    mcp = MCPServer(
        "expert-chat-documents",
        title="Expert Chat 文档服务",
        description="读取、检查、编辑和转换 Expert Chat 文档。",
        instructions=(
            "客户端通过 begin_upload、append_upload、finish_upload 分块上传文件；"
            "先调用 list_documents 找到当前账户的 file_id；"
            "需要了解结构时调用 inspect_document；"
            "编辑和转换总是生成新文件并返回 resource_link，不覆盖原文件。"
        ),
        version=version,
        token_verifier=GatewayTokenVerifier(
            backend.resolve_token,
            resource_server_url,
        ),
        auth=AuthSettings(
            issuer_url=AnyHttpUrl(issuer_url),
            resource_server_url=AnyHttpUrl(resource_server_url),
            required_scopes=["gateway.use"],
        ),
    )

    read_only = ToolAnnotations(read_only_hint=True, open_world_hint=False)
    creates_document = ToolAnnotations(
        read_only_hint=False,
        destructive_hint=False,
        idempotent_hint=False,
        open_world_hint=False,
    )
    upload_annotation = ToolAnnotations(
        read_only_hint=False,
        destructive_hint=False,
        idempotent_hint=True,
        open_world_hint=False,
    )

    if (
        backend.begin_upload is not None
        and backend.append_upload is not None
        and backend.finish_upload is not None
        and backend.abort_upload is not None
    ):

        @mcp.tool(title="开始上传文档", annotations=upload_annotation)
        async def begin_upload(
            filename: Annotated[str, Field(min_length=1, max_length=180)],
            mime_type: Annotated[str, Field(min_length=1, max_length=160)],
            size_bytes: Annotated[int, Field(ge=1)],
        ) -> dict[str, Any]:
            """创建 MCP 分块上传；由客户端内部调用，不应让模型生成文件内容。"""

            subject = _subject_with_scope("files.write")
            return await asyncio.to_thread(
                backend.begin_upload,
                subject,
                filename,
                mime_type,
                size_bytes,
            )

        @mcp.tool(title="追加上传分块", annotations=upload_annotation)
        async def append_upload(
            upload_id: Annotated[str, Field(min_length=1, max_length=96)],
            chunk_base64: Annotated[str, Field(min_length=1, max_length=1_500_000)],
            offset: Annotated[int, Field(ge=0)],
        ) -> dict[str, Any]:
            """按 offset 追加 Base64 文件分块；由客户端内部调用。"""

            subject = _subject_with_scope("files.write")
            return await asyncio.to_thread(
                backend.append_upload,
                subject,
                upload_id,
                chunk_base64,
                offset,
            )

        @mcp.tool(title="完成上传", annotations=creates_document)
        async def finish_upload(
            upload_id: Annotated[str, Field(min_length=1, max_length=96)],
        ) -> CallToolResult:
            """校验并提交已经上传的全部分块。"""

            subject = _subject_with_scope("files.write")
            document = await asyncio.to_thread(
                backend.finish_upload,
                subject,
                upload_id,
            )
            return _document_result(document, f"已上传“{document.filename}”。")

        @mcp.tool(title="放弃上传", annotations=upload_annotation)
        async def abort_upload(
            upload_id: Annotated[str, Field(min_length=1, max_length=96)],
        ) -> dict[str, Any]:
            """删除未完成上传的临时分块。"""

            subject = _subject_with_scope("files.write")
            return await asyncio.to_thread(
                backend.abort_upload,
                subject,
                upload_id,
            )

    @mcp.tool(
        title="列出文档",
        annotations=read_only,
    )
    async def list_documents(
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
    ) -> dict[str, Any]:
        """列出当前账户最近上传或由工具生成的文档及其 MCP Resource URI。"""

        subject = _subject_with_scope("gateway.use")
        items = await asyncio.to_thread(backend.list_documents, subject, limit)
        return {"documents": [item.to_dict() for item in items]}

    @mcp.tool(
        title="检查文档",
        annotations=read_only,
    )
    async def inspect_document(
        file_id: Annotated[str, Field(min_length=1, max_length=96)],
        max_chars: Annotated[int, Field(ge=1000, le=100_000)] = 20_000,
    ) -> dict[str, Any]:
        """提取一个文档的结构化文本预览，便于生成可靠的编辑补丁。"""

        subject = _subject_with_scope("gateway.use")
        return await asyncio.to_thread(
            backend.inspect_document,
            subject,
            file_id,
            max_chars,
        )

    @mcp.tool(
        title="编辑文档",
        annotations=creates_document,
        structured_output=False,
    )
    async def edit_document(
        file_id: Annotated[str, Field(min_length=1, max_length=96)],
        patch: DocumentPatchModel,
        output_filename: Annotated[str | None, Field(max_length=180)] = None,
    ) -> CallToolResult:
        """按 DocumentPatch v1 编辑文档；支持 xlsx/docx/pptx/txt/md/csv/tsv。"""

        subject = _subject_with_scope("documents.edit")
        patch_payload = patch.model_dump(exclude_none=True)
        if output_filename:
            patch_payload["output_filename"] = output_filename
        document = await asyncio.to_thread(
            backend.edit_document,
            subject,
            file_id,
            patch_payload,
        )
        return _document_result(
            document,
            f"已生成修改后的文件“{document.filename}”。",
        )

    @mcp.tool(
        title="转换文档",
        annotations=creates_document,
        structured_output=False,
    )
    async def convert_document(
        file_id: Annotated[str, Field(min_length=1, max_length=96)],
        target_format: DocumentFormat,
        output_filename: Annotated[str | None, Field(max_length=180)] = None,
    ) -> CallToolResult:
        """把文档转换为支持的目标格式，并以新 MCP Resource 返回。"""

        subject = _subject_with_scope("documents.convert")
        document = await asyncio.to_thread(
            backend.convert_document,
            subject,
            file_id,
            target_format,
            output_filename,
        )
        return _document_result(
            document,
            f"已转换为“{document.filename}”。",
        )

    if backend.delete_document is not None:

        @mcp.tool(
            title="删除文档",
            annotations=ToolAnnotations(
                read_only_hint=False,
                destructive_hint=True,
                idempotent_hint=True,
                open_world_hint=False,
            ),
        )
        async def delete_document(
            file_id: Annotated[str, Field(min_length=1, max_length=96)],
        ) -> dict[str, Any]:
            """删除 MCP Server 中的持久文档。"""

            subject = _subject_with_scope("files.write")
            return await asyncio.to_thread(
                backend.delete_document,
                subject,
                file_id,
            )

    @mcp.resource(
        "expert-chat://documents/{file_id}/metadata",
        name="document_metadata",
        title="文档元数据",
        description="读取当前账户中文档的名称、类型、大小和 Resource URI。",
        mime_type="application/json",
    )
    async def document_metadata(file_id: str) -> dict[str, Any]:
        subject = _subject_with_scope("gateway.use", resource=True)
        return await asyncio.to_thread(
            backend.read_document_metadata,
            subject,
            file_id,
        )

    @mcp.resource(
        "expert-chat://documents/{file_id}/text",
        name="document_text",
        title="文档提取文本",
        description="读取服务器从文档中提取的文本内容。",
        mime_type="text/plain",
    )
    async def document_text(file_id: str) -> str:
        subject = _subject_with_scope("gateway.use", resource=True)
        return await asyncio.to_thread(
            backend.read_document_text,
            subject,
            file_id,
        )

    @mcp.resource(
        "expert-chat://documents/{file_id}/binary",
        name="document_binary",
        title="文档原始文件",
        description="读取文档原始二进制内容。",
        mime_type="application/octet-stream",
    )
    async def document_binary(file_id: str) -> bytes:
        subject = _subject_with_scope("gateway.use", resource=True)
        return await asyncio.to_thread(
            backend.read_document_binary,
            subject,
            file_id,
        )

    return mcp


def mcp_transport_security_from_env(
    *,
    allowed_hosts: list[str],
    allowed_origins: list[str],
) -> TransportSecuritySettings | None:
    if not allowed_hosts and not allowed_origins:
        return None
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=allowed_hosts,
        allowed_origins=allowed_origins,
    )
