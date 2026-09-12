/// The iOS implementation of the `file_anchor` plugin.
///
/// App authors should depend on `file_anchor`; this package registers itself.
library;

import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

/// Durable file and folder access on iOS.
///
/// Like macOS, this is nearly empty by design: a bookmark resolves to a real
/// path, and once the access scope is open `dart:io` reads and writes it
/// directly. The Swift side only presents `UIDocumentPickerViewController`,
/// mints and resolves bookmarks, and holds the scope.
///
/// The picker is opened with `asCopy: false`. With `true` iOS hands back a
/// throwaway copy in a temporary directory, which is exactly what durable
/// access is not.
final class FileAnchorIOS extends BookmarkAnchorPlatform {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    FileAnchorPlatform.instance = FileAnchorIOS();
  }
}
