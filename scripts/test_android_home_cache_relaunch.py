import unittest

from verify_android_home_cache_relaunch import verify_session


def sample():
    return {
        "dart_main_enter": 0,
        "home_cache_read_start": 30000,
        "home_cache_read_done": 50000,
        "home_cache_summary_hit": 50010,
        "home_cache_summary_applied": 50200,
        "home_page_ready": 80000,
        "home_recent_ready": 90000,
        "home_summary_ready": 120000,
        "home_core_ready": 120010,
    }


class RealAndroidHomeCacheRelaunchParserTests(unittest.TestCase):
    def test_accepts_cache_hit_followed_by_authoritative_live_result(self):
        result = verify_session(sample())
        self.assertTrue(result["cache_persisted_after_force_stop"])
        self.assertTrue(result["cache_was_applied_before_live"])

    def test_accepts_live_winning_race_before_cache_application(self):
        values = sample()
        values.pop("home_cache_summary_applied")
        self.assertFalse(verify_session(values)["cache_was_applied_before_live"])

    def test_rejects_false_hit_or_missing_live_data(self):
        values = sample()
        values.pop("home_cache_summary_hit")
        with self.assertRaisesRegex(ValueError, "home_cache_summary_hit"):
            verify_session(values)
        values = sample()
        values.pop("home_summary_ready")
        with self.assertRaisesRegex(ValueError, "home_summary_ready"):
            verify_session(values)

    def test_rejects_stale_cache_applied_after_authoritative_summary(self):
        values = sample()
        values["home_cache_summary_applied"] = 130000
        with self.assertRaisesRegex(ValueError, "after authoritative"):
            verify_session(values)


if __name__ == "__main__":
    unittest.main()
