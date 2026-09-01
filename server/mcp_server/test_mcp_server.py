from __future__ import annotations

import asyncio
import base64
import importlib
import os
import sys
import tempfile
from unittest.mock import patch


def _fresh_server():
    sys.modules.pop("mcp_server.app.main", None)
    from mcp_server.app import main

    return importlib.reload(main)


def test_standalone_mcp_upload_edit_and_resource_download() -> None:
    with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
        os.environ,
        {
            "MCP_DATA_DIR": temp_dir,
            "MCP_API_TOKEN": "single-user-token",
            "MCP_PUBLIC_URL": "http://127.0.0.1:8790/mcp",
            "MCP_ALLOWED_HOSTS": "127.0.0.1:*,testserver",
        },
        clear=False,
    ):
        main = _fresh_server()

        async def exercise() -> None:
            import httpx2
            from mcp import Client
            from mcp.client.streamable_http import streamable_http_client

            headers = {"Authorization": "Bearer single-user-token"}
            transport = httpx2.ASGITransport(app=main.app)
            async with (
                main.DOCUMENT_MCP.session_manager.run(),
                httpx2.AsyncClient(
                    transport=transport,
                    base_url="http://127.0.0.1:8790",
                    headers=headers,
                ) as http_client,
                Client(
                    streamable_http_client(
                        "http://127.0.0.1:8790/mcp",
                        http_client=http_client,
                    )
                ) as client,
            ):
                    tools = await client.list_tools()
                    names = {tool.name for tool in tools.tools}
                    assert {
                        "begin_upload",
                        "append_upload",
                        "finish_upload",
                        "abort_upload",
                        "list_documents",
                        "inspect_document",
                        "edit_document",
                        "convert_document",
                        "delete_document",
                    } <= names

                    source = "统一前的文本".encode()
                    started = await client.call_tool(
                        "begin_upload",
                        {
                            "filename": "source.txt",
                            "mime_type": "text/plain",
                            "size_bytes": len(source),
                        },
                    )
                    upload_id = started.structured_content["upload_id"]
                    appended = await client.call_tool(
                        "append_upload",
                        {
                            "upload_id": upload_id,
                            "chunk_base64": base64.b64encode(source).decode(),
                            "offset": 0,
                        },
                    )
                    assert appended.structured_content["complete"] is True
                    finished = await client.call_tool(
                        "finish_upload",
                        {"upload_id": upload_id},
                    )
                    source_id = finished.structured_content["file_id"]

                    edited = await client.call_tool(
                        "edit_document",
                        {
                            "file_id": source_id,
                            "output_filename": "edited.txt",
                            "patch": {
                                "schema_version": 1,
                                "format": "txt",
                                "ops": [
                                    {
                                        "op": "replace_text",
                                        "find": "统一前",
                                        "replace": "统一后",
                                    }
                                ],
                            },
                        },
                    )
                    edited_id = edited.structured_content["file_id"]
                    resource = await client.read_resource(
                        f"expert-chat://documents/{edited_id}/binary"
                    )
                    assert resource.contents[0].blob == base64.b64encode(
                        "统一后的文本".encode()
                    ).decode()

                    deleted = await client.call_tool(
                        "delete_document",
                        {"file_id": source_id},
                    )
                    assert deleted.structured_content["deleted"] is True

        asyncio.run(exercise())
