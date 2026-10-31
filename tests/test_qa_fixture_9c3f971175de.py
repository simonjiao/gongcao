import importlib.util
import unittest
from pathlib import Path

_MODULE_PATH = Path(__file__).resolve().parents[1] / "qa_fixture_9c3f971175de.py"
_SPEC = importlib.util.spec_from_file_location("qa_fixture_9c3f971175de", _MODULE_PATH)
if _SPEC is None or _SPEC.loader is None:
    raise ImportError(f"Cannot load {_MODULE_PATH}")
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)


class TestClampScore(unittest.TestCase):
    def test_positive_in_range(self) -> None:
        for value in (1, 42, 99):
            with self.subTest(value=value):
                self.assertEqual(_MODULE.clamp_score(value), value)

    def test_upper_bound(self) -> None:
        self.assertEqual(_MODULE.clamp_score(100), 100)

    def test_above_upper_bound(self) -> None:
        for value in (101, 1000):
            with self.subTest(value=value):
                self.assertEqual(_MODULE.clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
