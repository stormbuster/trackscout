#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Merge the TrackScout answers and photos into one view for coding agents.

The Blender-side agent reads the output of this tool instead of juggling
three separate documents. It produces, in the output directory:

  answers_merged.json   one document: every question with its latest
                        answer (or null) and its photos attached, plus
                        photos that belong to no question (unattached)
  answers_summary.md    the same, grouped by place, readable by a person
                        or an agent: bold = a real owner answer,
                        *Don't know* = still open, WRONG LOCATION =
                        the pavement point is wrong (see the comment)

Inputs are local file paths or http(s) URLs - whatever is convenient,
including the reference server's endpoints:

    python3 tools/export_for_agents.py --base http://your-server:8765 \
        --out export/

derives /data/owner_questions.json, /data/owner_answers.json and
/data/owner_photos.json from the base URL. Explicit inputs also work
(and win over --base):

    python3 tools/export_for_agents.py questions.json data/answers.json \
        data/photos.jsonl --out export/

Answers and photos may legitimately be missing: a 404, a missing local
file, or an empty object all mean "there are none yet" and are not
errors (the questions input, however, must be present - a 404 for it
is fatal, because there would be nothing to merge). Corrupt JSON is
always an error.

Photo inputs may be a JSON object (the GET /data/owner_photos.json
shape: a map from photo_id) or a JSONL file (one record per line, like
the reference server's data/photos.jsonl).

Relative paths in the output are resolved so the agent can actually
open them: a questions file that came from a URL gets its relative
images[].src rewritten to GET /qimg/<path>; a photo's `stored` is
rewritten to GET /photo/<path> (or to the absolute local file). The
original values are kept in `src` / `stored` next to the resolved
`src_resolved` / `stored_resolved`.

Python 3.9+ standard library only. Exit status 0 on success.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# The answer strings the app sends for the two special protocol states
# (questions PRD section 3).
DONT_KNOW = "Don't know"
WRONG_LOCATION = "WRONG LOCATION"

OUTPUT_NAMES = ("answers_merged.json", "answers_summary.md")


class ExportError(Exception):
    """A condition that stops the export (bad input, network failure)."""


# ---------------------------------------------------------------------------
# Input loading
# ---------------------------------------------------------------------------


def _is_url(source: str) -> bool:
    return source.startswith(("http://", "https://"))


def _fetch_url(url: str, timeout: float):
    """Fetch a URL and parse it as JSON. 404 or {} -> None (absent)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise ExportError(f"GET {url} failed: HTTP {e.code}") from None
    except (urllib.error.URLError, OSError) as e:
        raise ExportError(f"cannot reach {url}: {e}") from None
    try:
        data = json.loads(body or b"{}")
    except json.JSONDecodeError as e:
        raise ExportError(f"{url} returned invalid JSON: {e}") from None
    return data or None


def _read_local(path: str):
    """Read a local JSON file. Missing file -> None (absent, not an
    error: the reference server's data files appear only after the
    first answer or photo). Returns the parsed object."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise ExportError(f"{path} is not valid JSON: {e}") from None
    except OSError as e:
        raise ExportError(f"cannot read {path}: {e}") from None
    return data or None


def _read_jsonl(path: str):
    """Read a JSONL file (one record per line); torn lines are skipped
    with a notice, the way the reference server replays its logs."""
    records = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    print(f"  notice: {path}:{lineno}: skipping torn line",
                          file=sys.stderr)
                    continue
                if isinstance(rec, dict):
                    records.append(rec)
    except OSError as e:
        raise ExportError(f"cannot read {path}: {e}") from None
    return records


def load_input(source: str, timeout: float, allow_jsonl: bool):
    """Load one input (path or URL). Returns (data, kind) where kind is
    'url' or 'path' and data is the parsed object, a list of records
    (jsonl), or None when absent."""
    if _is_url(source):
        return _fetch_url(source, timeout), "url"
    if allow_jsonl and source.endswith(".jsonl"):
        if os.path.isfile(source):
            return _read_jsonl(source), "path"
        return None, "path"  # absent: the file appears after first use
    return _read_local(source), "path"


def load_questions(source: str, timeout: float) -> tuple:
    data, kind = load_input(source, timeout, allow_jsonl=False)
    if data is None:
        raise ExportError(
            f"questions input {source} is absent (404 or missing file): "
            "there is nothing to merge without the questions document"
        )
    if not isinstance(data, dict) or not isinstance(data.get("questions"), list):
        raise ExportError(f"{source} is not a questions document "
                          "(no 'questions' array)")
    return data, kind


def load_map(source: str, timeout: float, what: str) -> tuple:
    """Load answers or photos, normalising to a map keyed by their id.
    Returns (map, kind)."""
    data, kind = load_input(source, timeout, allow_jsonl=True)
    if data is None:
        return {}, kind
    if isinstance(data, list):
        out = {}
        for rec in data:
            key = rec.get("photo_id") or rec.get("id")
            if isinstance(key, str) and key:
                out[key] = rec
        return out, kind
    if isinstance(data, dict):
        return data, kind
    raise ExportError(f"{source}: {what} is neither a JSON object nor JSONL")


# ---------------------------------------------------------------------------
# Resolving relative paths to absolute locations
# ---------------------------------------------------------------------------


def _quote_path(p: str) -> str:
    return urllib.parse.quote(p, safe="/")


def _base_of_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


def resolve_image_src(src: str, questions_source: str, questions_kind: str,
                      base_url: str) -> str | None:
    """Where a relative image actually lives, or None for absolute URLs."""
    if not src or src.startswith(("http://", "https://")):
        return src or None
    if questions_kind == "url" and base_url:
        return f"{base_url}/qimg/{_quote_path(src)}"
    if questions_kind == "path":
        root = os.path.dirname(os.path.abspath(questions_source))
        return os.path.join(root, src)
    return None


def resolve_stored(stored: str, base_url: str, data_dir: str | None) -> str | None:
    """Where a stored photo actually lives (GET /photo/... or a local path)."""
    if not stored:
        return None
    if base_url:
        return f"{base_url}/photo/{_quote_path(stored)}"
    if data_dir:
        return os.path.join(data_dir, stored)
    return None


def _round5(value: float) -> float:
    """Swift's Geometry.round5: (x * 100000).rounded() / 100000, i.e. half
    away from zero (Python's round() is banker's - do not use it)."""
    scaled = value * 100_000
    if scaled >= 0:
        return math.floor(scaled + 0.5) / 100_000
    return math.ceil(scaled - 0.5) / 100_000


def place_key(lat, lon) -> str | None:
    """The app's place key (Geometry.key): 5-decimal rounded lat/lon,
    ~1 m. Questions at the same rounded point are one place."""
    if not (isinstance(lat, (int, float)) and isinstance(lon, (int, float))
            and isinstance(lat, bool) is False and isinstance(lon, bool) is False
            and math.isfinite(lat) and math.isfinite(lon)):
        return None
    return f"{_round5(float(lat)):.5f},{_round5(float(lon)):.5f}"


# ---------------------------------------------------------------------------
# The merged document
# ---------------------------------------------------------------------------


def build_merged(questions_doc: dict, answers: dict, photos: dict,
                 base_url: str, questions_source: str, questions_kind: str,
                 answers_source: str, photos_source: str,
                 data_dir: str | None) -> dict:
    now = datetime.now().astimezone().isoformat(timespec="seconds")

    question_items = []
    photos_by_question: dict = {}
    unattached = []
    for rec in photos.values():
        if not isinstance(rec, dict):
            continue
        stored = rec.get("stored")
        if isinstance(stored, str) and not stored.startswith(("http://", "https://")):
            rec = dict(rec)
            rec["stored_resolved"] = resolve_stored(stored, base_url, data_dir)
        qid = rec.get("question_id")
        if isinstance(qid, str) and qid:
            photos_by_question.setdefault(qid, []).append(rec)
        else:
            unattached.append(rec)

    for q in questions_doc["questions"]:
        if not isinstance(q, dict):
            continue
        item = dict(q)
        qid = q.get("id")
        answer = answers.get(qid) if isinstance(qid, str) else None
        item["answer"] = answer if isinstance(answer, dict) else None
        item["photos"] = photos_by_question.get(qid, [])
        key = place_key(q.get("lat"), q.get("lon"))
        if key is not None:
            item["place_key"] = key
        item["images"] = _resolve_images(item, base_url, questions_source,
                                         questions_kind)
        question_items.append(item)

    answered = sum(1 for q in question_items if q.get("answer"))
    return {
        "generated": questions_doc.get("generated"),
        "exported_at": now,
        "question_count": len(question_items),
        "answered_count": answered,
        "photo_count": len(photos),
        "unattached_photo_count": len(unattached),
        "source": {
            "questions": questions_source,
            "answers": answers_source,
            "photos": photos_source,
        },
        "questions": question_items,
        "unattached_photos": unattached,
    }


def _resolve_images(question: dict, base_url: str, questions_source: str,
                    questions_kind: str) -> list:
    """The question's images with relative srcs resolved to a fetchable
    location (server /qimg URL or absolute local path)."""
    out = []
    for im in question.get("images", []):
        if not isinstance(im, dict):
            out.append(im)
            continue
        im = dict(im)
        src = im.get("src", "")
        if src and not src.startswith(("http://", "https://")):
            resolved = resolve_image_src(src, questions_source,
                                         questions_kind, base_url)
            if resolved is not None:
                im["src_resolved"] = resolved
        out.append(im)
    return out


# ---------------------------------------------------------------------------
# The Markdown summary
# ---------------------------------------------------------------------------


def _style_answer(answer: dict) -> str:
    text = answer.get("answer", "")
    when = f" ({answer['time']})" if answer.get("time") else ""
    if text == DONT_KNOW:
        styled = f"*{DONT_KNOW}*"
    elif text == WRONG_LOCATION:
        comment = (answer.get("comment") or "").strip()
        suffix = f" — corrected: `{comment}`" if comment else ""
        styled = f"`{WRONG_LOCATION}`{suffix}"
    elif text:
        styled = f"**{text}**"
    else:
        styled = "_(empty)_"
    return f"**A:** {styled}{when}"


def _photo_line(rec: dict) -> str:
    bits = [rec.get("kind", "?"), rec.get("light", "?")]
    taken = rec.get("taken")
    if taken:
        bits.append(taken)
    link = rec.get("stored_resolved")
    label = "photo"
    if link:
        return f"- {label} ({', '.join(b for b in bits if b)}) — [{link}]({link})"
    return f"- {label} ({', '.join(b for b in bits if b)})"


def _group_rank(groups: list | None) -> "Callable[[str], int]":
    """Mirror of PlaceBuilder.groupOrder: a label ranks by its index in the
    document's `groups` array; labels absent from it rank last."""
    rank = {g: i for i, g in enumerate(groups)} if groups else {}
    missing = len(groups) if groups else 0
    return lambda label: rank.get(label, missing)


def _question_sort_key(q: dict, rank) -> tuple:
    """The app's in-place question order (PlaceBuilder.build): group label,
    then page, then order. Labels the `groups` array does not list sort
    after listed ones, alphabetically among themselves."""
    group = q.get("group")
    if not isinstance(group, str) or not group:
        group_key = ("\xff", "")
    else:
        group_key = (rank(group), group.lower())
    return (group_key,
            q.get("page") if isinstance(q.get("page"), (int, float)) else 0,
            q.get("order") if isinstance(q.get("order"), (int, float)) else 0)


def build_markdown(merged: dict, questions_doc: dict) -> str:
    lines = [
        "# TrackScout answers summary",
        "",
        f"Exported {merged['exported_at']} by `tools/export_for_agents.py` "
        f"from {merged['source']['questions']}.",
        "",
        f"{merged['question_count']} questions, {merged['answered_count']} answered, "
        f"{merged['photo_count']} photos"
        + (f" ({merged['unattached_photo_count']} unattached)"
           if merged["unattached_photo_count"] else "")
        + ".",
        "",
        "Places are grouped the way the app's All tab does: questions at the "
        "same point (lat/lon rounded to ~1 m) form one place; a place sits in "
        "the section of the group of its first question.",
        "",
        "How to read this: **bold** is a real answer from the owner and "
        f"overrides your research; *{DONT_KNOW}* means the decision stays "
        f"open; `{WRONG_LOCATION}` means the pavement point is wrong and the "
        "comment carries the corrected coordinates.",
        "",
    ]

    # Group into places the way the app does (PlaceBuilder.build).
    by_place: dict = {}
    for q in merged["questions"]:
        key = q.get("place_key") or "(no coordinates)"
        by_place.setdefault(key, []).append(q)

    groups = questions_doc.get("groups") if isinstance(
        questions_doc.get("groups"), list) else None
    rank = _group_rank(groups)
    for questions in by_place.values():
        questions.sort(key=lambda q: _question_sort_key(q, rank))

    places = []
    for key, questions in by_place.items():
        first = questions[0]
        places.append({
            "key": key,
            "building": first.get("building") or "(unnamed place)",
            "group": first.get("group") or "other",
            "lat": first.get("lat"),
            "lon": first.get("lon"),
            "questions": questions,
        })

    # Sections in group-label order, places alphabetical within a section
    # (AllPlacesView.recompute).
    sections: dict = {}
    for p in places:
        sections.setdefault(p["group"], []).append(p)
    for p in sections.values():
        p.sort(key=lambda x: x["building"].lower())
    ordered = sorted(sections.items(),
                     key=lambda kv: (rank(kv[0]), kv[0].lower()))

    for group, places_ in ordered:
        lines.append(f"## Group: {group}")
        lines.append("")
        for place in places_:
            head = f"### {place['building']}"
            if place["lat"] is not None and place["lon"] is not None \
                    and math.isfinite(place["lat"]) and math.isfinite(place["lon"]):
                head += f" — {place['lat']}, {place['lon']}"
            lines.append(head)
            lines.append("")
            for q in place["questions"]:
                if q.get("context"):
                    lines.append(f"_{q['context']}_")
                lines.append(f"**Q:** {q.get('question', '?')}")
                if q.get("answer"):
                    lines.append(_style_answer(q["answer"]))
                    comment = (q["answer"].get("comment") or "").strip()
                    if comment and q["answer"].get("answer") != WRONG_LOCATION:
                        lines.append(f"  > {comment}")
                else:
                    lines.append("**A:** _(not answered yet)_")
                for rec in q.get("photos", []):
                    lines.append(_photo_line(rec))
                lines.append("")
        lines.append("")

    if merged["unattached_photos"]:
        lines.append("## Unattached photos")
        lines.append("")
        lines.append("Photos with no matching question (capture mode, or the "
                     "question no longer exists). Judge for yourself whether "
                     "they are useful; never invent a question for one.")
        lines.append("")
        for rec in merged["unattached_photos"]:
            lines.append(_photo_line(rec))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------


def _infer_base_url(questions_source: str, questions_kind: str) -> str:
    if questions_kind == "url":
        return _base_of_url(questions_source)
    return ""


def _infer_data_dir(answers_source: str, photos_source: str,
                    answers_kind: str, photos_kind: str,
                    base_url: str) -> str | None:
    """For local inputs with a relative `stored`, the data folder is the
    directory the answers/photos input lives in. For URL inputs the
    resolved path is a URL anyway, so this stays None."""
    if base_url:
        return None
    for source, kind in ((answers_source, answers_kind), (photos_source, photos_kind)):
        if kind == "path" and os.path.isfile(source):
            return os.path.dirname(os.path.abspath(source))
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Merge TrackScout answers and photos into one view for agents.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="examples:\n"
        "  python3 tools/export_for_agents.py --base http://your-server:8765 --out export/\n"
        "  python3 tools/export_for_agents.py my_questions.json data/answers.json data/photos.jsonl\n",
    )
    ap.add_argument("--base",
                    help="base URL of the server (e.g. http://your-server:8765); "
                         "the three /data/ endpoints are derived from it")
    ap.add_argument("inputs", nargs="*",
                    help="questions, then optional answers, then optional photos "
                         "(paths or URLs)")
    ap.add_argument("--out", default=".",
                    help="output directory for answers_merged.json and "
                         "answers_summary.md (default: current directory)")
    ap.add_argument("--timeout", type=float, default=15.0,
                    help="per-request timeout in seconds (default 15)")
    args = ap.parse_args()

    if args.base and args.inputs:
        print("use --base OR explicit inputs, not both", file=sys.stderr)
        return 2

    if args.base:
        base = args.base.rstrip("/")
        questions_src = f"{base}/data/owner_questions.json"
        answers_src = f"{base}/data/owner_answers.json"
        photos_src = f"{base}/data/owner_photos.json"
    else:
        if not args.inputs:
            print("give --base URL or a questions file (see --help)",
                  file=sys.stderr)
            return 2
        questions_src = args.inputs[0]
        answers_src = args.inputs[1] if len(args.inputs) > 1 else ""
        photos_src = args.inputs[2] if len(args.inputs) > 2 else ""
        base = ""

    try:
        questions_doc, q_kind = load_questions(questions_src, args.timeout)
        base_url = _infer_base_url(questions_src, q_kind)
        answers, a_kind = (None, "path")
        if answers_src:
            answers, a_kind = load_map(answers_src, args.timeout, "answers")
        else:
            answers = {}
        photos, p_kind = (None, "path")
        if photos_src:
            photos, p_kind = load_map(photos_src, args.timeout, "photos")
        else:
            photos = {}
        data_dir = _infer_data_dir(answers_src, photos_src, a_kind, p_kind,
                                   base_url)
    except ExportError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    merged = build_merged(questions_doc, answers, photos, base_url,
                          questions_src, q_kind, answers_src, photos_src,
                          data_dir)
    markdown = build_markdown(merged, questions_doc)

    os.makedirs(args.out, exist_ok=True)
    json_path = os.path.join(args.out, OUTPUT_NAMES[0])
    md_path = os.path.join(args.out, OUTPUT_NAMES[1])
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(merged, f, indent=1, ensure_ascii=False)
        f.write("\n")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(markdown)

    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    print(f"  {merged['question_count']} questions, "
          f"{merged['answered_count']} answered, "
          f"{merged['photo_count']} photos"
          + (f" ({merged['unattached_photo_count']} unattached)"
             if merged["unattached_photo_count"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
