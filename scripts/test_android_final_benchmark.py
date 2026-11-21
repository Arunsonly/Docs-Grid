import unittest
from unittest.mock import patch
from pathlib import Path

from benchmark_android_cold_launch import PACKAGE, ACTIVITY, summarize
from compare_android_final_release import comparison, validate


def sample(values):
    return {
        "apk_sha256": "hash", "package": PACKAGE, "activity": ACTIVITY,
        "metric": "Android am start -S -W TotalTime (TTID)",
        "ttfd_measured": False,
        **summarize(values),
    }


class FinalComparatorTests(unittest.TestCase):
    @patch("compare_android_final_release.file_sha256", return_value="hash")
    def test_accepts_seven_actual_ttid_samples(self, _):
        validate(sample([2100, 2200, 2300, 2400, 2500, 2600, 2800]), Path("x.apk"), "old")

    @patch("compare_android_final_release.file_sha256", return_value="hash")
    def test_rejects_incomplete_samples_and_fake_ttfdd(self, _):
        broken = sample([2300] * 7)
        broken["samples_ms"] = [2300] * 6
        with self.assertRaisesRegex(ValueError, "seven"):
            validate(broken, Path("x.apk"), "old")
        broken = sample([2300] * 7)
        broken["ttfd_measured"] = True
        with self.assertRaisesRegex(ValueError, "TTID"):
            validate(broken, Path("x.apk"), "old")

    def test_large_slowdown_is_flagged_without_false_certainty(self):
        old = sample([2000] * 7)
        new = sample([2600] * 7)
        result = comparison(old, new)
        self.assertTrue(result["possible_large_regression_flag"])
        self.assertEqual(result["p50_delta_ms"], 600)

    def test_small_changes_are_not_false_regressions(self):
        old = sample([2000] * 7)
        new = sample([2100] * 7)
        self.assertFalse(comparison(old, new)["possible_large_regression_flag"])


if __name__ == "__main__":
    unittest.main()
