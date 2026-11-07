package com.docsgrid.docs_grid

import android.app.Activity
import android.content.Intent
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
                        "getSelectedFolder" -> {
                            val uri = getSharedPreferences("docsgrid_storage", MODE_PRIVATE)
                                .getString("tree_uri", null)
                            result.success(uri?.let { mapOf("uri" to it, "name" to "Selected folder") })
                        }
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
                            destination.parentFile?.mkdirs()
                            contentResolver.openInputStream(source)?.use { input ->
                                destination.outputStream().buffered().use { output ->
                                    input.copyTo(output, 64 * 1024)
                                    output.flush()
                                }
                            } ?: throw IllegalStateException("Could not read the source PDF.")
                            result.success(true)
                        }
                        "sha256Pdf" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            result.success(digest(uri).joinToString("") { "%02x".format(it) })
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
        val flags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            callback?.error("PERMISSION", "Could not retain folder access.", null)
            return
        }
        getSharedPreferences("docsgrid_storage", MODE_PRIVATE).edit()
            .putString("tree_uri", uri.toString()).apply()
        callback?.success(mapOf("uri" to uri.toString(), "name" to "Selected folder"))
    }
}
