import importlib
import json
import os
import tempfile
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


if __name__ == "__main__":
    unittest.main()
