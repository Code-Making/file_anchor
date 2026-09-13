import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

/// Casts a channel value to a string-keyed map, or fails with a typed error.
Map<String, Object?> asMap(Object? value, String context) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  throw AnchorIoFailure('$context: expected a map, got ${value.runtimeType}.');
}

/// Reads an optional epoch-millis field as a [DateTime].
DateTime? _modified(Object? millis) => switch (millis) {
  final int m when m > 0 => DateTime.fromMillisecondsSinceEpoch(m),
  _ => null,
};

/// Deserialises one directory entry.
AnchorEntry anchorEntryFromMap(Map<String, Object?> map) => AnchorEntry(
  relativePath:
      map['relativePath'] as String? ??
      (throw const AnchorIoFailure('Entry is missing relativePath.')),
  isDirectory: map['isDirectory'] as bool? ?? false,
  size: map['size'] as int?,
  modified: _modified(map['modified']),
  mimeType: map['mimeType'] as String?,
);

/// Deserialises entry metadata.
AnchorStat anchorStatFromMap(Map<String, Object?> map) => AnchorStat(
  isDirectory: map['isDirectory'] as bool? ?? false,
  size: map['size'] as int?,
  modified: _modified(map['modified']),
  mimeType: map['mimeType'] as String?,
);

/// Deserialises a pick or resolve result.
///
/// The native side returns a bare `content://` URI; the durable token is built
/// here, so the Kotlin layer never needs to know the token encoding.
ResolvedAnchor resolvedAnchorFromMap(Map<String, Object?> map) {
  final uri =
      map['uri'] as String? ??
      (throw const AnchorIoFailure('Result is missing uri.'));
  return ResolvedAnchor(
    token: AnchorToken.of(AnchorKind.saf, uri),
    displayName: map['displayName'] as String? ?? 'Selected folder',
    isStale: map['isStale'] as bool? ?? false,
    capabilities: AnchorCapabilities(
      // SAF documents are append/replace; there is no positional write.
      canRandomAccessWrite: false,
      canRename: map['canRename'] as bool? ?? false,
      canQueryFreeSpace: false,
      // Android needs no security scope; only iOS and macOS do.
      requiresExplicitScope: false,
      persistsAcrossReboot: map['persistsAcrossReboot'] as bool? ?? true,
    ),
  );
}
