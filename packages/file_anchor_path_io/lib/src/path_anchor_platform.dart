import 'dart:async';
import 'dart:io';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Every `file_anchor` operation, implemented with `dart:io`.
///
/// Windows, Linux and macOS all hand out real filesystem paths, so once a path
/// is known there is nothing platform-specific left about reading or writing.
/// This base class therefore implements the whole [FileAnchorPlatform] contract,
/// and a platform package only has to supply the two things that genuinely
/// differ: how the picker is shown, and -- on sandboxed macOS -- how a bookmark
/// turns back into a path.
///
/// That is why there is no C++ or Objective-C in the Windows and Linux
/// implementations at all.
abstract base class PathAnchorPlatform extends FileAnchorPlatform {
  /// Resolves [token] to an absolute path on disk.
  ///
  /// The default understands [AnchorKind.path]. Sandboxed macOS overrides this
  /// to resolve a security-scoped bookmark instead.
  @protected
  Future<String> rootPathOf(AnchorToken token) async {
    if (token.kind != AnchorKind.path) {
      throw AnchorTokenMalformed(
        'This platform expects a path token, but the token is of kind '
        '"${token.kind.name}".',
      );
    }
    return token.payload;
  }

  /// Capabilities reported for anchors on this platform.
  @protected
  AnchorCapabilities get capabilities => const AnchorCapabilities(
    canRandomAccessWrite: true,
    canRename: true,
    // dart:io exposes no portable free-space query, so say so rather than
    // guessing.
    canQueryFreeSpace: false,
    requiresExplicitScope: false,
    persistsAcrossReboot: true,
  );

  /// Builds a [ResolvedAnchor] for an absolute [path], without touching disk.
  @protected
  ResolvedAnchor describePath(String path, {bool isStale = false}) =>
      ResolvedAnchor(
        token: AnchorToken.of(AnchorKind.path, path),
        displayName: p.basename(path).isEmpty ? path : p.basename(path),
        capabilities: capabilities,
        isStale: isStale,
      );

  // --------------------------------------------------------------- resolution

  @override
  Future<ResolvedAnchor> resolve(AnchorToken token) async {
    final root = await rootPathOf(token);
    await assertReachable(root);
    return ResolvedAnchor(
      token: token,
      displayName: p.basename(root).isEmpty ? root : p.basename(root),
      capabilities: capabilities,
    );
  }

  /// Verifies the anchor root is there, with the right error when it is not.
  ///
  ///
  /// The three missing-target cases are genuinely different and callers must
  /// respond differently, so they are separated here:
  ///
  /// * the parent still exists, so the target itself was moved or deleted --
  ///   [AnchorStale], re-prompt;
  /// * no ancestor exists, so a whole volume or share is detached --
  ///   [AnchorUnavailable], retry later and do *not* re-prompt;
  /// * it exists but cannot be read -- [AnchorPermissionDenied].
  @protected
  Future<void> assertReachable(String root) async {
    final type = await FileSystemEntity.type(root, followLinks: true);
    if (type != FileSystemEntityType.notFound) {
      try {
        if (type == FileSystemEntityType.directory) {
          // take(1) reads at most one entry and yields an empty list for an
          // empty directory, which must not look like a read failure.
          await Directory(root).list(followLinks: false).take(1).toList();
        } else {
          await File(root).length();
        }
      } on FileSystemException catch (e) {
        throw AnchorPermissionDenied(
          'The anchor exists but cannot be read: ${e.osError?.message ?? e.message}',
          e,
        );
      }
      return;
    }

    var ancestor = p.dirname(root);
    var sawAncestor = false;
    while (ancestor.isNotEmpty && ancestor != p.dirname(ancestor)) {
      if (await Directory(ancestor).exists()) {
        sawAncestor = true;
        break;
      }
      ancestor = p.dirname(ancestor);
    }
    if (sawAncestor && ancestor == p.dirname(root)) {
      throw const AnchorStale(
        'The anchored location is gone, though its parent is still there. '
        'It was most likely moved or deleted.',
      );
    }
    throw const AnchorUnavailable(
      'Neither the anchored location nor its parents are reachable. The volume '
      'is probably detached; retry later rather than re-prompting.',
    );
  }

  /// Joins [relativePath] onto the anchor root, refusing to escape it.
  ///
  /// Rejects `..`, absolute paths, and anything whose normalised form leaves
  /// the anchor. An anchor is a permission boundary, so it behaves like one.
  ///
  /// The check is lexical. A symlink the user placed *inside* the anchor is
  /// followed, which matches what the platform itself would do -- the user
  /// granted this folder, symlinks included -- and matches Android SAF and the
  /// macOS sandbox. Listing, by contrast, does not descend through symlinks, so
  /// a cycle cannot hang a walk.
  @protected
  Future<String> resolveWithin(AnchorToken token, String? relativePath) async {
    final root = p.normalize(await rootPathOf(token));
    if (relativePath == null || relativePath.trim().isEmpty) return root;

    final segments = relativePath
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (segments.any((s) => s == '..')) {
      throw const AnchorUnsupported(
        'A relative path may not contain ".."; an anchor is a boundary.',
      );
    }
    if (p.isAbsolute(relativePath)) {
      throw const AnchorUnsupported(
        'A relative path must be relative, not absolute.',
      );
    }

    final joined = p.normalize(p.joinAll([root, ...segments]));
    if (!p.equals(joined, root) && !p.isWithin(root, joined)) {
      throw const AnchorUnsupported('That path resolves outside the anchor.');
    }
    return joined;
  }

  /// Converts an absolute [target] into the `/`-separated relative form.
  ///
  /// The contract says entry paths use `/` on every platform, so Windows
  /// backslashes are translated here rather than leaking to callers.
  String _relativize(String root, String target) =>
      p.relative(target, from: root).replaceAll(r'\', '/');

  // ------------------------------------------------------------- directories

  @override
  Stream<AnchorEntry> list(AnchorToken token, {bool recursive = false}) async* {
    final root = p.normalize(await rootPathOf(token));
    final type = await FileSystemEntity.type(root, followLinks: true);

    // A single-file anchor lists exactly itself.
    if (type == FileSystemEntityType.file) {
      yield await _entryFor(p.dirname(root), root);
      return;
    }
    if (type == FileSystemEntityType.notFound) {
      await assertReachable(root);
    }

    final stream = Directory(
      root,
    ).list(recursive: recursive, followLinks: false);
    await for (final entity in stream) {
      yield await _entryFor(root, entity.path, entity: entity);
    }
  }

  Future<AnchorEntry> _entryFor(
    String root,
    String target, {
    FileSystemEntity? entity,
  }) async {
    final resolved =
        entity ??
        (await FileSystemEntity.isDirectory(target)
            ? Directory(target)
            : File(target));
    FileStat? stat;
    try {
      stat = await resolved.stat();
    } on FileSystemException {
      // A file can vanish mid-listing; report what is known rather than failing
      // the whole walk.
      stat = null;
    }
    final isDirectory =
        stat?.type == FileSystemEntityType.directory ||
        (stat == null && resolved is Directory);
    return AnchorEntry(
      relativePath: _relativize(root, target),
      isDirectory: isDirectory,
      size: isDirectory ? null : stat?.size,
      modified: stat?.modified,
    );
  }

  @override
  Future<AnchorEntry> createFile(
    AnchorToken token,
    String relativePath, {
    String? mimeType,
  }) async {
    final root = p.normalize(await rootPathOf(token));
    final target = await resolveWithin(token, relativePath);
    final file = File(target);
    try {
      await file.parent.create(recursive: true);
      if (!await file.exists()) await file.create();
    } on FileSystemException catch (e) {
      throw _mapFileSystemException(e, target);
    }
    return AnchorEntry(
      relativePath: _relativize(root, target),
      isDirectory: false,
      size: await file.length(),
      modified: (await file.stat()).modified,
      mimeType: mimeType,
    );
  }

  @override
  Future<AnchorEntry> createDirectory(
    AnchorToken token,
    String relativePath,
  ) async {
    final root = p.normalize(await rootPathOf(token));
    final target = await resolveWithin(token, relativePath);
    try {
      await Directory(target).create(recursive: true);
    } on FileSystemException catch (e) {
      throw _mapFileSystemException(e, target);
    }
    return AnchorEntry(
      relativePath: _relativize(root, target),
      isDirectory: true,
    );
  }

  @override
  Future<void> delete(AnchorToken token, String relativePath) async {
    final target = await resolveWithin(token, relativePath);
    final type = await FileSystemEntity.type(target, followLinks: false);
    try {
      switch (type) {
        case FileSystemEntityType.notFound:
          throw AnchorEntryNotFound('No entry at "$relativePath".');
        case FileSystemEntityType.directory:
          await Directory(target).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(target).delete();
        default:
          await File(target).delete();
      }
    } on FileSystemException catch (e) {
      throw _mapFileSystemException(e, target);
    }
  }

  @override
  Future<bool> exists(AnchorToken token, String relativePath) async {
    final target = await resolveWithin(token, relativePath);
    return await FileSystemEntity.type(target, followLinks: true) !=
        FileSystemEntityType.notFound;
  }

  @override
  Future<AnchorStat> stat(AnchorToken token, String relativePath) async {
    final target = await resolveWithin(token, relativePath);
    final stat = await FileStat.stat(target);
    if (stat.type == FileSystemEntityType.notFound) {
      throw AnchorEntryNotFound('No entry at "$relativePath".');
    }
    final isDirectory = stat.type == FileSystemEntityType.directory;
    return AnchorStat(
      isDirectory: isDirectory,
      size: isDirectory ? null : stat.size,
      modified: stat.modified,
    );
  }

  // ------------------------------------------------------------------- bytes

  @override
  Future<Stream<List<int>>> openRead(
    AnchorToken token,
    String relativePath, {
    int? start,
    int? end,
  }) async {
    if (start != null && start < 0) {
      throw AnchorIoFailure(
        'openRead start must not be negative (got $start).',
      );
    }
    if (start != null && end != null && end < start) {
      throw AnchorIoFailure('openRead end ($end) is before start ($start).');
    }
    final target = await resolveWithin(token, relativePath);
    final stat = await FileStat.stat(target);
    // Validate eagerly so the caller gets a typed error before streaming, which
    // is the contract the platform interface promises.
    switch (stat.type) {
      case FileSystemEntityType.notFound:
        throw AnchorEntryNotFound('No entry at "$relativePath".');
      case FileSystemEntityType.directory:
        throw const AnchorUnsupported('Cannot read a directory as bytes.');
      default:
        break;
    }
    return File(target).openRead(start, end).handleError((
      Object error,
      StackTrace trace,
    ) {
      if (error is FileSystemException) {
        throw _mapFileSystemException(error, target);
      }
      throw AnchorIoFailure('Read failed.', error);
    });
  }

  @override
  Future<StreamSink<List<int>>> openWrite(
    AnchorToken token,
    String relativePath, {
    bool append = false,
  }) async {
    final target = await resolveWithin(token, relativePath);
    final file = File(target);
    try {
      await file.parent.create(recursive: true);
      return file.openWrite(mode: append ? FileMode.append : FileMode.write);
    } on FileSystemException catch (e) {
      throw _mapFileSystemException(e, target);
    }
  }

  // ------------------------------------------------------------------ grants

  @override
  Future<void> release(AnchorToken token) async {
    // A path carries no grant to give back. Subclasses holding a bookmark or a
    // FutureAccessList entry override this.
  }

  @override
  Future<int> releaseUnused(Set<AnchorToken> keep) async => 0;

  /// Turns a `dart:io` failure into the sealed hierarchy.
  AnchorError _mapFileSystemException(FileSystemException e, String target) {
    final code = e.osError?.errorCode;
    final message = e.osError?.message ?? e.message;
    // 2/3 ENOENT-ish, 13/5 EACCES/EPERM, 19/53 no such device.
    return switch (code) {
      2 || 3 => AnchorEntryNotFound('No entry at "$target": $message', e),
      13 ||
      1 ||
      5 => AnchorPermissionDenied('Refused for "$target": $message', e),
      19 ||
      53 ||
      6 => AnchorUnavailable('The volume for "$target" is gone: $message', e),
      28 => AnchorQuotaExceeded('No space left writing "$target".', e),
      _ => AnchorIoFailure('I/O failure for "$target": $message', e),
    };
  }
}
