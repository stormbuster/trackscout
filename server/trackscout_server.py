#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""TrackScout reference server.

The single server implementation for TrackScout (photo capture PRD 8.3).
Plain Python 3.9+, standard library only, one file. It implements every
endpoint the app speaks:

    GET  /data/owner_questions.json   the questions file (--questions)
    GET  /data/owner_answers.json     the latest answer per question;
                                      404 while there are none yet
    GET  /data/owner_photos.json      every stored photo, keyed by
                                      photo_id; 404 while there are none
    GET  /data/trackscout.json        optional project settings (name,
                                      alert radius, night window); 404 if
                                      the data folder has no such file
    GET  /qimg/<url-encoded path>     a question image. Only the relative
                                      paths listed in the questions file
                                      are served, resolved against --root
                                      (default: the questions file's own
                                      directory, like any relative link).
    GET  /photo/<url-encoded path>    a stored photo, path relative to the
                                      data folder (photos/<date>/<id>.jpg)
    POST /api/answer                  {"id","answer","comment"}. 200 + the
                                      stored record, or 400 {"error"} for an
                                      unknown id or an empty answer.
                                      Re-POSTing the same id replaces it.
    POST /api/photo                   multipart/form-data with a `meta` part
                                      (JSON) and a `photo` part (JPEG).
                                      200 + {"photo_id","stored","duplicate"}.
                                      Re-POSTing a known photo_id is a no-op
                                      that reports duplicate=true. 400 for
                                      bad meta or a non-JPEG body, 413 over
                                      25 MB.
    OPTIONS anything                  204, for CORS preflight.

State lives in one data folder (--data, default ./data):

    answers.json   the current answer per question (the GET document)
    answers.jsonl  append-only history, one line per POST
    photos.jsonl   one line per stored photo (replayed at start-up)
    photos/<YYYY-MM-DD>/<photo_id>.jpg   the JPEGs, by capture date
    trackscout.json  optional, served at /data/trackscout.json

Safety: it serves only the files it must. There is no directory listing,
and the /qimg and /photo paths are contained in their directories via
realpath (unit-tested in test_trackscout_server.py). There is no
authentication: it is for a home LAN only.

Usage:
    python3 server/trackscout_server.py \
        [--questions examples/demo_questions.json] \
        [--data data] [--root DIR] \
        [--host 0.0.0.0] [--port 8765] [--latency 0.0]

--latency sleeps that many seconds before every response (handy for
exercising the app's 3 s timeout).
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))

# photo PRD 3: the server rejects photo bodies over 25 MB with a 413.
MAX_PHOTO_BYTES = 25 * 1024 * 1024

ANSWERS_FILE = "answers.json"
ANSWERS_LOG = "answers.jsonl"
PHOTOS_FILE = "photos.jsonl"
PHOTOS_DIRNAME = "photos"
SETTINGS_FILE = "trackscout.json"


class ApiError(Exception):
    """A 400-level problem with a request payload."""


def _atomic_write_json(path: str, obj) -> None:
    """Write JSON via a temp file + rename so readers never see a torn file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def _contained(base: str, path: str) -> bool:
    """True if `path` (relative) resolves to a regular file inside `base`.

    This is the path-traversal guard for /qimg and /photo: the candidate
    is resolved with realpath, which collapses `..` segments and symlinks,
    and must stay strictly inside the base directory.
    """
    base_real = os.path.realpath(base)
    candidate = os.path.realpath(os.path.join(base_real, path))
    if not candidate.startswith(base_real + os.sep):
        return False
    return os.path.isfile(candidate)


class ServerState:
    """All mutable state, confined to one data folder.

    Every public method takes the lock; the HTTP handler delegates to it
    from one thread per connection, so a single `threading.Lock` is enough.
    """

    def __init__(self, questions_file: str, data_dir: str,
                 root: str = None):
        self._lock = threading.Lock()
        self.questions_file = os.path.abspath(questions_file)
        self.data_dir = os.path.abspath(data_dir)
        # The base directory for relative images[].src paths. Defaults to the
        # questions file's own directory, like a relative link in a document.
        if root is None:
            root = os.path.dirname(self.questions_file)
        self.images_root = os.path.abspath(root)
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(os.path.join(self.data_dir, PHOTOS_DIRNAME), exist_ok=True)

        with open(questions_file, "rb") as f:
            self._questions_bytes = f.read()
        try:
            questions = json.loads(self._questions_bytes).get("questions", [])
        except json.JSONDecodeError:
            questions = []
        self.questions = questions
        self.question_ids = {q.get("id") for q in questions if q.get("id")}
        # Every *relative* image path the questions file lists. Absolute
        # http(s) URLs are fetched by the app directly and never via /qimg.
        self.qimg_paths = set()
        for q in questions:
            for im in q.get("images", []):
                src = im.get("src", "")
                if src and not src.startswith(("http://", "https://")):
                    self.qimg_paths.add(src)

        self.answers = self._load_json(self._path(ANSWERS_FILE)) or {}
        self.photos = self._load_photos_log(self._path(PHOTOS_FILE))

    # ------------------------------ file layout ----------------------------

    def _path(self, name: str) -> str:
        return os.path.join(self.data_dir, name)

    @staticmethod
    def _load_json(path: str):
        if not os.path.exists(path):
            return None
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return None

    @staticmethod
    def _load_photos_log(path: str) -> dict:
        """Replay photos.jsonl into {photo_id: record}.

        One line per stored photo; a malformed line is skipped, so a torn
        final line (a crash mid-append) never loses the earlier photos.
        """
        photos = {}
        if not os.path.exists(path):
            return photos
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                photo_id = record.get("photo_id")
                if isinstance(photo_id, str) and photo_id:
                    photos[photo_id] = record
        return photos

    # ------------------------------ questions ------------------------------

    def questions_bytes(self) -> bytes:
        return self._questions_bytes

    # ------------------------------- answers -------------------------------

    def answers_doc(self) -> dict:
        with self._lock:
            return dict(self.answers)

    def post_answer(self, payload) -> dict:
        """Validate a POST /api/answer body and store it.

        Raises ApiError for the 400 cases; returns the stored record.
        Re-POSTing the same id replaces the current answer and appends a
        new line to the history log.
        """
        if not isinstance(payload, dict):
            raise ApiError("body must be a JSON object")
        qid = payload.get("id")
        answer = payload.get("answer")
        if not isinstance(qid, str) or qid not in self.question_ids:
            raise ApiError(f"unknown question id: {qid!r}")
        if not isinstance(answer, str) or not answer.strip():
            raise ApiError("answer must not be empty")
        comment = payload.get("comment")
        record = {
            "id": qid,
            "answer": answer,
            "comment": comment if isinstance(comment, str) else "",
            "time": time.strftime("%Y-%m-%d %H:%M"),
        }
        with self._lock:
            self.answers[qid] = record
            _atomic_write_json(self._path(ANSWERS_FILE), self.answers)
            # History: the same record plus a second-precision stamp so two
            # posts in one minute are distinguishable. Never served to the app.
            line = dict(record)
            line["received_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
            with open(self._path(ANSWERS_LOG), "a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
        return record

    # -------------------------------- photos -------------------------------

    def photos_doc(self) -> dict:
        with self._lock:
            return dict(self.photos)

    @staticmethod
    def photo_parts(content_type: str, body: bytes) -> dict:
        """Split a multipart/form-data body into {part name: raw bytes}."""
        # Only the first line: a header value must not carry CRLF.
        header = (content_type or "multipart/form-data").splitlines()[0]
        message = BytesParser(policy=policy.HTTP).parsebytes(
            b"Content-Type: " + header.encode("utf-8") + b"\r\n\r\n" + body
        )
        parts = {}
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if name is None:
                continue
            # get_payload(decode=True) yields the raw part bytes no matter
            # what Content-Type the part declares (get_content() would hand
            # back a parsed dict for the application/json meta part).
            parts[name] = part.get_payload(decode=True) or b""
        return parts

    def post_photo(self, content_type: str, body: bytes) -> tuple:
        """Store an uploaded photo (photo PRD 3).

        Returns (status, payload): 200 + {"photo_id","stored","duplicate"}
        on success; 400 for a bad meta or a non-JPEG body; 413 when the
        whole body is over 25 MB. Re-POSTing a known photo_id stores
        nothing new and reports duplicate=True.
        """
        if len(body) > MAX_PHOTO_BYTES:
            return 413, {"error": "photo body over 25 MB"}
        parts = self.photo_parts(content_type, body)
        if "meta" not in parts or "photo" not in parts:
            return 400, {"error": "missing meta or photo part"}

        try:
            meta = json.loads(parts["meta"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return 400, {"error": "meta is not valid JSON"}
        if not isinstance(meta, dict):
            return 400, {"error": "meta is not a JSON object"}

        photo_id = meta.get("photo_id")
        if not isinstance(photo_id, str) or not photo_id:
            return 400, {"error": "meta.photo_id is required"}
        if not isinstance(meta.get("taken"), str) or not meta["taken"]:
            return 400, {"error": "meta.taken is required"}
        for field, allowed in (
            ("kind", {"storefront", "sign", "facade", "detail", "night_lighting", "other"}),
            ("light", {"day", "dusk", "night"}),
            ("source", {"camera", "import"}),
        ):
            if not isinstance(meta.get(field), str) or meta[field] not in allowed:
                return 400, {
                    "error": "meta.%s must be one of: %s"
                    % (field, ", ".join(sorted(allowed)))
                }
        # The position is optional in the meta (imports without a location)
        # but the app always sends it; check only the types, not the presence.
        for field in ("lat", "lon"):
            value = meta.get(field)
            if value is not None and not isinstance(value, (int, float)):
                return 400, {"error": "meta.%s must be a number" % field}

        jpeg = parts["photo"]
        if len(jpeg) < 2 or jpeg[:3] != b"\xff\xd8\xff" or jpeg[-2:] != b"\xff\xd9":
            return 400, {"error": "photo is not a JPEG"}

        # Capture-mode photos have no question: the app sends question_id
        # (and place_key) present but null, and the record stores that
        # verbatim (the app's PhotoRecord reads null as nil).
        record = {
            "photo_id": photo_id,
            "question_id": meta.get("question_id"),
            "place_key": meta.get("place_key"),
            "kind": meta["kind"],
            "light": meta["light"],
            "taken": meta["taken"],
        }
        # The file is stored under the *taken* date (the date the modellers
        # want it grouped by). Fall back to today for an unparsable taken.
        date_prefix = meta["taken"][:10]
        ok = (
            len(date_prefix) == 10
            and date_prefix[4] == "-"
            and date_prefix[7] == "-"
            and date_prefix[:4].isdigit()
            and date_prefix[5:7].isdigit()
            and date_prefix[8:10].isdigit()
        )
        if not ok:
            date_prefix = time.strftime("%Y-%m-%d")

        with self._lock:
            existing = self.photos.get(photo_id)
            if existing is not None:
                return 200, {
                    "photo_id": photo_id,
                    "stored": existing.get("stored"),
                    "duplicate": True,
                }
            stored = "%s/%s/%s.jpg" % (PHOTOS_DIRNAME, date_prefix, photo_id)
            path = os.path.join(self.data_dir, PHOTOS_DIRNAME, date_prefix, photo_id + ".jpg")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(jpeg)
            record["stored"] = stored
            self.photos[photo_id] = record
            with open(self._path(PHOTOS_FILE), "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            return 200, {"photo_id": photo_id, "stored": stored, "duplicate": False}

    def photo_bytes(self, stored: str):
        """The JPEG for a stored path, or None. `stored` is data-folder-relative."""
        path = os.path.join(self.data_dir, stored)
        if not _contained(self.data_dir, stored):
            return None
        try:
            with open(path, "rb") as f:
                return f.read()
        except OSError:
            return None

    # --------------------------- question images ---------------------------

    def qimg_bytes(self, src: str):
        """The file for a relative images[].src, or None.

        Two gates: the path must be listed in the questions file, and it
        must resolve inside the images root (the questions file's directory
        by default). Unlisted or escaping paths 404.
        """
        if src not in self.qimg_paths:
            return None
        if not _contained(self.images_root, src):
            return None
        try:
            with open(os.path.join(self.images_root, src), "rb") as f:
                return f.read()
        except OSError:
            return None

    # ---------------------------- project settings -------------------------

    def settings_doc(self):
        """The optional trackscout.json from the data folder, or None (404)."""
        return self._load_json(self._path(SETTINGS_FILE))


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


def _image_content_type(path: str) -> str:
    lowered = path.lower()
    if lowered.endswith((".jpg", ".jpeg")):
        return "image/jpeg"
    if lowered.endswith(".webp"):
        return "image/webp"
    return "image/png"


class Handler(BaseHTTPRequestHandler):
    server_version = "TrackScoutServer/1.0"
    protocol_version = "HTTP/1.1"

    # Set on the server instance by main().
    state: ServerState | None = None
    latency: float = 0.0

    def log_message(self, fmt, *args):  # one quiet line per request
        print(f"[trackscout] {self.address_string()} {fmt % args}", flush=True)

    def _reply(self, code: int, body: bytes, content_type: str) -> None:
        if self.latency:
            time.sleep(self.latency)
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._reply(
            code,
            json.dumps(obj, ensure_ascii=False).encode("utf-8"),
            "application/json",
        )

    def do_OPTIONS(self):
        self._reply(204, b"", "text/plain")

    def do_GET(self):
        assert self.state is not None
        path = unquote(self.path.split("?", 1)[0])
        if path == "/healthz":
            self._json(
                200,
                {
                    "ok": True,
                    "questions": len(self.state.questions),
                    "answers": len(self.state.answers_doc()),
                    "photos": len(self.state.photos_doc()),
                },
            )
        elif path == "/data/owner_questions.json":
            self._reply(200, self.state.questions_bytes(), "application/json")
        elif path == "/data/owner_answers.json":
            answers = self.state.answers_doc()
            if not answers:
                self._reply(404, b"{}", "application/json")
            else:
                self._json(200, answers)
        elif path == "/data/owner_photos.json":
            photos = self.state.photos_doc()
            if not photos:
                self._reply(404, b"{}", "application/json")
            else:
                self._json(200, photos)
        elif path == "/data/trackscout.json":
            settings = self.state.settings_doc()
            if settings is None:
                self._json(404, {"error": "no settings file"})
            else:
                self._json(200, settings)
        elif path.startswith("/qimg/"):
            src = path[len("/qimg/"):]
            data = self.state.qimg_bytes(src)
            if data is None:
                self._json(404, {"error": "no such image"})
            else:
                self._reply(200, data, _image_content_type(src))
        elif path.startswith("/photo/"):
            data = self.state.photo_bytes(path[len("/photo/"):])
            if data is None:
                self._json(404, {"error": "no such photo"})
            else:
                self._reply(200, data, "image/jpeg")
        else:
            # No directory listings: anything not explicitly listed 404s.
            self._json(404, {"error": "not found"})

    def do_POST(self):
        assert self.state is not None
        path = self.path.split("?", 1)[0]
        if path == "/api/photo":
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            code, payload = self.state.post_photo(
                self.headers.get("Content-Type") or "multipart/form-data", body
            )
            self._json(code, payload)
            return
        if path != "/api/answer":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "body is not valid JSON"})
            return
        try:
            record = self.state.post_answer(payload)
        except ApiError as e:
            self._json(400, {"error": str(e)})
            return
        self._json(200, record)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="TrackScout reference server (Python 3.9+, stdlib only)"
    )
    ap.add_argument("--host", default="0.0.0.0",
                    help="bind address (default 0.0.0.0, for the home LAN)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--questions",
                    default=os.path.join(HERE, "..", "examples", "demo_questions.json"),
                    help="the questions file to serve (default: examples/demo_questions.json)")
    ap.add_argument("--data", default="data",
                    help="data folder for answers, photos, settings (default: ./data)")
    ap.add_argument("--root", default=None,
                    help="base directory for the relative image paths listed in "
                    "the questions file (default: the questions file's own directory)")
    ap.add_argument("--latency", type=float, default=0.0,
                    help="seconds to sleep before every response")
    args = ap.parse_args()

    questions_file = os.path.abspath(args.questions)
    if not os.path.isfile(questions_file):
        raise SystemExit(f"questions file not found: {questions_file}")

    state = ServerState(questions_file, args.data, root=args.root)

    if args.host in ("0.0.0.0", "::"):
        print("WARNING: listening on the whole network with NO authentication.")
        print("This server has no access control: run it on your home LAN only,")
        print("and stop it when you are done.")
    print(f"TrackScout reference server on http://{args.host}:{args.port}")
    print(f"  questions: {questions_file} ({len(state.questions)} questions)")
    print(f"  images:    {state.images_root} (base for relative image paths)")
    print(f"  data:      {os.path.abspath(args.data)} "
          f"({len(state.answers)} stored answers, {len(state.photos)} stored photos)")
    print("  Ctrl-C to stop")

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    Handler.state = state
    Handler.latency = args.latency
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
