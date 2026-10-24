import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "acceptance_fixture", Path(__file__).resolve().parents[1] / "acceptance_fixture.py"
)
if spec is None or spec.loader is None:
    raise ImportError("Could not load acceptance fixture")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ClampScoreTests(unittest.TestCase):
    def test_positive_in_range(self) -> None:
        for value in (1, 25, 50, 99):
            with self.subTest(value=value):
                self.assertEqual(module.clamp_score(value), value)

    def test_upper_bound(self) -> None:
        for value in (100, 101, 1000):
            with self.subTest(value=value):
                self.assertEqual(module.clamp_score(value), 100)
