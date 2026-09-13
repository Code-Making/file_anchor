import 'dart:async';

import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'channel_write_sink.dart';
import 'codecs.dart';

/// The Android implementation of `file_anchor`, backed by the Storage Access
/// Framework.
///
/// Durability comes from `ContentResolver.takePersistableUriPermission`, which
/// the native layer calls inside the picker's result callback. Taken any later,
/// the grant dies with the process.
///
/// Streaming uses a pull protocol: the native side opens a session and Dart asks
/// for the next chunk. That gives natural backpressure and a bounded message
/// size, which an event-channel push model does not.
final class FileAnchorAndroid extends FileAnchorPlatform {
  /// Creates the implementation, optionally over a test [channel].
  FileAnchorAndroid({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The method channel shared with the Kotlin plugin.
  static const String channelName = 'com.codemaking.file_anchor/methods';

  /// Bytes requested per `readChunk` call.
  static const int readChunkSize = 64 * 1024;

  /// Entries requested per `listNext` call.
  ///
  /// Batching matters on Android: a naive traversal costs one IPC round trip per
  /// file, which is what makes hand-rolled SAF code feel slow.
  static const int listBatchSize = 256;

  final MethodChannel _channel;

  /// Registers this class as the platform implementation.
  ///
  /// Called by Flutter's generated plugin registrant.
  static void registerWith() {
    final instance = FileAnchorAndroid();
    FileAnchorPlatform.instance = instance;
    // A hot restart replaces the Dart isolate while the plugin keeps running,
    // so sessions opened by the previous isolate are still open natively with
    // nobody left to close them. Registration is the one moment we are
    // guaranteed to run in both cases, so clear that state here.
    unawaited(instance.resetNative());
  }

  /// Drops native state left behind by a previous Dart isolate.
  ///
  /// Safe to call against an older native side that does not implement it: the
  /// failure is swallowed, because there is nothing a caller could do about it.
  @visibleForTesting
  Future<void> resetNative() async {
    try {
      await _void('reset');
    } on AnchorError {
      // Nothing to recover from; the worst case is the pre-existing leak.
    }
  }

  // ---------------------------------------------------------------- plumbing

  Future<Object?> _raw(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw mapPlatformException(e);
    } on MissingPluginException catch (e) {
      throw AnchorUnsupported(
        'The file_anchor Android implementation is not registered.',
        e,
      );
    }
  }

  Future<Map<String, Object?>> _map(
    String method, [
    Map<String, Object?>? args,
  ]) async => asMap(await _raw(method, args), method);

  Future<Map<String, Object?>?> _mapOrNull(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final result = await _raw(method, args);
    return result == null ? null : asMap(result, method);
  }

  Future<int> _int(String method, [Map<String, Object?>? args]) async {
    final result = await _raw(method, args);
    if (result is int) return result;
    throw AnchorIoFailure(
      '$method returned ${result.runtimeType}, wanted int.',
    );
  }

  Future<bool> _bool(String method, [Map<String, Object?>? args]) async {
    final result = await _raw(method, args);
    if (result is bool) return result;
    throw AnchorIoFailure(
      '$method returned ${result.runtimeType}, wanted bool.',
    );
  }

  Future<Uint8List> _bytes(String method, [Map<String, Object?>? args]) async {
    final result = await _raw(method, args);
    if (result is Uint8List) return result;
    if (result == null) return Uint8List(0);
    throw AnchorIoFailure(
      '$method returned ${result.runtimeType}, wanted bytes.',
    );
  }

  Future<void> _void(String method, [Map<String, Object?>? args]) =>
      _raw(method, args);

  /// Closes a native session, swallowing failures.
  ///
  /// Cleanup must not mask the error that caused it.
  Future<void> _endQuietly(String method, Map<String, Object?> args) async {
    try {
      await _void(method, args);
    } on AnchorError {
      // Intentionally ignored.
    }
  }

  /// Extracts the `content://` URI, rejecting a token from another platform.
  ///
  /// Callers must be `async` before invoking this: it throws while the argument
  /// map is being built, and a synchronous throw out of a `Future`-returning
  /// method is a trap for anyone using `.catchError`.
  static String _uriOf(AnchorToken token) {
    if (token.kind != AnchorKind.saf) {
      throw AnchorTokenMalformed(
        'Expected a Storage Access Framework token on Android, '
        'but this token is of kind "${token.kind.name}".',
      );
    }
    return token.payload;
  }

  // ------------------------------------------------------------------ picking

  @override
  Future<ResolvedAnchor?> pickDirectory({String? purpose}) async {
    final map = await _mapOrNull('pickDirectory', {'purpose': purpose});
    return map == null ? null : resolvedAnchorFromMap(map);
  }

  @override
  Future<ResolvedAnchor?> pickFile({
    String? purpose,
    List<String>? mimeTypes,
  }) async {
    final map = await _mapOrNull('pickFile', {
      'purpose': purpose,
      'mimeTypes': mimeTypes,
    });
    return map == null ? null : resolvedAnchorFromMap(map);
  }

  @override
  Future<ResolvedAnchor> resolve(AnchorToken token) async =>
      resolvedAnchorFromMap(await _map('resolve', {'uri': _uriOf(token)}));

  @override
  Future<void> release(AnchorToken token) async =>
      _void('release', {'uri': _uriOf(token)});

  @override
  Future<int> releaseUnused(Set<AnchorToken> keep) async =>
      _int('releaseUnused', {
        'keep': [
          for (final token in keep)
            if (token.kind == AnchorKind.saf) token.payload,
        ],
      });

  // ------------------------------------------------------------- directories

  @override
  Stream<AnchorEntry> list(AnchorToken token, {bool recursive = false}) async* {
    final session = await _int('beginList', {
      'uri': _uriOf(token),
      'recursive': recursive,
    });
    try {
      while (true) {
        final page = await _map('listNext', {
          'session': session,
          'batch': listBatchSize,
        });
        final entries = page['entries'];
        if (entries is List) {
          for (final entry in entries) {
            yield anchorEntryFromMap(asMap(entry, 'listNext entry'));
          }
        }
        if (page['done'] == true) break;
      }
    } finally {
      await _endQuietly('endList', {'session': session});
    }
  }

  @override
  Future<AnchorEntry> createFile(
    AnchorToken token,
    String relativePath, {
    String? mimeType,
  }) async => anchorEntryFromMap(
    await _map('createFile', {
      'uri': _uriOf(token),
      'relativePath': relativePath,
      'mimeType': mimeType,
    }),
  );

  @override
  Future<AnchorEntry> createDirectory(
    AnchorToken token,
    String relativePath,
  ) async => anchorEntryFromMap(
    await _map('createDirectory', {
      'uri': _uriOf(token),
      'relativePath': relativePath,
    }),
  );

  @override
  Future<void> delete(AnchorToken token, String relativePath) async =>
      _void('delete', {'uri': _uriOf(token), 'relativePath': relativePath});

  @override
  Future<bool> exists(AnchorToken token, String relativePath) async =>
      _bool('exists', {'uri': _uriOf(token), 'relativePath': relativePath});

  @override
  Future<AnchorStat> stat(AnchorToken token, String relativePath) async =>
      anchorStatFromMap(
        await _map('stat', {
          'uri': _uriOf(token),
          'relativePath': relativePath,
        }),
      );

  // -------------------------------------------------------------------- bytes

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
    // Opening eagerly means a missing document or revoked grant fails here,
    // with a typed error, rather than inside the caller's `await for`.
    final session = await _int('beginRead', {
      'uri': _uriOf(token),
      'relativePath': relativePath,
      'start': start,
      'end': end,
    });
    return _readSession(session);
  }

  Stream<List<int>> _readSession(int session) async* {
    try {
      while (true) {
        final chunk = await _bytes('readChunk', {
          'session': session,
          'size': readChunkSize,
        });
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await _endQuietly('endRead', {'session': session});
    }
  }

  @override
  Future<StreamSink<List<int>>> openWrite(
    AnchorToken token,
    String relativePath, {
    bool append = false,
  }) async {
    final session = await _int('beginWrite', {
      'uri': _uriOf(token),
      'relativePath': relativePath,
      'append': append,
    });
    return ChannelWriteSink(
      writeChunk: (bytes) =>
          _void('writeChunk', {'session': session, 'bytes': bytes}),
      commit: () => _void('endWrite', {'session': session, 'commit': true}),
      abort: () => _void('endWrite', {'session': session, 'commit': false}),
    );
  }
}
