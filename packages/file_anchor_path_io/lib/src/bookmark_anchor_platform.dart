import 'dart:async';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'path_anchor_platform.dart';

/// What the native side reports when a bookmark is resolved.
@immutable
final class BookmarkResolution {
  /// Creates a resolution result.
  const BookmarkResolution({
    required this.path,
    required this.isStale,
    this.bookmark,
  });

  /// The absolute path the bookmark now points at.
  final String path;

  /// Whether the bookmark had gone stale and was repaired.
  final bool isStale;

  /// A replacement bookmark, present only when one was regenerated.
  final String? bookmark;
}

/// The engine for Apple platforms, where the durable handle is a
/// security-scoped bookmark rather than a path.
///
/// A bookmark resolves *to* a path, so once resolved everything falls back to
/// [PathAnchorPlatform] and `dart:io`. Only three things need native code: the
/// picker, turning a bookmark back into a URL, and opening the access scope.
///
/// The scope is the part that bites. Apple requires
/// `startAccessingSecurityScopedResource` before any I/O and a balanced
/// `stopAccessing...` after. Miss the first and reads fail *silently*; miss the
/// second and a kernel resource leaks until the process dies. `Anchor.use`
/// makes that impossible to get wrong from Dart, and the native side
/// reference-counts per path so two anchors on one folder cannot close each
/// other's scope.
abstract base class BookmarkAnchorPlatform extends PathAnchorPlatform {
  /// The channel shared with the Swift implementation.
  static const String channelName = 'com.codemaking.file_anchor/apple';

  /// The channel to talk over; overridable for tests.
  @protected
  MethodChannel get channel => const MethodChannel(channelName);

  /// Resolved paths, keyed by token, so each token costs one channel call.
  final Map<String, String> _pathCache = <String, String>{};

  @override
  AnchorCapabilities get capabilities => const AnchorCapabilities(
    canRandomAccessWrite: true,
    canRename: true,
    canQueryFreeSpace: false,
    // The whole reason `use()` exists.
    requiresExplicitScope: true,
    persistsAcrossReboot: true,
  );

  // ---------------------------------------------------------------- plumbing

  Future<Map<String, Object?>?> _invoke(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final raw = await channel.invokeMethod<Object?>(method, args);
      if (raw == null) return null;
      if (raw is! Map) {
        throw AnchorIoFailure(
          '$method returned ${raw.runtimeType}, wanted a map.',
        );
      }
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      throw mapPlatformException(e);
    } on MissingPluginException catch (e) {
      throw AnchorUnsupported(
        'The file_anchor implementation for this Apple platform is not registered.',
        e,
      );
    }
  }

  Future<void> _invokeVoid(String method, Map<String, Object?> args) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw mapPlatformException(e);
    } on MissingPluginException catch (e) {
      throw AnchorUnsupported('Not registered.', e);
    }
  }

  /// Asks the native side to turn [token] back into a path.
  @protected
  Future<BookmarkResolution> resolveBookmark(AnchorToken token) async {
    final map = await _invoke('resolveBookmark', {'bookmark': token.payload});
    final path = map?['path'] as String?;
    if (path == null) {
      throw const AnchorIoFailure('resolveBookmark returned no path.');
    }
    return BookmarkResolution(
      path: path,
      isStale: map?['isStale'] as bool? ?? false,
      bookmark: map?['bookmark'] as String?,
    );
  }

  // -------------------------------------------------------------- resolution

  @override
  Future<String> rootPathOf(AnchorToken token) async {
    // A non-sandboxed macOS build can hold a plain path, which needs no scope.
    if (token.kind == AnchorKind.path) return token.payload;
    if (token.kind != AnchorKind.bookmark) {
      throw AnchorTokenMalformed(
        'This platform expects a bookmark token, but the token is of kind '
        '"${token.kind.name}".',
      );
    }
    final cached = _pathCache[token.value];
    if (cached != null) return cached;
    final resolution = await resolveBookmark(token);
    _pathCache[token.value] = resolution.path;
    return resolution.path;
  }

  @override
  Future<ResolvedAnchor> resolve(AnchorToken token) async {
    if (token.kind == AnchorKind.path) return super.resolve(token);

    final resolution = await resolveBookmark(token);
    // A repaired bookmark is a *new* durable handle. Hand it back so the caller
    // can re-persist it; keeping the old one works until it does not.
    final refreshed = resolution.bookmark == null
        ? token
        : AnchorToken.of(AnchorKind.bookmark, resolution.bookmark!);
    _pathCache[token.value] = resolution.path;
    _pathCache[refreshed.value] = resolution.path;

    // Reachability has to be checked *inside* the scope: outside it, a perfectly
    // good sandboxed folder looks unreadable.
    await beginAccess(refreshed);
    try {
      await assertReachable(resolution.path);
    } finally {
      await endAccess(refreshed);
    }

    return ResolvedAnchor(
      token: refreshed,
      displayName: p.basename(resolution.path),
      capabilities: capabilities,
      isStale: resolution.isStale,
    );
  }

  // ------------------------------------------------------------------- scope

  @override
  Future<void> beginAccess(AnchorToken token) async {
    if (token.kind != AnchorKind.bookmark) return;
    await _invokeVoid('beginAccess', {
      'bookmark': token.payload,
      'path': await rootPathOf(token),
    });
  }

  @override
  Future<void> endAccess(AnchorToken token) async {
    if (token.kind != AnchorKind.bookmark) return;
    await _invokeVoid('endAccess', {'path': await rootPathOf(token)});
  }

  // ----------------------------------------------------------------- picking

  @override
  Future<ResolvedAnchor?> pickDirectory({String? purpose}) =>
      _pick('pickDirectory', {'purpose': purpose});

  @override
  Future<ResolvedAnchor?> pickFile({
    String? purpose,
    List<String>? mimeTypes,
  }) => _pick('pickFile', {'purpose': purpose, 'mimeTypes': mimeTypes});

  Future<ResolvedAnchor?> _pick(
    String method,
    Map<String, Object?> args,
  ) async {
    final map = await _invoke(method, args);
    // Cancellation is not an error.
    if (map == null) return null;

    final path = map['path'] as String?;
    if (path == null) {
      throw AnchorIoFailure('$method returned no path.');
    }
    final bookmark = map['bookmark'] as String?;
    final token = bookmark == null
        ? AnchorToken.of(AnchorKind.path, path)
        : AnchorToken.of(AnchorKind.bookmark, bookmark);
    _pathCache[token.value] = path;

    return ResolvedAnchor(
      token: token,
      displayName: map['displayName'] as String? ?? p.basename(path),
      capabilities: capabilities,
    );
  }

  // ------------------------------------------------------------------ grants

  @override
  Future<void> release(AnchorToken token) async {
    _pathCache.remove(token.value);
    if (token.kind != AnchorKind.bookmark) return;
    // Best effort: dropping a bookmark the app has forgotten is not a failure
    // worth surfacing to the caller.
    try {
      await _invokeVoid('release', {'bookmark': token.payload});
    } on AnchorError {
      // Intentionally ignored.
    }
  }
}
