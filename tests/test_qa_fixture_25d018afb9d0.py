import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_25d018afb9d0.py"
SPEC = importlib.util.spec_from_file_location("qa_fixture_25d018afb9d0", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ClampScoreTests(unittest.TestCase):
    def test_clamps_to_inclusive_score_range(self) -> None:
        cases = (
            (-100, 0),
            (-1, 0),
            (0, 0),
            (1, 1),
            (50, 50),
            (99, 99),
            (100, 100),
            (101, 100),
            (1000, 100),
        )
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(MODULE.clamp_score(value), expected)


if __name__ == "__main__":
    unittest.main()
