# file_anchor

Pick a file or folder once and keep durable access to it across app restarts and
device reboots — on **Android, iOS, macOS, Windows and Linux**.

A filesystem path is the wrong abstraction for this, because the platforms
disagree about what a location even is. `file_anchor` replaces the path with an
opaque, versioned **token** that all five can represent honestly.

See [`packages/file_anchor`](packages/file_anchor) for usage.

## Packages

| Package | Role |
| --- | --- |
| [`file_anchor`](packages/file_anchor) | The package apps depend on |
| [`file_anchor_platform_interface`](packages/file_anchor_platform_interface) | The shared contract |
| [`file_anchor_path_io`](packages/file_anchor_path_io) | Shared `dart:io` engine for path- and bookmark-backed platforms |
| [`file_anchor_android`](packages/file_anchor_android) | Storage Access Framework (Kotlin) |
| [`file_anchor_ios`](packages/file_anchor_ios) | `UIDocumentPickerViewController` + bookmarks (Swift) |
| [`file_anchor_macos`](packages/file_anchor_macos) | `NSOpenPanel` + bookmarks (Swift) |
| [`file_anchor_windows`](packages/file_anchor_windows) | `IFileOpenDialog` — **pure Dart** |
| [`file_anchor_linux`](packages/file_anchor_linux) | XDG desktop portal — **pure Dart** |

## How it fits together

Windows, Linux, macOS and iOS all end up at a real filesystem path — directly on
the desktop platforms, and after resolving a bookmark on Apple ones. So one
`dart:io` engine does every read, write and directory walk, and each platform
package supplies only what genuinely differs: **how the picker is shown**, and on
Apple, **how a bookmark becomes a path and its access scope is held**.

That is why Windows and Linux need no C or C++ at all, and why the Swift and
Kotlin layers are small. Android is the outlier: SAF never exposes a path, so it
has a full native implementation.

## Development

A Dart pub workspace; no melos required.

```bash
flutter pub get          # resolves every package
flutter analyze          # whole workspace
cd packages/file_anchor && flutter test
```

One example app in [`example/`](example) builds for every platform:

```bash
cd example
flutter build apk --debug      # Android
flutter build macos --debug    # macOS
flutter build ios --debug --no-codesign
flutter build windows          # on Windows
flutter build linux            # on Linux
```

It shows the durability claim rather than asserting it: the token is displayed
instead of stored, so you can copy it, kill the app, relaunch, paste it back and
confirm access survived the process.
