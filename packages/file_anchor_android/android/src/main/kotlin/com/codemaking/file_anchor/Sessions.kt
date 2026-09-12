package com.codemaking.file_anchor

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import java.io.InputStream
import java.io.OutputStream

/**
 * A paged directory walk.
 *
 * Holds an open cursor between calls so that one provider query serves many
 * entries. A breadth-first queue handles recursion, which keeps memory bounded
 * even for a tree with tens of thousands of files.
 */
internal class ListSession(
    private val store: SafStore,
    private val anchorUri: Uri,
    private val recursive: Boolean,
) {
    private data class Pending(val documentId: String, val prefix: String)

    private val queue = ArrayDeque<Pending>()
    private var cursor: Cursor? = null
    private var currentPrefix: String = ""
    private var singleEmitted = false

    init {
        if (SafStore.isTreeUri(anchorUri)) {
            queue.add(Pending(DocumentsContract.getTreeDocumentId(anchorUri), ""))
        }
    }

    /** Returns up to [batch] entries, plus whether the walk is finished. */
    fun next(batch: Int): Pair<List<Map<String, Any?>>, Boolean> {
        val out = ArrayList<Map<String, Any?>>()

        // A single-file anchor lists exactly itself.
        if (!SafStore.isTreeUri(anchorUri)) {
            if (!singleEmitted) {
                singleEmitted = true
                val row = store.resolveRow(anchorUri, null)
                out.add(entryMap(row.displayName ?: "", row))
            }
            return out to true
        }

        while (out.size < batch) {
            val open = cursor
            if (open == null) {
                val pending = queue.removeFirstOrNull() ?: break
                currentPrefix = pending.prefix
                cursor = store.queryChildren(anchorUri, pending.documentId)
                continue
            }
            if (!open.moveToNext()) {
                open.close()
                cursor = null
                continue
            }
            val row = store.rowFromCursor(open)
            val name = row.displayName ?: continue
            val relative = if (currentPrefix.isEmpty()) name else "$currentPrefix/$name"
            // Subdirectories are only enqueued when recursing, so a
            // non-recursive walk naturally stops at the root level.
            if (row.isDirectory && recursive) {
                queue.add(Pending(row.documentId, relative))
            }
            out.add(entryMap(relative, row))
        }

        return out to (cursor == null && queue.isEmpty())
    }

    fun close() {
        cursor?.let { runCatching { it.close() } }
        cursor = null
        queue.clear()
    }

    private fun entryMap(relative: String, row: DocRow): Map<String, Any?> = mapOf(
        "relativePath" to relative,
        "isDirectory" to row.isDirectory,
        "size" to row.size,
        "modified" to row.lastModified,
        "mimeType" to row.mimeType,
    )
}

/** A byte read in progress, optionally limited to a range. */
internal class ReadSession(private val stream: InputStream, private var remaining: Long?) {

    /** Reads up to [size] bytes; an empty result means end of stream. */
    fun read(size: Int): ByteArray {
        val limit = remaining?.let { minOf(size.toLong(), it).toInt() } ?: size
        if (limit <= 0) return ByteArray(0)
        val buffer = ByteArray(limit)
        var filled = 0
        // InputStream.read may return short; loop so a full chunk crosses the
        // channel rather than many tiny ones.
        while (filled < limit) {
            val read = stream.read(buffer, filled, limit - filled)
            if (read <= 0) break
            filled += read
        }
        remaining = remaining?.minus(filled.toLong())
        return if (filled == limit) buffer else buffer.copyOf(filled)
    }

    fun close() {
        runCatching { stream.close() }
    }
}

/** A byte write in progress. */
internal class WriteSession(
    private val stream: OutputStream,
    private val documentUri: Uri,
    private val createdHere: Boolean,
    private val resolver: ContentResolver,
) {
    fun write(bytes: ByteArray) {
        stream.write(bytes)
    }

    fun commit() {
        stream.flush()
        stream.close()
    }

    /**
     * Abandons the write.
     *
     * A document created by this session is deleted, so a failed write leaves
     * nothing behind. A pre-existing document cannot be restored: the Storage
     * Access Framework has no truncation rollback, and pretending otherwise
     * would be worse than saying so.
     */
    fun abort() {
        runCatching { stream.close() }
        if (createdHere) {
            runCatching { DocumentsContract.deleteDocument(resolver, documentUri) }
        }
    }
}

/** Hands out integer handles for stateful native sessions. */
internal class SessionRegistry {
    private val sessions = HashMap<Int, Any>()
    private var nextId = 1

    fun add(session: Any): Int = synchronized(this) {
        val id = nextId++
        sessions[id] = session
        id
    }

    inline fun <reified T : Any> require(id: Int): T {
        val session = peek(id)
            ?: throw AnchorException(
                ErrorCodes.IO,
                "Session $id is not open; it was closed or never created.",
            )
        return session as? T ?: throw AnchorException(
            ErrorCodes.IO,
            "Session $id is a ${session.javaClass.simpleName}, not a ${T::class.simpleName}.",
        )
    }

    fun remove(id: Int): Any? = synchronized(this) { sessions.remove(id) }

    fun clear(): List<Any> = synchronized(this) {
        val open = sessions.values.toList()
        sessions.clear()
        open
    }

    @PublishedApi
    internal fun peek(id: Int): Any? = synchronized(this) { sessions[id] }
}
