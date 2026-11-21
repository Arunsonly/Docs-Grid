import unittest
from benchmark_end_to_end_startup import analyze, parse_markers


def sample():
    return {
        "dart_main_enter": 0, "flutter_binding_ready": 20000,
        "run_app_called": 21000, "root_home_init": 25000,
        "home_init": 30000, "home_first_frame": 80000,
        "database_open_start": 35000, "database_open_ready": 110000,
        "home_cache_read_start": 33000, "home_cache_read_done": 100000,
        "home_page_start": 34000, "home_page_ready": 130000,
        "home_summary_start": 34001, "home_summary_ready": 180000,
        "home_recent_start": 36000, "home_recent_ready": 195000,
        "home_core_ready": 195010,
    }


class EndToEndTests(unittest.TestCase):
    def test_only_markers_are_parsed_and_duplicates_dropped(self):
        s = ("I/flutter: DOCSGRID_STARTUP|v1|home_first_frame|80000\n"
             "PDF path: /private/a.pdf\n"
             "I/flutter: DOCSGRID_STARTUP|v1|home_first_frame|99999")
        self.assertEqual(parse_markers(s), {"home_first_frame": 80000})

    def test_concurrent_tasks_are_measured_not_summed(self):
        r = analyze(sample())
        self.assertEqual(r["last_finished_core_gate"], "home_recent_ready")
        self.assertEqual(r["durations_ms"]["home_core_from_dart_ms"], 195.01)
        self.assertEqual(r["durations_ms"]["sqlite_open_ms"], 75)

    def test_missing_required_markers_fail_closed(self):
        bad = sample()
        bad.pop("home_summary_ready")
        with self.assertRaisesRegex(ValueError, "home_summary_ready"):
            analyze(bad)

    def test_early_ready_fails(self):
        bad = sample()
        bad["home_core_ready"] = 80000
        with self.assertRaisesRegex(ValueError, "before"):
            analyze(bad)

    def test_negative_duration_fails(self):
        bad = sample()
        bad["database_open_ready"] = 0
        with self.assertRaisesRegex(ValueError, "Negative"):
            analyze(bad)


if __name__ == "__main__":
    unittest.main()
