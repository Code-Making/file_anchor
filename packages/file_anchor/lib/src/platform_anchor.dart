import 'dart:async';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

import 'anchor.dart';

/// An [Anchor] backed by the registered platform implementation.
///
/// Not constructed directly; obtain one from `FileAnchor`.
final class PlatformAnchor implements Anchor {
  /// Wraps the result of a pick or resolve call.
  PlatformAnchor(this._resolved);

  final ResolvedAnchor _resolved;

  /// Depth of active [use] calls, so nesting does not close the scope early.
  int _scopeDepth = 0;

  FileAnchorPlatform get _platform => FileAnchorPlatform.instance;

  AnchorToken get _token => _resolved.token;

  @override
  String get token => _resolved.token.value;

  @override
  String get displayName => _resolved.displayName;

  @override
  bool get isStale => _resolved.isStale;

  @override
  AnchorCapabilities get capabilities => _resolved.capabilities;

  @override
  Stream<AnchorEntry> list({bool recursive = false}) =>
      _platform.list(_token, recursive: recursive);

  @override
  Future<AnchorEntry> createFile(String relativePath, {String? mimeType}) =>
      _platform.createFile(_token, relativePath, mimeType: mimeType);

  @override
  Future<AnchorEntry> createDirectory(String relativePath) =>
      _platform.createDirectory(_token, relativePath);

  @override
  Future<void> delete(String relativePath) =>
      _platform.delete(_token, relativePath);

  @override
  Future<bool> exists(String relativePath) =>
      _platform.exists(_token, relativePath);

  @override
  Future<AnchorStat> stat(String relativePath) =>
      _platform.stat(_token, relativePath);

  @override
  Future<Stream<List<int>>> openRead(
    String relativePath, {
    int? start,
    int? end,
  }) async =>
      _platform.openRead(_token, relativePath, start: start, end: end);

  @override
  Future<StreamSink<List<int>>> openWrite(
    String relativePath, {
    bool append = false,
  }) =>
      _platform.openWrite(_token, relativePath, append: append);

  @override
  Future<T> use<T>(Future<T> Function() body) async {
    if (_scopeDepth == 0) {
      await _platform.beginAccess(_token);
    }
    _scopeDepth++;
    try {
      return await body();
    } finally {
      _scopeDepth--;
      if (_scopeDepth == 0) {
        await _platform.endAccess(_token);
      }
    }
  }

  @override
  Future<void> release() => _platform.release(_token);
}
