"""Black-box CLI + stdio MCP checks; only disposable, generated projects are used."""

from pathlib import Path
import json
import os
import queue
import subprocess
import tempfile
import threading
import unittest

NEXT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("EXPERT_DESKTOP_BIN", NEXT / "target/debug" / ("expert-desktop.exe" if os.name == "nt" else "expert-desktop")))


class Client:
    def __init__(self, state, workspace):
        self.process = subprocess.Popen(
            [str(BINARY), "--data-dir", str(state), "serve", workspace],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
        )
        self.output = queue.Queue()
        self.sequence = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        initialized = self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "workspace-test", "version": "1"},
        })
        if initialized["protocolVersion"] != "2025-11-25":
            raise AssertionError(initialized)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for line in self.process.stdout:
            self.output.put(json.loads(line))
        self.output.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        current = self.sequence
        self.send({"jsonrpc": "2.0", "id": current, "method": method, "params": params})
        while True:
            result = self.output.get(timeout=15)
            if result is None:
                raise AssertionError("MCP connection closed unexpectedly")
            if result.get("id") == current:
                if "error" in result:
                    raise AssertionError(result["error"])
                return result["result"]

    def tool(self, name, **arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()


def text_result(result):
    if result.get("isError"):
        raise AssertionError(result)
    return json.loads(result["content"][0]["text"])


class WorkspaceIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.project = self.root / "project"
        (self.project / "src").mkdir(parents=True)
        (self.project / "src/calc.py").write_text("def add(a, b):\n    return a - b\n", encoding="utf-8")
        self.cli("workspace", "add", "example", "--name", "测试项目", "--path", str(self.project))

    def cli(self, *args):
        result = subprocess.run([str(BINARY), "--data-dir", str(self.state), *args],
                                capture_output=True, text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def client(self):
        client = Client(self.state, "example")
        self.addCleanup(client.close)
        return client

    def test_real_edit_and_live_permission_revocation(self):
        client = self.client()
        original = text_result(client.tool("coding_read_file", scope="root", path="src/calc.py"))
        fixed = "def add(a, b):\n    return a + b\n"
        denied = client.tool("coding_write_file", scope="root", path="src/calc.py",
                             content=fixed, expected_sha256=original["sha256"])
        self.assertTrue(denied["isError"])
        self.cli("scope", "set", "example", "source", "--path", str(self.project / "src"), "--access", "read-write")
        edited = text_result(client.tool("coding_write_file", scope="root", path="src/calc.py",
                                         content=fixed, expected_sha256=original["sha256"]))
        self.assertNotEqual(edited["sha256"], original["sha256"])
        self.assertEqual((self.project / "src/calc.py").read_text(encoding="utf-8"), fixed)
        # Execute only this fixed test-owned fixture in the test harness.
        # This does not expose command execution through the desktop MCP server.
        namespace = {}
        exec(compile(fixed, "calc.py", "exec"), namespace)
        self.assertEqual(namespace["add"](2, 3), 5)
        self.cli("scope", "set", "example", "source", "--path", str(self.project / "src"), "--access", "read-only")
        denied = client.tool("coding_write_file", scope="root", path="src/calc.py",
                             content="should not write", expected_sha256=edited["sha256"])
        self.assertTrue(denied["isError"])
        self.assertEqual((self.project / "src/calc.py").read_text(encoding="utf-8"), fixed)

    def test_server_exposes_no_permission_or_process_tools(self):
        client = self.client()
        names = {t["name"] for t in client.request("tools/list", {})["tools"]}
        self.assertEqual(names, {"coding_workspace_info", "coding_list_directory", "coding_read_file",
                                 "coding_write_file", "coding_create_directory"})
        info = text_result(client.tool("coding_workspace_info"))
        self.assertEqual(info["workspace"]["id"], "example")
        self.assertEqual(info["commands"], "disabled")
        self.assertEqual(info["policy_changes"], "local_cli_only")

    def test_rpc_traversal_and_denied_child_cannot_read_external_content(self):
        client = self.client()
        (self.root / "outside.txt").write_text("not granted", encoding="utf-8")
        for path in ["../outside.txt", str(self.root / "outside.txt"), "src/calc.py:secret"]:
            with self.subTest(path=path):
                self.assertTrue(client.tool("coding_read_file", scope="root", path=path)["isError"])
        self.cli("scope", "set", "example", "source", "--path", str(self.project / "src"), "--access", "deny")
        self.assertTrue(client.tool("coding_read_file", scope="root", path="src/calc.py")["isError"])
        listing = text_result(client.tool("coding_list_directory", scope="root", path="."))
        self.assertNotIn("src", [entry["name"] for entry in listing["entries"]])

    def test_removal_revokes_existing_connection_without_deleting_files(self):
        client = self.client()
        self.cli("workspace", "remove", "example")
        self.assertTrue(client.tool("coding_read_file", scope="root", path="src/calc.py")["isError"])
        self.assertTrue((self.project / "src/calc.py").is_file())


if __name__ == "__main__":
    if not BINARY.is_file():
        raise SystemExit("Build first: cargo build --manifest-path next/Cargo.toml --locked")
    unittest.main(verbosity=2)
