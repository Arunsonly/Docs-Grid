package com.docsgrid.docs_grid

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
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
