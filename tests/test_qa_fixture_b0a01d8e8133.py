"""Standard-library tests for the score-clamping fixture."""

import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "qa_fixture_b0a01d8e8133",
    Path(__file__).resolve().parents[1] / "qa_fixture_b0a01d8e8133.py",
)
if _spec is None or _spec.loader is None:
    raise ImportError("Unable to load the score-clamping fixture")
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
clamp_score = _module.clamp_score


class ClampScoreTests(unittest.TestCase):
    def test_negative_values_clamp_to_zero(self) -> None:
        for value in (-1, -100, -(10**100)):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), 0)

    def test_zero_is_preserved(self) -> None:
        self.assertEqual(clamp_score(0), 0)

    def test_in_range_values_are_preserved(self) -> None:
        for value in (1, 42, 99):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), value)

    def test_one_hundred_is_preserved(self) -> None:
        self.assertEqual(clamp_score(100), 100)

    def test_larger_values_clamp_to_one_hundred(self) -> None:
        for value in (101, 200, 10**100):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
