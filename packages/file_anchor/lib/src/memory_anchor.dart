import 'dart:async';
import 'dart:typed_data';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

import 'anchor.dart';

/// An in-memory [Anchor] for tests.
///
/// Shipped in the package on purpose. Code that touches user files is normally
/// untestable without a device, so it does not get tested. With this, file
/// logic runs under plain `flutter test`.
///
/// ```dart
/// final anchor = MemoryAnchor(files: {'notes.md': utf8.encode('hello')});
/// expect(await anchor.readAsString('notes.md'), 'hello');
/// ```
///
/// Use [MemoryAnchor.failing] to exercise recovery paths:
///
/// ```dart
/// final dead = MemoryAnchor.failing(const AnchorRevoked());
/// expect(() => dead.list().toList(), throwsA(isA<AnchorRevoked>()));
/// ```
final class MemoryAnchor implements Anchor {
  /// Creates an anchor seeded with [files], keyed by relative path.
  MemoryAnchor({
    this.displayName = 'memory',
    Map<String, List<int>>? files,
    Set<String>? directories,
    this.capabilities = _memoryCapabilities,
  })  : _files = {
          for (final e in (files ?? const {}).entries)
            _normalize(e.key): Uint8List.fromList(e.value),
        },
        _directories = {...?directories?.map(_normalize)},
        _failure = null;

  /// Creates an anchor where every operation throws [error].
  MemoryAnchor.failing(AnchorError error, {this.displayName = 'memory'})
      : _files = {},
        _directories = {},
        capabilities = _memoryCapabilities,
        _failure = error;

  static const AnchorCapabilities _memoryCapabilities = AnchorCapabilities(
    canRandomAccessWrite: false,
    canRename: true,
    canQueryFreeSpace: false,
    requiresExplicitScope: true,
    persistsAcrossReboot: false,
  );

  final Map<String, Uint8List> _files;
  final Set<String> _directories;
  final AnchorError? _failure;

  @override
  final String displayName;

  @override
  final AnchorCapabilities capabilities;

  /// How many times [use] currently has the scope open.
  ///
  /// Tests assert this returns to zero, which proves scope handling is balanced.
  int get scopeDepth => _scopeDepth;
  int _scopeDepth = 0;

  /// The highest [scopeDepth] ever reached, to verify nesting is refcounted.
  int get maxScopeDepth => _maxScopeDepth;
  int _maxScopeDepth = 0;

  /// Whether [release] has been called.
  bool get isReleased => _released;
  bool _released = false;

  static int _bound(int value, int low, int high) =>
      value < low ? low : (value > high ? high : value);

  static String _normalize(String path) {
    final trimmed = path.replaceAll(r'\', '/');
    return trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  }

  void _check() {
    final failure = _failure;
    if (failure != null) throw failure;
    if (_released) throw const AnchorRevoked('This MemoryAnchor was released.');
  }

  @override
  String get token => AnchorToken.of(AnchorKind.memory, displayName).value;

  @override
  bool get isStale => false;

  @override
  Stream<AnchorEntry> list({bool recursive = false}) {
    _check();
    Iterable<AnchorEntry> collect() {
      final seen = <String, AnchorEntry>{};
      for (final dir in _directories) {
        if (recursive || !dir.contains('/')) {
          seen[dir] = AnchorEntry(relativePath: dir, isDirectory: true);
        }
      }
      for (final entry in _files.entries) {
        final path = entry.key;
        if (recursive) {
          seen[path] = AnchorEntry(
            relativePath: path,
            isDirectory: false,
            size: entry.value.length,
          );
        } else if (path.contains('/')) {
          // Surface the top-level directory rather than the nested file.
          final top = path.substring(0, path.indexOf('/'));
          seen[top] = AnchorEntry(relativePath: top, isDirectory: true);
        } else {
          seen[path] = AnchorEntry(
            relativePath: path,
            isDirectory: false,
            size: entry.value.length,
          );
        }
      }
      return seen.values;
    }

    return Stream<AnchorEntry>.fromIterable(collect());
  }

  @override
  Future<AnchorEntry> createFile(String relativePath, {String? mimeType}) async {
    _check();
    final path = _normalize(relativePath);
    _files.putIfAbsent(path, () => Uint8List(0));
    return AnchorEntry(
      relativePath: path,
      isDirectory: false,
      size: _files[path]!.length,
      mimeType: mimeType,
    );
  }

  @override
  Future<AnchorEntry> createDirectory(String relativePath) async {
    _check();
    final path = _normalize(relativePath);
    _directories.add(path);
    return AnchorEntry(relativePath: path, isDirectory: true);
  }

  @override
  Future<void> delete(String relativePath) async {
    _check();
    final path = _normalize(relativePath);
    final removedFile = _files.remove(path) != null;
    final removedDir = _directories.remove(path);
    final removedChildren =
        _files.keys.where((k) => k.startsWith('$path/')).toList();
    for (final child in removedChildren) {
      _files.remove(child);
    }
    if (!removedFile && !removedDir && removedChildren.isEmpty) {
      throw AnchorEntryNotFound('No entry at "$relativePath".');
    }
  }

  @override
  Future<bool> exists(String relativePath) async {
    _check();
    final path = _normalize(relativePath);
    return _files.containsKey(path) || _directories.contains(path);
  }

  @override
  Future<AnchorStat> stat(String relativePath) async {
    _check();
    final path = _normalize(relativePath);
    final bytes = _files[path];
    if (bytes != null) {
      return AnchorStat(isDirectory: false, size: bytes.length);
    }
    if (_directories.contains(path)) {
      return const AnchorStat(isDirectory: true);
    }
    throw AnchorEntryNotFound('No entry at "$relativePath".');
  }

  @override
  Future<Stream<List<int>>> openRead(
    String relativePath, {
    int? start,
    int? end,
  }) async {
    _check();
    final path = _normalize(relativePath);
    final bytes = _files[path];
    if (bytes == null) throw AnchorEntryNotFound('No entry at "$relativePath".');
    final from = _bound(start ?? 0, 0, bytes.length);
    final to = _bound(end ?? bytes.length, from, bytes.length);
    // Emit in chunks so consumers exercise real streaming behaviour.
    const chunk = 64 * 1024;
    final chunks = <List<int>>[];
    for (var i = from; i < to; i += chunk) {
      final stop = i + chunk < to ? i + chunk : to;
      chunks.add(Uint8List.sublistView(bytes, i, stop));
    }
    return Stream<List<int>>.fromIterable(chunks);
  }

  @override
  Future<StreamSink<List<int>>> openWrite(
    String relativePath, {
    bool append = false,
  }) async {
    _check();
    final path = _normalize(relativePath);
    final builder = BytesBuilder(copy: false);
    if (append && _files.containsKey(path)) {
      builder.add(_files[path]!);
    }
    return _MemorySink(builder, (bytes) => _files[path] = bytes);
  }

  @override
  Future<T> use<T>(Future<T> Function() body) async {
    _check();
    _scopeDepth++;
    if (_scopeDepth > _maxScopeDepth) _maxScopeDepth = _scopeDepth;
    try {
      return await body();
    } finally {
      _scopeDepth--;
    }
  }

  @override
  Future<void> release() async {
    _check();
    _released = true;
  }
}

/// Accumulates writes and commits them once on close, so `done` is meaningful.
final class _MemorySink implements StreamSink<List<int>> {
  _MemorySink(this._builder, this._commit);

  final BytesBuilder _builder;
  final void Function(Uint8List bytes) _commit;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('Cannot add to a closed sink.');
    _builder.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    _commit(_builder.takeBytes());
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
