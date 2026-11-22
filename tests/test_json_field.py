"""Tests for scripts/json_field.py. Run: python3 -m unittest discover -s tests -v"""

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "json_field.py"
spec = importlib.util.spec_from_file_location("json_field", SCRIPT)
json_field = importlib.util.module_from_spec(spec)
spec.loader.exec_module(json_field)


def run_main(envelope):
    """Write an envelope to a temp file, run main(), return (exit code, stdout)."""
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "out.json"
        path.write_text(json.dumps(envelope), encoding="utf-8")
        out = io.StringIO()
        with mock.patch("sys.argv", ["json_field.py", str(path)]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = json_field.main()
    return code, out.getvalue()


class JsonFieldTest(unittest.TestCase):
    def test_reads_object_from_reply(self):
        code, out = run_main({"result": '{"verdict":"PROCEED","risk":"low"}', "total_cost_usd": 0.01})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"verdict": "PROCEED", "risk": "low"})

    def test_reads_object_surrounded_by_prose(self):
        reply = 'Here is my answer: {"verdict":"REJECT","risk":"high"} Thanks.'
        code, out = run_main({"result": reply})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["verdict"], "REJECT")

    def test_error_envelope_fails(self):
        code, out = run_main({"is_error": True, "result": '{"verdict":"PROCEED"}'})
        self.assertEqual(code, 1)
        self.assertEqual(out, "")

    def test_reply_without_braces_fails(self):
        code, _ = run_main({"result": "PROCEED"})
        self.assertEqual(code, 1)

    def test_malformed_json_fails(self):
        code, _ = run_main({"result": '{"verdict": PROCEED}'})
        self.assertEqual(code, 1)

    def test_null_result_fails(self):
        code, _ = run_main({"result": None})
        self.assertEqual(code, 1)

    def test_missing_result_fails(self):
        code, _ = run_main({})
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
