import tempfile
import unittest
from pathlib import Path

from prepare_android_ocr import configure_ocr


class NativeOcrDependencyTest(unittest.TestCase):
    def test_kotlin_gradle_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder) / "build.gradle.kts"
            build.write_text('android {}\ndependencies {}')
            configure_ocr(build)
            one = build.read_text()
            configure_ocr(build)
            self.assertEqual(build.read_text(), one)
            self.assertIn(
                'implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")',
                one,
            )

    def test_does_not_accept_conflicting_ocr_dependency(self):
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder) / "build.gradle.kts"
            original = ('dependencies { implementation('
                        '"com.google.mlkit:text-recognition-devanagari:15.0.0") }')
            build.write_text(original)
            with self.assertRaises(RuntimeError):
                configure_ocr(build)
            self.assertEqual(build.read_text(), original)

    def test_groovy_gradle_uses_groovy_dependency_syntax(self):
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder) / "build.gradle"
            build.write_text("android {}\ndependencies {}")
            configure_ocr(build)
            self.assertIn(
                "implementation 'com.google.mlkit:text-recognition-devanagari:16.0.1'",
                build.read_text(),
            )


if __name__ == "__main__":
    unittest.main()
