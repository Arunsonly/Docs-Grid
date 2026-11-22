#!/usr/bin/env python3
"""Offline validation for the Perfetto startup capture's baseline safety gate."""
import unittest

from profile_android_startup import checked_baseline
from benchmark_android_cold_launch import PACKAGE, parse_ttid


def baseline():
    return {
        "apk_sha256": "ab" * 32,
        "package": PACKAGE,
        "metric": "Android am start -S -W TotalTime (TTID)",
        "iterations": 7,
        "samples_ms": [3500, 3100, 2600, 2900, 3700, 4000, 3300],
        "p50_ms": 3300,
        "p95_ms": 4000,
    }


class StartupCriticalPathTests(unittest.TestCase):
    def test_accepts_exact_same_apk_untraced_reference(self):
        self.assertEqual(
            checked_baseline(baseline(), "ab" * 32),
            {"baseline_p50_ms": 3300, "baseline_p95_ms": 4000},
        )

    def test_refuses_wrong_apk_or_wrong_metric(self):
        for key, value in (
            ("apk_sha256", "cd" * 32),
            ("package", "other.package"),
            ("metric", "TTFD"),
            ("iterations", 8),
            ("samples_ms", [100]),
            ("p95_ms", None),
        ):
            with self.subTest(key=key):
                corrupt = baseline()
                corrupt[key] = value
                with self.assertRaises(ValueError):
                    checked_baseline(corrupt, "ab" * 32)

    def test_rejects_failed_android_launch(self):
        with self.assertRaises(ValueError):
            parse_ttid("Status: timeout\nTotalTime: 1200\nComplete\n")


if __name__ == "__main__":
    unittest.main()
