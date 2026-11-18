import tempfile
import unittest
from pathlib import Path

from prepare_android_release_signing import configure_release


class ReleaseSigningTest(unittest.TestCase):
    def test_missing_keys_do_not_modify_gradle(self):
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder) / "build.gradle.kts"
            original = 'android { buildTypes { release { signingConfig = signingConfigs.getByName("debug") } } }'
            build.write_text(original)
            with self.assertRaises(RuntimeError):
                configure_release(build, {})
            self.assertEqual(build.read_text(), original)

    def test_only_explicit_key_replaces_debug_signing(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            build = directory / "build.gradle.kts"
            store = directory / "release-keystore"
            store.write_bytes(b"test fixture only")
            build.write_text('android { buildTypes { release { signingConfig = signingConfigs.getByName("debug") } } }')
            env = {
                "DOCSGRID_ANDROID_KEYSTORE_PATH": str(store),
                "DOCSGRID_ANDROID_STORE_PASSWORD": "secret-not-shown",
                "DOCSGRID_ANDROID_KEY_ALIAS": "test",
                "DOCSGRID_ANDROID_KEY_PASSWORD": "secret-not-shown",
            }
            configure_release(build, env)
            source = build.read_text()
            self.assertIn('docsgridProduction', source)
            self.assertNotIn('getByName("debug")', source)
            self.assertNotIn("secret-not-shown", source)


if __name__ == "__main__":
    unittest.main()
