package com.wweiyi.expert_chat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Receives ACTION_SEND / ACTION_SEND_MULTIPLE and holds one pending payload
 * until Dart takes it. Dart is only signalled ("shareAvailable"); it always
 * pulls with "takeShare", so cold starts and early warm shares cannot be lost
 * before the Dart handler exists.
 */
class SharedIntake(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    // All fields below are only touched on the main thread.
    private var pending: Map<String, Any?>? = null
    private var processing = 0
    private var delivered = 0
    private val waiters = mutableListOf<MethodChannel.Result>()

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeShare" -> take(result)
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        waiters.forEach { it.success(null) }
        waiters.clear()
    }

    /** Returns true when [intent] was a share this class will deliver. */
    fun handle(intent: Intent?): Boolean {
        if (intent == null || !isShare(intent)) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        val text = sharedText(intent)
        val uris = sharedUris(intent)
        if (text.isEmpty() && uris.isEmpty()) return false
        val generation = ++processing
        io.execute {
            val payload = try {
                buildPayload(text, uris)
            } catch (error: Exception) {
                Log.w(TAG, "share intake failed", error)
                mapOf("text" to text, "files" to emptyList<Any>(), "unreadable" to uris.size)
            }
            main.post { deliver(generation, payload) }
        }
        return true
    }

    private fun take(result: MethodChannel.Result) {
        if (pending == null && processing > delivered) {
            waiters.add(result)
            return
        }
        result.success(pending)
        pending = null
    }

    private fun deliver(generation: Int, payload: Map<String, Any?>) {
        delivered = generation
        // A newer share replaces an older one that is still being copied.
        if (generation != processing) return
        if (waiters.isNotEmpty()) {
            waiters.removeAt(0).success(payload)
            waiters.forEach { it.success(null) }
            waiters.clear()
            return
        }
        pending = payload
        channel?.invokeMethod("shareAvailable", null)
    }

    private fun isShare(intent: Intent) =
        intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE

    private fun sharedText(intent: Intent): String {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
        return when {
            subject.isEmpty() || text.contains(subject) -> text
            text.isEmpty() -> subject
            else -> "$subject\n$text"
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            return list.orEmpty().filterNotNull()
        }
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        return listOfNotNull(uri)
    }

    /** Runs on [io]: copies content:// streams into a private cache folder. */
    private fun buildPayload(text: String, uris: List<Uri>): Map<String, Any?> {
        val dir = File(context.cacheDir, "shared_intake")
        dir.deleteRecursively()
        dir.mkdirs()
        val files = mutableListOf<Map<String, Any?>>()
        var tooLarge = 0
        var tooMany = 0
        var unreadable = 0
        for ((index, uri) in uris.withIndex()) {
            if (files.size >= MAX_FILES) {
                tooMany++
                continue
            }
            try {
                val (name, reportedSize) = describe(uri, index)
                if (reportedSize != null && reportedSize > MAX_BYTES) {
                    tooLarge++
                    continue
                }
                val target = File(dir, "$index-$name")
                val copied = copyCapped(uri, target)
                if (copied == null) {
                    target.delete()
                    tooLarge++
                    continue
                }
                files.add(mapOf("path" to target.absolutePath, "name" to name, "size" to copied))
            } catch (error: Exception) {
                Log.w(TAG, "cannot read shared uri", error)
                unreadable++
            }
        }
        return mapOf(
            "text" to text,
            "files" to files,
            "tooLarge" to tooLarge,
            "tooMany" to tooMany,
            "unreadable" to unreadable,
        )
    }

    private fun describe(uri: Uri, index: Int): Pair<String, Long?> {
        var name: String? = null
        var size: Long? = null
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            }
        }
        var safe = (name ?: uri.lastPathSegment ?: "shared-$index")
            .replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_")
            .take(120)
            .ifBlank { "shared-$index" }
        // Gallery URIs often have no extension; Dart routes files by extension.
        if (!safe.contains('.')) {
            val ext = context.contentResolver.getType(uri)
                ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            if (!ext.isNullOrBlank()) safe = "$safe.$ext"
        }
        return safe to size
    }

    /** Returns bytes copied, or null when the stream exceeds [MAX_BYTES]. */
    private fun copyCapped(uri: Uri, target: File): Long? {
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("no input stream")
        input.use { source ->
            target.outputStream().use { sink ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) return total
                    total += read
                    if (total > MAX_BYTES) return null
                    sink.write(buffer, 0, read)
                }
            }
        }
    }

    companion object {
        private const val TAG = "SharedIntake"

        // Mirrors AttachmentIngestor.maxAttachments / maxAttachmentBytes.
        private const val MAX_FILES = 8
        private const val MAX_BYTES = 10L * 1024 * 1024
    }
}
