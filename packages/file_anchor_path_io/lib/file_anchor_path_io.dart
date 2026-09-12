/// Shared engines for `file_anchor` on platforms backed by real paths.
///
/// [PathAnchorPlatform] serves Windows and Linux, where the durable handle is a
/// path. [BookmarkAnchorPlatform] serves iOS and macOS, where it is a
/// security-scoped bookmark that resolves to a path -- so the same `dart:io`
/// engine does the actual work on all four.
///
/// Not intended for app authors, who should depend on `file_anchor`.
library;

export 'src/bookmark_anchor_platform.dart'
    show BookmarkAnchorPlatform, BookmarkResolution;
export 'src/path_anchor_platform.dart' show PathAnchorPlatform;
