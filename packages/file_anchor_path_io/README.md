# file_anchor_path_io

Shared engines for [`file_anchor`](../file_anchor) on platforms backed by real
filesystem paths. Not for app authors.

Two base classes, one `dart:io` engine underneath:

- **`PathAnchorPlatform`** — Windows and Linux, where the durable handle *is* a
  path.
- **`BookmarkAnchorPlatform`** — iOS and macOS, where it is a security-scoped
  bookmark that resolves *to* a path, plus the access scope around it.

Because a bookmark resolves to a path, the same engine does the real work on all
four platforms. A platform package only supplies what genuinely differs: how the
picker is shown, and how a bookmark becomes a path again. That is why the Windows
and Linux implementations contain no C or C++ at all.
