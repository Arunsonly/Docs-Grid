import unittest
from quality_coverage import coverage

class CoverageTests(unittest.TestCase):
    def test_counts_unique_lines_and_merges_hits(self):
        self.assertEqual(coverage("SF:lib/a.dart\nDA:1,0\nDA:2,1\nend_of_record\nSF:lib/a.dart\nDA:1,2\nend_of_record\n"), (2, 2))

    def test_ignores_non_application_records(self):
        self.assertEqual(coverage("SF:test/a.dart\nDA:1,4\nend_of_record\nSF:lib/b.dart\nDA:1,1\nDA:2,0\nend_of_record\n"), (1, 2))

    def test_invalid_or_empty_evidence_fails(self):
        for value in ("", "DA:1,1", "SF:lib/a.dart\nDA:1,0", "SF:lib/a.dart\nDA:0,1", "SF:lib/a.dart\nDA:1,-1", "SF:lib/a.dart\nDA:1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                coverage(value)
