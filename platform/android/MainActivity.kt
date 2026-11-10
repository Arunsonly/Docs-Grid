package com.docsgrid.docs_grid

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

private class MissingStorageChildException(message: String) : IllegalStateException(message)

class MainActivity : FlutterActivity() {
    private val storageExecutor = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(64))
    private val mainHandler = Handler(Looper.getMainLooper())
    private val channelName = "docsgrid/storage"
    private val requestChooseFolder = 4817
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingRecoverySelection = false

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
                                if (savedRoot?.startsWith("content://") == true &&
                                    savedDatabase?.startsWith("content://") == true &&
                                    savedRecovery?.startsWith("content://") == true &&
                                    savedLibrary?.startsWith("content://") == true) {
                                    val selectedLocations = mutableMapOf<String, String>(
                                        "rootUri" to savedRoot,
                                        "databaseUri" to savedDatabase,
                                        "recoveryUri" to savedRecovery,
                                        "libraryUri" to savedLibrary
                                    )
                                    if (savedDocuments?.startsWith("content://") == true) {
                                        selectedLocations["documentsUri"] = savedDocuments
                                    }
                                    result.success(selectedLocations)
                                    return
                                }
                                // Initialize the automatic portable tree independently of backup discovery.
                                // A fresh install must never require an old snapshot to create storage.
                                if (android.os.Build.VERSION.SDK_INT >= 30 &&
                                    !android.os.Environment.isExternalStorageManager()) {
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
                                val tempFolder = java.io.File(system, "Temp")
                                val logsFolder = java.io.File(system, "Logs")
                                val exportsFolder = java.io.File(system, "Exports")
                                val thumbnailsFolder = java.io.File(system, "Thumbnails")
                                val required = listOf(root, myFiles, unfiled, folders, shared, system,
                                    databaseFolder, recoveryFolder, backupsFolder, tempFolder,
                                    logsFolder, exportsFolder, thumbnailsFolder)
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

    private fun fileForUri(uri: Uri): java.io.File {
        if (uri.scheme != "file") throw IllegalArgumentException("Expected a local file URI.")
        if (android.os.Build.VERSION.SDK_INT >= 30 &&
            !android.os.Environment.isExternalStorageManager()) {
            throw SecurityException("Allow Full internal storage access in DocsGrid Settings.")
        }
        val file = java.io.File(uri.path ?: throw IllegalArgumentException("Invalid file URI."))
        val root = android.os.Environment.getExternalStorageDirectory().canonicalFile
        val canonical = file.canonicalFile
        if (canonical.path != root.path && !canonical.path.startsWith(root.path + java.io.File.separator)) {
            throw SecurityException("DocsGrid file access is limited to shared internal storage.")
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
                "size" to if (child.isFile) child.length() else 0L
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
        val sourceFile = fileForUri(source)
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
            if (!digest(Uri.fromFile(sourceFile)).contentEquals(digest(Uri.fromFile(temporary))) ||
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
                DocumentsContract.Document.COLUMN_SIZE
            ),
            null, null, null
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            while (cursor.moveToNext()) {
                if (idIndex < 0 || nameIndex < 0 || mimeIndex < 0) continue
                val id = cursor.getString(idIndex)
                val mime = cursor.getString(mimeIndex)
                output.add(mapOf(
                    "name" to cursor.getString(nameIndex),
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(directoryUri, id).toString(),
                    "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                    "size" to if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else 0L
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

    private fun digest(uri: Uri): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        val inputStream = if (uri.scheme == "file") {
            fileForUri(uri).inputStream()
        } else {
            contentResolver.openInputStream(uri)
        } ?: throw IllegalStateException("Could not read PDF for verification.")
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
            contentResolver.openInputStream(source)?.use { input ->
                contentResolver.openOutputStream(destination, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: throw IllegalStateException("Could not write the destination PDF.")
            } ?: throw IllegalStateException("Could not read the source PDF.")
            if (!digest(source).contentEquals(digest(destination))) {
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
                val docsGrid = if (selectedName.equals("DocsGrid", ignoreCase = true)) {
                    selectedRoot
                } else {
                    findChildUri(uri, "DocsGrid")
                }
                // Recovery selection is read/validate-only: never create a new
                // DocsGrid tree that could masquerade as a recoverable backup.
                val documents = findChildUri(docsGrid, "Documents")
                val folders = findChildUri(docsGrid, "Folders")
                val database = findChildUri(docsGrid, "Database")
                val recovery = findChildUri(docsGrid, "Recovery")
                val snapshots = listDirectory(database).filter {
                    it["isDirectory"] == true && (it["name"] as? String)?.startsWith("snapshot_") == true
                }
                if (snapshots.isEmpty()) {
                    throw IllegalStateException("The existing DocsGrid/Database folder contains no recovery snapshots.")
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
