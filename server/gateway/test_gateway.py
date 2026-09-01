import asyncio
import concurrent.futures
import importlib
import json
import os
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException
from fastapi.testclient import TestClient


class GatewayAuthenticatorTest(unittest.TestCase):
    def test_oidc_enforces_issuer_audience_expiry_and_subject(self) -> None:
        from gateway.app.auth import GatewayAuthenticator

        private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public_key = private_key.public_key()

        class FakeJwksClient:
            def get_signing_key_from_jwt(self, _token):
                return type("SigningKey", (), {"key": public_key})()

        now = datetime.now(timezone.utc)

        def token(**overrides):
            claims = {
                "iss": "https://auth.example.test/",
                "aud": "expert-chat",
                "sub": "user-123",
                "iat": now,
                "exp": now + timedelta(minutes=5),
            }
            claims.update(overrides)
            return jwt.encode(claims, private_key, algorithm="RS256")

        with patch.dict(
            os.environ,
            {
                "GATEWAY_AUTH_MODE": "oidc",
                "GATEWAY_OIDC_ISSUER": "https://auth.example.test/",
                "GATEWAY_OIDC_AUDIENCE": "expert-chat",
                "GATEWAY_OIDC_REQUIRE_AUDIENCE": "true",
                "GATEWAY_ADMIN_SUBS": "user-123",
            },
        ):
            auth = GatewayAuthenticator()
            auth._jwks_client = FakeJwksClient()

            principal = auth.authenticate(f"Bearer {token()}")
            self.assertEqual(principal.subject, "user-123")
            self.assertTrue(principal.bootstrap_admin)

            for invalid in (
                token(aud="another-project"),
                token(iss="https://attacker.example/"),
                token(exp=now - timedelta(seconds=1)),
                token(sub=""),
            ):
                with self.assertRaises(HTTPException) as caught:
                    auth.authenticate(f"Bearer {invalid}")
                self.assertEqual(caught.exception.status_code, 401)


class GatewayFlowTest(unittest.TestCase):
    def test_accounts_are_isolated_and_entitlements_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ,
            {
                "GATEWAY_DATA_DIR": temp_dir,
                "GATEWAY_AUTH_MODE": "hybrid",
                "GATEWAY_API_TOKEN": "migration-token",
                "LLM_BASE_URL": "http://upstream.invalid/v1",
                "LLM_MODEL": "test-model",
            },
        ):
            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)

            def authenticate(value):
                token = (value or "").removeprefix("Bearer ")
                return Principal(
                    subject=token,
                    display_name=token,
                    scopes=frozenset(),
                    auth_kind="oidc",
                    bootstrap_admin=token == "admin-user",
                )

            async def fake_completion(model, messages):
                return "片段摘要"

            async def fake_stream(task_id, model, messages):
                return "完成"

            with patch.object(main.AUTH, "authenticate", authenticate), patch.object(
                main, "_completion", fake_completion
            ), patch.object(main, "_stream_completion", fake_stream), TestClient(
                main.app
            ) as client:
                user_a = {"Authorization": "Bearer user-a"}
                user_b = {"Authorization": "Bearer user-b"}
                admin = {"Authorization": "Bearer admin-user"}
                upload = client.post(
                    "/v1/files",
                    headers=user_a,
                    files={"file": ("private.txt", "私有内容", "text/plain")},
                )
                self.assertEqual(upload.status_code, 200, upload.text)
                file_id = upload.json()["id"]
                created = client.post(
                    "/v1/tasks",
                    headers=user_a,
                    json={"prompt": "总结", "file_ids": [file_id]},
                )
                self.assertEqual(created.status_code, 200, created.text)
                task_id = created.json()["id"]

                foreign_file = client.post(
                    "/v1/tasks",
                    headers=user_b,
                    json={"prompt": "读取", "file_ids": [file_id]},
                )
                self.assertEqual(foreign_file.status_code, 400, foreign_file.text)
                foreign_task = client.get(f"/v1/tasks/{task_id}", headers=user_b)
                self.assertEqual(foreign_task.status_code, 404, foreign_task.text)

                client.get("/v1/me", headers=user_b)
                with main._db() as db:
                    db.execute(
                        "UPDATE user_entitlements SET permissions_json = ? "
                        "WHERE owner_sub = ?",
                        (json.dumps(["gateway.use"]), "user-b"),
                    )
                denied = client.post(
                    "/v1/files",
                    headers=user_b,
                    files={"file": ("denied.txt", "no", "text/plain")},
                )
                self.assertEqual(denied.status_code, 403, denied.text)

                not_admin = client.get("/v1/admin/overview", headers=user_a)
                self.assertEqual(not_admin.status_code, 403, not_admin.text)
                overview = client.get("/v1/admin/overview", headers=admin)
                self.assertEqual(overview.status_code, 200, overview.text)
                self.assertGreaterEqual(overview.json()["users"], 3)

                admin_page = client.get("/admin")
                self.assertEqual(admin_page.status_code, 200, admin_page.text)
                self.assertIn("使用 AuthService 登录", admin_page.text)
                self.assertIn(
                    "default-src 'none'",
                    admin_page.headers["content-security-policy"],
                )

    def test_cleanup_removes_only_expired_terminal_tasks_and_events(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            with patch.dict(
                os.environ,
                {
                    "GATEWAY_DATA_DIR": temp_dir,
                    "GATEWAY_TASK_RETENTION_DAYS": "30",
                },
            ):
                from gateway.app import main

                importlib.reload(main)
                main._init_db()
                now = datetime(2026, 8, 13, tzinfo=timezone.utc)
                old = (now - timedelta(days=31)).isoformat()
                recent = (now - timedelta(days=29)).isoformat()

                with main._db() as db:
                    for task_id, status, updated_at in (
                        ("task_old", "completed", old),
                        ("task_recent", "failed", recent),
                        ("task_running", "running", old),
                    ):
                        db.execute(
                            """
                            INSERT INTO tasks(
                                id, status, prompt, instructions, messages_json,
                                file_ids_json, model, output_text, progress,
                                created_at, updated_at
                            ) VALUES (?, ?, '', '', '[]', '[]', 'test-model',
                                      '', 0, ?, ?)
                            """,
                            (task_id, status, updated_at, updated_at),
                        )
                        db.execute(
                            "INSERT INTO events(task_id, type, data_json, created_at) "
                            "VALUES (?, 'progress', '{}', ?)",
                            (task_id, updated_at),
                        )

                self.assertEqual(main._cleanup_expired_tasks(now=now), 1)
                with main._db() as db:
                    task_ids = {
                        row["id"] for row in db.execute("SELECT id FROM tasks")
                    }
                    event_task_ids = {
                        row["task_id"]
                        for row in db.execute("SELECT task_id FROM events")
                    }
                self.assertEqual(task_ids, {"task_recent", "task_running"})
                self.assertEqual(event_task_ids, {"task_recent", "task_running"})

    def test_provision_skips_writes_when_entitlement_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ, {"GATEWAY_DATA_DIR": temp_dir}
        ):
            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)
            main._init_db()
            principal = Principal(
                subject="user-1",
                display_name="用户一",
                scopes=frozenset(),
                auth_kind="oidc",
            )

            main._provision_principal(principal)
            with main._db() as db:
                db.execute(
                    "UPDATE user_entitlements SET updated_at = 'sentry' "
                    "WHERE owner_sub = 'user-1'"
                )
            main._provision_principal(principal)
            with main._db() as db:
                row = db.execute(
                    "SELECT updated_at FROM user_entitlements "
                    "WHERE owner_sub = 'user-1'"
                ).fetchone()
            self.assertEqual(row["updated_at"], "sentry")

            changed = Principal(
                subject="user-1",
                display_name="用户二",
                scopes=frozenset(),
                auth_kind="oidc",
            )
            main._provision_principal(changed)
            with main._db() as db:
                row = db.execute(
                    "SELECT display_name, updated_at FROM user_entitlements "
                    "WHERE owner_sub = 'user-1'"
                ).fetchone()
            self.assertEqual(row["display_name"], "用户二")
            self.assertNotEqual(row["updated_at"], "sentry")

    def test_upload_quota_is_checked_atomically_with_the_insert(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ,
            {
                "GATEWAY_DATA_DIR": temp_dir,
                "GATEWAY_AUTH_MODE": "hybrid",
                "GATEWAY_API_TOKEN": "migration-token",
                "LLM_BASE_URL": "http://upstream.invalid/v1",
                "LLM_MODEL": "test-model",
            },
        ):
            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)

            def authenticate(value):
                del value
                return Principal(
                    subject="quota-user",
                    display_name="quota-user",
                    scopes=frozenset(),
                    auth_kind="oidc",
                )

            with patch.object(main.AUTH, "authenticate", authenticate), TestClient(
                main.app
            ) as client:
                headers = {"Authorization": "Bearer quota-user"}
                main._provision_principal(
                    Principal(
                        subject="quota-user",
                        display_name="quota-user",
                        scopes=frozenset(),
                        auth_kind="oidc",
                    )
                )
                with main._db() as db:
                    db.execute(
                        "UPDATE user_entitlements SET storage_quota_bytes = ? "
                        "WHERE owner_sub = 'quota-user'",
                        (200,),
                    )
                first = client.post(
                    "/v1/files",
                    headers=headers,
                    files={"file": ("a.txt", b"x" * 100, "text/plain")},
                )
                self.assertEqual(first.status_code, 200, first.text)
                over = client.post(
                    "/v1/files",
                    headers=headers,
                    files={"file": ("b.txt", b"y" * 150, "text/plain")},
                )
                self.assertEqual(over.status_code, 413, over.text)
                with main._db() as db:
                    count = db.execute(
                        "SELECT COUNT(*) AS total FROM files "
                        "WHERE owner_sub = 'quota-user'"
                    ).fetchone()["total"]
                self.assertEqual(count, 1)
                self.assertEqual(len(list(main.UPLOAD_DIR.glob("file_*"))), 1)

    def test_rate_limit_windows_are_swept_after_expiry(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ, {"GATEWAY_DATA_DIR": temp_dir}
        ):
            from gateway.app import main

            importlib.reload(main)
            with patch.object(main.time, "monotonic", return_value=0.0):
                for index in range(main._RATE_WINDOW_SWEEP_EVERY - 1):
                    main._consume_rate_limit(f"subject-{index}", "api")
            self.assertEqual(len(main._rate_windows), 255)
            with patch.object(main.time, "monotonic", return_value=120.0):
                main._consume_rate_limit("subject-new", "api")
            self.assertEqual(len(main._rate_windows), 1)
            self.assertIn(("subject-new", "api"), main._rate_windows)

    def test_upload_durable_task_events_and_idempotency(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            os.environ["GATEWAY_DATA_DIR"] = temp_dir
            os.environ["GATEWAY_API_TOKEN"] = "test-token"
            os.environ["LLM_BASE_URL"] = "http://upstream.invalid/v1"
            os.environ["LLM_MODEL"] = "test-model"

            from gateway.app import main

            importlib.reload(main)

            async def fake_completion(model, messages):
                self.assertEqual(model, "test-model")
                return "片段事实：测试文档包含可恢复任务。"

            async def fake_stream(task_id, model, messages):
                output = "这是持久化的最终结果。"
                main._update_task(
                    task_id,
                    output_text=output,
                    progress=0.98,
                    detail="正在生成结果",
                )
                main._event(task_id, "output_delta", {"delta": output})
                return output

            headers = {"Authorization": "Bearer test-token"}
            with patch.object(main, "_completion", fake_completion), patch.object(
                main, "_stream_completion", fake_stream
            ), TestClient(main.app) as client:
                upload = client.post(
                    "/v1/files",
                    headers=headers,
                    files={"file": ("notes.txt", "一段测试文档", "text/plain")},
                )
                self.assertEqual(upload.status_code, 200, upload.text)
                file_id = upload.json()["id"]

                payload = {
                    "prompt": "总结文件",
                    "file_ids": [file_id],
                    "client_request_id": "assistant-message-1",
                }
                discovered = client.get("/v1/capabilities", headers=headers)
                self.assertEqual(discovered.status_code, 200, discovered.text)
                capability_ids = discovered.json()["capabilities"].keys()
                self.assertIn("long_tasks", capability_ids)
                self.assertIn("document_edit", capability_ids)
                self.assertIn("document_convert", capability_ids)

                edited = client.post(
                    "/v1/documents/edit",
                    headers=headers,
                    files={
                        "file": (
                            "draft.txt",
                            "统一前的文本".encode(),
                            "text/plain",
                        )
                    },
                    data={
                        "filename": "draft.txt",
                        "patch": json.dumps(
                            {
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
                            ensure_ascii=False,
                        ),
                    },
                )
                self.assertEqual(edited.status_code, 200, edited.text)
                self.assertEqual(edited.content.decode(), "统一后的文本")

                created = client.post("/v1/tasks", headers=headers, json=payload)
                self.assertEqual(created.status_code, 200, created.text)
                task_id = created.json()["id"]

                duplicate = client.post("/v1/tasks", headers=headers, json=payload)
                self.assertEqual(duplicate.json()["id"], task_id)

                snapshot = created.json()
                for _ in range(100):
                    snapshot = client.get(
                        f"/v1/tasks/{task_id}", headers=headers
                    ).json()
                    if snapshot["status"] in {"completed", "failed"}:
                        break
                    time.sleep(0.01)

                self.assertEqual(snapshot["status"], "completed", snapshot)
                self.assertEqual(snapshot["output_text"], "这是持久化的最终结果。")
                self.assertEqual(snapshot["progress"], 1.0)

                events = client.get(
                    f"/v1/tasks/{task_id}/events?after=0", headers=headers
                ).json()
                event_types = [event["type"] for event in events["events"]]
                self.assertIn("output_delta", event_types)
                self.assertIn("completed", event_types)
                self.assertGreater(events["next_after"], 0)
                self.assertTrue((Path(temp_dir) / "gateway.sqlite3").exists())

    def test_startup_finalizes_cancel_requested_ghost_tasks(self) -> None:
        """Hard-crash leftovers with cancel_requested=1 must not occupy quota.

        The recovery UPDATE used to only re-queue cancel_requested=0 rows, so
        ghosts stayed queued/running forever: _cleanup_expired_tasks deletes
        terminal states only, and create_task counts them against
        max_concurrent_tasks until the user is permanently 429-locked.
        """
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ,
            {
                "GATEWAY_DATA_DIR": temp_dir,
                "GATEWAY_AUTH_MODE": "hybrid",
                "GATEWAY_API_TOKEN": "migration-token",
                "LLM_BASE_URL": "http://upstream.invalid/v1",
                "LLM_MODEL": "test-model",
            },
        ):
            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)
            main._init_db()
            stamp = datetime.now(timezone.utc).isoformat()
            with main._db() as db:
                for task_id, status in (
                    ("ghost_running", "running"),
                    ("ghost_queued", "queued"),
                ):
                    db.execute(
                        """
                        INSERT INTO tasks(
                            id, owner_sub, status, prompt, instructions,
                            messages_json, file_ids_json, model, cancel_requested,
                            created_at, updated_at
                        ) VALUES (?, 'user-a', ?, '', '', '[]', '[]',
                                  'test-model', 1, ?, ?)
                        """,
                        (task_id, status, stamp, stamp),
                    )

            def authenticate(value):
                token = (value or "").removeprefix("Bearer ")
                return Principal(
                    subject=token,
                    display_name=token,
                    scopes=frozenset(),
                    auth_kind="oidc",
                )

            async def fake_stream(task_id, model, messages):
                return "完成"

            with patch.object(main.AUTH, "authenticate", authenticate), patch.object(
                main, "_stream_completion", fake_stream
            ), TestClient(main.app) as client:
                headers = {"Authorization": "Bearer user-a"}
                with main._db() as db:
                    statuses = {
                        row["id"]: row["status"]
                        for row in db.execute("SELECT id, status FROM tasks")
                    }
                self.assertEqual(statuses["ghost_running"], "cancelled")
                self.assertEqual(statuses["ghost_queued"], "cancelled")

                # The finalized ghosts no longer occupy the account quota.
                upload = client.post(
                    "/v1/files",
                    headers=headers,
                    files={"file": ("note.txt", "内容", "text/plain")},
                )
                self.assertEqual(upload.status_code, 200, upload.text)
                created = client.post(
                    "/v1/tasks",
                    headers=headers,
                    json={"prompt": "总结", "file_ids": [upload.json()["id"]]},
                )
                self.assertEqual(created.status_code, 200, created.text)

    def test_provision_first_login_race_is_insert_or_ignore(self) -> None:
        """Concurrent first logins for one subject must not 500 on the PK.

        Two requests can both pass the SELECT before either commits; the
        loser used to crash with sqlite3.IntegrityError (sync deps run on a
        thread pool, so this is real concurrency).
        """
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ, {"GATEWAY_DATA_DIR": temp_dir}
        ):
            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)
            main._init_db()
            principal = Principal(
                subject="user-race",
                display_name="并发用户",
                scopes=frozenset(),
                auth_kind="oidc",
            )

            workers = 8
            barrier = threading.Barrier(workers)

            def hit():
                barrier.wait()
                return main._provision_principal(principal)

            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                for future in concurrent.futures.as_completed(
                    [pool.submit(hit) for _ in range(workers)]
                ):
                    future.result()  # must not raise IntegrityError

            with main._db() as db:
                total = db.execute(
                    "SELECT COUNT(*) AS total FROM user_entitlements "
                    "WHERE owner_sub = 'user-race'"
                ).fetchone()["total"]
            self.assertEqual(total, 1)


class GatewayMcpTest(unittest.TestCase):
    def test_document_tools_and_resources_use_standard_mcp(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ,
            {
                "GATEWAY_DATA_DIR": temp_dir,
                "GATEWAY_AUTH_MODE": "legacy",
                "GATEWAY_API_TOKEN": "mcp-test-token",
                "GATEWAY_MCP_PUBLIC_URL": "http://127.0.0.1:8790/mcp",
                "GATEWAY_MCP_ALLOWED_HOSTS": "127.0.0.1:*,testserver",
            },
        ):
            import httpx2
            from mcp import Client
            from mcp.client.streamable_http import streamable_http_client
            from mcp.types import BlobResourceContents, ResourceLink

            from gateway.app import main

            importlib.reload(main)
            headers = {"Authorization": "Bearer mcp-test-token"}

            with TestClient(main.app) as rest:
                unauthenticated = rest.post("/mcp", json={})
                self.assertEqual(unauthenticated.status_code, 401)
                protected_resource = rest.get(
                    "/.well-known/oauth-protected-resource/mcp"
                )
                self.assertEqual(
                    protected_resource.status_code,
                    200,
                    protected_resource.text,
                )
                self.assertEqual(
                    protected_resource.json()["resource"],
                    "http://127.0.0.1:8790/mcp",
                )

                uploaded = rest.post(
                    "/v1/files",
                    headers=headers,
                    files={"file": ("draft.txt", "统一前的文本", "text/plain")},
                )
                self.assertEqual(uploaded.status_code, 200, uploaded.text)
                source_id = uploaded.json()["id"]
                discovered = rest.get("/v1/capabilities", headers=headers)
                self.assertIn("document_mcp", discovered.json()["capabilities"])

                async def exercise_protocol() -> None:
                    url = "http://127.0.0.1:8790/mcp"
                    transport = httpx2.ASGITransport(app=main.app)
                    async with httpx2.AsyncClient(
                        transport=transport,
                        base_url="http://127.0.0.1:8790",
                        headers=headers,
                        follow_redirects=True,
                    ) as http_client:
                        async with Client(
                            streamable_http_client(url, http_client=http_client)
                        ) as client:
                            tools = await client.list_tools()
                            tool_names = {tool.name for tool in tools.tools}
                            self.assertEqual(
                                tool_names,
                                {
                                    "list_documents",
                                    "inspect_document",
                                    "edit_document",
                                    "convert_document",
                                },
                            )
                            edit_schema = next(
                                tool.input_schema
                                for tool in tools.tools
                                if tool.name == "edit_document"
                            )
                            serialized_schema = json.dumps(edit_schema)
                            self.assertIn("set_cells", serialized_schema)
                            self.assertIn("replace_text", serialized_schema)
                            self.assertIn("set_shape_text", serialized_schema)

                            templates = await client.list_resource_templates()
                            template_uris = {
                                str(item.uri_template) for item in templates.resource_templates
                            }
                            self.assertIn(
                                "expert-chat://documents/{file_id}/text",
                                template_uris,
                            )
                            self.assertIn(
                                "expert-chat://documents/{file_id}/binary",
                                template_uris,
                            )

                            listed = await client.call_tool("list_documents", {})
                            self.assertFalse(listed.is_error)
                            listed_ids = {
                                item["file_id"]
                                for item in listed.structured_content["documents"]
                            }
                            self.assertIn(source_id, listed_ids)

                            inspected = await client.call_tool(
                                "inspect_document",
                                {"file_id": source_id},
                            )
                            self.assertFalse(inspected.is_error)
                            self.assertIn(
                                "统一前的文本",
                                inspected.structured_content["text"],
                            )

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
                            self.assertFalse(edited.is_error, edited.content)
                            edited_id = edited.structured_content["file_id"]
                            self.assertNotEqual(edited_id, source_id)
                            self.assertEqual(
                                edited.structured_content["filename"],
                                "edited.txt",
                            )
                            self.assertTrue(
                                any(isinstance(block, ResourceLink) for block in edited.content)
                            )

                            text_resource = await client.read_resource(
                                f"expert-chat://documents/{edited_id}/text"
                            )
                            self.assertEqual(text_resource.contents[0].text, "统一后的文本")
                            binary_resource = await client.read_resource(
                                f"expert-chat://documents/{edited_id}/binary"
                            )
                            self.assertIsInstance(
                                binary_resource.contents[0],
                                BlobResourceContents,
                            )

                            converted = await client.call_tool(
                                "convert_document",
                                {
                                    "file_id": edited_id,
                                    "target_format": "md",
                                    "output_filename": "edited.md",
                                },
                            )
                            self.assertFalse(converted.is_error, converted.content)
                            self.assertEqual(
                                converted.structured_content["filename"],
                                "edited.md",
                            )

                asyncio.run(exercise_protocol())

    def test_mcp_preserves_account_isolation_and_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(
            os.environ,
            {
                "GATEWAY_DATA_DIR": temp_dir,
                "GATEWAY_AUTH_MODE": "hybrid",
                "GATEWAY_API_TOKEN": "migration-token",
                "GATEWAY_MCP_PUBLIC_URL": "http://127.0.0.1:8790/mcp",
                "GATEWAY_MCP_ALLOWED_HOSTS": "127.0.0.1:*",
            },
        ):
            import httpx2
            from mcp import Client, MCPError
            from mcp.client.streamable_http import streamable_http_client

            from gateway.app import main
            from gateway.app.auth import Principal

            importlib.reload(main)

            def authenticate(value):
                token = (value or "").removeprefix("Bearer ")
                if token not in {"user-a", "user-b"}:
                    raise HTTPException(status_code=401, detail="invalid")
                return Principal(
                    subject=token,
                    display_name=token,
                    scopes=frozenset(),
                    auth_kind="oidc",
                )

            with patch.object(main.AUTH, "authenticate", authenticate), TestClient(
                main.app
            ) as rest:
                source = rest.post(
                    "/v1/files",
                    headers={"Authorization": "Bearer user-a"},
                    files={"file": ("private.txt", "仅用户 A 可见", "text/plain")},
                )
                self.assertEqual(source.status_code, 200, source.text)
                source_id = source.json()["id"]
                rest.get("/v1/me", headers={"Authorization": "Bearer user-b"})
                with main._db() as db:
                    db.execute(
                        "UPDATE user_entitlements SET permissions_json = ? "
                        "WHERE owner_sub = ?",
                        (json.dumps(["gateway.use"]), "user-b"),
                    )

                async def exercise_denials() -> None:
                    url = "http://127.0.0.1:8790/mcp"
                    transport = httpx2.ASGITransport(app=main.app)
                    async with httpx2.AsyncClient(
                        transport=transport,
                        base_url="http://127.0.0.1:8790",
                        headers={"Authorization": "Bearer user-b"},
                        follow_redirects=True,
                    ) as http_client:
                        async with Client(
                            streamable_http_client(url, http_client=http_client)
                        ) as client:
                            listed = await client.call_tool("list_documents", {})
                            self.assertEqual(
                                listed.structured_content["documents"],
                                [],
                            )
                            inspected = await client.call_tool(
                                "inspect_document",
                                {"file_id": source_id},
                            )
                            self.assertTrue(inspected.is_error)
                            edited = await client.call_tool(
                                "edit_document",
                                {
                                    "file_id": source_id,
                                    "patch": {
                                        "schema_version": 1,
                                        "format": "txt",
                                        "ops": [
                                            {
                                                "op": "replace_text",
                                                "find": "A",
                                                "replace": "B",
                                            }
                                        ],
                                    },
                                },
                            )
                            self.assertTrue(edited.is_error)
                            with self.assertRaises(MCPError):
                                await client.read_resource(
                                    f"expert-chat://documents/{source_id}/text"
                                )

                asyncio.run(exercise_denials())


class StandaloneDocEditAuthTest(unittest.TestCase):
    def test_empty_or_whitespace_bearer_is_rejected(self) -> None:
        with patch.dict(os.environ, {"GATEWAY_API_TOKEN": "secret-token"}):
            from doc_edit.app import main as doc_edit

            importlib.reload(doc_edit)
            for header in ("Bearer", "Bearer   ", "Bearer\t"):
                with self.subTest(header=header):
                    with self.assertRaises(HTTPException) as caught:
                        doc_edit.require_auth(header)
                    self.assertEqual(caught.exception.status_code, 401)
            doc_edit.require_auth("Bearer secret-token")

    def test_wrong_token_is_rejected(self) -> None:
        with patch.dict(os.environ, {"GATEWAY_API_TOKEN": "secret-token"}):
            from doc_edit.app import main as doc_edit

            importlib.reload(doc_edit)
            with self.assertRaises(HTTPException) as caught:
                doc_edit.require_auth("Bearer other-token")
            self.assertEqual(caught.exception.status_code, 401)


class GatewayLegacyTokenCompareTest(unittest.TestCase):
    def test_non_ascii_legacy_token_compares_without_500(self) -> None:
        with patch.dict(
            os.environ,
            {
                "GATEWAY_AUTH_MODE": "legacy",
                "GATEWAY_API_TOKEN": "令牌-密钥",
            },
        ):
            from gateway.app.auth import GatewayAuthenticator

            auth = GatewayAuthenticator()
            principal = auth.authenticate("Bearer 令牌-密钥")
            self.assertEqual(principal.auth_kind, "legacy")
            with self.assertRaises(HTTPException) as caught:
                auth.authenticate("Bearer 错误令牌")
            self.assertEqual(caught.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main()
