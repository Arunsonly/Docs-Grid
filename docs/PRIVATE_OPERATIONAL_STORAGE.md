# Private operational storage

Android local and SAF portable roots retain My Files, Database snapshots, Backups and Recovery. Cache, Thumbnails, Temp, Logs and internal Exports are app-private. New diagnostic writes are private; backup and restore staging uses the platform temporary directory on both Android and iOS. iOS already avoids creating these five folders in its selected provider tree. User-selected explicit backup exports remain supported.

On local Android upgrade, only empty known legacy operational directories are pruned non-recursively. Existing non-empty directories, exported files, recovery artifacts, unknown children and symlinks are not deleted or moved. Old local thumbnail files can still be read for compatibility. Provider-backed legacy directories are not automatically deleted because provider deletion can be recursive. Actual on-device verification is required before claiming upgrade or uninstall safety.
