import 'dart:convert';

import 'errors.dart';

/// How a platform represents a location internally.
///
/// Consumers never need this. It exists so a token can be routed to the right
/// platform implementation after being read back from disk.
enum AnchorKind {
  /// Android Storage Access Framework `content://` URI.
  saf('s'),

  /// Apple security-scoped bookmark data, base64-encoded.
  bookmark('b'),

  /// A plain filesystem path (unpackaged Windows, and desktop in general).
  path('p'),

  /// Windows `StorageApplicationPermissions.FutureAccessList` token (MSIX).
  futureAccessList('f'),

  /// An in-memory anchor, used by `MemoryAnchor` in tests.
  memory('m');

  const AnchorKind(this.code);

  /// Single-character discriminator used in the encoded token.
  final String code;

  static AnchorKind fromCode(String code) => switch (code) {
        's' => AnchorKind.saf,
        'b' => AnchorKind.bookmark,
        'p' => AnchorKind.path,
        'f' => AnchorKind.futureAccessList,
        'm' => AnchorKind.memory,
        _ => throw AnchorTokenMalformed('Unknown anchor kind code "$code".'),
      };
}

/// An opaque, durable reference to a user-chosen file or folder.
///
/// The encoded form is `fa1.<kind>.<base64url payload>`. Treat [value] as a
/// black box: persist it, hand it back to `FileAnchor.resolve`, and never parse
/// it. The `fa1` prefix is a format version, so the encoding can evolve without
/// breaking tokens already stored on users' devices.
///
/// A token is deliberately **not** a path. On Android a path is meaningless, and
/// on iOS it is a value that changes underneath you.
final class AnchorToken {
  const AnchorToken._(this.kind, this.payload);

  /// Wraps a platform-native [payload] of the given [kind].
  factory AnchorToken.of(AnchorKind kind, String payload) =>
      AnchorToken._(kind, payload);

  /// Parses a token previously produced by [value].
  ///
  /// Throws [AnchorTokenMalformed] if the string was not produced by this
  /// package or uses a newer format version.
  factory AnchorToken.parse(String raw) {
    final parts = raw.split('.');
    if (parts.length != 3) {
      throw const AnchorTokenMalformed('Expected three dot-separated segments.');
    }
    if (parts[0] != _version) {
      throw AnchorTokenMalformed(
        'Unsupported token version "${parts[0]}"; this build understands "$_version".',
      );
    }
    final kind = AnchorKind.fromCode(parts[1]);
    final String payload;
    try {
      payload = utf8.decode(base64Url.decode(parts[2]));
    } on FormatException catch (e) {
      throw AnchorTokenMalformed('Payload is not valid base64url.', e);
    }
    return AnchorToken._(kind, payload);
  }

  static const String _version = 'fa1';

  /// Which platform representation [payload] holds.
  final AnchorKind kind;

  /// The platform-native reference: a `content://` URI, base64 bookmark data, a
  /// path, or a FutureAccessList token.
  final String payload;

  /// The durable string to persist. Safe to store in preferences or a database.
  String get value =>
      '$_version.${kind.code}.${base64Url.encode(utf8.encode(payload))}';

  @override
  String toString() => 'AnchorToken(${kind.name})';

  @override
  bool operator ==(Object other) =>
      other is AnchorToken && other.kind == kind && other.payload == payload;

  @override
  int get hashCode => Object.hash(kind, payload);
}
