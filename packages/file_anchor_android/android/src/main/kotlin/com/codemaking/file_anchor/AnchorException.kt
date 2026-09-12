package com.codemaking.file_anchor

/**
 * Error codes shared with the Dart side.
 *
 * These strings are a contract: `error_codes.dart` maps each one onto a case of
 * the sealed `AnchorError` hierarchy. Changing a value here without changing it
 * there turns a typed error into a generic I/O failure.
 */
internal object ErrorCodes {
    const val STALE = "file_anchor/stale"
    const val REVOKED = "file_anchor/revoked"
    const val UNAVAILABLE = "file_anchor/unavailable"
    const val PERMISSION_DENIED = "file_anchor/permission_denied"
    const val QUOTA_EXCEEDED = "file_anchor/quota_exceeded"
    const val NOT_FOUND = "file_anchor/not_found"
    const val UNSUPPORTED = "file_anchor/unsupported"
    const val MALFORMED_TOKEN = "file_anchor/malformed_token"
    const val IO = "file_anchor/io"
}

/**
 * A failure already classified for Dart.
 *
 * The native layer classifies because only it can distinguish, say, a revoked
 * grant from an unmounted volume.
 */
internal class AnchorException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
