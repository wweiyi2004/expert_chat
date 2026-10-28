import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from PIL import Image
from pypdf import PdfWriter

WORKER = Path(__file__).with_name("desktop_media_worker.py")


class MediaWorkerTests(unittest.TestCase):
    def request(self, operation, data, **extra):
        with tempfile.TemporaryDirectory(prefix="expert-media-test-") as directory:
            request = Path(directory) / "request.json"
            request.write_text(json.dumps({"op": operation, "data": base64.b64encode(data).decode(), **extra}), encoding="utf-8")
            binary = os.environ.get("EXPERT_TEST_MEDIA_BINARY")
            command = [binary] if binary else [sys.executable, str(WORKER)]
            result = subprocess.run([*command, str(request)], capture_output=True, timeout=25)
            return result.returncode, json.loads(result.stdout)

    def test_resize_keeps_aspect_ratio(self):
        image = Image.new("RGB", (3200, 1600), "blue")
        source = io.BytesIO(); image.save(source, format="PNG")
        code, result = self.request("image_resize", source.getvalue(), max_side=1000)
        self.assertEqual(code, 0); self.assertTrue(result["changed"])
        with Image.open(io.BytesIO(base64.b64decode(result["data"]))) as resized:
            self.assertEqual(resized.size, (1000, 500))

    def test_small_image_preserves_original_bytes(self):
        source = io.BytesIO(); Image.new("RGBA", (16, 8), (0, 0, 0, 0)).save(source, format="PNG")
        code, result = self.request("image_resize", source.getvalue(), max_side=1000)
        self.assertEqual(code, 0); self.assertFalse(result["changed"])

    def test_empty_pdf_is_a_valid_empty_result(self):
        document = PdfWriter(); document.add_blank_page(width=100, height=100)
        source = io.BytesIO(); document.write(source)
        code, result = self.request("pdf_text", source.getvalue())
        self.assertEqual(code, 0); self.assertEqual(result["text"], "")

    def test_parser_failure_never_echoes_input(self):
        code, result = self.request("pdf_text", b"SYNTHETIC_PRIVATE_DOCUMENT")
        self.assertNotEqual(code, 0); self.assertFalse(result["ok"])
        self.assertNotIn("SYNTHETIC_PRIVATE_DOCUMENT", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
