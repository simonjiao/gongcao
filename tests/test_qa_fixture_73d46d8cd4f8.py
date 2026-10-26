import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_73d46d8cd4f8.py"
SPEC = importlib.util.spec_from_file_location("qa_fixture_73d46d8cd4f8", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ClampScoreTests(unittest.TestCase):
    def test_positive_and_upper_bound_values(self) -> None:
        for value, expected in ((1, 1), (42, 42), (99, 99), (100, 100), (101, 100)):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), expected)
