import importlib.util
import unittest
from pathlib import Path

_module_path = Path(__file__).resolve().parents[1] / "qa_fixture_d805b26ab5f2.py"
_spec = importlib.util.spec_from_file_location("qa_fixture_d805b26ab5f2", _module_path)
if _spec is None or _spec.loader is None:
    raise ImportError(f"Cannot load module from {_module_path}")
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)


class ClampScoreTests(unittest.TestCase):
    def test_negative_values(self) -> None:
        for value in (-1, -100, -(10**100)):
            with self.subTest(value=value):
                self.assertEqual(_module.clamp_score(value), 0)

    def test_zero(self) -> None:
        self.assertEqual(_module.clamp_score(0), 0)

    def test_in_range_values(self) -> None:
        for value in (1, 42, 99):
            with self.subTest(value=value):
                self.assertEqual(_module.clamp_score(value), value)

    def test_upper_boundary(self) -> None:
        self.assertEqual(_module.clamp_score(100), 100)

    def test_values_above_upper_boundary(self) -> None:
        for value in (101, 1000, 10**100):
            with self.subTest(value=value):
                self.assertEqual(_module.clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
