import unittest

from acceptance_fixture import clamp_score


class ClampScoreTests(unittest.TestCase):
    def test_negative_values(self) -> None:
        for value in (-1, -10, -100):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), 0)

    def test_zero(self) -> None:
        self.assertEqual(clamp_score(0), 0)

    def test_in_range_positive_values(self) -> None:
        for value in (1, 25, 50, 99):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), value)

    def test_upper_bound(self) -> None:
        self.assertEqual(clamp_score(100), 100)

    def test_values_above_upper_bound(self) -> None:
        for value in (101, 200):
            with self.subTest(value=value):
                self.assertEqual(clamp_score(value), 100)


if __name__ == "__main__":
    unittest.main()
