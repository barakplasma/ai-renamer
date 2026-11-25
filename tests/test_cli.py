import base64
from collections import Counter
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/ai-renamer"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR14AAAAASUVORK5CYII="
)


class ModelServer(ThreadingHTTPServer):
    request_queue_size = 128


@contextmanager
def model(answer="Quarterly Report", delay=0, *, model_id="lm-vision"):
    requests = []
    hits = Counter()
    active = peak = 0
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, status=200):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            try:
                self.wfile.write(json.dumps(body).encode())
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            hits[self.path] += 1
            if self.path == "/api/tags":
                self.send({"models": [{"name": "mistral"}, {"name": "llava:latest"}]})
            elif self.path == "/v1/models":
                self.send({"data": [{"id": model_id}]})
            else:
                self.send({}, 404)

        def do_POST(self):
            nonlocal active, peak
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                requests.append((self.path, self.headers.get("Authorization"), body))
                active += 1
                peak = max(peak, active)
            try:
                time.sleep(delay)
                if answer is None:
                    self.send({"error": {"message": "Model unavailable"}}, 503)
                elif self.path == "/api/generate":
                    self.send({"response": answer})
                else:
                    self.send({"choices": [{"message": {"content": answer}}]})
            finally:
                with lock:
                    active -= 1

    with ModelServer(("127.0.0.1", 0), Handler) as server:
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", requests, hits, lambda: peak
        finally:
            server.shutdown()
            server_thread.join()


@contextmanager
def docling(status="success", text="# Quarterly accounts", http_status=200):
    uploads = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            from email import policy
            from email.parser import BytesParser

            raw = self.rfile.read(int(self.headers["Content-Length"]))
            header = f"Content-Type: {self.headers['Content-Type']}\r\n\r\n".encode()
            message = BytesParser(policy=policy.default).parsebytes(header + raw)
            fields = {
                part.get_param("name", header="content-disposition"):
                    (part.get_filename(), part.get_payload(decode=True))
                for part in message.iter_parts()
            }
            uploads.append((self.path, self.headers.get("X-Api-Key"), fields))
            self.send_response(http_status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": status, "document": {"md_content": text}}).encode())

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", uploads
        finally:
            server.shutdown()
            thread.join(timeout=5)


class Renamer(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.files = self.root / "files"
        self.files.mkdir()
        self.env = {**os.environ, "HOME": str(self.home),
                    "XDG_STATE_HOME": str(self.root / "state")}

        self.env.pop("DOCLING_SERVE_URL", None)
        self.env.pop("DOCLING_SERVE_API_KEY", None)

    def run_cli(self, *args, ok=True):
        result = subprocess.run([BINARY, *args, "+RTS", "--threads", "2", "-RTS"],
                                env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_recursive_progress_collision_and_config(self):
        sub = self.files / "sub"
        sub.mkdir()
        (sub / "loop").symlink_to(self.files, target_is_directory=True)
        (self.files / "original.TXT").write_text("root text")
        (sub / "other.txt").write_text("nested text")
        (self.files / "quarterly_report.txt").write_text("existing content")
        (sub / "skip.bin").write_bytes(b"binary")
        (sub / ".DS_Store").touch()
        with model() as (url, requests, hits, _):
            output = self.run_cli(self.files, f"--base-url={url}", "-s", "true",
                                  "--case", "snakeCase", "--custom-prompt=Ignore dates")
            self.assertIn("100% || 4/4 Files || ETA: 0s", output)
            self.assertIn("Processing directory: sub", output)
            self.assertIn("Unsupported file: sub/skip.bin", output)
            self.assertEqual(hits["/api/tags"], 1)
            self.assertTrue(all(body["model"] == "llava:latest" and
                                "Ignore dates" in body["prompt"] for _, _, body in requests))
            self.assertEqual((self.files / "quarterly_report.txt").read_text(), "existing content")
            self.assertEqual((self.files / "quarterly_report1.txt").read_text(), "root text")
            self.assertEqual((sub / "quarterly_report.txt").read_text(), "nested text")
            self.assertEqual(len(requests), 3)
            (self.files / "new.txt").write_text("new")
            self.run_cli(self.files / "new.txt")
            self.assertEqual((self.files / "quarterly_report2.txt").read_text(), "new")

    def test_concurrent_requests_and_unique_names(self):
        for index in range(64):
            (self.files / f"input-{index:02}.txt").write_text(str(index))
        with model("Parallel Result", delay=0.25) as (url, calls, _, peak):
            output = self.run_cli(self.files, "-u", url, "-m", "mock", "--jobs=32")
        self.assertGreaterEqual(peak(), 12)
        self.assertEqual(len(calls), 64)
        self.assertIn("100% || 64/64 Files", output)
        self.assertEqual(len(list(self.files.glob("parallel-result*.txt"))), 64)
        self.assertEqual({f.read_text() for f in self.files.iterdir()}, {str(i) for i in range(64)})
        print(f"Concurrency test peak: {peak()} simultaneous model requests")

    def test_openai_image_and_lm_studio_discovery(self):
        source = self.files / "img.PNG"
        source.write_bytes(PNG)
        with model("Simple Image") as (url, calls, hits, _):
            self.run_cli(source, "-p", "openai", "-u", url + "/v1", "-a", "test-key")
            path, authorization, body = calls[-1]
            self.assertEqual(path, "/v1/chat/completions")
            self.assertEqual(authorization, "Bearer test-key")
            self.assertEqual(body["model"], "gpt-4o")
            self.assertEqual(body["messages"][0]["content"][1]["image_url"]["url"],
                             "data:image/png;base64," + base64.b64encode(PNG).decode())
            self.assertEqual((self.files / "simple-image.png").read_bytes(), PNG)
            self.run_cli(self.files / "simple-image.png", "-p", "lm-studio")
            self.assertEqual(hits["/v1/models"], 1)
            self.assertEqual(calls[-1][2]["model"], "lm-vision")

    def test_local_provider_discovers_model_and_keeps_settings_separate(self):
        first = self.files / "first.txt"
        first.write_text("Quarterly spreadsheet plan")
        saved = self.home / "ai-renamer.json"
        saved.write_text(json.dumps({
            "defaultProvider": "openai",
            "defaultModel": "cloud-model",
            "defaultBaseURL": "https://api.openai.com",
            "defaultApiKey": "cloud-test-key",
        }))
        with model("first renamed<|eot_id|>", model_id="system") as (url, requests, hits, _):
            self.run_cli(first, "--provider=local", "--base-url=" + url + "/v1/")
            self.assertEqual(hits["/v1/models"], 1)
            path, auth, body = requests[0]
            self.assertEqual((path, auth, body["model"]), ("/v1/chat/completions", None, "system"))
            self.assertIn("Quarterly spreadsheet plan", body["messages"][0]["content"])
            self.assertIsInstance(body["messages"][0]["content"], str)
            first = self.files / "first-renamed.txt"
            self.run_cli(first, "--model=custom-local", "--api-key=local-test-key")
            self.assertEqual(requests[1][1], "Bearer local-test-key")
            self.assertEqual(requests[1][2]["model"], "custom-local")
        with model("new endpoint", model_id="llama-file") as (url, requests, hits, _):
            self.run_cli(first, "--base-url=" + url)
            self.assertEqual(hits["/v1/models"], 1)
            self.assertEqual(requests[0][2]["model"], "llama-file")
            self.assertIsNone(requests[0][1])
        self.assertEqual(json.loads(saved.read_text())["defaultApiKey"], "cloud-test-key")


    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is unavailable")
    def test_short_video_sends_frames_and_cleans_up(self):
        source = self.files / "clip.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=s=32x32:d=0.5",
                        "-pix_fmt", "yuv420p", str(source)], check=True, timeout=15)
        self.env["TMPDIR"] = str(self.root)
        with model("Sample Video") as (url, calls, _, _):
            self.run_cli(source, "-u", url, "-m", "vision")
            body = calls[0][2]
        self.assertEqual(len(body["images"]), 1)
        self.assertIn("Analyze these 1 frames", body["prompt"])
        self.assertTrue((self.files / "sample-video.mp4").is_file())
        self.assertEqual(list(self.root.glob("ai-renamer-*")), [])

    @unittest.skipUnless(shutil.which("pdftotext"), "pdftotext is unavailable")
    def test_pdf_is_sent_as_extracted_text(self):
        source = self.files / "document.pdf"
        stream = b"BT /F1 16 Tf 20 55 Td (Quarterly accounts) Tj ET"
        objects = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] "
            b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        ]
        pdf = b"%PDF-1.4\n"
        offsets = []
        for number, body in enumerate(objects, 1):
            offsets.append(len(pdf))
            pdf += b"%d 0 obj\n" % number + body + b"\nendobj\n"
        xref = len(pdf)
        pdf += b"xref\n0 6\n0000000000 65535 f \n"
        pdf += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
        pdf += b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % xref
        source.write_bytes(pdf)
        with model("Annual Accounts") as (url, calls, _, _):
            self.run_cli(source, "-u", url, "-m", "mock")
        self.assertIn("Quarterly accounts", calls[0][2]["prompt"])
        self.assertEqual((self.files / "annual-accounts.pdf").read_bytes(), pdf)

    def test_docling_upload_supplies_extracted_text_to_model_and_rollback(self):
        original = self.files / "2025 accounts.DOCX"
        original.write_bytes(b"opaque office bytes")
        with docling() as (docling_url, uploads), model("New Name") as (url, calls, _, _):
            self.env.update(DOCLING_SERVE_URL=docling_url + "/v1/", DOCLING_SERVE_API_KEY="local-test")
            output = self.run_cli(original, "-u", url, "-m", "mock")
        path, key, fields = uploads[0]
        self.assertEqual((path, key), ("/v1/convert/file", "local-test"))
        self.assertEqual(fields["files"], ("2025 accounts.DOCX", b"opaque office bytes"))
        self.assertEqual(fields["to_formats"][1], b"md")
        self.assertIn("# Quarterly accounts", calls[0][2]["prompt"])
        self.assertNotIn("opaque office bytes", calls[0][2]["prompt"])
        self.assertTrue((self.files / "new-name.docx").is_file())
        run = re.search(r"Run ID: (\S+)", output).group(1)
        self.assertIn("restored 1 file(s)", self.run_cli("--rollback", run))
        self.assertEqual(original.read_bytes(), b"opaque office bytes")

    def test_docling_failures_leave_documents_untouched(self):
        for status, http_status in (("failure", 200), ("failure", 503)):
            with self.subTest(http_status=http_status):
                original = self.files / f"incoming-{http_status}.pdf"
                original.write_bytes(b"PDF fixture")
                with docling(status, "partial content", http_status) as (docling_url, uploads), \
                     model() as (url, calls, _, _):
                    self.env["DOCLING_SERVE_URL"] = docling_url
                    output = self.run_cli(original, "--base-url=" + url, "-m", "mock", ok=False)
                self.assertIn("Docling", output)
                self.assertEqual(len(uploads), 1)
                self.assertEqual(len(calls), 0)
                self.assertEqual(original.read_bytes(), b"PDF fixture")


    def test_empty_directory_reaches_completion(self):
        output = self.run_cli(self.files, "-m", "mock")
        self.assertIn("100% || 0/0 Files || ETA: 0s", output)


    def test_failed_model_leaves_source_intact(self):
        original = self.files / "source.txt"
        original.write_text("Keep this")
        with model(None) as (url, _, _, _):
            output = self.run_cli(original, "-m", "mock", "-u", url, ok=False)
        self.assertIn("Model unavailable", output)
        self.assertIn("1/1 Files", output)
        self.assertEqual(original.read_text(), "Keep this")

    def test_rollback_restores_all_original_names_and_is_repeatable(self):
        expected = {"one.TXT": b"one", "two.txt": b"two"}
        for filename, text in expected.items():
            (self.files / filename).write_bytes(text)
        with model("Same Name") as (url, _, _, _):
            output = self.run_cli(self.files, "-u", url, "-m", "mock")
        run = re.search(r"Run ID: (\S+)", output).group(1)
        self.assertEqual(self.run_cli("--list-runs").strip(), run)
        self.assertIn("restored 2 file(s)", self.run_cli("--rollback", run))
        self.assertIn("restored 0 file(s)", self.run_cli("--rollback", run))
        self.assertEqual({p.name: p.read_bytes() for p in self.files.iterdir()}, expected)

    def test_rollback_conflicts_preserve_both_files(self):
        original = self.files / "original.txt"
        original.write_text("original")
        with model("new name") as (url, _, _, _):
            output = self.run_cli(original, "-u", url, "-m", "mock")
        run = re.search(r"Run ID: (\S+)", output).group(1)
        renamed = self.files / "new-name.txt"
        original.write_text("unrelated replacement")
        self.assertIn("occupied", self.run_cli("--rollback", run, ok=False))
        self.assertEqual(original.read_text(), "unrelated replacement")
        self.assertEqual(renamed.read_text(), "original")
        original.unlink()
        renamed.write_text("edited after rename")
        self.assertIn("changed", self.run_cli("--rollback", run, ok=False))
        self.assertEqual(renamed.read_text(), "edited after rename")
        self.assertFalse(original.exists())

    def test_failed_journal_prevents_renames(self):
        bad_state = Path(self.env["XDG_STATE_HOME"])
        bad_state.write_text("this is a file")
        original = self.files / "original.txt"
        original.write_text("untouched")
        with model() as (url, calls, _, _):
            output = self.run_cli(original, "-u", url, "-m", "mock", ok=False)
        self.assertIn("Cannot start the recovery journal", output)
        self.assertEqual(calls, [])
        self.assertEqual(original.read_text(), "untouched")

    def test_killed_run_is_recoverable_and_active_run_is_locked(self):
        expected = {"first.txt": "first", "second.txt": "second"}
        for filename, content in expected.items():
            (self.files / filename).write_text(content)
        moved = self.files / "new-name.txt"
        with model("new name", delay=1.5) as (url, _, _, _):
            process = subprocess.Popen(
                [BINARY, self.files, "-u", url, "-m", "mock", "-j", "1",
                 "+RTS", "--threads", "2", "-RTS"],
                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 10
                while not moved.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.025)
                self.assertTrue(moved.exists())
                run = self.run_cli("--list-runs").strip()
                self.assertIn("still active", self.run_cli("--rollback", run, ok=False))
            finally:
                process.kill()
                process.communicate(timeout=5)
        self.assertIn("restored 1 file(s)", self.run_cli("--rollback", run))
        self.assertEqual({p.name: p.read_text() for p in self.files.iterdir()}, expected)
        self.assertFalse(moved.exists())

    def test_rollback_ignores_an_incomplete_journal_tail(self):
        original = self.files / "original.txt"
        original.write_text("untouched")
        with model("new name") as (url, _, _, _):
            output = self.run_cli(original, "-u", url, "-m", "mock")
        run = re.search(r"Run ID: (\S+)", output).group(1)
        # Re-create the disk state between a synced intent and its rename.
        (self.files / "new-name.txt").rename(original)
        journal = Path(self.env["XDG_STATE_HOME"]) / "ai-renamer" / (run + ".journal")
        with journal.open("ab") as stream:
            stream.write(b"incomplete journal write")
        self.assertIn("restored 0 file(s)", self.run_cli("--rollback", run))
        self.assertEqual(original.read_text(), "untouched")

    def test_source_replaced_during_inference_is_left_alone(self):
        original = self.files / "original.txt"
        original.write_text("before")
        with model("New Name", delay=1) as (url, calls, _, _):
            process = subprocess.Popen(
                [BINARY, original, "-u", url, "-m", "mock", "+RTS", "--threads", "2", "-RTS"],
                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not calls and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(calls)
                old = self.root / "old.txt"
                original.rename(old)
                original.write_text("replacement")
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 1, stdout + stderr)
                self.assertIn("source changed", stdout + stderr)
                self.assertEqual(old.read_text(), "before")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
        self.assertEqual(original.read_text(), "replacement")
        self.assertFalse((self.files / "new-name.txt").exists())

    def test_without_recursion_only_root_files_are_counted(self):
        sub = self.files / "sub"
        sub.mkdir()
        (sub / "nested.txt").write_text("nested")
        (self.files / "root.txt").write_text("root")
        with model() as (url, calls, _, _):
            output = self.run_cli(self.files, "-u", url, "-m", "mock")
        self.assertEqual(len(calls), 1)
        self.assertIn("100% || 1/1 Files", output)
        self.assertTrue((sub / "nested.txt").exists())
