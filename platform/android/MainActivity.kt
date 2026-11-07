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
                        "movePdf" -> {
                            val source = Uri.parse(call.argument<String>("sourceUri")!!)
                            val parent = Uri.parse(call.argument<String>("parentUri")!!)
                            val name = call.argument<String>("name")!!
                            result.success(movePdf(source, parent, name).toString())
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
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
        } catch (_: IllegalArgumentException) {
            uri
        }
    }

    private fun createDirectory(parentUri: Uri, name: String): Uri {
        return DocumentsContract.createDocument(
            contentResolver, resolveParentUri(parentUri),
            DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw IllegalStateException("Could not create folder in the selected storage location.")
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

    private fun movePdf(source: Uri, parentUri: Uri, name: String): Uri {
        val destination = DocumentsContract.createDocument(
            contentResolver, resolveParentUri(parentUri), "application/pdf", name
        ) ?: throw IllegalStateException("Could not create the destination PDF.")
        try {
            contentResolver.openInputStream(source)?.use { input ->
                contentResolver.openOutputStream(destination, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: throw IllegalStateException("Could not write the destination PDF.")
            } ?: throw IllegalStateException("Could not read the source PDF.")
            if (!digest(source).contentEquals(digest(destination))) {
                throw IllegalStateException("PDF verification failed; original file was kept.")
            }
            if (!DocumentsContract.deleteDocument(contentResolver, source)) {
                throw IllegalStateException("Verified copy created, but original could not be removed. Both files were kept.")
            }
            return destination
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(contentResolver, destination) } catch (_: Exception) {}
            throw error
        }
    }

    private fun createPdf(treeUri: Uri, requestedName: String, bytes: ByteArray): Uri {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeId)
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
