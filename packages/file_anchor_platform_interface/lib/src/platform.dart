import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'anchor_token.dart';
import 'models.dart';

/// The contract every `file_anchor` platform implementation fulfils.
///
/// Operations are addressed by [AnchorToken] rather than by object identity,
/// because no object can be held across the platform channel boundary.
///
/// Methods throw [UnimplementedError] by default rather than being abstract, so
/// that adding a new operation is not a breaking change for existing
/// implementations.
abstract class FileAnchorPlatform extends PlatformInterface {
  /// Constructs a platform implementation.
  FileAnchorPlatform() : super(token: _token);

  static final Object _token = Object();

  static FileAnchorPlatform _instance = _UnimplementedFileAnchorPlatform();

  /// The registered implementation for the current platform.
  static FileAnchorPlatform get instance => _instance;

  /// Registers [value] as the implementation for the current platform.
  static set instance(FileAnchorPlatform value) {
    PlatformInterface.verifyToken(value, _token);
    _instance = value;
  }

  /// Shows the native folder picker and takes durable access to the result.
  ///
  /// Returns null if the user cancelled. Implementations must make access
  /// persistent before returning; on Android that means calling
  /// `takePersistableUriPermission` inside the activity result callback.
  Future<ResolvedAnchor?> pickDirectory({String? purpose}) =>
      throw UnimplementedError('pickDirectory() has not been implemented.');

  /// Shows the native file picker and takes durable access to the result.
  ///
  /// Returns null if the user cancelled.
  Future<ResolvedAnchor?> pickFile({String? purpose, List<String>? mimeTypes}) =>
      throw UnimplementedError('pickFile() has not been implemented.');

  /// Re-establishes access to a previously persisted [token].
  Future<ResolvedAnchor> resolve(AnchorToken token) =>
      throw UnimplementedError('resolve() has not been implemented.');

  /// Opens the platform's security scope for [token].
  ///
  /// A no-op on Android and Windows. Callers should prefer `Anchor.use`, which
  /// guarantees this is balanced with [endAccess].
  Future<void> beginAccess(AnchorToken token) => Future<void>.value();

  /// Closes the security scope opened by [beginAccess].
  Future<void> endAccess(AnchorToken token) => Future<void>.value();

  /// Permanently drops durable access to [token].
  Future<void> release(AnchorToken token) =>
      throw UnimplementedError('release() has not been implemented.');

  /// Drops every persisted grant except those in [keep]; returns how many went.
  ///
  /// Exists because Android caps persisted URI permissions per app.
  Future<int> releaseUnused(Set<AnchorToken> keep) =>
      throw UnimplementedError('releaseUnused() has not been implemented.');

  /// Lists the entries under [token].
  ///
  /// Returns a [Stream] deliberately: a directory may hold tens of thousands of
  /// entries, and a caller must be able to render the first ones immediately.
  Stream<AnchorEntry> list(AnchorToken token, {bool recursive = false}) =>
      throw UnimplementedError('list() has not been implemented.');

  /// Creates an empty file named [relativePath] under [token].
  Future<AnchorEntry> createFile(
    AnchorToken token,
    String relativePath, {
    String? mimeType,
  }) =>
      throw UnimplementedError('createFile() has not been implemented.');

  /// Creates a directory at [relativePath] under [token].
  Future<AnchorEntry> createDirectory(AnchorToken token, String relativePath) =>
      throw UnimplementedError('createDirectory() has not been implemented.');

  /// Deletes the entry at [relativePath] under [token].
  Future<void> delete(AnchorToken token, String relativePath) =>
      throw UnimplementedError('delete() has not been implemented.');

  /// Whether an entry exists at [relativePath] under [token].
  Future<bool> exists(AnchorToken token, String relativePath) =>
      throw UnimplementedError('exists() has not been implemented.');

  /// Metadata for the entry at [relativePath] under [token].
  Future<AnchorStat> stat(AnchorToken token, String relativePath) =>
      throw UnimplementedError('stat() has not been implemented.');

  /// Opens a byte stream over [relativePath], optionally a `[start, end)` range.
  Stream<List<int>> openRead(
    AnchorToken token,
    String relativePath, {
    int? start,
    int? end,
  }) =>
      throw UnimplementedError('openRead() has not been implemented.');

  /// Opens a sink writing into [relativePath].
  ///
  /// The caller must await `close()`; the returned sink's `done` future
  /// completes only once bytes are durably handed to the platform.
  Future<StreamSink<List<int>>> openWrite(
    AnchorToken token,
    String relativePath, {
    bool append = false,
  }) =>
      throw UnimplementedError('openWrite() has not been implemented.');
}

/// Fallback used on platforms with no registered implementation.
final class _UnimplementedFileAnchorPlatform extends FileAnchorPlatform {}
