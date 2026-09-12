import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

/// Durable access to a user-chosen file or folder.
///
/// Obtain one from `FileAnchor.pickDirectory`, `FileAnchor.pickFile` or
/// `FileAnchor.resolve`. Persist [token] and resolve it again after a restart.
///
/// This interface is deliberately small. Convenience helpers such as
/// `readAsString` live in the [AnchorIo] extension, so that anything wrapping an
/// anchor -- an encrypting decorator, a test fake -- has few members to get
/// right and inherits the sugar for free.
abstract interface class Anchor {
  /// The opaque, durable string to persist.
  ///
  /// Hand it back to `FileAnchor.resolve` later. Never parse it, and never
  /// assume it is a path.
  String get token;

  /// A user-presentable name, typically the folder name.
  String get displayName;

  /// Whether the underlying reference had moved and was repaired on resolve.
  ///
  /// When true, re-persist [token]: it may have changed.
  bool get isStale;

  /// What this anchor supports on the current platform.
  AnchorCapabilities get capabilities;

  /// Lists entries under this anchor.
  ///
  /// A [Stream], not a `Future<List>`: a folder may hold tens of thousands of
  /// entries and the first ones should be renderable immediately.
  Stream<AnchorEntry> list({bool recursive = false});

  /// Creates an empty file at [relativePath].
  Future<AnchorEntry> createFile(String relativePath, {String? mimeType});

  /// Creates a directory at [relativePath].
  Future<AnchorEntry> createDirectory(String relativePath);

  /// Deletes the entry at [relativePath].
  Future<void> delete(String relativePath);

  /// Whether an entry exists at [relativePath].
  Future<bool> exists(String relativePath);

  /// Metadata for the entry at [relativePath].
  Future<AnchorStat> stat(String relativePath);

  /// Opens a byte stream over [relativePath], optionally a `[start, end)` range.
  ///
  /// Streaming is the primitive, not a convenience: a multi-gigabyte file must
  /// never be buffered whole, and chunked encryption is built on top of this.
  Future<Stream<List<int>>> openRead(
    String relativePath, {
    int? start,
    int? end,
  });

  /// Opens a sink writing into [relativePath].
  ///
  /// Always await `close()`, then `done`, before assuming bytes landed.
  Future<StreamSink<List<int>>> openWrite(
    String relativePath, {
    bool append = false,
  });

  /// Runs [body] with the platform's security scope held open.
  ///
  /// iOS requires `startAccessingSecurityScopedResource` before any I/O and a
  /// balanced `stopAccessing...` afterwards. Forget the first and reads fail
  /// silently; forget the second and a kernel resource leaks until the process
  /// dies.
  ///
  /// Exposing this as a callback rather than two methods makes that whole class
  /// of bug structurally impossible. On Android and Windows it is a passthrough.
  /// Nested calls are reference-counted and safe.
  Future<T> use<T>(Future<T> Function() body);

  /// Permanently drops durable access.
  ///
  /// On Android this releases the persisted URI permission. The [token] is dead
  /// afterwards and the user must pick the location again.
  Future<void> release();
}

/// Convenience I/O layered over [Anchor]'s streaming primitives.
///
/// Deliberately an extension: every [Anchor] implementation gets these without
/// having to implement them.
extension AnchorIo on Anchor {
  /// Reads [relativePath] fully into memory.
  ///
  /// Only for files you know are small. Prefer [Anchor.openRead] otherwise.
  Future<Uint8List> readAsBytes(String relativePath) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in await openRead(relativePath)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Reads [relativePath] and decodes it as text.
  Future<String> readAsString(
    String relativePath, {
    Encoding encoding = utf8,
  }) async =>
      encoding.decode(await readAsBytes(relativePath));

  /// Writes [bytes] to [relativePath], replacing any existing content.
  Future<void> writeBytes(
    String relativePath,
    List<int> bytes, {
    bool append = false,
  }) async {
    final sink = await openWrite(relativePath, append: append);
    sink.add(bytes);
    await sink.close();
    await sink.done;
  }

  /// Encodes [contents] and writes it to [relativePath].
  Future<void> writeAsString(
    String relativePath,
    String contents, {
    Encoding encoding = utf8,
    bool append = false,
  }) =>
      writeBytes(relativePath, encoding.encode(contents), append: append);
}
