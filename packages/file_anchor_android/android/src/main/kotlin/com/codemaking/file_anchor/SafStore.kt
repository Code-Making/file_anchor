package com.codemaking.file_anchor

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream

/** One row of document metadata. */
internal data class DocRow(
    val documentId: String,
    val displayName: String?,
    val mimeType: String?,
    val size: Long?,
    val lastModified: Long?,
    val flags: Int,
) {
    val isDirectory: Boolean
        get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

    val canRename: Boolean
        get() = flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0
}

/**
 * Every Storage Access Framework operation the plugin needs.
 *
 * Deliberately built on [DocumentsContract] rather than `androidx.documentfile`.
 * DocumentFile issues a separate query per file, which is the single biggest
 * reason hand-rolled SAF traversal feels slow; querying children in bulk is the
 * whole performance story here. It also avoids a dependency.
 */
internal class SafStore(private val context: Context) {

    private val resolver: ContentResolver
        get() = context.contentResolver

    companion object {
        const val PERSISTABLE_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        /**
         * Guard rail below the platform's persisted-grant cap.
         *
         * Android allows roughly 128 persisted URI grants per app (512 on newer
         * releases) and, crucially, **silently evicts the oldest** past that
         * limit rather than throwing. Silent eviction means a long-lived app
         * would lose old anchors with no signal at all, so refuse proactively
         * and let the caller reap orphans instead.
         */
        const val PERSISTED_GRANT_SOFT_LIMIT = 120

        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )

        /**
         * Whether [uri] is a document *tree*.
         *
         * Hand-rolled rather than `DocumentsContract.isTreeUri`, which is API 24
         * while the rest of what we need is API 21. Same check the framework
         * makes.
         */
        fun isTreeUri(uri: Uri): Boolean {
            val segments = uri.pathSegments
            return segments.size >= 2 && segments[0] == "tree"
        }

        /** Splits a relative path, rejecting attempts to escape the anchor. */
        fun splitPath(relativePath: String?): List<String> {
            if (relativePath.isNullOrBlank()) return emptyList()
            val segments = relativePath.split('/', '\\').filter { it.isNotEmpty() }
            if (segments.any { it == ".." }) {
                throw AnchorException(
                    ErrorCodes.UNSUPPORTED,
                    "A relative path may not contain \"..\"; an anchor is a boundary.",
                )
            }
            return segments.filter { it != "." }
        }
    }

    // ------------------------------------------------------------------ grants

    /** Takes a durable grant on [uri], refusing when near the platform cap. */
    fun takePersistableAccess(uri: Uri) {
        val held = resolver.persistedUriPermissions
        val alreadyHeld = held.any { it.uri == uri }
        if (!alreadyHeld && held.size >= PERSISTED_GRANT_SOFT_LIMIT) {
            throw AnchorException(
                ErrorCodes.QUOTA_EXCEEDED,
                "This app already holds ${held.size} persisted grants. Android " +
                    "evicts the oldest past its limit without warning, so call " +
                    "FileAnchor.releaseUnused() before anchoring another location.",
            )
        }
        try {
            resolver.takePersistableUriPermission(uri, PERSISTABLE_FLAGS)
        } catch (e: SecurityException) {
            throw AnchorException(
                ErrorCodes.PERMISSION_DENIED,
                "The system refused to persist access to this location.",
                e,
            )
        }
    }

    /** Drops the grant on [uri]. */
    fun release(uri: Uri) {
        try {
            resolver.releasePersistableUriPermission(uri, PERSISTABLE_FLAGS)
        } catch (e: SecurityException) {
            // Already gone; releasing twice is not an error worth surfacing.
        }
    }

    /** Releases every grant whose URI is absent from [keep]; returns the count. */
    fun releaseUnused(keep: Set<String>): Int {
        var released = 0
        for (permission in resolver.persistedUriPermissions) {
            val uri = permission.uri.toString()
            if (uri !in keep) {
                release(permission.uri)
                released++
            }
        }
        return released
    }

    private fun requireGrant(uri: Uri) {
        val granted = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        if (!granted) {
            throw AnchorException(
                ErrorCodes.REVOKED,
                "The persisted permission for this location is gone. The user must " +
                    "pick it again; retrying will not help.",
            )
        }
    }

    // ---------------------------------------------------------------- describe

    /** The document URI for an anchor's root, tree or single file alike. */
    fun rootDocumentUri(uri: Uri): Uri =
        if (isTreeUri(uri)) {
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            )
        } else {
            uri
        }

    /**
     * Metadata for the pick/resolve result, and a liveness check.
     *
     * Distinguishes the three failure states the Dart contract requires: a
     * missing grant is revoked, a query that returns nothing is stale, and a
     * provider that cannot be reached at all is unavailable.
     */
    fun describe(uri: Uri, checkGrant: Boolean = true): Map<String, Any?> {
        if (checkGrant) requireGrant(uri)
        val row = try {
            queryDocument(rootDocumentUri(uri))
        } catch (e: AnchorException) {
            throw e
        } catch (e: SecurityException) {
            throw AnchorException(ErrorCodes.REVOKED, "Access was revoked.", e)
        } catch (e: Exception) {
            throw AnchorException(
                ErrorCodes.UNAVAILABLE,
                "The provider backing this location is not reachable right now. " +
                    "Retry later rather than re-prompting the user.",
                e,
            )
        } ?: throw AnchorException(
            ErrorCodes.STALE,
            "The location no longer resolves; it was probably moved or deleted.",
        )

        return mapOf(
            "uri" to uri.toString(),
            "displayName" to (row.displayName ?: "Selected location"),
            "canRename" to row.canRename,
            "persistsAcrossReboot" to true,
            "isStale" to false,
            "isDirectory" to row.isDirectory,
        )
    }

    // ------------------------------------------------------------- resolution

    private fun queryDocument(documentUri: Uri): DocRow? =
        resolver.query(documentUri, PROJECTION, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.toDocRow() else null
        }

    private fun Cursor.toDocRow(): DocRow {
        fun idx(name: String) = getColumnIndex(name)
        val sizeIndex = idx(DocumentsContract.Document.COLUMN_SIZE)
        val modifiedIndex = idx(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val flagsIndex = idx(DocumentsContract.Document.COLUMN_FLAGS)
        return DocRow(
            documentId = getString(idx(DocumentsContract.Document.COLUMN_DOCUMENT_ID)),
            displayName = idx(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                .takeIf { it >= 0 }?.let { if (isNull(it)) null else getString(it) },
            mimeType = idx(DocumentsContract.Document.COLUMN_MIME_TYPE)
                .takeIf { it >= 0 }?.let { if (isNull(it)) null else getString(it) },
            size = sizeIndex.takeIf { it >= 0 && !isNull(it) }?.let { getLong(it) },
            lastModified = modifiedIndex.takeIf { it >= 0 && !isNull(it) }?.let { getLong(it) },
            flags = flagsIndex.takeIf { it >= 0 && !isNull(it) }?.let { getInt(it) } ?: 0,
        )
    }

    /** One bulk query returning every child of [parentDocumentId]. */
    fun queryChildren(treeUri: Uri, parentDocumentId: String): Cursor {
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
        return resolver.query(childrenUri, PROJECTION, null, null, null)
            ?: throw AnchorException(
                ErrorCodes.UNAVAILABLE,
                "The provider returned no cursor for this directory.",
            )
    }

    fun rowFromCursor(cursor: Cursor): DocRow = cursor.toDocRow()

    /** Walks [relativePath] from the anchor root and returns the document row. */
    fun resolveRow(uri: Uri, relativePath: String?): DocRow {
        val segments = splitPath(relativePath)
        if (!isTreeUri(uri)) {
            if (segments.isNotEmpty()) {
                throw AnchorException(
                    ErrorCodes.UNSUPPORTED,
                    "This anchor is a single file, so it has no entry at " +
                        "\"$relativePath\". Use an empty path to address the file itself.",
                )
            }
            return queryDocument(uri)
                ?: throw AnchorException(ErrorCodes.STALE, "The file no longer resolves.")
        }

        var current = queryDocument(rootDocumentUri(uri))
            ?: throw AnchorException(ErrorCodes.STALE, "The folder no longer resolves.")
        for (segment in segments) {
            current = findChild(uri, current.documentId, segment)
                ?: throw AnchorException(
                    ErrorCodes.NOT_FOUND,
                    "No entry named \"$segment\" in \"$relativePath\".",
                )
        }
        return current
    }

    private fun findChild(treeUri: Uri, parentId: String, name: String): DocRow? =
        queryChildren(treeUri, parentId).use { cursor ->
            while (cursor.moveToNext()) {
                val row = cursor.toDocRow()
                if (row.displayName == name) return row
            }
            null
        }

    fun documentUri(anchorUri: Uri, row: DocRow): Uri =
        if (isTreeUri(anchorUri)) {
            DocumentsContract.buildDocumentUriUsingTree(anchorUri, row.documentId)
        } else {
            anchorUri
        }

    // -------------------------------------------------------------- mutations

    /** Creates intermediate directories, mkdirs-style, and returns the deepest. */
    fun ensureDirectory(treeUri: Uri, segments: List<String>): DocRow {
        requireTree(treeUri)
        var current = queryDocument(rootDocumentUri(treeUri))
            ?: throw AnchorException(ErrorCodes.STALE, "The folder no longer resolves.")
        for (segment in segments) {
            val existing = findChild(treeUri, current.documentId, segment)
            current = if (existing != null) {
                if (!existing.isDirectory) {
                    throw AnchorException(
                        ErrorCodes.UNSUPPORTED,
                        "\"$segment\" already exists and is a file, not a directory.",
                    )
                }
                existing
            } else {
                val created = DocumentsContract.createDocument(
                    resolver,
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, current.documentId),
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    segment,
                ) ?: throw AnchorException(
                    ErrorCodes.IO,
                    "The provider refused to create the directory \"$segment\".",
                )
                queryDocument(created) ?: throw AnchorException(
                    ErrorCodes.IO,
                    "The directory \"$segment\" was created but cannot be read back.",
                )
            }
        }
        return current
    }

    /** Creates (or finds) a file at [relativePath], creating parents as needed. */
    fun createFile(treeUri: Uri, relativePath: String, mimeType: String?): DocRow {
        requireTree(treeUri)
        val segments = splitPath(relativePath)
        if (segments.isEmpty()) {
            throw AnchorException(ErrorCodes.UNSUPPORTED, "A file name is required.")
        }
        val parent = ensureDirectory(treeUri, segments.dropLast(1))
        val name = segments.last()
        findChild(treeUri, parent.documentId, name)?.let { return it }

        val created = DocumentsContract.createDocument(
            resolver,
            DocumentsContract.buildDocumentUriUsingTree(treeUri, parent.documentId),
            mimeType ?: "application/octet-stream",
            name,
        ) ?: throw AnchorException(
            ErrorCodes.IO,
            "The provider refused to create \"$name\".",
        )
        // Providers may adjust the display name, for example by adding an
        // extension, so read back rather than assuming.
        return queryDocument(created) ?: throw AnchorException(
            ErrorCodes.IO,
            "\"$name\" was created but cannot be read back.",
        )
    }

    fun delete(anchorUri: Uri, relativePath: String?) {
        val row = resolveRow(anchorUri, relativePath)
        val deleted = try {
            DocumentsContract.deleteDocument(resolver, documentUri(anchorUri, row))
        } catch (e: FileNotFoundException) {
            throw AnchorException(ErrorCodes.NOT_FOUND, "Already gone.", e)
        } catch (e: SecurityException) {
            throw AnchorException(ErrorCodes.PERMISSION_DENIED, "Delete refused.", e)
        }
        if (!deleted) {
            throw AnchorException(
                ErrorCodes.IO,
                "The provider reported that the delete did not happen.",
            )
        }
    }

    fun exists(anchorUri: Uri, relativePath: String?): Boolean =
        try {
            resolveRow(anchorUri, relativePath)
            true
        } catch (e: AnchorException) {
            if (e.code == ErrorCodes.NOT_FOUND || e.code == ErrorCodes.STALE) false else throw e
        }

    // ------------------------------------------------------------------ bytes

    fun openInput(anchorUri: Uri, relativePath: String?): InputStream {
        val row = resolveRow(anchorUri, relativePath)
        if (row.isDirectory) {
            throw AnchorException(ErrorCodes.UNSUPPORTED, "Cannot read a directory.")
        }
        return try {
            resolver.openInputStream(documentUri(anchorUri, row))
                ?: throw AnchorException(ErrorCodes.IO, "The provider returned no stream.")
        } catch (e: FileNotFoundException) {
            throw AnchorException(ErrorCodes.NOT_FOUND, "No such document.", e)
        } catch (e: SecurityException) {
            throw AnchorException(ErrorCodes.REVOKED, "Access was revoked.", e)
        }
    }

    /**
     * Opens a write stream, reporting whether the document was created here.
     *
     * That flag is what makes an abort meaningful: a document this session
     * created can be deleted on failure, whereas SAF offers no way to roll back
     * a truncation of a pre-existing file.
     */
    fun openOutput(
        treeUri: Uri,
        relativePath: String,
        append: Boolean,
    ): Triple<OutputStream, Uri, Boolean> {
        val existed = exists(treeUri, relativePath)
        val row = if (existed) {
            resolveRow(treeUri, relativePath)
        } else {
            createFile(treeUri, relativePath, null)
        }
        val target = documentUri(treeUri, row)
        // "wa" is optional for providers; fall back to a truncating write rather
        // than silently appending to the wrong place.
        val mode = if (append) "wa" else "wt"
        val stream = try {
            resolver.openOutputStream(target, mode)
                ?: throw AnchorException(ErrorCodes.IO, "The provider returned no stream.")
        } catch (e: IllegalArgumentException) {
            throw AnchorException(
                ErrorCodes.UNSUPPORTED,
                "This provider does not support opening a document in mode \"$mode\".",
                e,
            )
        } catch (e: FileNotFoundException) {
            throw AnchorException(ErrorCodes.NOT_FOUND, "No such document.", e)
        } catch (e: SecurityException) {
            throw AnchorException(ErrorCodes.REVOKED, "Access was revoked.", e)
        }
        return Triple(stream, target, !existed)
    }

    private fun requireTree(uri: Uri) {
        if (!isTreeUri(uri)) {
            throw AnchorException(
                ErrorCodes.UNSUPPORTED,
                "This anchor is a single file; it cannot contain other entries.",
            )
        }
    }
}
