import 'dart:async';
import 'dart:typed_data';

/// A [StreamSink] that batches bytes and forwards them over a method channel.
///
/// [StreamSink.add] is synchronous but a channel call is not, so writes are
/// buffered and flushed on a serialised future chain. That keeps chunks in order
/// and keeps each channel message a sane size.
///
/// Failure is deliberate about cleanup: if any chunk fails, [close] aborts the
/// native session so a half-written document is not left behind, then rethrows.
final class ChannelWriteSink implements StreamSink<List<int>> {
  /// Creates a sink over the three native operations it needs.
  ChannelWriteSink({
    required Future<void> Function(Uint8List bytes) writeChunk,
    required Future<void> Function() commit,
    required Future<void> Function() abort,
    int flushThreshold = defaultFlushThreshold,
  }) : _writeChunk = writeChunk,
       _commit = commit,
       _abort = abort,
       _flushThreshold = flushThreshold;

  /// Bytes buffered before a flush is queued.
  static const int defaultFlushThreshold = 256 * 1024;

  final Future<void> Function(Uint8List bytes) _writeChunk;
  final Future<void> Function() _commit;
  final Future<void> Function() _abort;
  final int _flushThreshold;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();

  Future<void> _chain = Future<void>.value();
  Object? _failure;
  StackTrace? _failureTrace;
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) {
      throw StateError('Cannot add to a ChannelWriteSink after close().');
    }
    _buffer.add(data);
    if (_buffer.length >= _flushThreshold) _queueFlush();
  }

  void _queueFlush() {
    if (_buffer.isEmpty) return;
    final bytes = _buffer.takeBytes();
    _chain = _chain
        .then((_) {
          if (_failure != null) return null;
          return _writeChunk(bytes);
        })
        .catchError((Object error, StackTrace trace) {
          _failure ??= error;
          _failureTrace ??= trace;
        });
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _failure ??= error;
    _failureTrace ??= stackTrace;
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

    _queueFlush();
    await _chain;

    if (_failure case final error?) {
      // Do not leave a partially written document behind.
      try {
        await _abort();
      } on Object {
        // The abort is best effort; the original failure is what matters.
      }
      _completeError(error, _failureTrace);
      return _done.future;
    }

    try {
      await _commit();
      _done.complete();
    } on Object catch (error, trace) {
      _completeError(error, trace);
    }
    return _done.future;
  }

  void _completeError(Object error, StackTrace? trace) {
    if (_done.isCompleted) return;
    _done.completeError(error, trace);
    // Mark handled so a caller that only awaits close() does not trip the
    // unhandled-async-error reporter.
    _done.future.ignore();
  }

  @override
  Future<void> get done => _done.future;
}
