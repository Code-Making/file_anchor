import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter/services.dart';

/// Error codes the Kotlin side sends, and their [AnchorError] counterparts.
///
/// The native layer classifies failures because only it can tell, for example, a
/// revoked grant from an unmounted volume. Dart's job is to make sure nothing
/// escapes as a raw [PlatformException].
abstract final class AnchorErrorCode {
  /// The document moved or was renamed.
  static const String stale = 'file_anchor/stale';

  /// The persisted URI permission is gone.
  static const String revoked = 'file_anchor/revoked';

  /// The volume is not mounted right now.
  static const String unavailable = 'file_anchor/unavailable';

  /// The system refused the operation.
  static const String permissionDenied = 'file_anchor/permission_denied';

  /// The persisted grant limit was reached.
  static const String quotaExceeded = 'file_anchor/quota_exceeded';

  /// No document at the requested path.
  static const String notFound = 'file_anchor/not_found';

  /// The operation cannot be expressed through the Storage Access Framework.
  static const String unsupported = 'file_anchor/unsupported';

  /// The URI was not a usable SAF document tree.
  static const String malformedToken = 'file_anchor/malformed_token';

  /// Anything else.
  static const String io = 'file_anchor/io';
}

/// Converts a channel failure into the sealed error hierarchy.
///
/// An unrecognised code becomes [AnchorIoFailure] rather than leaking, so a
/// newer native layer talking to an older Dart layer degrades predictably.
AnchorError mapPlatformException(PlatformException e) {
  final message = e.message ?? 'Native call failed (${e.code}).';
  return switch (e.code) {
    AnchorErrorCode.stale => AnchorStale(message, e),
    AnchorErrorCode.revoked => AnchorRevoked(message, e),
    AnchorErrorCode.unavailable => AnchorUnavailable(message, e),
    AnchorErrorCode.permissionDenied => AnchorPermissionDenied(message, e),
    AnchorErrorCode.quotaExceeded => AnchorQuotaExceeded(message, e),
    AnchorErrorCode.notFound => AnchorEntryNotFound(message, e),
    AnchorErrorCode.unsupported => AnchorUnsupported(message, e),
    AnchorErrorCode.malformedToken => AnchorTokenMalformed(message, e),
    _ => AnchorIoFailure(message, e),
  };
}
