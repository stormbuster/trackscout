#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate a TrackScout questions file before you publish it.

Checks the file against schemas/questions.schema.json and then applies the
field rules that JSON Schema cannot express:

  * question ids must be unique;
  * `type` and `options` must agree: `choice` has 2-5 options,
    `yesno` and `text` have none;
  * every `group` used by a question should appear in the document's
    `groups` array (warning only: the app still shows it, just
    alphabetically).

Usage:
    python3 tools/validate_questions.py path/to/questions.json
    python3 tools/validate_questions.py path/to/other.json --schema schemas/answers.schema.json

Exit status 0 = valid, 1 = invalid or unreadable. Python 3.9+ standard
library only - agents run this with nothing installed. The built-in
validator understands the keywords the shipped schemas use; documentation
keywords (title, description, examples, ...) are ignored, and any other
unimplemented validation keyword is reported as a warning rather than
skipped silently.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO_ROOT / "schemas" / "questions.schema.json"


class Validator:
    """A small draft-07 validator: exactly the keywords the shipped
    schemas use, no more. Unknown keywords are reported as warnings so a
    future schema extension cannot pass silently."""

    _TYPES = {"string": str, "object": dict, "array": list, "boolean": bool}

    # Documentation-style keywords: they never constrain data, so they are
    # ignored silently. Anything else that is not implemented below gets a
    # warning, so a future schema extension cannot pass silently.
    _NON_VALIDATION = {
        "$schema", "$id", "$comment", "title", "description",
        "default", "examples", "definitions",
    }

    def __init__(self, schema: dict, root: dict):
        self.schema = schema
        self.root = root
        self.errors = []
        self.warnings = []
        self._unknown = set()

    # ------------------------------ public --------------------------------

    def validate(self, value, schema=None, path="$") -> None:
        schema = self.schema if schema is None else schema
        if "$ref" in schema:
            schema = self._resolve(schema["$ref"], path)
            if schema is None:
                return
        for keyword in schema:
            if keyword in ("$ref", *self._NON_VALIDATION):
                continue
            if keyword not in self._KNOWN:
                if keyword not in self._unknown:
                    self._unknown.add(keyword)
                    self.warnings.append(
                        f"{path}: the built-in validator does not implement "
                        f"the schema keyword '{keyword}'; it was skipped "
                        "(pip install jsonschema for full coverage)"
                    )
                continue
            if keyword == "additionalProperties":
                self._additional(value, schema[keyword], schema, path)
            else:
                self._check(value, schema[keyword], keyword, path)

    # ---------------------------- the checks ------------------------------

    def _additional(self, value, spec, schema: dict, path: str) -> None:
        """additionalProperties: False, or a schema for the extras."""
        if not isinstance(value, dict):
            return
        known = set(schema.get("properties", {})) | set(schema.get("patternProperties", {}))
        for key in value:
            if key in known:
                continue
            if spec is False:
                self.errors.append(f"{path}: unexpected property '{key}'")
            elif isinstance(spec, dict):
                self.validate(value[key], spec, f"{path}.{key}")

    def _check(self, value, spec, keyword, path) -> None:
        if keyword == "type":
            types = spec if isinstance(spec, list) else [spec]
            if not any(self._has_type(value, t) for t in types):
                self.errors.append(
                    f"{path}: expected type {' or '.join(types)}, got {self._type_name(value)}"
                )
        elif keyword == "enum":
            if value not in spec:
                self.errors.append(
                    f"{path}: {value!r} is not one of: {', '.join(map(repr, spec))}"
                )
        elif keyword == "required":
            if isinstance(value, dict):
                for key in spec:
                    if key not in value:
                        self.errors.append(f"{path}: missing required property '{key}'")
        elif keyword == "properties":
            if isinstance(value, dict):
                for key, sub in spec.items():
                    if key in value:
                        self.validate(value[key], sub, f"{path}.{key}")
        elif keyword == "items":
            if isinstance(value, list) and isinstance(spec, dict):
                for i, item in enumerate(value):
                    self.validate(item, spec, f"{path}[{i}]")
        elif keyword in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"):
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                if keyword == "minimum" and value < spec:
                    self.errors.append(f"{path}: {value} is less than {spec}")
                elif keyword == "maximum" and value > spec:
                    self.errors.append(f"{path}: {value} is greater than {spec}")
                elif keyword == "exclusiveMinimum" and value <= spec:
                    self.errors.append(f"{path}: {value} is not greater than {spec}")
                elif keyword == "exclusiveMaximum" and value >= spec:
                    self.errors.append(f"{path}: {value} is not less than {spec}")
        elif keyword in ("minLength", "maxLength"):
            if isinstance(value, str):
                if keyword == "minLength" and len(value) < spec:
                    self.errors.append(f"{path}: shorter than {spec} characters")
                elif keyword == "maxLength" and len(value) > spec:
                    self.errors.append(f"{path}: longer than {spec} characters")
        elif keyword in ("minItems", "maxItems"):
            if isinstance(value, list):
                if keyword == "minItems" and len(value) < spec:
                    self.errors.append(f"{path}: has {len(value)} items, wants at least {spec}")
                elif keyword == "maxItems" and len(value) > spec:
                    self.errors.append(f"{path}: has {len(value)} items, wants at most {spec}")
        elif keyword == "pattern":
            if isinstance(value, str) and not re.search(spec, value):
                self.errors.append(f"{path}: does not match pattern {spec}")

    _KNOWN = {
        "type", "enum", "required", "properties", "additionalProperties",
        "patternProperties", "items", "minimum", "maximum",
        "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
        "minItems", "maxItems", "pattern",
    }

    def _has_type(self, value, type_name: str) -> bool:
        if type_name == "integer":
            return isinstance(value, int) and not isinstance(value, bool)
        if type_name == "number":
            return (
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value)
            )
        if type_name == "null":
            return value is None
        return isinstance(value, self._TYPES.get(type_name, ()))

    @staticmethod
    def _type_name(value) -> str:
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, int):
            return "integer"
        if isinstance(value, float):
            return "number"
        if isinstance(value, str):
            return "string"
        if isinstance(value, dict):
            return "object"
        if isinstance(value, list):
            return "array"
        return type(value).__name__

    def _resolve(self, ref: str, path: str) -> dict | None:
        if not ref.startswith("#"):
            self.warnings.append(f"{path}: external $ref {ref!r} is not supported")
            return None
        node = self.root
        for part in ref[1:].split("/"):
            if not part:
                continue
            node = node.get(part) if isinstance(node, dict) else None
            if node is None:
                self.warnings.append(f"{path}: $ref {ref!r} does not resolve")
                return None
        return node if isinstance(node, dict) else None


# ---------------------------------------------------------------------------
# Cross-field field rules (the ones JSON Schema cannot express)
# ---------------------------------------------------------------------------


def field_rules(doc: dict, path: str) -> tuple[list, list]:
    """Cross-field rules for the questions document. Returns (errors, warnings)."""
    errors: list = []
    warnings: list = []
    questions = doc.get("questions")
    if not isinstance(questions, list):
        return errors, warnings  # the schema already complained

    seen = set()
    for i, q in enumerate(questions):
        if not isinstance(q, dict):
            continue
        where = f"{path}.questions[{i}]"
        qid = q.get("id")
        if isinstance(qid, str) and qid:
            if qid in seen:
                errors.append(f"{where}: duplicate question id {qid!r}")
            seen.add(qid)

        qtype = q.get("type")
        options = q.get("options")
        if qtype in ("yesno", "text") and isinstance(options, list) and options:
            errors.append(
                f"{where}: type '{qtype}' must have no options (found {len(options)})"
            )
        elif qtype == "choice":
            count = len(options) if isinstance(options, list) else 0
            if not 2 <= count <= 5:
                errors.append(
                    f"{where}: a 'choice' question needs 2-5 options (found {count})"
                )

        group = q.get("group")
        groups = doc.get("groups")
        if isinstance(group, str) and isinstance(groups, list) and group not in groups:
            warnings.append(
                f"{where}: group {group!r} is not listed in the document's 'groups' "
                f"array; the app will order it alphabetically instead"
            )
    return errors, warnings


# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate a TrackScout questions file (or any file against a schema)."
    )
    ap.add_argument("file", help="the JSON file to validate")
    ap.add_argument(
        "--schema",
        default=str(SCHEMA_PATH),
        help=f"the JSON Schema to validate against (default: {SCHEMA_PATH})",
    )
    args = ap.parse_args()

    try:
        schema = json.loads(Path(args.schema).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read schema {args.schema}: {e}", file=sys.stderr)
        return 1

    try:
        doc = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except OSError as e:
        print(f"cannot read {args.file}: {e}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"{args.file} is not valid JSON: {e}", file=sys.stderr)
        return 1

    v = Validator(schema, schema)
    v.validate(doc)
    if "questions" in schema.get("properties", {}):
        # The questions schema: add the cross-field rules.
        e, w = field_rules(doc, "$")
        v.errors.extend(e)
        v.warnings.extend(w)

    count = len(doc.get("questions")) if isinstance(doc, dict) else None
    header = args.file + (f" ({count} questions)" if count is not None else "")
    print(header)
    for message in v.warnings:
        print(f"  WARNING  {message}")
    for message in v.errors:
        print(f"  ERROR    {message}")
    if v.errors:
        print(f"  {len(v.errors)} error(s), {len(v.warnings)} warning(s)")
        return 1
    print("  OK - valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
