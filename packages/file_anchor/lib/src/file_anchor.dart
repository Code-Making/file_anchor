import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

import 'anchor.dart';
import 'platform_anchor.dart';

/// Entry point for obtaining durable file and folder access.
///
/// The flow is always the same: ask the user once, persist the resulting
/// [Anchor.token], and [resolve] it on the next launch.
///
/// ```dart
/// final anchor = await FileAnchor.pickDirectory(purpose: 'Choose your vault');
/// if (anchor != null) {
///   await prefs.setString('vault', anchor.token);
/// }
///
/// // ...next cold start:
/// final vault = await FileAnchor.resolve(prefs.getString('vault')!);
/// await vault.use(() async {
///   await for (final entry in vault.list()) print(entry.name);
/// });
/// ```
abstract final class FileAnchor {
  /// Shows the native folder picker.
  ///
  /// Returns null if the user cancelled. [purpose] is surfaced to the user where
  /// the platform supports it; keep it short and specific.
  ///
  /// Access is made durable before this returns, so the token survives a reboot.
  static Future<Anchor?> pickDirectory({String? purpose}) async {
    final resolved = await FileAnchorPlatform.instance.pickDirectory(
      purpose: purpose,
    );
    return resolved == null ? null : PlatformAnchor(resolved);
  }

  /// Shows the native file picker.
  ///
  /// Returns null if the user cancelled. [mimeTypes] filters the selection where
  /// the platform supports it.
  static Future<Anchor?> pickFile({
    String? purpose,
    List<String>? mimeTypes,
  }) async {
    final resolved = await FileAnchorPlatform.instance.pickFile(
      purpose: purpose,
      mimeTypes: mimeTypes,
    );
    return resolved == null ? null : PlatformAnchor(resolved);
  }

  /// Re-establishes access to a previously persisted [token].
  ///
  /// Throws [AnchorTokenMalformed] if [token] did not come from this package.
  /// Throws [AnchorRevoked] if the user withdrew permission -- you must prompt
  /// again. Throws [AnchorUnavailable] if the volume is merely offline, in which
  /// case retry later rather than re-prompting.
  ///
  /// Check [Anchor.isStale] on success: the token may have been repaired and is
  /// then worth re-persisting.
  static Future<Anchor> resolve(String token) async {
    final resolved = await FileAnchorPlatform.instance.resolve(
      AnchorToken.parse(token),
    );
    return PlatformAnchor(resolved);
  }

  /// Releases every persisted grant except those whose token is in [keep].
  ///
  /// Returns the number released. Android caps persistable URI permissions per
  /// app (commonly 128, 512 on newer releases), and exceeding the cap fails in
  /// a confusing way -- so reap orphans when you drop an anchor.
  static Future<int> releaseUnused({required Iterable<String> keep}) {
    final tokens = keep.map(AnchorToken.parse).toSet();
    return FileAnchorPlatform.instance.releaseUnused(tokens);
  }
}
