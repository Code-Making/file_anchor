/// Shared `dart:io` engine for `file_anchor` on platforms with real paths.
///
/// Used by the Windows, Linux and macOS implementations. Not intended for app
/// authors, who should depend on `file_anchor`.
library;

export 'src/path_anchor_platform.dart' show PathAnchorPlatform;
