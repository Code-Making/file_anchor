package com.codemaking.file_anchor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The Android side of `file_anchor`.
 *
 * Two things here are easy to get wrong and worth stating plainly.
 *
 * First, the durable grant is taken inside [onActivityResult]. Taken any later
 * -- in a `then`, on the next frame, after a hop to a background thread -- it is
 * gone when the process dies, and the anchor silently stops working on the next
 * cold start.
 *
 * Second, a plugin cannot use `registerForActivityResult`: that needs an
 * `ActivityResultCaller`, which only the host Activity or Fragment is. The
 * framework-sanctioned equivalent is
 * [ActivityPluginBinding.addActivityResultListener], which is the host Activity
 * forwarding its own result. Same guarantees, different entry point.
 */
class FileAnchorPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    private companion object {
        const val CHANNEL = "com.codemaking.file_anchor/methods"
        const val RC_PICK_TREE = 0xFA01
        const val RC_PICK_FILE = 0xFA02

        val ASYNC_METHODS = setOf(
            "resolve", "release", "releaseUnused",
            "exists", "stat", "delete", "createFile", "createDirectory",
            "beginList", "listNext", "endList",
            "beginRead", "readChunk", "endRead",
            "beginWrite", "writeChunk", "endWrite",
        )
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var store: SafStore

    private val sessions = SessionRegistry()
    private val main = Handler(Looper.getMainLooper())

    /**
     * A single worker, on purpose.
     *
     * Serialising native work keeps chunk ordering correct and session state
     * race-free without locks. Each call moves at most one 64 KiB chunk, so
     * queueing behind another call is cheap.
     */
    private var io: ExecutorService = Executors.newSingleThreadExecutor()

    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null

    // ------------------------------------------------------------- lifecycle

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        store = SafStore(context)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // Abandon anything still open rather than leaking a file descriptor.
        for (session in sessions.clear()) {
            when (session) {
                is ListSession -> session.close()
                is ReadSession -> session.close()
                is WriteSession -> session.abort()
            }
        }
        io.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        // A picker cannot survive losing its Activity; fail rather than hang.
        pendingPick?.error(
            ErrorCodes.UNSUPPORTED,
            "The Activity went away while the picker was open.",
            null,
        )
        pendingPick = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // --------------------------------------------------------------- dispatch

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Pickers must start on the main thread and finish in a callback,
            // so they do not go through the worker.
            "pickDirectory" -> beginPick(result, tree = true)
            "pickFile" -> beginPick(result, tree = false, mimeTypes = call.argument("mimeTypes"))
            in ASYNC_METHODS -> runAsync(result) { dispatch(call) }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: AnchorException) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Throwable) {
                // Nothing uncategorised may reach Dart as a bare platform
                // error, so everything left becomes an I/O failure.
                main.post { result.error(ErrorCodes.IO, e.message ?: e.toString(), null) }
            }
        }
    }

    private fun dispatch(call: MethodCall): Any? = when (call.method) {
        "resolve" -> store.describe(uriArg(call))

        "release" -> {
            store.release(uriArg(call))
            null
        }

        "releaseUnused" ->
            store.releaseUnused((call.argument<List<String>>("keep") ?: emptyList()).toSet())

        "exists" -> store.exists(uriArg(call), call.argument("relativePath"))

        "stat" -> statMap(store.resolveRow(uriArg(call), call.argument("relativePath")))

        "delete" -> {
            store.delete(uriArg(call), call.argument("relativePath"))
            null
        }

        "createFile" -> {
            val path = pathArg(call)
            entryMap(path, store.createFile(uriArg(call), path, call.argument("mimeType")))
        }

        "createDirectory" -> {
            val path = pathArg(call)
            val segments = SafStore.splitPath(path)
            entryMap(segments.joinToString("/"), store.ensureDirectory(uriArg(call), segments))
        }

        "beginList" -> sessions.add(
            ListSession(store, uriArg(call), call.argument<Boolean>("recursive") ?: false),
        )

        "listNext" -> {
            val batch = call.argument<Int>("batch") ?: 128
            val (entries, done) = sessions.require<ListSession>(sessionArg(call)).next(batch)
            mapOf("entries" to entries, "done" to done)
        }

        "endList" -> {
            (sessions.remove(sessionArg(call)) as? ListSession)?.close()
            null
        }

        "beginRead" -> beginRead(call)

        "readChunk" -> sessions
            .require<ReadSession>(sessionArg(call))
            .read(call.argument<Int>("size") ?: (64 * 1024))

        "endRead" -> {
            (sessions.remove(sessionArg(call)) as? ReadSession)?.close()
            null
        }

        "beginWrite" -> beginWrite(call)

        "writeChunk" -> {
            val bytes = call.argument<ByteArray>("bytes")
                ?: throw AnchorException(ErrorCodes.IO, "writeChunk needs bytes.")
            sessions.require<WriteSession>(sessionArg(call)).write(bytes)
            null
        }

        "endWrite" -> endWrite(call)

        else -> throw AnchorException(ErrorCodes.UNSUPPORTED, "Unknown method ${call.method}.")
    }

    // ---------------------------------------------------------------- picking

    /**
     * Starts the system picker.
     *
     * The `purpose` argument is accepted and ignored here: Android's document
     * picker shows no caller-supplied prompt, and inventing a dialog to carry
     * one would be a worse experience than the platform's own UI. iOS uses it.
     */
    private fun beginPick(
        result: MethodChannel.Result,
        tree: Boolean,
        mimeTypes: List<String>? = null,
    ) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error(
                ErrorCodes.UNSUPPORTED,
                "A picker needs an Activity, and none is attached.",
                null,
            )
            return
        }
        if (pendingPick != null) {
            result.error(
                ErrorCodes.UNSUPPORTED,
                "A picker is already open; await the first one.",
                null,
            )
            return
        }

        val intent = if (tree) {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                if (!mimeTypes.isNullOrEmpty()) {
                    putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
                }
            }
        }
        // FLAG_GRANT_PERSISTABLE_URI_PERMISSION belongs on the *request*. Without
        // it the returned grant cannot be persisted at all, no matter what is
        // done afterwards.
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )

        pendingPick = result
        try {
            activity.startActivityForResult(intent, if (tree) RC_PICK_TREE else RC_PICK_FILE)
        } catch (e: Exception) {
            pendingPick = null
            result.error(
                ErrorCodes.UNSUPPORTED,
                "This device has no document provider to handle the picker.",
                null,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != RC_PICK_TREE && requestCode != RC_PICK_FILE) return false
        val result = pendingPick ?: return true
        pendingPick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // Cancellation is not an error.
            result.success(null)
            return true
        }

        try {
            // Here, and nowhere later. See the class comment.
            store.takePersistableAccess(uri)
            assertSelectable(uri)
            result.success(store.describe(uri))
        } catch (e: AnchorException) {
            result.error(e.code, e.message, null)
        } catch (e: Throwable) {
            result.error(ErrorCodes.IO, e.message ?: e.toString(), null)
        }
        return true
    }

    /**
     * Rejects locations Android refuses to expose through a document tree.
     *
     * Android 11 blocked selecting the Download root and `Android/data` and
     * `Android/obb`. The system picker normally prevents it in the UI, but OEM
     * providers vary, and a clear error now beats operations failing later for
     * no visible reason.
     */
    private fun assertSelectable(uri: Uri) {
        if (!SafStore.isTreeUri(uri)) return
        val documentId = DocumentsContract.getTreeDocumentId(uri)
        val blocked = documentId.endsWith(":Download") ||
            documentId.contains("Android/data") ||
            documentId.contains("Android/obb")
        if (blocked) {
            throw AnchorException(
                ErrorCodes.UNSUPPORTED,
                "Android does not allow anchoring \"$documentId\". Ask the user for a " +
                    "different folder, such as one inside Documents.",
            )
        }
    }

    // ------------------------------------------------------------------ bytes

    private fun beginRead(call: MethodCall): Int {
        val stream = store.openInput(uriArg(call), call.argument("relativePath"))
        val start = call.argument<Number>("start")?.toLong()
        val end = call.argument<Number>("end")?.toLong()

        if (start != null && start > 0) {
            var skipped = 0L
            while (skipped < start) {
                val moved = stream.skip(start - skipped)
                // skip() may legitimately return 0; stop rather than spin.
                if (moved <= 0L) break
                skipped += moved
            }
        }
        val remaining = end?.let { (it - (start ?: 0L)).coerceAtLeast(0L) }
        return sessions.add(ReadSession(stream, remaining))
    }

    private fun beginWrite(call: MethodCall): Int {
        val (stream, target, createdHere) = store.openOutput(
            uriArg(call),
            pathArg(call),
            call.argument<Boolean>("append") ?: false,
        )
        return sessions.add(
            WriteSession(stream, target, createdHere, context.contentResolver),
        )
    }

    private fun endWrite(call: MethodCall): Any? {
        val id = sessionArg(call)
        val commit = call.argument<Boolean>("commit") ?: true
        val session = sessions.remove(id) as? WriteSession
            ?: throw AnchorException(ErrorCodes.IO, "Write session $id is not open.")
        if (commit) session.commit() else session.abort()
        return null
    }

    // ---------------------------------------------------------------- helpers

    private fun uriArg(call: MethodCall): Uri {
        val raw = call.argument<String>("uri")
            ?: throw AnchorException(ErrorCodes.MALFORMED_TOKEN, "No uri was supplied.")
        return Uri.parse(raw)
    }

    private fun pathArg(call: MethodCall): String =
        call.argument<String>("relativePath")
            ?: throw AnchorException(ErrorCodes.IO, "No relativePath was supplied.")

    private fun sessionArg(call: MethodCall): Int =
        call.argument<Int>("session")
            ?: throw AnchorException(ErrorCodes.IO, "No session id was supplied.")

    private fun entryMap(relativePath: String, row: DocRow): Map<String, Any?> = mapOf(
        "relativePath" to relativePath,
        "isDirectory" to row.isDirectory,
        "size" to row.size,
        "modified" to row.lastModified,
        "mimeType" to row.mimeType,
    )

    private fun statMap(row: DocRow): Map<String, Any?> = mapOf(
        "isDirectory" to row.isDirectory,
        "size" to row.size,
        "modified" to row.lastModified,
        "mimeType" to row.mimeType,
    )
}
