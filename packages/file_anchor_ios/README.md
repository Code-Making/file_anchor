# file_anchor_ios

The iOS implementation of [`file_anchor`](../file_anchor), using
`UIDocumentPickerViewController` and security-scoped bookmarks. Registered
automatically. Requires iOS 14.

Almost all the work happens in Dart: a bookmark resolves to a real path, and with
the access scope open `dart:io` reads and writes it directly. The Swift side only
presents the picker, mints and resolves bookmarks, and holds the scope.

Two traps it handles:

- The picker uses `asCopy: false`. With `true`, iOS hands back a throwaway copy
  in a temporary directory — the opposite of durable access.
- `.withSecurityScope` is **macOS-only**. On iOS the scope is implicit in the
  bookmark and passing that option throws. This is one of the most common iOS
  bookmark bugs.

`purpose` is accepted and ignored, because iOS offers no caller-supplied prompt
on the picker. Only macOS can show it.
