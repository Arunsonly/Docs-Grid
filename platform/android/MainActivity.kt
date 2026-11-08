package com.docsgrid.docs_grid

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "docsgrid/storage"
    private val requestChooseFolder = 4817
    private var pendingFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "chooseFolder" -> {
                            if (pendingFolderResult != null) {
                                result.error("BUSY", "Folder picker is already open.", null)
                            } else {
                                pendingFolderResult = result
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
                            val prefs = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                            val database = prefs.getString("database_uri", null)
                                ?: throw IllegalStateException("DocsGrid Database folder is not configured. Re-select the library folder.")
                            val recovery = prefs.getString("recovery_uri", null)
                                ?: throw IllegalStateException("DocsGrid Recovery folder is not configured. Re-select the library folder.")
                            val library = prefs.getString("folders_uri", null)
                                ?: prefs.getString("my_files_uri", null)
                                ?: throw IllegalStateException("DocsGrid Folders location is not configured. Re-select the library folder.")
                            val documents = prefs.getString("documents_uri", null)
                                ?: throw IllegalStateException("DocsGrid Documents location is not configured. Re-select the library folder.")
                            result.success(mapOf("databaseUri" to database, "recoveryUri" to recovery, "libraryUri" to library, "documentsUri" to documents))
                        }
                        "getSelectedFolder" -> {
                            val prefs = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                            val uri = prefs.getString("folders_uri", null) ?: prefs.getString("my_files_uri", null)
                            result.success(uri?.let { mapOf("uri" to it, "name" to "DocsGrid/Folders") })
                        }
                        "consumeSharedPdfs" -> result.success(consumeSharedPdfs())
                        "checkStorageAccess" -> result.success(checkStorageAccess())
                        "savePdf" -> {
                            val tree = Uri.parse(call.argument<String>("treeUri")!!)
                            val name = call.argument<String>("name")!!
                            val bytes = call.argument<ByteArray>("bytes")!!
                            result.success(createPdf(tree, name, bytes).toString())
                        }
                        "createDirectory" -> {
                            val parent = Uri.parse(call.argument<String>("parentUri")!!)
                            val name = call.argument<String>("name")!!
                            result.success(createDirectory(parent, name).toString())
                        }
                        "copyPdf" -> {
                            val source = Uri.parse(call.argument<String>("sourceUri")!!)
                            val parent = Uri.parse(call.argument<String>("parentUri")!!)
                            val name = call.argument<String>("name")!!
                            result.success(copyPdf(source, parent, name).toString())
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
                            result.success(writeTextFile(parent, name, contents).toString())
                        }
                        "readTextFile" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                ?: throw IllegalStateException("Could not read metadata file.")
                            result.success(String(bytes, Charsets.UTF_8))
                        }
                        "listDirectory" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            result.success(listDirectory(uri))
                        }
                        "readPdf" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                ?: throw IllegalStateException("Could not read the selected PDF.")
                            result.success(bytes)
                        }
                        "findChildUri" -> {
                            val parent = Uri.parse(call.argument<String>("parentUri")!!)
                            val name = call.argument<String>("name")!!
                            result.success(findChildUri(parent, name).toString())
                        }
                        "renamePdf" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            val name = call.argument<String>("name")!!
                            val renamed = DocumentsContract.renameDocument(contentResolver, uri, name)
                                ?: throw IllegalStateException("Android could not rename this PDF.")
                            result.success(renamed.toString())
                        }
                        "deletePdf" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            result.success(DocumentsContract.deleteDocument(contentResolver, uri))
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
                } catch (error: Exception) {
                    result.error("STORAGE_ERROR", error.message ?: "Storage operation failed.", null)
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun consumeSharedPdfs(): List<Map<String, String>> {
        val incoming = intent ?: return emptyList()
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
        setIntent(Intent())
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
        } catch (_: Exception) {
            createDirectory(parentUri, name)
        }
    }

    private fun createDirectory(parentUri: Uri, name: String): Uri {
        return DocumentsContract.createDocument(
            contentResolver, resolveParentUri(parentUri),
            DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw IllegalStateException("Could not create folder in the selected storage location.")
    }

    private fun findChildUri(parentUri: Uri, name: String): Uri {
        val parent = resolveParentUri(parentUri)
        val parentId = DocumentsContract.getDocumentId(parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, parentId)
        contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                if (idIndex >= 0 && nameIndex >= 0 && cursor.getString(nameIndex) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(parentUri, cursor.getString(idIndex))
                }
            }
        }
        throw IllegalStateException("Could not find '$name' inside the selected folder.")
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
        contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                md.update(buffer, 0, count)
            }
        } ?: throw IllegalStateException("Could not read PDF for verification.")
        return md.digest()
    }

    // Copy and verify without deleting the source. Dart updates SQLite first,
    // then explicitly deletes the source after the metadata transaction commits.
    private fun copyPdf(source: Uri, parentUri: Uri, name: String): Uri {
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
            // Create or reconnect the app's shared folder layout using SAF.
            val docsGrid = ensureDirectory(uri, "DocsGrid")
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
