#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-test for `tools/validate_questions.py` (acceptance, photo PRD 8.6).

Runs the validator as a subprocess - the same way agents run it - and
checks:

  * `examples/demo_questions.json` passes (exit 0, "OK - valid");
  * a document whose first question is missing its `id` fails;
  * a document whose first question has a type outside the enum fails;
  * a document whose first question has an out-of-range latitude fails.

The three broken documents are built from the example, so the only
difference between a passing and a failing case is the break itself.
Standard library only; nothing to install.

Usage:
    python3 tools/test_validate_questions.py
"""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
SCRIPT = HERE / "validate_questions.py"
EXAMPLE = REPO_ROOT / "examples" / "demo_questions.json"


def _run_validator(doc: dict) -> tuple[int, str]:
    """Write `doc` to a scratch file, run the validator CLI on it, and
    return (exit code, combined output)."""
    with tempfile.TemporaryDirectory(prefix="trackscout-validate-") as tmp:
        path = Path(tmp) / "questions.json"
        path.write_text(json.dumps(doc), encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(path)],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
        )
        return proc.returncode, proc.stdout + proc.stderr


def _broken_case(mutate) -> tuple[int, str]:
    """The example document with `mutate` applied to its first question."""
    doc = copy.deepcopy(json.loads(EXAMPLE.read_text(encoding="utf-8")))
    mutate(doc["questions"][0])
    return _run_validator(doc)


class ValidateQuestionsTests(unittest.TestCase):
    def test_example_passes(self):
        doc = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        code, out = _run_validator(doc)
        self.assertEqual(code, 0, out)
        self.assertIn("OK - valid", out)

    def test_missing_id_fails(self):
        code, out = _broken_case(lambda q: q.pop("id"))
        self.assertEqual(code, 1, out)
        self.assertIn("missing required property 'id'", out)
        self.assertIn("questions[0]", out)

    def test_bad_type_fails(self):
        code, out = _broken_case(lambda q: q.update(type="checkbox"))
        self.assertEqual(code, 1, out)
        self.assertIn("'checkbox' is not one of", out)

    def test_bad_lat_fails(self):
        code, out = _broken_case(lambda q: q.update(lat=148.870671))
        self.assertEqual(code, 1, out)
        self.assertIn("is greater than 90", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
