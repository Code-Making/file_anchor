/// The macOS implementation of the `file_anchor` plugin.
///
/// App authors should depend on `file_anchor`; this package registers itself.
library;

import 'dart:async';

import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

/// Durable file and folder access on macOS.
///
/// There is almost nothing here, and that is the point. A security-scoped
/// bookmark resolves to a real path, so [BookmarkAnchorPlatform] and `dart:io`
/// do every read, write and directory walk. The Swift side only shows
/// `NSOpenPanel`, mints and resolves bookmarks, and opens the access scope.
///
/// A sandboxed app needs the `com.apple.security.files.user-selected.read-write`
/// entitlement for this to work. Without the sandbox, macOS cannot mint a
/// security-scoped bookmark at all, so the plugin falls back to a plain path
/// token, which is equally durable for an unsandboxed build.
final class FileAnchorMacOS extends BookmarkAnchorPlatform {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    final instance = FileAnchorMacOS();
    FileAnchorPlatform.instance = instance;
    // Clears any access scope still held from before a hot restart; see
    // BookmarkAnchorPlatform.resetNative.
    unawaited(instance.resetNative());
  }
}
