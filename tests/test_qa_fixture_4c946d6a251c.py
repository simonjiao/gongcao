import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_4c946d6a251c.py"
SPEC = importlib.util.spec_from_file_location("qa_fixture_4c946d6a251c", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ClampScoreTests(unittest.TestCase):
    def test_negative_values(self) -> None:
        for value in (-100, -1):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), 0)

    def test_zero(self) -> None:
        self.assertEqual(MODULE.clamp_score(0), 0)

    def test_positive_in_range(self) -> None:
        for value in (1, 50, 99):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), value)

    def test_upper_boundary(self) -> None:
        self.assertEqual(MODULE.clamp_score(100), 100)

    def test_above_upper_boundary(self) -> None:
        for value in (101, 1000):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
