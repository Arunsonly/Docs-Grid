package com.docsgrid.docs_grid

import android.app.Activity
import android.content.Intent
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.content.ContentUris
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

private class MissingStorageChildException(message: String) : IllegalStateException(message)

class MainActivity : FlutterActivity() {
    // Storage providers may perform a remote query for every directory.
    // A small bounded pool keeps scans responsive without creating unbounded IO.
    private val storageExecutor = ThreadPoolExecutor(4, 4, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(64))
    private val mainHandler = Handler(Looper.getMainLooper())
    private val channelName = "docsgrid/storage"
    private val requestChooseFolder = 4817
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingRecoverySelection = false
    private var storageChangeSink: EventChannel.EventSink? = null
    private val storageObservers = mutableListOf<ContentObserver>()
    private var storageObserversRegistered = false
    private var storageChangeRunnable: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docsgrid/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSettings" -> {
                        try {
                            val settingsIntent = if (android.os.Build.VERSION.SDK_INT >= 26) {
                                Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                    putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                                }
                            } else {
                                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                            }
                            startActivity(settingsIntent)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("SETTINGS_ERROR", error.message ?: "Could not open notification settings.", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "docsgrid/storage_changes")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    storageChangeSink = events
                    registerStorageChangeObservers()
                }

                override fun onCancel(arguments: Any?) {
                    storageChangeSink = null
                    unregisterStorageChangeObservers()
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val mainThreadOnly = call.method == "chooseFolder" || call.method == "chooseRecoveryFolder" || call.method == "openPdf"
                if (mainThreadOnly) {
                    handleStorageCall(call, result)
                } else if (call.method == "consumeSharedPdfs") {
                    // Clear the Activity intent only after the bounded queue
                    // accepts the work, so an incoming share is not discarded.
                    val incomingIntent = intent
                    val accepted = enqueueStorageCall(result) {
                        handleStorageCall(call, onMainThreadResult(result), incomingIntent)
                    }
                    if (accepted) setIntent(Intent())
                } else {
                    enqueueStorageCall(result) {
                        handleStorageCall(call, onMainThreadResult(result))
                    }
                }
            }
    }

    override fun onResume() {
        super.onResume()
        registerStorageChangeObservers()
    }

    override fun onPause() {
        unregisterStorageChangeObservers()
        super.onPause()
    }

    private fun registerStorageChangeObservers() {
        if (storageObserversRegistered || storageChangeSink == null) return
        val observedUris = linkedMapOf<String, Uri>()
        observedUris["media"] = MediaStore.Files.getContentUri("external")
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            try {
                MediaStore.getExternalVolumeNames(this).forEach { volume ->
                    observedUris["volume:$volume"] = MediaStore.Files.getContentUri(volume)
                }
            } catch (_: Exception) {
                // The aggregate external observer above remains as a fallback.
            }
        }
        try {
            contentResolver.persistedUriPermissions
                .filter { it.isReadPermission }
                .forEach { permission ->
                    observedUris[permission.uri.toString()] = permission.uri
                }
        } catch (_: Exception) {
            // MediaStore observation remains available when SAF grants cannot be read.
        }

        observedUris.values.forEach { uri ->
            try {
                val observer = object : ContentObserver(mainHandler) {
                    override fun onChange(selfChange: Boolean) {
                        scheduleStorageChangeEvent()
                    }

                    override fun onChange(selfChange: Boolean, changedUri: Uri?) {
                        scheduleStorageChangeEvent()
                    }
                }
                contentResolver.registerContentObserver(uri, true, observer)
                storageObservers.add(observer)
            } catch (_: Exception) {
                // A provider can reject observation. Resume reconciliation still runs.
            }
        }
        storageObserversRegistered = true
    }

    private fun unregisterStorageChangeObservers() {
        storageChangeRunnable?.let { mainHandler.removeCallbacks(it) }
        storageChangeRunnable = null
        storageObservers.forEach { observer ->
            try { contentResolver.unregisterContentObserver(observer) } catch (_: Exception) {}
        }
        storageObservers.clear()
        storageObserversRegistered = false
    }

    private fun scheduleStorageChangeEvent() {
        storageChangeRunnable?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            storageChangeSink?.success(mapOf("changedAt" to System.currentTimeMillis()))
        }
        storageChangeRunnable = task
        mainHandler.postDelayed(task, 650L)
    }

    private fun isAppUpdateInstall(): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val info = packageManager.getPackageInfo(packageName, 0)
            info.lastUpdateTime > info.firstInstallTime
        } catch (_: Exception) {
            // Unknown install state must not suppress a possible recovery prompt.
            false
        }
    }

    private fun detectLegacyDocsGridData(): Map<String, Any> {
        if (android.os.Build.VERSION.SDK_INT >= 30 &&
            !android.os.Environment.isExternalStorageManager()) {
            return mapOf("status" to "detection_unavailable")
        }
        val mediaRoot = java.io.File(
            android.os.Environment.getExternalStorageDirectory(),
            "Android/media"
        )
        val roots = listOf(
            java.io.File(mediaRoot, "DocsGrid"),
            java.io.File(mediaRoot, "com.docsgrid")
        ).filter { it.exists() && it.isDirectory && it.canRead() }

        fun isPdf(file: java.io.File): Boolean {
            if (!file.isFile || !file.name.lowercase().endsWith(".pdf")) return false
            return try {
                file.inputStream().use { input ->
                    val header = ByteArray(5)
                    input.read(header) == 5 && String(header) == "%PDF-"
                }
            } catch (_: Exception) { false }
        }

        fun hasValidBackup(file: java.io.File): Boolean {
            if (!file.isFile || !file.name.lowercase().endsWith(".zip")) return false
            return try {
                java.util.zip.ZipFile(file).use { zip ->
                    val entry = zip.getEntry("manifest.json") ?: return@use false
                    val manifestText = zip.getInputStream(entry).bufferedReader().use {
                        it.readText().take(128 * 1024)
                    }
                    val manifest = org.json.JSONObject(manifestText)
                    val backupType = manifest.optString("backupType")
                    if (manifest.optString("format") != "DocsGridBackup" ||
                        manifest.optInt("version") != 1 ||
                        (backupType != "full" && backupType != "database") ||
                        manifest.optInt("databaseSchemaVersion", 1) !in 1..11) {
                        return@use false
                    }
                    val tables = manifest.optJSONObject("tables") ?: return@use false
                    if (!tables.has("documents") || !tables.has("folders")) return@use false
                    val metadata = manifest.optJSONArray("metadataFiles") ?: return@use false
                    if (metadata.length() == 0) return@use false
                    val seen = mutableSetOf<String>()
                    for (index in 0 until metadata.length()) {
                        val record = metadata.optJSONObject(index) ?: return@use false
                        val name = record.optString("entry")
                        val size = record.optLong("sizeBytes", -1L)
                        val expected = record.optString("sha256")
                        if (name.isBlank() || name.contains("/") || name.contains("\\") ||
                            !name.endsWith(".json") || !seen.add(name) || size < 0 ||
                            !expected.matches(Regex("(?i)^[a-f0-9]{64}$"))) return@use false
                        val payload = zip.getEntry(name) ?: return@use false
                        if (payload.size >= 0 && payload.size != size) return@use false
                        val digest = java.security.MessageDigest.getInstance("SHA-256")
                        zip.getInputStream(payload).buffered().use { input ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                digest.update(buffer, 0, count)
                            }
                        }
                        val actual = digest.digest().joinToString("") { "%02x".format(it) }
                        if (!actual.equals(expected, ignoreCase = true)) return@use false
                        if (!tables.has(name.removeSuffix(".json"))) return@use false
                    }
                    val pdfs = manifest.optJSONArray("files") ?: return@use false
                    if (backupType == "database" && pdfs.length() != 0) return@use false
                    for (index in 0 until pdfs.length()) {
                        val record = pdfs.optJSONObject(index) ?: return@use false
                        val entryName = record.optString("entry")
                        val digest = record.optString("sha256")
                        if (!entryName.startsWith("pdfs/") ||
                            entryName.contains("..") ||
                            !digest.matches(Regex("(?i)^[a-f0-9]{64}$")) ||
                            zip.getEntry(entryName) == null) return@use false
                    }
                    true
                }
            } catch (_: Exception) { false }
        }

        fun hasValidSnapshot(directory: java.io.File): Boolean {
            if (!directory.isDirectory || !directory.name.startsWith("snapshot_")) return false
            return try {
                val manifestFile = java.io.File(directory, "manifest.json")
                if (!manifestFile.isFile) return false
                val manifest = org.json.JSONObject(
                    manifestFile.readText(Charsets.UTF_8).take(128 * 1024)
                )
                if (manifest.optString("format") != "DocsGridPortableData" ||
                    manifest.optInt("formatVersion") != 1 ||
                    manifest.optInt("databaseSchemaVersion", 0) !in 1..11) return false
                val tables = manifest.optJSONObject("tables") ?: return false
                if (!tables.has("documents") || !tables.has("folders")) return false
                val records = manifest.optJSONArray("files") ?: return false
                if (records.length() == 0) return false
                val seen = mutableSetOf<String>()
                for (index in 0 until records.length()) {
                    val record = records.optJSONObject(index) ?: return false
                    val name = record.optString("path")
                    if (name.isBlank() || name.contains("/") || name.contains("\\") ||
                        !name.endsWith(".json") || !seen.add(name)) return false
                    val size = record.optLong("sizeBytes", -1L)
                    val expected = record.optString("sha256")
                    if (size < 0 || !expected.matches(Regex("(?i)^[a-f0-9]{64}$"))) return false
                    val payload = java.io.File(directory, name)
                    if (!payload.isFile || payload.length() != size) return false
                    val digest = java.security.MessageDigest.getInstance("SHA-256")
                    payload.inputStream().buffered().use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            digest.update(buffer, 0, count)
                        }
                    }
                    val actual = digest.digest().joinToString("") { "%02x".format(it) }
                    if (!actual.equals(expected, ignoreCase = true)) return false
                    if (!tables.has(name.removeSuffix(".json"))) return false
                }
                true
            } catch (_: Exception) { false }
        }

        var hasPdfs = false
        var hasBackup = false
        var hasSnapshot = false
        for (root in roots) {
            val libraryRoots = listOf(
                java.io.File(root, "My Files/Unfiled"),
                java.io.File(root, "My Files/Folders"),
                java.io.File(root, "Documents"),
                java.io.File(root, "Folders"),
                java.io.File(root, "Unfiled"),
                java.io.File(root, "PDFs")
            )
            val queue = java.util.ArrayDeque<Pair<java.io.File, Int>>()
            libraryRoots.filter { it.isDirectory && it.canRead() }
                .forEach { queue.add(it to 0) }
            var visitedDirectories = 0
            while (queue.isNotEmpty() && visitedDirectories < 1500 && !hasPdfs) {
                val (directory, depth) = queue.removeFirst()
                visitedDirectories++
                val children = try { directory.listFiles() } catch (_: Exception) { null } ?: continue
                for (child in children) {
                    if (isPdf(child)) {
                        hasPdfs = true
                        break
                    }
                    if (child.isDirectory && depth < 12 && child.canRead()) {
                        queue.add(child to (depth + 1))
                    }
                }
            }
            val backupDirectories = listOf(
                java.io.File(root, "Backups"),
                java.io.File(root, "Backups/Full"),
                java.io.File(root, "Backups/Database"),
                java.io.File(root, "System/Backups"),
                java.io.File(root, "System/Backups/Full"),
                java.io.File(root, "System/Backups/Database")
            )
            hasBackup = hasBackup || backupDirectories.any { directory ->
                (directory.listFiles() ?: emptyArray()).any { hasValidBackup(it) }
            }
            val snapshotDirectories = listOf(
                java.io.File(root, "Database"),
                java.io.File(root, "System/Database"),
                java.io.File(root, "MetadataSnapshots"),
                java.io.File(root, "System/MetadataSnapshots")
            )
            hasSnapshot = hasSnapshot || snapshotDirectories.any { parent ->
                (parent.listFiles() ?: emptyArray()).any { hasValidSnapshot(it) }
            }
        }
        val found = hasPdfs || hasBackup || hasSnapshot
        return mapOf(
            "status" to when {
                found -> "found_recoverable_data"
                roots.isNotEmpty() -> "found_folder_without_verified_recoverable_data"
                else -> "confirmed_no_previous_data"
            },
            "hasPdfs" to hasPdfs,
            "hasBackup" to hasBackup,
            "hasSnapshot" to hasSnapshot,
            "legacyRoots" to roots.map { it.absolutePath }
        )
    }

    private fun queryPhonePdfIndex(): Map<String, Any> {
        if (android.os.Build.VERSION.SDK_INT >= 30 &&
            !android.os.Environment.isExternalStorageManager()) {
            throw SecurityException("Allow Full internal storage access to index all shared PDF files.")
        }

        val entries = mutableListOf<Map<String, Any>>()
        val volumeStates = linkedMapOf<String, Map<String, Any>>()
        val volumes = if (android.os.Build.VERSION.SDK_INT >= 29) {
            MediaStore.getExternalVolumeNames(this).toList().sorted()
        } else {
            listOf("external")
        }
        // Android 9 and earlier do not expose RELATIVE_PATH or per-volume
        // generation values consistently. The caller will use the verified
        // recursive scan on those releases instead of mis-grouping every PDF.
        var complete = android.os.Build.VERSION.SDK_INT >= 29

        volumes.forEachIndexed { volumeIndex, volumeName ->
            try {
                val collection = if (android.os.Build.VERSION.SDK_INT >= 29) {
                    MediaStore.Files.getContentUri(volumeName)
                } else {
                    MediaStore.Files.getContentUri("external")
                }
                val relativePathColumn = if (android.os.Build.VERSION.SDK_INT >= 29) {
                    MediaStore.MediaColumns.RELATIVE_PATH
                } else {
                    null
                }
                val projection = mutableListOf(
                    MediaStore.MediaColumns._ID,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.MIME_TYPE,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.DATE_MODIFIED
                )
                relativePathColumn?.let { projection.add(it) }
                if (android.os.Build.VERSION.SDK_INT >= 30) {
                    projection.add(MediaStore.MediaColumns.GENERATION_MODIFIED)
                    projection.add(MediaStore.MediaColumns.IS_TRASHED)
                }

                val version = if (android.os.Build.VERSION.SDK_INT >= 30) {
                    MediaStore.getVersion(this, volumeName)
                } else {
                    "legacy"
                }
                val generation = if (android.os.Build.VERSION.SDK_INT >= 30) {
                    MediaStore.getGeneration(this, volumeName)
                } else {
                    0L
                }
                volumeStates[volumeName] = mapOf(
                    "version" to version,
                    "generation" to generation,
                    "label" to if (volumeName == MediaStore.VOLUME_EXTERNAL_PRIMARY) {
                        "Internal"
                    } else {
                        "External storage ${volumeIndex}"
                    }
                )

                val idIndexName = MediaStore.MediaColumns._ID
                val nameIndexName = MediaStore.MediaColumns.DISPLAY_NAME
                val mimeIndexName = MediaStore.MediaColumns.MIME_TYPE
                val sizeIndexName = MediaStore.MediaColumns.SIZE
                val modifiedIndexName = MediaStore.MediaColumns.DATE_MODIFIED
                val relativeIndexName = relativePathColumn
                // Exclude MediaStore's own trash flag; OEMs that implement trash
                // as a hidden directory are filtered by relativePath below.
                val pdfSelection = if (android.os.Build.VERSION.SDK_INT >= 30) {
                    "($mimeIndexName = ? OR $nameIndexName LIKE ?) AND " +
                        MediaStore.MediaColumns.IS_TRASHED + " = 0"
                } else {
                    "$mimeIndexName = ? OR $nameIndexName LIKE ?"
                }
                contentResolver.query(
                    collection,
                    projection.toTypedArray(),
                    pdfSelection,
                    arrayOf("application/pdf", "%.pdf"),
                    "$modifiedIndexName DESC"
                )?.use { cursor ->
                    val idIndex = cursor.getColumnIndex(idIndexName)
                    val nameIndex = cursor.getColumnIndex(nameIndexName)
                    val mimeIndex = cursor.getColumnIndex(mimeIndexName)
                    val sizeIndex = cursor.getColumnIndex(sizeIndexName)
                    val modifiedIndex = cursor.getColumnIndex(modifiedIndexName)
                    val relativeIndex = relativeIndexName?.let {
                        cursor.getColumnIndex(it)
                    } ?: -1
                    val generationIndex = if (android.os.Build.VERSION.SDK_INT >= 30) {
                        cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_MODIFIED)
                    } else {
                        -1
                    }
                    if (idIndex < 0 || nameIndex < 0) {
                        throw IllegalStateException("MediaStore returned incomplete PDF columns.")
                    }
                    while (cursor.moveToNext()) {
                        val name = cursor.getString(nameIndex) ?: continue
                        if (!name.lowercase().endsWith(".pdf")) continue
                        val relativePath = if (relativeIndex >= 0 && !cursor.isNull(relativeIndex)) {
                            cursor.getString(relativeIndex).orEmpty()
                                .replace('\\', '/').trim('/')
                        } else {
                            ""
                        }
                        val normalized = relativePath.lowercase()
                        // Android/Samsung file-manager trash folders are not live Phone files.
                        val pathSegments = normalized.split('/').filter { it.isNotBlank() }
                        if (pathSegments.any {
                            it == ".trash" || it == ".trashed" || it == ".recycle" ||
                                it == "recycle_bin" || it == "recycle bin"
                        }) continue
                        // DocsGrid-managed files belong to the Grid library, not Phone storage.
                        if (normalized.startsWith("android/media/com.docsgrid/") ||
                            normalized == "android/media/com.docsgrid" ||
                            normalized.startsWith("android/media/docsgrid/") ||
                            normalized == "android/media/docsgrid") {
                            continue
                        }
                        val sizeKnown = sizeIndex >= 0 && !cursor.isNull(sizeIndex) &&
                            cursor.getLong(sizeIndex) >= 0L
                        val size = if (sizeKnown) cursor.getLong(sizeIndex) else 0L
                        val modifiedMillis = if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) {
                            cursor.getLong(modifiedIndex).coerceAtLeast(0L) * 1000L
                        } else {
                            0L
                        }
                        val label = if (volumeName == MediaStore.VOLUME_EXTERNAL_PRIMARY) {
                            "Internal"
                        } else {
                            "External storage ${volumeIndex}"
                        }
                        val folderPath = when {
                            relativePath.isEmpty() -> ""
                            label == "Internal" -> "Internal/$relativePath"
                            else -> "$label/$relativePath"
                        }
                        val item = mutableMapOf<String, Any>(
                            "name" to name,
                            "uri" to ContentUris.withAppendedId(collection, cursor.getLong(idIndex)).toString(),
                            "isDirectory" to false,
                            "sizeBytes" to size,
                            "sizeKnown" to sizeKnown,
                            "lastModified" to modifiedMillis,
                            "folderPath" to folderPath,
                            "volumeName" to volumeName
                        )
                        if (generationIndex >= 0 && !cursor.isNull(generationIndex)) {
                            item["generationModified"] = cursor.getLong(generationIndex)
                        }
                        entries.add(item)
                    }
                } ?: throw IllegalStateException("MediaStore could not query volume $volumeName.")
            } catch (error: Exception) {
                complete = false
                volumeStates[volumeName] = mapOf(
                    "error" to (error.message ?: "Volume query failed"),
                    "label" to if (volumeName == MediaStore.VOLUME_EXTERNAL_PRIMARY) {
                        "Internal"
                    } else {
                        "External storage ${volumeIndex}"
                    }
                )
            }
        }

        entries.sortByDescending { it["lastModified"] as Long }
        return mapOf(
            "entries" to entries,
            "volumes" to volumeStates,
            "complete" to complete
        )
    }

    private fun enqueueStorageCall(result: MethodChannel.Result, task: () -> Unit): Boolean {
        return try {
            storageExecutor.execute { task() }
            true
        } catch (_: RejectedExecutionException) {
            result.error("BUSY", "DocsGrid storage is busy. Please retry after the current file operation finishes.", null)
            false
        }
    }

    private fun onMainThreadResult(result: MethodChannel.Result): MethodChannel.Result =
        object : MethodChannel.Result {
            override fun success(value: Any?) { mainHandler.post { result.success(value) } }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                mainHandler.post { result.error(errorCode, errorMessage, errorDetails) }
            }
            override fun notImplemented() { mainHandler.post { result.notImplemented() } }
        }

    private fun handleStorageCall(
        call: MethodCall,
        result: MethodChannel.Result,
        incomingShareIntent: Intent? = null,
    ) {
                    try {
                        when (call.method) {
                            "chooseFolder", "chooseRecoveryFolder" -> {
                                if (pendingFolderResult != null) {
                                    result.error("BUSY", "Folder picker is already open.", null)
                                } else {
                                    pendingFolderResult = result
                                    pendingRecoverySelection = call.method == "chooseRecoveryFolder"
                                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                                    intent.addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                                    )
                                    startActivityForResult(intent, requestChooseFolder)
                                }
                            }
                            "isAppUpdateInstall" -> result.success(isAppUpdateInstall())
                            "detectLegacyDocsGridData" -> result.success(detectLegacyDocsGridData())
                            "getPortableDataLocations" -> {
                                // A user-selected SAF recovery tree remains usable without
                                // MANAGE_EXTERNAL_STORAGE. Return its persisted opaque URIs
                                // before attempting the automatic Android/media layout.
                                val saved = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                                val savedRoot = saved.getString("docsgrid_uri", null)
                                val savedDatabase = saved.getString("database_uri", null)
                                val savedRecovery = saved.getString("recovery_uri", null)
                                val savedLibrary = saved.getString("folders_uri", null)
                                    ?: saved.getString("my_files_uri", null)
                                val savedDocuments = saved.getString("documents_uri", null)
                                val hasAllFilesAccess = android.os.Build.VERSION.SDK_INT < 30 ||
                                    android.os.Environment.isExternalStorageManager()
                                val savedRootDocumentId = savedRoot
                                    ?.takeIf { it.startsWith("content://") }
                                    ?.let { rootUri ->
                                        runCatching {
                                            DocumentsContract.getTreeDocumentId(Uri.parse(rootUri))
                                        }.getOrNull()
                                    }
                                    ?.replace('\\', '/')
                                    ?.lowercase()
                                    .orEmpty()
                                val savedRootIsLegacyDocsGrid =
                                    savedRootDocumentId.contains("android/media/docsgrid")
                                if (savedRoot?.startsWith("content://") == true &&
                                    savedDatabase?.startsWith("content://") == true &&
                                    savedRecovery?.startsWith("content://") == true &&
                                    savedLibrary?.startsWith("content://") == true &&
                                    !(hasAllFilesAccess && savedRootIsLegacyDocsGrid)) {
                                    val selectedLocations = mutableMapOf<String, String>(
                                        "rootUri" to savedRoot,
                                        "databaseUri" to savedDatabase,
                                        "recoveryUri" to savedRecovery,
                                        "libraryUri" to savedLibrary
                                    )
                                    if (savedDocuments?.startsWith("content://") == true) {
                                        selectedLocations["documentsUri"] = savedDocuments
                                    }
                                    // Extend an existing, user-selected portable tree in place.
                                    // All additions are idempotent; no old recovery data is moved.
                                    try {
                                        val rootUri = Uri.parse(savedRoot)
                                        val systemUri = ensureDirectory(rootUri, "System")
                                        val cacheUri = ensureDirectory(systemUri, "Cache")
                                        val pagePreviewsUri = ensureDirectory(cacheUri, "PagePreviews")
                                        val searchIndexUri = ensureDirectory(cacheUri, "SearchIndex")
                                        val folderIndexUri = ensureDirectory(cacheUri, "FolderIndex")
                                        val backupsUri = ensureDirectory(systemUri, "Backups")
                                        val fullBackupsUri = ensureDirectory(backupsUri, "Full")
                                        val databaseBackupsUri = ensureDirectory(backupsUri, "Database")
                                        val recoveryUri = Uri.parse(savedRecovery)
                                        val restoreReportsUri = ensureDirectory(recoveryUri, "Reports")
                                        val restoreCheckpointsUri = ensureDirectory(recoveryUri, "Checkpoints")
                                        selectedLocations["cacheUri"] = cacheUri.toString()
                                        selectedLocations["pagePreviewsUri"] = pagePreviewsUri.toString()
                                        selectedLocations["searchIndexUri"] = searchIndexUri.toString()
                                        selectedLocations["folderIndexUri"] = folderIndexUri.toString()
                                        selectedLocations["backupsUri"] = backupsUri.toString()
                                        selectedLocations["fullBackupsUri"] = fullBackupsUri.toString()
                                        selectedLocations["databaseBackupsUri"] = databaseBackupsUri.toString()
                                        selectedLocations["restoreReportsUri"] = restoreReportsUri.toString()
                                        selectedLocations["restoreCheckpointsUri"] = restoreCheckpointsUri.toString()
                                        saved.edit()
                                            .putString("cache_uri", cacheUri.toString())
                                            .putString("page_previews_uri", pagePreviewsUri.toString())
                                            .putString("search_index_uri", searchIndexUri.toString())
                                            .putString("folder_index_uri", folderIndexUri.toString())
                                            .putString("backups_uri", backupsUri.toString())
                                            .putString("full_backups_uri", fullBackupsUri.toString())
                                            .putString("database_backups_uri", databaseBackupsUri.toString())
                                            .putString("restore_reports_uri", restoreReportsUri.toString())
                                            .putString("restore_checkpoints_uri", restoreCheckpointsUri.toString())
                                            .apply()
                                    } catch (_: Exception) {
                                        // Older or limited SAF providers may not support all
                                        // optional subfolders. Existing core URIs remain valid.
                                    }
                                    result.success(selectedLocations)
                                    return
                                }
                                // Initialize the automatic portable tree independently of backup discovery.
                                // A fresh install must never require an old snapshot to create storage.
                                if (!hasAllFilesAccess) {
                                    throw IllegalStateException("Allow Full internal storage access in DocsGrid Settings, then retry portable storage setup.")
                                }
                                val mediaRoot = java.io.File(
                                    android.os.Environment.getExternalStorageDirectory(),
                                    "Android/media"
                                )
                                val legacyRoot = java.io.File(mediaRoot, "DocsGrid")
                                val root = java.io.File(mediaRoot, "com.docsgrid")
                                val myFiles = java.io.File(root, "My Files")
                                val unfiled = java.io.File(myFiles, "Unfiled")
                                val folders = java.io.File(myFiles, "Folders")
                                val shared = java.io.File(myFiles, "Shared")
                                val system = java.io.File(root, "System")
                                val databaseFolder = java.io.File(system, "Database")
                                val recoveryFolder = java.io.File(system, "Recovery")
                                val backupsFolder = java.io.File(system, "Backups")
                                val fullBackupsFolder = java.io.File(backupsFolder, "Full")
                                val databaseBackupsFolder = java.io.File(backupsFolder, "Database")
                                val restoreReportsFolder = java.io.File(recoveryFolder, "Reports")
                                val restoreCheckpointsFolder = java.io.File(recoveryFolder, "Checkpoints")
                                val tempFolder = java.io.File(system, "Temp")
                                val logsFolder = java.io.File(system, "Logs")
                                val exportsFolder = java.io.File(system, "Exports")
                                // Preserve the original System/Thumbnails path for existing caches.
                                val thumbnailsFolder = java.io.File(system, "Thumbnails")
                                val cacheFolder = java.io.File(system, "Cache")
                                val pagePreviewsFolder = java.io.File(cacheFolder, "PagePreviews")
                                val searchIndexFolder = java.io.File(cacheFolder, "SearchIndex")
                                val folderIndexFolder = java.io.File(cacheFolder, "FolderIndex")
                                val required = listOf(root, myFiles, unfiled, folders, shared, system,
                                    databaseFolder, recoveryFolder, backupsFolder, fullBackupsFolder,
                                    databaseBackupsFolder, restoreReportsFolder, restoreCheckpointsFolder,
                                    tempFolder, logsFolder, exportsFolder, thumbnailsFolder,
                                    cacheFolder, pagePreviewsFolder, searchIndexFolder, folderIndexFolder)
                                required.forEach { directory ->
                                    if (!directory.exists() && !directory.mkdirs() && !directory.isDirectory) {
                                        throw IllegalStateException("Could not create DocsGrid storage folder: ${directory.name}")
                                    }
                                    if (!directory.isDirectory) {
                                        throw IllegalStateException("DocsGrid storage path is not a directory: ${directory.name}")
                                    }
                                }
                                val database = Uri.fromFile(databaseFolder).toString()
                                val recovery = Uri.fromFile(recoveryFolder).toString()
                                val library = Uri.fromFile(folders).toString()
                                val documents = Uri.fromFile(unfiled).toString()
                                val prefs = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                                prefs.edit()
                                    .putString("docsgrid_uri", Uri.fromFile(root).toString())
                                    .putString("database_uri", database)
                                    .putString("recovery_uri", recovery)
                                    .putString("folders_uri", library)
                                    .putString("my_files_uri", library)
                                    .putString("documents_uri", documents)
                                    .putString("shared_uri", Uri.fromFile(shared).toString())
                                    .putString("backups_uri", Uri.fromFile(backupsFolder).toString())
                                    .putString("full_backups_uri", Uri.fromFile(fullBackupsFolder).toString())
                                    .putString("database_backups_uri", Uri.fromFile(databaseBackupsFolder).toString())
                                    .putString("restore_reports_uri", Uri.fromFile(restoreReportsFolder).toString())
                                    .putString("restore_checkpoints_uri", Uri.fromFile(restoreCheckpointsFolder).toString())
                                    .putString("cache_uri", Uri.fromFile(cacheFolder).toString())
                                    .putString("page_previews_uri", Uri.fromFile(pagePreviewsFolder).toString())
                                    .putString("search_index_uri", Uri.fromFile(searchIndexFolder).toString())
                                    .putString("folder_index_uri", Uri.fromFile(folderIndexFolder).toString())
                                    .putString("temp_uri", Uri.fromFile(tempFolder).toString())
                                    .putString("logs_uri", Uri.fromFile(logsFolder).toString())
                                    .putString("exports_uri", Uri.fromFile(exportsFolder).toString())
                                    .putString("thumbnails_uri", Uri.fromFile(thumbnailsFolder).toString())
                                    .apply()
                                result.success(mapOf(
                                    "rootUri" to Uri.fromFile(root).toString(),
                                    "legacyRootUri" to Uri.fromFile(legacyRoot).toString(),
                                    "databaseUri" to database,
                                    "recoveryUri" to recovery,
                                    "libraryUri" to library,
                                    "documentsUri" to documents,
                                    "sharedUri" to Uri.fromFile(shared).toString(),
                                    "backupsUri" to Uri.fromFile(backupsFolder).toString(),
                                    "fullBackupsUri" to Uri.fromFile(fullBackupsFolder).toString(),
                                    "databaseBackupsUri" to Uri.fromFile(databaseBackupsFolder).toString(),
                                    "restoreReportsUri" to Uri.fromFile(restoreReportsFolder).toString(),
                                    "restoreCheckpointsUri" to Uri.fromFile(restoreCheckpointsFolder).toString(),
                                    "cacheUri" to Uri.fromFile(cacheFolder).toString(),
                                    "pagePreviewsUri" to Uri.fromFile(pagePreviewsFolder).toString(),
                                    "searchIndexUri" to Uri.fromFile(searchIndexFolder).toString(),
                                    "folderIndexUri" to Uri.fromFile(folderIndexFolder).toString(),
                                    "tempUri" to Uri.fromFile(tempFolder).toString(),
                                    "logsUri" to Uri.fromFile(logsFolder).toString(),
                                    "exportsUri" to Uri.fromFile(exportsFolder).toString(),
                                    "thumbnailsUri" to Uri.fromFile(thumbnailsFolder).toString()
                                ))
                            }
                            "getSelectedFolder" -> {
                                val prefs = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                                val uri = prefs.getString("folders_uri", null) ?: prefs.getString("my_files_uri", null)
                                val hasAllFiles = android.os.Build.VERSION.SDK_INT < 30 ||
                                    android.os.Environment.isExternalStorageManager()
                                val selected = if (hasAllFiles) {
                                    Uri.fromFile(android.os.Environment.getExternalStorageDirectory()).toString()
                                } else uri
                                result.success(selected?.let {
                                    mapOf("uri" to it, "name" to if (hasAllFiles) "Internal storage" else "DocsGrid/Folders")
                                })
                            }
                            "queryPhonePdfIndex" -> result.success(queryPhonePdfIndex())
                            "getAccessibleScanRoots" -> {
                                val roots = linkedMapOf<String, Map<String, String>>()
                                val hasAllFiles = android.os.Build.VERSION.SDK_INT < 30 ||
                                    android.os.Environment.isExternalStorageManager()
                                if (hasAllFiles) {
                                    // getExternalFilesDirs exposes the app-specific directory on
                                    // each mounted shared-storage volume. Walk back to each volume
                                    // root so removable SD cards are included when Android grants
                                    // MANAGE_EXTERNAL_STORAGE.
                                    getExternalFilesDirs(null).filterNotNull().forEachIndexed { index, appDirectory ->
                                        val appPath = appDirectory.canonicalPath
                                        val marker = "/Android/data/$packageName"
                                        val markerIndex = appPath.indexOf(marker)
                                        if (markerIndex >= 0) {
                                            val volumeRoot = java.io.File(appPath.substring(0, markerIndex))
                                            if (volumeRoot.isDirectory && volumeRoot.canRead()) {
                                                val label = if (index == 0) "Internal storage" else "External storage $index"
                                                roots[volumeRoot.canonicalPath] = mapOf(
                                                    "uri" to Uri.fromFile(volumeRoot).toString(),
                                                    "name" to label
                                                )
                                            }
                                        }
                                    }
                                }
                                val prefs = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                                val docsGridRoots = listOfNotNull(
                                    prefs.getString("docsgrid_uri", null),
                                    prefs.getString("folders_uri", null),
                                    prefs.getString("my_files_uri", null),
                                    prefs.getString("documents_uri", null),
                                    prefs.getString("database_uri", null),
                                    prefs.getString("recovery_uri", null)
                                ).toSet()
                                contentResolver.persistedUriPermissions.filter { it.isReadPermission }
                                    .forEachIndexed { index, permission ->
                                        val uri = permission.uri
                                        if (uri.toString() in docsGridRoots) return@forEachIndexed
                                        // When full shared-storage access is already available, the
                                        // primary: SAF subtree is covered by the file root. Keep
                                        // non-primary/removable SAF roots as independent locations.
                                        if (hasAllFiles) {
                                            val treeId = try { DocumentsContract.getTreeDocumentId(uri) } catch (_: Exception) { "" }
                                            if (treeId.startsWith("primary:")) return@forEachIndexed
                                        }
                                        roots.putIfAbsent(uri.toString(), mapOf("uri" to uri.toString(), "name" to "Granted folder ${index + 1}"))
                                    }
                                result.success(roots.values.toList())
                            }
                            "consumeSharedPdfs" -> result.success(consumeSharedPdfs(incomingShareIntent))
                            "checkStorageAccess" -> result.success(checkStorageAccess())
                            "hasAllFilesAccess" -> result.success(
                                android.os.Build.VERSION.SDK_INT < 30 ||
                                    android.os.Environment.isExternalStorageManager()
                            )
                            "getStorageUsage" -> {
                                val stats = android.os.StatFs(
                                    android.os.Environment.getExternalStorageDirectory().absolutePath
                                )
                                val totalBytes = stats.totalBytes.coerceAtLeast(0L)
                                val availableBytes = stats.availableBytes.coerceIn(0L, totalBytes)
                                result.success(mapOf(
                                    "totalBytes" to totalBytes,
                                    "availableBytes" to availableBytes,
                                    "usedBytes" to (totalBytes - availableBytes)
                                ))
                            }
                            "requestAllFilesAccess" -> {
                                if (android.os.Build.VERSION.SDK_INT < 30 ||
                                    android.os.Environment.isExternalStorageManager()) {
                                    result.success(true)
                                } else {
                                    val settingsIntent = Intent(
                                        android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                        Uri.parse("package:$packageName")
                                    )
                                    startActivity(settingsIntent)
                                    result.success(false)
                                }
                            }
                            "savePdf" -> {
                                val tree = Uri.parse(call.argument<String>("treeUri")!!)
                                val name = call.argument<String>("name")!!
                                val bytes = call.argument<ByteArray>("bytes")!!
                                result.success((if (tree.scheme == "file") createFilePdf(tree, name, bytes) else createPdf(tree, name, bytes)).toString())
                            }
                            "createDirectory" -> {
                                val parent = Uri.parse(call.argument<String>("parentUri")!!)
                                val name = call.argument<String>("name")!!
                                result.success((if (parent.scheme == "file") createFileDirectory(parent, name) else createDirectory(parent, name)).toString())
                            }
                            "copyPdf" -> {
                                val source = Uri.parse(call.argument<String>("sourceUri")!!)
                                val parent = Uri.parse(call.argument<String>("parentUri")!!)
                                val name = call.argument<String>("name")!!
                                result.success((if (parent.scheme == "file") copyFilePdf(source, parent, name) else copyPdf(source, parent, name)).toString())
                            }
                            "copyFileToStorage" -> {
                                val sourcePath = call.argument<String>("sourcePath")!!
                                val parent = Uri.parse(call.argument<String>("parentUri")!!)
                                val name = call.argument<String>("name")!!
                                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                                result.success(copyPrivateFileToStorage(sourcePath, parent, name, mimeType).toString())
                            }
                            "copyStorageFileToPath" -> {
                                val source = Uri.parse(call.argument<String>("sourceUri")!!)
                                val destinationPath = call.argument<String>("destinationPath")!!
                                result.success(copyStorageFileToPrivatePath(source, destinationPath))
                            }
                            "copyPdfToPath" -> {
                                val source = Uri.parse(call.argument<String>("sourceUri")!!)
                                val destinationPath = call.argument<String>("destinationPath")!!
                                val destination = java.io.File(destinationPath)
                                val parent = destination.parentFile
                                    ?: throw IllegalArgumentException("Destination folder is invalid.")
                                if (!parent.exists() && !parent.mkdirs()) {
                                    throw IllegalStateException("Could not create the destination folder.")
                                }
                                if (destination.exists()) {
                                    throw IllegalStateException("The destination file already exists.")
                                }
                                val temporary = java.io.File(parent, ".docsgrid-copy-${java.util.UUID.randomUUID()}.tmp")
                                try {
                                    val sourceDigest = digest(source)
                                    contentResolver.openInputStream(source)?.use { input ->
                                        temporary.outputStream().buffered().use { output ->
                                            input.copyTo(output, 64 * 1024)
                                            output.flush()
                                        }
                                    } ?: throw IllegalStateException("Could not read the source PDF.")
                                    if (!sourceDigest.contentEquals(digest(Uri.fromFile(temporary)))) {
                                        throw IllegalStateException("The temporary PDF copy failed SHA-256 verification.")
                                    }
                                    if (destination.exists() || !temporary.renameTo(destination)) {
                                        throw IllegalStateException("Could not safely publish the copied PDF.")
                                    }
                                } finally {
                                    if (temporary.exists()) temporary.delete()
                                }
                                result.success(true)
                            }
                            "sha256Pdf" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                result.success(digest(uri).joinToString("") { "%02x".format(it) })
                            }
                            "writeTextFile" -> {
                                val parent = Uri.parse(call.argument<String>("parentUri")!!)
                                val name = call.argument<String>("name")!!
                                val contents = call.argument<String>("contents")!!
                                result.success((if (parent.scheme == "file") writeFileText(parent, name, contents) else writeTextFile(parent, name, contents)).toString())
                            }
                            "readTextFile" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val bytes = if (uri.scheme == "file") {
                                    fileForUri(uri).readBytes()
                                } else {
                                    contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                        ?: throw IllegalStateException("Could not read metadata file.")
                                }
                                result.success(String(bytes, Charsets.UTF_8))
                            }
                            "listDirectory" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                result.success(if (uri.scheme == "file") listFileDirectory(uri) else listDirectory(uri))
                            }
                            "readPdf" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val bytes = if (uri.scheme == "file") {
                                    fileForUri(uri).readBytes()
                                } else {
                                    contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                        ?: throw IllegalStateException("Could not read the selected PDF.")
                                }
                                result.success(bytes)
                            }
                            "findChildUri" -> {
                                val parent = Uri.parse(call.argument<String>("parentUri")!!)
                                val name = call.argument<String>("name")!!
                                result.success((if (parent.scheme == "file") findFileChild(parent, name) else findChildUri(parent, name)).toString())
                            }
                            "renamePdf" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val name = call.argument<String>("name")!!
                                val renamed = if (uri.scheme == "file") {
                                    val source = fileForUri(uri)
                                    validateLeafName(name)
                                    val target = java.io.File(source.parentFile, name)
                                    if (target.exists() || !source.renameTo(target)) {
                                        throw IllegalStateException("Android could not rename this PDF.")
                                    }
                                    Uri.fromFile(target)
                                } else {
                                    DocumentsContract.renameDocument(contentResolver, uri, name)
                                        ?: throw IllegalStateException("Android could not rename this PDF.")
                                }
                                result.success(renamed.toString())
                            }
                            "deletePdf" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                if (uri.scheme == "file") {
                                val target = fileForUri(uri)
                                if (target.isDirectory && target.listFiles()?.isNotEmpty() == true) {
                                    throw IllegalStateException("Folder contains files or subfolders and cannot be deleted.")
                                }
                                result.success(target.delete())
                            } else {
                                if (uri.authority == "media") {
                                    // MediaStore item URIs are not SAF document URIs.
                                    result.success(contentResolver.delete(uri, null, null) > 0)
                                } else {
                                    val documentUri = resolveParentUri(uri)
                                    val metadata = contentResolver.query(
                                        documentUri, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
                                        null, null, null
                                    ) ?: throw IllegalStateException("Could not inspect the selected storage item.")
                                    val mime = metadata.use { if (it.moveToFirst()) it.getString(0) else null }
                                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                        val documentId = DocumentsContract.getDocumentId(documentUri)
                                        val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, documentId)
                                        val cursor = contentResolver.query(
                                            children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                                            null, null, null
                                        ) ?: throw IllegalStateException("Could not verify whether the folder is empty.")
                                        cursor.use {
                                            if (it.moveToFirst()) {
                                                throw IllegalStateException("Folder contains files or subfolders and cannot be deleted.")
                                            }
                                        }
                                    }
                                    result.success(DocumentsContract.deleteDocument(contentResolver, uri))
                                }
                            }
                            }
                            "openPdf" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/pdf")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                startActivity(Intent.createChooser(intent, "Open PDF"))
                                result.success(true)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (error: MissingStorageChildException) {
                        result.error("NOT_FOUND", error.message ?: "The requested child does not exist.", null)
                    } catch (error: Exception) {
                        result.error("STORAGE_ERROR", error.message ?: "Storage operation failed.", null)
                    }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onDestroy() {
        storageExecutor.shutdown()
        super.onDestroy()
    }

    private fun consumeSharedPdfs(incomingIntent: Intent? = intent): List<Map<String, String>> {
        val incoming = incomingIntent ?: return emptyList()
        val uris = linkedSetOf<Uri>()
        if (incoming.action == Intent.ACTION_SEND) {
            val single = if (android.os.Build.VERSION.SDK_INT >= 33) {
                incoming.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                incoming.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            }
            if (single != null) uris.add(single)
        } else if (incoming.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            val many = incoming.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            many?.let { uris.addAll(it) }
        }
        incoming.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let { uris.add(it) }
        }
        val output = mutableListOf<Map<String, String>>()
        val shareDir = java.io.File(cacheDir, "incoming_docs").apply { mkdirs() }
        // These files are only hand-off copies. Remove leftovers from a prior
        // interrupted share/import before staging the current incoming items.
        shareDir.listFiles()?.forEach { stale -> try { stale.delete() } catch (_: Exception) {} }
        uris.forEachIndexed { index, uri ->
            try {
                val mime = contentResolver.getType(uri)
                var displayName: String? = null
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (column >= 0) displayName = cursor.getString(column)
                    }
                }
                val name = displayName ?: "Shared_Document_${index + 1}.pdf"
                if (mime != "application/pdf" && !name.lowercase().endsWith(".pdf")) return@forEachIndexed
                val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "_")
                val target = java.io.File(shareDir, "${System.currentTimeMillis()}_$safe")
                contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().buffered().use { outputStream -> input.copyTo(outputStream, 64 * 1024) }
                } ?: return@forEachIndexed
                val validPdf = target.inputStream().use { input ->
                    val header = ByteArray(5)
                    input.read(header) == 5 && String(header) == "%PDF-"
                }
                if (validPdf) output.add(mapOf("path" to target.absolutePath, "name" to name))
                else target.delete()
            } catch (_: Exception) { }
        }
        return output
    }

    private fun checkStorageAccess(): Map<String, String> {
        val saved = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
            .getString("tree_uri", null)
            ?: return mapOf("status" to "not_configured", "message" to "No external folder has been selected. App-private storage is available.")
        val uri = Uri.parse(saved)
        val grant = contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (grant == null) {
            return mapOf("status" to "revoked", "message" to "Android no longer has the saved folder permission. Select the folder again to restore access.")
        }
        return try {
            contentResolver.query(
                DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri)),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    mapOf("status" to "available", "message" to "Saved folder permission is active.")
                } else {
                    mapOf("status" to "revoked", "message" to "The selected folder is no longer available. Select it again.")
                }
            } ?: mapOf("status" to "revoked", "message" to "The selected storage provider did not respond. Re-select the folder.")
        } catch (_: Exception) {
            mapOf("status" to "revoked", "message" to "Folder access failed. Select the folder again; existing PDF records will be preserved.")
        }
    }

    private fun sharedStorageVolumeRoots(): List<java.io.File> {
        val marker = "/Android/data/$packageName"
        val roots = getExternalFilesDirs(null).filterNotNull().mapNotNull { appDirectory ->
            try {
                val path = appDirectory.canonicalPath
                val markerIndex = path.indexOf(marker)
                if (markerIndex < 0) null
                else java.io.File(path.substring(0, markerIndex)).canonicalFile
            } catch (_: Exception) {
                null
            }
        }.toMutableList()
        // Include mounted shared volumes even when an OEM omits the app-specific
        // Android/data path from getExternalFilesDirs().
        try {
            roots.add(android.os.Environment.getExternalStorageDirectory().canonicalFile)
        } catch (_: Exception) {}
        if (android.os.Build.VERSION.SDK_INT >= 24) {
            try {
                val manager = getSystemService(android.os.storage.StorageManager::class.java)
                manager.storageVolumes.mapNotNull { volume ->
                    try { volume.directory?.canonicalFile } catch (_: Exception) { null }
                }.forEach { roots.add(it) }
            } catch (_: Exception) {}
        }
        return roots.distinctBy { it.path }
    }

    private fun appPrivateStorageRoots(): List<java.io.File> {
        val roots = mutableListOf(filesDir, cacheDir, codeCacheDir, noBackupFilesDir)
        externalCacheDir?.let { roots.add(it) }
        getExternalFilesDirs(null).filterNotNull().forEach { roots.add(it) }
        return roots.mapNotNull { directory ->
            try { directory.canonicalFile } catch (_: Exception) { null }
        }
    }

    private fun fileForUri(uri: Uri, allowAppPrivate: Boolean = false): java.io.File {
        if (uri.scheme != "file") throw IllegalArgumentException("Expected a local file URI.")
        val file = java.io.File(uri.path ?: throw IllegalArgumentException("Invalid file URI."))
        val canonical = file.canonicalFile
        val separator = java.io.File.separator
        if (allowAppPrivate) {
            val isAppPrivate = appPrivateStorageRoots().any { root ->
                canonical.path == root.path || canonical.path.startsWith(root.path + separator)
            }
            if (isAppPrivate) return canonical
        }
        if (android.os.Build.VERSION.SDK_INT >= 30 &&
            !android.os.Environment.isExternalStorageManager()) {
            throw SecurityException("Allow Full internal storage access in DocsGrid Settings.")
        }
        val allowed = sharedStorageVolumeRoots().any { root ->
            canonical.path == root.path || canonical.path.startsWith(root.path + separator)
        }
        if (!allowed) {
            throw SecurityException("DocsGrid file access is limited to Android shared-storage volumes.")
        }
        return canonical
    }

    private fun listFileDirectory(uri: Uri): List<Map<String, Any>> {
        val directory = fileForUri(uri)
        if (!directory.exists()) throw java.io.FileNotFoundException("Missing directory: ${directory.path}")
        if (!directory.isDirectory) throw IllegalStateException("The selected storage item is not a folder.")
        // Do not disguise inaccessible directories as empty.
        val children = directory.listFiles()
            ?: throw SecurityException("Android could not enumerate this directory: ${directory.name}")
        return children.sortedBy { it.name.lowercase() }.map { child ->
            mapOf(
                "name" to child.name,
                "uri" to Uri.fromFile(child).toString(),
                "isDirectory" to child.isDirectory,
                "size" to if (child.isFile) child.length() else 0L,
                "sizeKnown" to (!child.isFile || child.length() >= 0L),
                "lastModified" to child.lastModified()
            )
        }
    }

    private fun createFilePdf(parent: Uri, requestedName: String, bytes: ByteArray): Uri {
        validateLeafName(requestedName)
        val directory = fileForUri(parent)
        val base = requestedName.removeSuffix(".pdf")
        var candidate = "$base.pdf"
        var suffix = 1
        while (java.io.File(directory, candidate).exists()) {
            candidate = "$base ($suffix).pdf"
            suffix++
        }
        val target = java.io.File(directory, candidate)
        target.outputStream().buffered().use { it.write(bytes); it.flush() }
        if (!target.isFile || target.length() != bytes.size.toLong()) {
            target.delete()
            throw IllegalStateException("Could not verify the saved PDF.")
        }
        return Uri.fromFile(target)
    }

    private fun copyFilePdf(source: Uri, parent: Uri, requestedName: String): Uri {
        validateLeafName(requestedName)
        // The picker may stage the source under this app's private cache.
        // Permit that path for reading only; the destination remains restricted
        // to an approved shared-storage volume.
        val sourceFile = fileForUri(source, allowAppPrivate = true)
        val destinationFolder = fileForUri(parent)
        val base = requestedName.removeSuffix(".pdf")
        var candidate = "$base.pdf"
        var suffix = 1
        while (java.io.File(destinationFolder, candidate).exists()) {
            candidate = "$base ($suffix).pdf"
            suffix++
        }
        val destination = java.io.File(destinationFolder, candidate)
        val temporary = java.io.File(destinationFolder, ".docsgrid-${java.util.UUID.randomUUID()}.tmp")
        try {
            sourceFile.inputStream().buffered().use { input ->
                temporary.outputStream().buffered().use { output -> input.copyTo(output, 64 * 1024); output.flush() }
            }
            if (!digest(Uri.fromFile(sourceFile), allowAppPrivateFile = true)
                    .contentEquals(digest(Uri.fromFile(temporary))) ||
                !temporary.renameTo(destination)) {
                throw IllegalStateException("PDF copy verification or publish failed.")
            }
            return Uri.fromFile(destination)
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun writeFileText(parent: Uri, name: String, contents: String): Uri {
        validateLeafName(name)
        val target = java.io.File(fileForUri(parent), name)
        val temporary = java.io.File(target.parentFile, ".$name.tmp-${java.util.UUID.randomUUID()}")
        try {
            val bytes = contents.toByteArray(Charsets.UTF_8)
            temporary.writeBytes(bytes)
            if (!bytes.contentEquals(temporary.readBytes()) || !temporary.renameTo(target)) {
                throw IllegalStateException("Could not safely publish metadata file.")
            }
            return Uri.fromFile(target)
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun findFileChild(parent: Uri, name: String): Uri {
        validateLeafName(name)
        val child = java.io.File(fileForUri(parent), name)
        if (!child.exists()) throw MissingStorageChildException("Could not find '$name'.")
        return Uri.fromFile(child)
    }

    private fun createFileDirectory(parent: Uri, name: String): Uri {
        validateLeafName(name)
        val directory = java.io.File(fileForUri(parent), name)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create folder in internal storage.")
        }
        if (!directory.isDirectory) throw IllegalStateException("A file with this folder name already exists.")
        return Uri.fromFile(directory)
    }

    private fun resolveParentUri(uri: Uri): Uri {
        return try {
            val documentId = DocumentsContract.getDocumentId(uri)
            DocumentsContract.buildDocumentUriUsingTree(uri, documentId)
        } catch (_: IllegalArgumentException) {
            try {
                val treeId = DocumentsContract.getTreeDocumentId(uri)
                DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
            } catch (_: IllegalArgumentException) {
                uri
            }
        }
    }

    private fun ensureDirectory(parentUri: Uri, name: String): Uri {
        return try {
            findChildUri(parentUri, name)
        } catch (_: MissingStorageChildException) {
            createDirectory(parentUri, name)
        }
    }

    private fun validateLeafName(name: String) {
        require(name.isNotBlank() && name != "." && name != ".." &&
            '/' !in name && '\\' !in name && '\u0000' !in name) {
            "Invalid file or folder name."
        }
    }

    private fun createDirectory(parentUri: Uri, name: String): Uri {
        validateLeafName(name)
        try {
            findChildUri(parentUri, name)
            throw IllegalStateException("A folder with this name already exists in the selected storage location.")
        } catch (_: MissingStorageChildException) {
            // Only an explicit missing-child result permits creation.
        }
        return DocumentsContract.createDocument(
            contentResolver, resolveParentUri(parentUri),
            DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw IllegalStateException("Could not create folder in the selected storage location.")
    }

    private fun findChildUri(parentUri: Uri, name: String): Uri {
        val parent = resolveParentUri(parentUri)
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, parentId)
        val cursor = contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        ) ?: throw IllegalStateException("The storage provider could not list this folder.")
        cursor.use {
            val idIndex = it.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = it.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            if (idIndex < 0 || nameIndex < 0) {
                throw IllegalStateException("The storage provider returned incomplete folder metadata.")
            }
            while (it.moveToNext()) {
                if (it.getString(nameIndex) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(parentUri, it.getString(idIndex))
                }
            }
        }
        throw MissingStorageChildException("Could not find '$name' inside the selected folder.")
    }

    private fun listDirectory(directoryUri: Uri): List<Map<String, Any>> {
        val parent = resolveParentUri(directoryUri)
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(directoryUri, parentId)
        val output = mutableListOf<Map<String, Any>>()
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED
            ),
            null, null, null
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                if (idIndex < 0 || nameIndex < 0 || mimeIndex < 0) continue
                val id = cursor.getString(idIndex)
                val mime = cursor.getString(mimeIndex)
                output.add(mapOf(
                    "name" to cursor.getString(nameIndex),
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(directoryUri, id).toString(),
                    "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                    "size" to if (sizeIndex >= 0 && !cursor.isNull(sizeIndex) && cursor.getLong(sizeIndex) >= 0L) cursor.getLong(sizeIndex) else 0L,
                    "sizeKnown" to (sizeIndex >= 0 && !cursor.isNull(sizeIndex) && cursor.getLong(sizeIndex) >= 0L),
                    "lastModified" to if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) cursor.getLong(modifiedIndex) else 0L
                ))
            }
        } ?: throw IllegalStateException("The storage provider could not list this folder.")
        return output
    }

    private fun writeTextFile(parentUri: Uri, name: String, contents: String): Uri {
        require(!name.contains("/") && !name.contains("\\") && name.isNotBlank()) {
            "Invalid metadata filename."
        }
        val parent = resolveParentUri(parentUri)
        val existing = try { findChildUri(parentUri, name) } catch (_: Exception) { null }
        val tempName = ".$name.tmp-${java.util.UUID.randomUUID()}"
        val temp = DocumentsContract.createDocument(
            contentResolver, parent, "application/json", tempName
        ) ?: throw IllegalStateException("Could not create temporary metadata file.")
        try {
            val bytes = contents.toByteArray(Charsets.UTF_8)
            contentResolver.openOutputStream(temp, "w")?.use { it.write(bytes); it.flush() }
                ?: throw IllegalStateException("Could not write metadata file.")
            val check = contentResolver.openInputStream(temp)?.use { it.readBytes() }
                ?: throw IllegalStateException("Could not verify metadata file.")
            if (!bytes.contentEquals(check)) throw IllegalStateException("Metadata verification failed.")
            var previousBackup: Uri? = null
            var published = false
            try {
                if (existing != null) {
                    previousBackup = DocumentsContract.renameDocument(
                        contentResolver, existing,
                        ".$name.previous-${java.util.UUID.randomUUID()}"
                    ) ?: throw IllegalStateException("Could not safely stage the previous metadata snapshot.")
                }
                val result = DocumentsContract.renameDocument(contentResolver, temp, name)
                    ?: throw IllegalStateException("Could not publish metadata file.")
                published = true
                if (previousBackup != null) {
                    // The new snapshot is already published and verified. A
                    // cleanup failure must not roll it back or risk old data.
                    try { DocumentsContract.deleteDocument(contentResolver, previousBackup) }
                    catch (_: Exception) {}
                }
                return result
            } catch (error: Exception) {
                if (!published && previousBackup != null) {
                    try {
                        DocumentsContract.renameDocument(contentResolver, previousBackup, name)
                    } catch (_: Exception) {
                        throw IllegalStateException(
                            "Snapshot publication failed and the previous snapshot remains under its recovery filename.",
                            error
                        )
                    }
                }
                throw error
            }
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(contentResolver, temp) } catch (_: Exception) {}
            throw error
        }
    }

    private fun openPdfSource(uri: Uri, allowAppPrivateFile: Boolean = false): java.io.InputStream? {
        return if (uri.scheme == "file") {
            fileForUri(uri, allowAppPrivate = allowAppPrivateFile).inputStream()
        } else {
            contentResolver.openInputStream(uri)
        }
    }

    private fun isInsideAppPrivateStorage(file: java.io.File): Boolean {
        val canonical = file.canonicalFile
        val separator = java.io.File.separator
        return appPrivateStorageRoots().any { root ->
            canonical.path == root.path || canonical.path.startsWith(root.path + separator)
        }
    }

    private fun fileSha256(file: java.io.File): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                md.update(buffer, 0, count)
            }
        }
        return md.digest()
    }

    /// Copies an app-private staged archive to selected SAF storage and verifies it
    /// before publishing the final name.
    private fun copyPrivateFileToStorage(
        sourcePath: String,
        parentUri: Uri,
        name: String,
        mimeType: String
    ): Uri {
        validateLeafName(name)
        val source = java.io.File(sourcePath).canonicalFile
        if (!source.isFile || !isInsideAppPrivateStorage(source)) {
            throw SecurityException("DocsGrid can only publish an app-staged file to selected storage.")
        }
        if (parentUri.scheme == "file") {
            val directory = fileForUri(parentUri)
            if (!directory.isDirectory) throw IllegalStateException("The selected destination is not a folder.")
            val destination = java.io.File(directory, name)
            if (destination.exists()) throw IllegalStateException("A file with this name already exists.")
            val temporary = java.io.File(directory, ".$name.tmp-${java.util.UUID.randomUUID()}")
            try {
                source.inputStream().buffered().use { input ->
                    temporary.outputStream().buffered().use { output ->
                        input.copyTo(output, 64 * 1024)
                        output.flush()
                    }
                }
                if (!fileSha256(source).contentEquals(fileSha256(temporary))) {
                    throw IllegalStateException("Backup copy failed SHA-256 verification.")
                }
                if (destination.exists() || !temporary.renameTo(destination)) {
                    throw IllegalStateException("Could not safely publish the copied file.")
                }
                return Uri.fromFile(destination)
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }

        val parent = resolveParentUri(parentUri)
        val temporaryName = ".$name.tmp-${java.util.UUID.randomUUID()}"
        val temporary = DocumentsContract.createDocument(
            contentResolver, parent, mimeType, temporaryName
        ) ?: throw IllegalStateException("Could not create a temporary file in the selected folder.")
        var published = false
        try {
            source.inputStream().buffered().use { input ->
                contentResolver.openOutputStream(temporary, "w")?.buffered()?.use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.flush()
                } ?: throw IllegalStateException("Could not write the selected-storage file.")
            }
            if (!fileSha256(source).contentEquals(digest(temporary))) {
                throw IllegalStateException("Selected-storage copy failed SHA-256 verification.")
            }
            val finalUri = DocumentsContract.renameDocument(
                contentResolver, temporary, name
            ) ?: throw IllegalStateException("Could not publish the verified file in the selected folder.")
            published = true
            return finalUri
        } finally {
            if (!published) {
                try { DocumentsContract.deleteDocument(contentResolver, temporary) }
                catch (_: Exception) {}
            }
        }
    }

    /// Stages a selected SAF file into app-private storage for ZIP validation.
    private fun copyStorageFileToPrivatePath(sourceUri: Uri, destinationPath: String): Boolean {
        val destination = java.io.File(destinationPath).canonicalFile
        val parent = destination.parentFile
            ?: throw IllegalArgumentException("Destination path is invalid.")
        if (!isInsideAppPrivateStorage(parent)) {
            throw SecurityException("DocsGrid can only stage selected files inside its private storage.")
        }
        if (!parent.exists() && !parent.mkdirs()) {
            throw IllegalStateException("Could not create the temporary staging folder.")
        }
        if (destination.exists()) {
            throw IllegalStateException("The temporary staging file already exists.")
        }
        val temporary = java.io.File(parent, ".docsgrid-stage-${java.util.UUID.randomUUID()}.tmp")
        try {
            val sourceDigest = digest(sourceUri)
            contentResolver.openInputStream(sourceUri)?.buffered()?.use { input ->
                temporary.outputStream().buffered().use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.flush()
                }
            } ?: throw IllegalStateException("Could not read the selected storage file.")
            if (!sourceDigest.contentEquals(fileSha256(temporary))) {
                throw IllegalStateException("The staged file failed SHA-256 verification.")
            }
            if (destination.exists() || !temporary.renameTo(destination)) {
                throw IllegalStateException("Could not safely publish the staged file.")
            }
            return true
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun digest(uri: Uri, allowAppPrivateFile: Boolean = false): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        val inputStream = openPdfSource(uri, allowAppPrivateFile)
            ?: throw IllegalStateException("Could not read PDF for verification.")
        inputStream.use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                md.update(buffer, 0, count)
            }
        }
        return md.digest()
    }

    // Copy and verify without deleting the source. Dart updates SQLite first,
    // then explicitly deletes the source after the metadata transaction commits.
    private fun copyPdf(source: Uri, parentUri: Uri, name: String): Uri {
        validateLeafName(name)
        val parent = resolveParentUri(parentUri)
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, parentId)
        val existing = mutableSetOf<String>()
        contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        )?.use { cursor ->
            val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) if (index >= 0) existing.add(cursor.getString(index))
        }
        val base = name.removeSuffix(".pdf")
        var candidate = "$base.pdf"
        var suffix = 1
        while (existing.contains(candidate)) {
            candidate = "$base ($suffix).pdf"
            suffix++
        }
        val destination = DocumentsContract.createDocument(
            contentResolver, parent, "application/pdf", candidate
        ) ?: throw IllegalStateException("Could not create the destination PDF.")
        try {
            openPdfSource(source, allowAppPrivateFile = true)?.use { input ->
                contentResolver.openOutputStream(destination, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: throw IllegalStateException("Could not write the destination PDF.")
            } ?: throw IllegalStateException("Could not read the source PDF.")
            if (!digest(source, allowAppPrivateFile = true).contentEquals(digest(destination))) {
                throw IllegalStateException("PDF verification failed; both source and destination were retained.")
            }
            return destination
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(contentResolver, destination) } catch (_: Exception) {}
            throw error
        }
    }

    private fun createPdf(treeUri: Uri, requestedName: String, bytes: ByteArray): Uri {
        validateLeafName(requestedName)
        val parent = resolveParentUri(treeUri)
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val existing = mutableSetOf<String>()
        contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                while (cursor.moveToNext()) if (index >= 0) existing.add(cursor.getString(index))
            }
        val base = requestedName.removeSuffix(".pdf")
        var candidate = "$base.pdf"
        var suffix = 1
        while (existing.contains(candidate)) {
            candidate = "$base ($suffix).pdf"
            suffix++
        }
        val created = DocumentsContract.createDocument(contentResolver, parent, "application/pdf", candidate)
            ?: throw IllegalStateException("Could not create the PDF in the selected folder.")
        try {
            contentResolver.openOutputStream(created, "w")!!.use { it.write(bytes) }
            val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
            if (!expected.contentEquals(digest(created))) {
                throw IllegalStateException("Saved PDF verification failed.")
            }
        } catch (error: Exception) {
            DocumentsContract.deleteDocument(contentResolver, created)
            throw error
        }
        return created
    }

    @Deprecated("Deprecated in Android API; retained for broad device compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestChooseFolder) return
        val callback = pendingFolderResult
        pendingFolderResult = null
        val recoveryOnly = pendingRecoverySelection
        pendingRecoverySelection = false
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            callback?.success(null)
            return
        }
        val uri = data.data!!
        val requiredFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val flags = data.flags and requiredFlags
        if (flags != requiredFlags) {
            callback?.error("PERMISSION", "The selected folder did not grant both read and write access.", null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            callback?.error("PERMISSION", "Could not retain folder access.", null)
            return
        }
        try {
            val selectedRoot = DocumentsContract.buildDocumentUriUsingTree(
                uri, DocumentsContract.getTreeDocumentId(uri)
            )
            if (recoveryOnly) {
                val selectedName = contentResolver.query(
                    selectedRoot,
                    arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                    null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                        if (index >= 0) cursor.getString(index) else null
                    } else null
                } ?: throw IllegalStateException("Could not read the selected folder name.")
                // Accept both the current Android/media/com.docsgrid layout and
                // older user-selected DocsGrid trees. When the parent is selected,
                // prefer the current canonical root and fall back to the legacy name.
                val docsGrid = if (
                    selectedName.equals("DocsGrid", ignoreCase = true) ||
                    selectedName.equals("com.docsgrid", ignoreCase = true)
                ) {
                    selectedRoot
                } else {
                    try {
                        findChildUri(uri, "com.docsgrid")
                    } catch (_: MissingStorageChildException) {
                        findChildUri(uri, "DocsGrid")
                    }
                }

                // Recovery selection is read/validate-only: never create folders
                // that could make an empty tree look like a recoverable backup.
                val canonicalMyFiles = try {
                    findChildUri(docsGrid, "My Files")
                } catch (_: MissingStorageChildException) {
                    null
                }
                val canonicalSystem = try {
                    findChildUri(docsGrid, "System")
                } catch (_: MissingStorageChildException) {
                    null
                }
                if ((canonicalMyFiles == null) != (canonicalSystem == null)) {
                    throw IllegalStateException("The selected DocsGrid folder has an incomplete My Files/System layout.")
                }
                val isCanonicalLayout = canonicalMyFiles != null && canonicalSystem != null
                val documents = if (isCanonicalLayout) {
                    findChildUri(canonicalMyFiles!!, "Unfiled")
                } else {
                    findChildUri(docsGrid, "Documents")
                }
                val folders = if (isCanonicalLayout) {
                    findChildUri(canonicalMyFiles!!, "Folders")
                } else {
                    findChildUri(docsGrid, "Folders")
                }
                val database = if (isCanonicalLayout) {
                    findChildUri(canonicalSystem!!, "Database")
                } else {
                    findChildUri(docsGrid, "Database")
                }
                val recovery = if (isCanonicalLayout) {
                    findChildUri(canonicalSystem!!, "Recovery")
                } else {
                    findChildUri(docsGrid, "Recovery")
                }
                val snapshots = listDirectory(database).filter {
                    it["isDirectory"] == true &&
                        (it["name"] as? String)?.startsWith("snapshot_") == true
                }
                if (snapshots.isEmpty()) {
                    throw IllegalStateException("The selected DocsGrid/System/Database (or legacy DocsGrid/Database) folder contains no recovery snapshots.")
                }
                getSharedPreferences("docsgrid_storage", MODE_PRIVATE).edit()
                    .putString("tree_uri", uri.toString())
                    .putString("docsgrid_uri", docsGrid.toString())
                    .putString("documents_uri", documents.toString())
                    .putString("folders_uri", folders.toString())
                    .putString("my_files_uri", folders.toString())
                    .putString("database_uri", database.toString())
                    .putString("recovery_uri", recovery.toString())
                    .apply()
                callback?.success(mapOf("uri" to docsGrid.toString(), "name" to "DocsGrid", "rootUri" to docsGrid.toString()))
                return
            }
            // Reuse the selected DocsGrid directory when the user selected it
            // directly. Previously this always created DocsGrid/DocsGrid, which
            // made Recovery point at a new empty tree instead of the existing data.
            // Reuse selectedRoot declared above; both recovery and normal
            // library setup refer to the same selected SAF tree.
            val selectedName = contentResolver.query(
                selectedRoot,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    if (index >= 0) cursor.getString(index) else null
                } else null
            }
            val docsGrid = if (selectedName.equals("DocsGrid", ignoreCase = true)) {
                selectedRoot
            } else {
                ensureDirectory(uri, "DocsGrid")
            }
            // Canonical portable layout; legacy folders remain untouched for migration.
            val documents = ensureDirectory(docsGrid, "Documents")
            val folders = ensureDirectory(docsGrid, "Folders")
            val database = ensureDirectory(docsGrid, "Database")
            val recovery = ensureDirectory(docsGrid, "Recovery")
            getSharedPreferences("docsgrid_storage", MODE_PRIVATE).edit()
                .putString("tree_uri", uri.toString())
                .putString("docsgrid_uri", docsGrid.toString())
                .putString("documents_uri", documents.toString())
                .putString("folders_uri", folders.toString())
                .putString("my_files_uri", folders.toString())
                .putString("database_uri", database.toString())
                .putString("recovery_uri", recovery.toString())
                .apply()
            callback?.success(mapOf("uri" to folders.toString(), "name" to "DocsGrid/Folders", "rootUri" to docsGrid.toString()))
        } catch (error: Exception) {
            callback?.error("LAYOUT_ERROR", "Could not prepare DocsGrid folders. Existing data was not changed: " + error.message, null)
        }
    }
}
