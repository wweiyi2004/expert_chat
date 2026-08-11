import importlib
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient


class GatewayFlowTest(unittest.TestCase):
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
