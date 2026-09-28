"""Exercise the packaged executable, including its isolated document worker.

Uses a random loopback port/token and temporary storage. Never loads installed
application settings or talks to a model service.
"""

import argparse
import asyncio
import base64
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request


async def exercise(url, token):
    import httpx2
    from mcp import Client
    from mcp.client.streamable_http import streamable_http_client

    async with httpx2.AsyncClient(headers={"Authorization": "Bearer " + token}) as http:
        async with Client(streamable_http_client(url, http_client=http)) as client:
            tools = await client.list_tools()
            assert any(tool.name == "edit_document" for tool in tools.tools)
            started = await client.call_tool(
                "begin_upload",
                {"filename": "fixture.txt", "mime_type": "text/plain", "size_bytes": 3},
            )
            upload_id = started.structured_content["upload_id"]
            await client.call_tool(
                "append_upload",
                {
                    "upload_id": upload_id,
                    "offset": 0,
                    "chunk_base64": base64.b64encode(b"old").decode(),
                },
            )
            finished = await client.call_tool("finish_upload", {"upload_id": upload_id})
            file_id = finished.structured_content["file_id"]
            repeated = await client.call_tool("finish_upload", {"upload_id": upload_id})
            assert repeated.structured_content["file_id"] == file_id
            edited = await client.call_tool(
                "edit_document",
                {
                    "file_id": file_id,
                    "patch": {
                        "schema_version": 1,
                        "format": "txt",
                        "ops": [{"op": "replace_text", "find": "old", "replace": "new"}],
                    },
                },
            )
            result_id = edited.structured_content["file_id"]
            resource = await client.read_resource(f"expert-chat://documents/{result_id}/binary")
            assert base64.b64decode(resource.contents[0].blob) == b"new"
            for item in [file_id, result_id]:
                await client.call_tool("delete_document", {"file_id": item})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--dart-acceptance", action="store_true")
    parser.add_argument("--report-directory", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    token = secrets.token_urlsafe(32)
    with tempfile.TemporaryDirectory(prefix="expert-packaged-smoke-") as folder:
        env = os.environ.copy()
        env.update(
            MCP_API_TOKEN=token,
            MCP_DATA_DIR=str(Path(folder) / "data"),
            MCP_PUBLIC_URL=f"http://127.0.0.1:{port}/mcp",
            MCP_ALLOWED_HOSTS="127.0.0.1:*",
        )
        with (Path(folder) / "process.log").open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [
                    str(executable),
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--env-file",
                    str(Path(folder) / "mcp.env"),
                    "--data-dir",
                    str(Path(folder) / "data"),
                ],
                cwd=folder,
                env=env,
                stdout=log,
                stderr=log,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("Packaged server exited during startup")
                    try:
                        with urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/health", timeout=1
                        ) as response:
                            assert response.status == 200
                        break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise TimeoutError("Packaged server did not become ready")
                asyncio.run(exercise(f"http://127.0.0.1:{port}/mcp", token))
                assert (Path(folder) / "data/documents.sqlite3").is_file()
                assert not (Path(folder) / "mcp.env").exists()
                if args.dart_acceptance:
                    root = Path(__file__).resolve().parents[3]
                    report = (
                        args.report_directory.resolve() if args.report_directory else Path(folder)
                    ) / "dart-mcp-results.json"
                    report.parent.mkdir(parents=True, exist_ok=True)
                    client_env = os.environ.copy()
                    client_env.update(
                        EXPERT_CHAT_MCP_URL=f"http://127.0.0.1:{port}/mcp",
                        EXPERT_CHAT_MCP_TOKEN=token,
                        EXPERT_CHAT_ACCEPTANCE_REPORT=str(report),
                    )
                    subprocess.run(
                        [shutil.which("dart"), "run", "tool/mcp_acceptance.dart"],
                        cwd=root,
                        env=client_env,
                        check=True,
                        timeout=90,
                    )
                    print("Production Dart MCP client acceptance passed against packaged server.")
                print("Packaged MCP upload/retry/edit/worker/download/delete smoke passed.")
            finally:
                process.terminate()
                try:
                    process.wait(10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(5)


if __name__ == "__main__":
    main()
