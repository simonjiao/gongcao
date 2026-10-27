import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_3f562f499836.py"
SPEC = importlib.util.spec_from_file_location("qa_fixture_3f562f499836", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ClampScoreTests(unittest.TestCase):
    def test_positive_scores(self) -> None:
        for value in (1, 42, 99):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), value)

    def test_upper_boundary(self) -> None:
        self.assertEqual(MODULE.clamp_score(100), 100)

    def test_above_upper_boundary(self) -> None:
        for value in (101, 150, 1000):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), 100)
