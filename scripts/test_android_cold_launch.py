#!/usr/bin/env python3
"""Fast unit tests for the offline cold-launch output parser (no ADB needed)."""
import unittest
import xml.etree.ElementTree as ET

from smoke_android_fresh_grid import find_grid_tab, grid_screen_visible

from benchmark_android_cold_launch import parse_ttid, summarize


class StartupParserTests(unittest.TestCase):
    def test_accepts_completed_android_startup(self):
        output = (
            "Starting: Intent { act=android.intent.action.MAIN }\n"
            "Status: ok\n"
            "LaunchState: COLD\n"
            "Activity: com.docsgrid.mobile/com.docsgrid.docs_grid.MainActivity\n"
            "ThisTime: 612\n"
            "TotalTime: 709\n"
            "WaitTime: 743\n"
            "Complete\n"
        )
        self.assertEqual(parse_ttid(output), 709)

    def test_does_not_misreport_wait_time_or_failed_launch(self):
        for response in (
            "Status: ok\nTotalTime: 100\n",
            "Status: timeout\nTotalTime: 900\nComplete\n",
            "Status: ok\nTotalTime: 100\nTotalTime: 200\nComplete\n",
            "Status: ok\nWaitTime: 300\nComplete\n",
            "Status: ok\nTotalTime: 0\nComplete\n",
        ):
            with self.subTest(response=response), self.assertRaises(ValueError):
                parse_ttid(response)

    def test_nearest_rank_percentiles_from_measured_values_only(self):
        sample = [330, 100, 220, 450, 180, 250, 300]
        stats = summarize(sample)
        self.assertEqual(stats["iterations"], 7)
        self.assertEqual(stats["p50_ms"], 250)
        self.assertEqual(stats["p95_ms"], 450)
        self.assertEqual(stats["min_ms"], 100)
        self.assertEqual(stats["max_ms"], 450)
        self.assertEqual(stats["samples_ms"], sample)

    def test_empty_samples_fail(self):
        with self.assertRaises(ValueError):
            summarize([])


class FreshGridNavigationTests(unittest.TestCase):
    def test_actual_grid_destination_wins_over_home_recent_filter(self):
        # Labels observed in the failing CI hierarchy, in the same order.
        home = ET.fromstring(
            '<hierarchy><node text="Grid" bounds="[0,800][300,900]"/>'
            '<node content-desc="Grid storage&#10;0 B"/>'
            '<node content-desc="Phone&#10;Tab 1 of 3"/>'
            '<node content-desc="Home&#10;Tab 2 of 3" selected="true"/>'
            '<node content-desc="Grid&#10;Tab 3 of 3" '
            'clickable="true" enabled="true" bounds="[720,2200][1080,2400]"/>'
            '</hierarchy>')
        current = list(home.iter("node"))
        tab = find_grid_tab(current)
        self.assertIsNotNone(tab)
        self.assertEqual(tab.get("bounds"), "[720,2200][1080,2400]")
        self.assertFalse(grid_screen_visible(current))

    def test_plain_grid_label_is_not_navigation(self):
        node = ET.Element("node", {"text": "Grid", "clickable": "true"})
        self.assertIsNone(find_grid_tab([node]))

    def test_grid_loading_screen_is_separate_from_home(self):
        node = ET.Element("node", {"text": "Search folders or PDF names"})
        self.assertTrue(grid_screen_visible([node]))


if __name__ == "__main__":
    unittest.main()
