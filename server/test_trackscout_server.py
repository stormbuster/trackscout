#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for the TrackScout reference server (photo capture PRD 8.3).

Runs the real server (trackscout_server.py) on 127.0.0.1 on an ephemeral
port, in a thread, and exercises every endpoint over HTTP with urllib —
including the safety cases the PRD calls out:

  * no directory listing (anything unlisted 404s),
  * no path traversal on /photo and /qimg (realpath containment),
  * unlisted question images are never served,
  * restart replay of the append-only logs (a torn line is skipped),
  * answers/photos 404 while empty, 200 after the first POST,
  * photo dedupe on photo_id, JPEG-only bodies, the 25 MB limit,
  * the optional /data/trackscout.json.

Run:  python3 server/test_trackscout_server.py
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib import request as urlrequest
from urllib.error import HTTPError

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trackscout_server as server  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# 1x1 black PNG and 1x1 JPEG (smallest real encodings; the JPEG magic
# bytes are what the server checks).
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
    "AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)
JPEG_1X1 = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8U"
    "HRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA"
    "/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEA"
    "AD8AVN//2Q=="
)
assert JPEG_1X1[:3] == b"\xff\xd8\xff" and JPEG_1X1[-2:] == b"\xff\xd9"


def questions_doc() -> dict:
    """The test questions file: three questions, one with a listed
    relative image, one with an absolute URL (never via /qimg) and one
    with a listed path that tries to escape above the site folder (the
    images root)."""
    return {
        "generated": "2026-11-01",
        "questions": [
            {
                "id": "q1", "page": 1, "order": 1, "group": "main",
                "building": "Test Building One", "lat": 1.0, "lon": 2.0,
                "context": "ctx one", "question": "Q1?", "type": "yesno",
                "options": [],
                "images": [{"src": "images/q1.png", "alt": "a"}],
            },
            {
                "id": "q2", "page": 1, "order": 2, "group": "main",
                "building": "Test Building Two", "lat": 1.1, "lon": 2.1,
                "context": "ctx two", "question": "Q2?", "type": "text",
                "options": [],
                "images": [
                    {"src": "https://example.com/external.png", "alt": "b"},
                    {"src": "../outside.txt", "alt": "c"},
                ],
            },
            {
                "id": "q3", "page": 1, "order": 3, "group": "main",
                "building": "Test Building Three", "lat": 1.2, "lon": 2.2,
                "context": "ctx three", "question": "Q3?", "type": "text",
                "options": [], "images": [],
            },
        ],
    }


def build_world(tmp: str):
    """A fresh site folder, data dir, and live server under `tmp`, on an
    ephemeral port bound to 127.0.0.1.

    The questions file lives in `tmp/site/`, which is the images root:
    relative `images[].src` paths resolve against it (the server default).
    `tmp/outside.txt` sits ABOVE that root, as the target of the listed
    escape path.

    Returns (httpd, state, base_url, tmp).
    """
    site = os.path.join(tmp, "site")
    images = os.path.join(site, "images")
    os.makedirs(images, exist_ok=True)
    with open(os.path.join(site, "questions.json"), "w", encoding="utf-8") as f:
        json.dump(questions_doc(), f)

    with open(os.path.join(images, "q1.png"), "wb") as f:
        f.write(PNG_1X1)
    # Present on disk (inside the root) but NOT listed in the questions file.
    with open(os.path.join(images, "secret.png"), "wb") as f:
        f.write(PNG_1X1 + b"extra")
    # Above the images root: the target of the listed escape path ../outside.txt.
    with open(os.path.join(tmp, "outside.txt"), "w", encoding="utf-8") as f:
        f.write("outside")

    state = server.ServerState(os.path.join(site, "questions.json"),
                               os.path.join(tmp, "data"))
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
    server.Handler.state = state
    server.Handler.latency = 0.0
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % httpd.server_address[1]
    return httpd, state, base, tmp


class WorldTestCase(unittest.TestCase):
    """Base: one world (fresh data dir + live server) per test, so no test
    sees the writes of another."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="trackscout-server-test-")
        self.httpd, self.state, self.base, _ = build_world(self.tmp)

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        server.Handler.state = None
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ------------------------------ helpers -------------------------------

    def http(self, method: str, path: str, body: bytes = None,
             content_type: str = None):
        url = self.base + path
        req = urlrequest.Request(url, data=body, method=method)
        if content_type is not None:
            req.add_header("Content-Type", content_type)
        try:
            with urlrequest.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def get(self, path: str):
        return self.http("GET", path)

    def post_json(self, path: str, obj, raw: bytes = None):
        body = raw if raw is not None else json.dumps(obj).encode("utf-8")
        return self.http("POST", path, body, "application/json")

    def post_photo(self, meta: dict, photo: bytes,
                   omit: tuple = (), include_photo: bool = True):
        """Assemble the same multipart layout the app sends and POST it:
        one CRLF after each payload, then the boundary line (the
        PhotoMultipart shape, CRLF line endings, `--boundary--` terminator)."""
        boundary = "----TrackScoutTestBoundary1234567890abcdef"
        chunks = []
        if "meta" not in omit:
            chunks.append(
                b'Content-Disposition: form-data; name="meta"\r\n'
                b"Content-Type: application/json\r\n\r\n"
                + json.dumps(meta).encode("utf-8")
            )
        if include_photo and "photo" not in omit:
            chunks.append(
                b'Content-Disposition: form-data; name="photo"; '
                b'filename="photo.jpg"\r\n'
                b"Content-Type: image/jpeg\r\n\r\n" + photo
            )
        body = b""
        for chunk in chunks:
            body += b"--" + boundary.encode() + b"\r\n" + chunk + b"\r\n"
        body += b"--" + boundary.encode() + b"--\r\n"
        return self.http(
            "POST", "/api/photo", body,
            "multipart/form-data; boundary=" + boundary,
        )

    @staticmethod
    def meta(photo_id: str = "ph-1", **overrides) -> dict:
        m = {
            "photo_id": photo_id,
            "question_id": "q1",
            "place_key": "1.0,2.0",
            "building": "Test Building One",
            "kind": "storefront",
            "light": "day",
            "taken": "2026-11-01T10:00:00+01:00",
            "lat": 1.0,
            "lon": 2.0,
            "source": "camera",
        }
        m.update(overrides)
        return m

    def read(self, *rel: str) -> bytes:
        with open(os.path.join(self.tmp, *rel), "rb") as f:
            return f.read()

    def read_json(self, *rel: str):
        return json.loads(self.read(*rel).decode("utf-8"))

    def count_lines(self, *rel: str) -> int:
        try:
            return len([l for l in self.read(*rel).decode("utf-8").splitlines() if l.strip()])
        except FileNotFoundError:
            return 0

    def data_dir(self) -> str:
        return os.path.join(self.tmp, "data")


# ---------------------------------------------------------------------------
# Fresh server: the empty states
# ---------------------------------------------------------------------------


class TestFresh(WorldTestCase):
    def test_questions_served_verbatim(self):
        status, body, headers = self.get("/data/owner_questions.json")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "application/json")
        self.assertEqual(body, self.read("site", "questions.json"))
        self.assertEqual(len(json.loads(body)["questions"]), 3)

    def test_answers_404_when_empty(self):
        status, body, _ = self.get("/data/owner_answers.json")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"{}")

    def test_photos_404_when_empty(self):
        status, body, _ = self.get("/data/owner_photos.json")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"{}")

    def test_settings_404_when_absent(self):
        status, body, _ = self.get("/data/trackscout.json")
        self.assertEqual(status, 404)
        self.assertIn("error", json.loads(body))

    def test_healthz(self):
        status, body, _ = self.get("/healthz")
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertTrue(doc["ok"])
        self.assertEqual(doc["questions"], 3)
        self.assertEqual(doc["answers"], 0)
        self.assertEqual(doc["photos"], 0)

    def test_options_preflight(self):
        status, _, headers = self.http("OPTIONS", "/api/answer")
        self.assertEqual(status, 204)
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")

    def test_no_directory_listing(self):
        for path in ("/", "/data", "/data/", "/photos", "/photos/",
                     "/nope", "/api", "/qimg"):
            status, body, headers = self.get(path)
            self.assertEqual(status, 404, path)
            self.assertEqual(headers.get("Content-Type"), "application/json")
            json.loads(body)  # a JSON error, never an HTML listing


# ---------------------------------------------------------------------------
# Answers
# ---------------------------------------------------------------------------


class TestAnswers(WorldTestCase):
    def test_post_and_get(self):
        status, body, _ = self.post_json(
            "/api/answer", {"id": "q1", "answer": "Yes", "comment": "sure"})
        self.assertEqual(status, 200)
        record = json.loads(body)
        self.assertEqual(record["id"], "q1")
        self.assertEqual(record["answer"], "Yes")
        self.assertEqual(record["comment"], "sure")
        self.assertRegex(record["time"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")

        status, body, _ = self.get("/data/owner_answers.json")
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertEqual(doc["q1"]["answer"], "Yes")
        self.assertEqual(self.count_lines("data", "answers.jsonl"), 1)
        self.assertEqual(self.read_json("data", "answers.json")["q1"]["answer"], "Yes")

    def test_repost_replaces_and_logs(self):
        self.post_json("/api/answer", {"id": "q2", "answer": "first"})
        status, body, _ = self.post_json(
            "/api/answer", {"id": "q2", "answer": "second"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["answer"], "second")

        status, body, _ = self.get("/data/owner_answers.json")
        doc = json.loads(body)
        self.assertEqual(list(doc), ["q2"])  # one key: replaced, not duplicated
        self.assertEqual(doc["q2"]["answer"], "second")

        # History keeps both posts; the extra field is the second stamp.
        lines = [json.loads(l) for l in
                 self.read("data", "answers.jsonl").decode().splitlines() if l.strip()]
        self.assertEqual(len(lines), 2)
        self.assertRegex(lines[1]["received_at"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")

    def test_unknown_id_rejected(self):
        status, body, _ = self.post_json("/api/answer", {"id": "nope", "answer": "x"})
        self.assertEqual(status, 400)
        self.assertIn("unknown question id", json.loads(body)["error"])

    def test_empty_answer_rejected(self):
        status, body, _ = self.post_json("/api/answer", {"id": "q1", "answer": "   "})
        self.assertEqual(status, 400)
        self.assertIn("empty", json.loads(body)["error"])

    def test_not_json_rejected(self):
        status, body, _ = self.post_json("/api/answer", None, raw=b"not json {")
        self.assertEqual(status, 400)
        self.assertIn("not valid JSON", json.loads(body)["error"])

    def test_non_object_rejected(self):
        status, body, _ = self.post_json("/api/answer", None, raw=b'["q1"]')
        self.assertEqual(status, 400)


# ---------------------------------------------------------------------------
# Photos
# ---------------------------------------------------------------------------


class TestPhotos(WorldTestCase):
    def test_upload(self):
        status, body, _ = self.post_photo(self.meta(), JPEG_1X1)
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertEqual(doc["photo_id"], "ph-1")
        self.assertEqual(doc["stored"], "photos/2026-11-01/ph-1.jpg")
        self.assertFalse(doc["duplicate"])

        # The file is stored under the capture date with the exact bytes.
        self.assertEqual(self.read("data", "photos", "2026-11-01", "ph-1.jpg"), JPEG_1X1)
        self.assertEqual(self.count_lines("data", "photos.jsonl"), 1)

        # The list document carries the full record.
        status, body, _ = self.get("/data/owner_photos.json")
        self.assertEqual(status, 200)
        record = json.loads(body)["ph-1"]
        self.assertEqual(
            record,
            {"photo_id": "ph-1", "question_id": "q1", "place_key": "1.0,2.0",
             "kind": "storefront", "light": "day",
             "taken": "2026-11-01T10:00:00+01:00",
             "stored": "photos/2026-11-01/ph-1.jpg"},
        )

        # Fetchable through /photo, encoded or not.
        status, body, headers = self.get("/photo/photos/2026-11-01/ph-1.jpg")
        self.assertEqual(status, 200)
        self.assertEqual(body, JPEG_1X1)
        self.assertEqual(headers.get("Content-Type"), "image/jpeg")
        status, body, _ = self.get("/photo/photos%2F2026-11-01%2Fph-1.jpg")
        self.assertEqual(status, 200)
        self.assertEqual(body, JPEG_1X1)

    def test_capture_mode_nulls_stored_verbatim(self):
        meta = self.meta(photo_id="ph-2")
        meta["question_id"] = None
        meta["place_key"] = None
        status, body, _ = self.post_photo(meta, JPEG_1X1)
        self.assertEqual(status, 200)
        status, body, _ = self.get("/data/owner_photos.json")
        record = json.loads(body)["ph-2"]
        self.assertIsNone(record["question_id"])
        self.assertIsNone(record["place_key"])

    def test_duplicate_is_noop(self):
        self.post_photo(self.meta(), JPEG_1X1)
        status, body, _ = self.post_photo(self.meta(), JPEG_1X1)  # same photo_id
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertTrue(doc["duplicate"])
        self.assertEqual(doc["stored"], "photos/2026-11-01/ph-1.jpg")
        # Nothing new was written.
        self.assertEqual(self.count_lines("data", "photos.jsonl"), 1)

    def test_meta_validation(self):
        cases = [
            ({k: v for k, v in self.meta().items() if k != "photo_id"}, "photo_id"),
            (self.meta(taken=None), "taken"),
            (self.meta(kind="nope"), "kind"),
            (self.meta(light="midnight"), "light"),
            (self.meta(source="gallery"), "source"),
            (self.meta(lat="here"), "lat"),
        ]
        for meta, field in cases:
            status, body, _ = self.post_photo(meta, JPEG_1X1)
            self.assertEqual(status, 400, meta)
            self.assertIn(field, json.loads(body)["error"])

    def test_missing_parts_rejected(self):
        status, body, _ = self.post_photo(self.meta(), JPEG_1X1, omit=("photo",))
        self.assertEqual(status, 400)
        self.assertIn("missing", json.loads(body)["error"])

    def test_bad_meta_json_rejected(self):
        boundary = "----TrackScoutTestBoundary1234567890abcdef"
        body = (
            b"--" + boundary.encode() + b"\r\n"
            b'Content-Disposition: form-data; name="meta"\r\n'
            b"Content-Type: application/json\r\n\r\n"
            b"not json{\r\n"
            b"--" + boundary.encode() + b"\r\n"
            b'Content-Disposition: form-data; name="photo"; filename="x.jpg"\r\n'
            b"Content-Type: image/jpeg\r\n\r\n" + JPEG_1X1 + b"\r\n"
            b"--" + boundary.encode() + b"--\r\n"
        )
        status, payload, _ = self.http(
            "POST", "/api/photo", body,
            "multipart/form-data; boundary=" + boundary)
        self.assertEqual(status, 400)
        self.assertIn("JSON", json.loads(payload)["error"])
        self.assertNotIn("ph-1", self.state.photos_doc())

    def test_non_jpeg_rejected(self):
        status, body, _ = self.post_photo(self.meta(), PNG_1X1)
        self.assertEqual(status, 400)
        self.assertIn("JPEG", json.loads(body)["error"])

    def test_oversized_rejected(self):
        huge = b"\xff\xd8\xff" + b"\x00" * (server.MAX_PHOTO_BYTES + 64) + b"\xff\xd9"
        status, body, _ = self.post_photo(self.meta(photo_id="ph-big"), huge)
        self.assertEqual(status, 413)
        self.assertNotIn("ph-big", self.state.photos_doc())

    def test_photo_traversal(self):
        self.post_photo(self.meta(), JPEG_1X1)
        for path in (
            "/photo/..%2f..%2fanswers.json",
            "/photo/%2e%2e%2f%2e%2e%2fanswers.json",
            "/photo/photos",                      # a directory, never a file
            "/photo/photos/2026-11-01/..%2f..%2fanswers.json",
        ):
            status, _, _ = self.get(path)
            self.assertEqual(status, 404, path)

    def test_photo_unknown_404(self):
        status, _, _ = self.get("/photo/photos/2099-01-01/nope.jpg")
        self.assertEqual(status, 404)


# ---------------------------------------------------------------------------
# Question images (/qimg)
# ---------------------------------------------------------------------------


class TestQuestionImages(WorldTestCase):
    def test_listed_and_contained_served(self):
        status, body, headers = self.get("/qimg/images/q1.png")
        self.assertEqual(status, 200)
        self.assertEqual(body, PNG_1X1)
        self.assertEqual(headers.get("Content-Type"), "image/png")

    def test_unlisted_never_served(self):
        status, _, _ = self.get("/qimg/images/secret.png")
        self.assertEqual(status, 404)

    def test_absolute_url_not_via_qimg(self):
        status, _, _ = self.get("/qimg/https%3A%2F%2Fexample.com%2Fexternal.png")
        self.assertEqual(status, 404)

    def test_listed_but_escaping_rejected(self):
        # Listed in the questions file, but it resolves above the images
        # root: the containment gate must reject it even though the file
        # exists on disk.
        status, _, _ = self.get("/qimg/..%2Foutside.txt")
        self.assertEqual(status, 404)

    def test_unlisted_escaping_rejected(self):
        status, _, _ = self.get("/qimg/..%2f..%2foutside.txt")
        self.assertEqual(status, 404)

    def test_listed_but_missing_on_disk(self):
        status, _, _ = self.get("/qimg/images/never-written.png")
        self.assertEqual(status, 404)


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------


class TestSettings(WorldTestCase):
    def test_absent_then_present(self):
        status, _, _ = self.get("/data/trackscout.json")
        self.assertEqual(status, 404)

        settings = {
            "name": "Demo Project",
            "alert_radius_meters": 250,
            "night_window": {"start_offset_minutes": 30, "end_hour": 23.5},
        }
        path = os.path.join(self.data_dir(), "trackscout.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(settings, f)

        status, body, _ = self.get("/data/trackscout.json")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), settings)


# ---------------------------------------------------------------------------
# Restart replay (append-only logs)
# ---------------------------------------------------------------------------


class TestReplay(unittest.TestCase):
    """Unit-level: a fresh ServerState on a pre-existing data folder
    rebuilds its state from the logs, skipping torn lines."""

    def _world(self, tmp: str) -> server.ServerState:
        with open(os.path.join(tmp, "questions.json"), "w", encoding="utf-8") as f:
            json.dump(questions_doc(), f)
        os.makedirs(os.path.join(tmp, "images"), exist_ok=True)
        return server.ServerState(os.path.join(tmp, "questions.json"),
                                  os.path.join(tmp, "data"))

    def test_photos_replayed_torn_line_skipped(self):
        tmp = tempfile.mkdtemp(prefix="trackscout-replay-")
        try:
            state = self._world(tmp)
            photos = os.path.join(tmp, "data", "photos")
            os.makedirs(os.path.join(photos, "2026-10-30"), exist_ok=True)
            with open(os.path.join(photos, "2026-10-30", "a.jpg"), "wb") as f:
                f.write(JPEG_1X1)

            lines = [
                json.dumps({"photo_id": "a", "question_id": "q1",
                            "place_key": None, "kind": "storefront",
                            "light": "day", "taken": "2026-10-30T09:00:00+01:00",
                            "stored": "photos/2026-10-30/a.jpg"}),
                "{ this line is torn",  # a crash mid-append
                json.dumps({"photo_id": "b", "question_id": "q2",
                            "place_key": "1.1,2.1", "kind": "sign",
                            "light": "night", "taken": "2026-11-01T22:00:00+01:00",
                            "stored": "photos/2026-10-30/b.jpg"}),
            ]
            with open(os.path.join(tmp, "data", "photos.jsonl"), "w",
                      encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")

            fresh = self._world(tmp)
            self.assertEqual(set(fresh.photos_doc()), {"a", "b"})
            self.assertEqual(fresh.photos_doc()["b"]["question_id"], "q2")

            # The stored paths resolve through the traversal guard.
            self.assertEqual(fresh.photo_bytes("photos/2026-10-30/a.jpg"), JPEG_1X1)
            self.assertIsNone(fresh.photo_bytes("../questions.json"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_answers_json_is_source_of_truth(self):
        tmp = tempfile.mkdtemp(prefix="trackscout-replay-")
        try:
            self._world(tmp)
            with open(os.path.join(tmp, "data", "answers.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"q1": {"id": "q1", "answer": "Yes", "comment": "",
                                   "time": "2026-11-01 10:00"}}, f)
            fresh = self._world(tmp)
            self.assertEqual(fresh.answers_doc()["q1"]["answer"], "Yes")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_torn_answers_json_degrades_to_empty(self):
        tmp = tempfile.mkdtemp(prefix="trackscout-replay-")
        try:
            self._world(tmp)
            with open(os.path.join(tmp, "data", "answers.json"), "w",
                      encoding="utf-8") as f:
                f.write('{"q1": ')  # a torn write
            fresh = self._world(tmp)
            self.assertEqual(fresh.answers_doc(), {})
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
