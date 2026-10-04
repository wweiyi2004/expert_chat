package com.wweiyi.expert_chat

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/** SAF preserves the selected directory URI instead of guessing a filesystem
 * path. Listing reads metadata only; confirmed files use bounded read streams. */
class UploadDirectory(private val activity: Activity) {
    companion object {
        const val REQUEST_CODE = 0xEC42
        private const val MAX_BYTES = 10 * 1024 * 1024
    }

    private val resolver get() = activity.contentResolver
    private val prefs get() = activity.getSharedPreferences("upload_directory", Activity.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var executor = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var choosing: MethodChannel.Result? = null
    private var transientRoot: Uri? = null

    fun attach(value: MethodChannel) {
        if (executor.isShutdown) executor = Executors.newSingleThreadExecutor()
        channel = value
        value.setMethodCallHandler { call, result ->
            when (call.method) {
                "choose" -> {
                    if (choosing != null) {
                        result.error("directory_busy", "请先完成当前目录选择", null)
                        return@setMethodCallHandler
                    }
                    choosing = result
                    try {
                        activity.startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                            },
                            REQUEST_CODE,
                        )
                    } catch (error: Exception) {
                        choosing = null
                        result.error("directory_picker_failed", "无法打开目录选择器", null)
                    }
                }
                "restore" -> work(result) {
                    val saved = prefs.getString("root", null)
                    if (saved == null) null else {
                        val root = Uri.parse(saved)
                        if (!isGranted(root)) {
                            prefs.edit().remove("root").apply()
                            null
                        } else snapshot(root, documentUri(root))
                    }
                }
                "list" -> work(result) {
                    val root = root(call.argument<String>("root"))
                    val node = node(root, call.argument<String>("uri"))
                    snapshot(root, node)
                }
                "read" -> work(result) {
                    val root = root(call.argument<String>("root"))
                    val node = node(root, call.argument<String>("uri"))
                    val output = ByteArrayOutputStream()
                    resolver.openInputStream(node)?.use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (Thread.currentThread().isInterrupted) throw IOException("读取已取消")
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > MAX_BYTES) throw IOException("文件超过 10 MB 限制")
                            output.write(buffer, 0, count)
                        }
                    } ?: throw IOException("无法读取所选文件")
                    output.toByteArray()
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = choosing ?: return true
        choosing = null
        val selected = data?.data
        if (resultCode != Activity.RESULT_OK || selected == null) {
            result.success(null)
            return true
        }
        transientRoot = selected
        work(result) {
            val flags = ((data?.flags ?: 0) and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            try {
                if (flags != 0) resolver.takePersistableUriPermission(selected, flags)
            } catch (_: SecurityException) {
                // Some providers grant access only for this Activity session.
            }
            val listed = snapshot(root(selected.toString()), documentUri(selected))
            if (isPersistentlyGranted(selected)) prefs.edit().putString("root", selected.toString()).apply()
            listed
        }
        return true
    }

    private fun isPersistentlyGranted(uri: Uri): Boolean =
        resolver.persistedUriPermissions.any { it.isReadPermission && it.uri == uri }

    private fun isGranted(uri: Uri): Boolean = transientRoot == uri || isPersistentlyGranted(uri)

    private fun root(value: String?): Uri {
        val root = value?.let(Uri::parse) ?: throw IOException("请重新选择目录")
        if (root.scheme != "content" || !DocumentsContract.isTreeUri(root) || !isGranted(root)) {
            throw SecurityException("目录授权已失效，请重新选择")
        }
        return root
    }

    private fun documentUri(root: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(
        root, DocumentsContract.getTreeDocumentId(root),
    )

    private fun node(root: Uri, value: String?): Uri {
        val uri = value?.let(Uri::parse) ?: throw IOException("请选择文件或目录")
        if (uri.authority != root.authority ||
            !DocumentsContract.isTreeUri(uri) ||
            DocumentsContract.getTreeDocumentId(uri) != DocumentsContract.getTreeDocumentId(root)
        ) throw SecurityException("文件不在所选目录内")
        // DocumentsProvider enforces that the document belongs to this tree.
        return DocumentsContract.buildDocumentUriUsingTree(root, DocumentsContract.getDocumentId(uri))
    }

    private fun snapshot(root: Uri, current: Uri): Map<String, Any> {
        val fields = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        var name = "所选目录"
        resolver.query(current, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0) ?: name
        }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            root, DocumentsContract.getDocumentId(current),
        )
        val entries = mutableListOf<Map<String, Any>>()
        val cursor = resolver.query(children, fields, null, null, null)
            ?: throw IOException("无法读取所选目录")
        cursor.use {
            while (it.moveToNext()) {
                if (Thread.currentThread().isInterrupted) throw IOException("读取已取消")
                val id = it.getString(0) ?: continue
                val displayName = it.getString(1) ?: continue
                val mime = it.getString(2) ?: ""
                entries.add(mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(root, id).toString(),
                    "name" to displayName,
                    "mimeType" to mime,
                    "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                    "sizeBytes" to if (it.isNull(3)) 0L else it.getLong(3),
                    "modifiedAt" to if (it.isNull(4)) 0L else it.getLong(4),
                ))
            }
        }
        return mapOf("root" to root.toString(), "uri" to current.toString(), "name" to name, "entries" to entries)
    }

    private fun work(result: MethodChannel.Result, action: () -> Any?) {
        executor.execute {
            try {
                val value = action()
                main.post { if (channel != null) result.success(value) }
            } catch (error: Exception) {
                val message = when (error) {
                    is SecurityException -> "目录授权已失效，请重新选择"
                    else -> error.message ?: "无法读取所选目录或文件"
                }
                main.post { if (channel != null) result.error("directory_read_failed", message, null) }
            }
        }
    }

    fun detach() {
        choosing?.error("directory_cancelled", "目录选择已取消", null)
        choosing = null
        channel?.setMethodCallHandler(null)
        channel = null
        executor.shutdownNow()
    }
}
