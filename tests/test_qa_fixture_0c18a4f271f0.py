"""Standard-library tests for the score clamping fixture."""

import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_0c18a4f271f0.py"
SPEC = importlib.util.spec_from_file_location("qa_fixture_0c18a4f271f0", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"Cannot load score clamping fixture from {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ClampScoreTests(unittest.TestCase):
    def test_negative_values(self) -> None:
        for value in (-1, -50, -(10**100)):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), 0)

    def test_zero(self) -> None:
        self.assertEqual(MODULE.clamp_score(0), 0)

    def test_in_range_values(self) -> None:
        for value in (1, 50, 99):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), value)

    def test_upper_boundary(self) -> None:
        self.assertEqual(MODULE.clamp_score(100), 100)

    def test_larger_values(self) -> None:
        for value in (101, 150, 10**100):
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
