import 'anchor_token.dart';
import 'capabilities.dart';

/// One entry inside an anchored directory.
final class AnchorEntry {
  const AnchorEntry({
    required this.relativePath,
    required this.isDirectory,
    this.size,
    this.modified,
    this.mimeType,
  });

  /// Path relative to the anchor root, using `/` on every platform.
  ///
  /// For a non-recursive listing this is just the entry's name. For a recursive
  /// one it is the full relative path, for example `notes/2026/january.md`.
  final String relativePath;

  /// The final segment of [relativePath].
  String get name {
    final i = relativePath.lastIndexOf('/');
    return i == -1 ? relativePath : relativePath.substring(i + 1);
  }

  /// Whether this entry is a directory.
  final bool isDirectory;

  /// Size in bytes, or null when the platform did not report it.
  final int? size;

  /// Last-modified time, or null when the platform did not report it.
  final DateTime? modified;

  /// MIME type as reported by the platform, if known.
  final String? mimeType;

  @override
  String toString() =>
      'AnchorEntry($relativePath${isDirectory ? '/' : ''}, size: $size)';
}

/// Metadata for a single entry.
final class AnchorStat {
  const AnchorStat({
    required this.isDirectory,
    this.size,
    this.modified,
    this.mimeType,
  });

  /// Whether the target is a directory.
  final bool isDirectory;

  /// Size in bytes, or null when unknown.
  final int? size;

  /// Last-modified time, or null when unknown.
  final DateTime? modified;

  /// MIME type as reported by the platform, if known.
  final String? mimeType;
}

/// What a platform returns when a token is successfully resolved.
final class ResolvedAnchor {
  const ResolvedAnchor({
    required this.token,
    required this.displayName,
    required this.capabilities,
    this.isStale = false,
  });

  /// The token for this anchor. May differ from the one passed in: iOS can
  /// repair a stale bookmark, which produces a fresh token worth re-persisting.
  final AnchorToken token;

  /// A user-presentable name, such as the folder name. Never a full path.
  final String displayName;

  /// What this anchor supports on the current platform.
  final AnchorCapabilities capabilities;

  /// Whether the underlying reference had moved and was repaired.
  final bool isStale;
}
