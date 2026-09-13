import 'package:file_anchor_android/file_anchor_android.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what Dart sent and replies with scripted answers.
final class FakeNativeSide {
  FakeNativeSide();

  final List<MethodCall> calls = <MethodCall>[];
  final Map<String, Object? Function(Map<String, Object?> args)> handlers = {};

  List<String> get methods => calls.map((c) => c.method).toList();

  Map<String, Object?> argsFor(String method) {
    final raw = calls.firstWhere((c) => c.method == method).arguments;
    return raw is Map
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, Object?>{};
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final handler = handlers[call.method];
    if (handler == null) return null;
    final raw = call.arguments;
    return handler(raw is Map ? raw.cast<String, Object?>() : const {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNativeSide native;
  late FileAnchorAndroid android;

  const safToken =
      'content://com.android.externalstorage.documents/tree/primary%3AVault';

  AnchorToken token() => AnchorToken.of(AnchorKind.saf, safToken);

  setUp(() {
    native = FakeNativeSide();
    const channel = MethodChannel(FileAnchorAndroid.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
    android = FileAnchorAndroid(channel: channel);
  });

  tearDown(() {
    const channel = MethodChannel(FileAnchorAndroid.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('error mapping', () {
    final cases = <String, Matcher>{
      AnchorErrorCode.stale: isA<AnchorStale>(),
      AnchorErrorCode.revoked: isA<AnchorRevoked>(),
      AnchorErrorCode.unavailable: isA<AnchorUnavailable>(),
      AnchorErrorCode.permissionDenied: isA<AnchorPermissionDenied>(),
      AnchorErrorCode.quotaExceeded: isA<AnchorQuotaExceeded>(),
      AnchorErrorCode.notFound: isA<AnchorEntryNotFound>(),
      AnchorErrorCode.unsupported: isA<AnchorUnsupported>(),
      AnchorErrorCode.malformedToken: isA<AnchorTokenMalformed>(),
    };

    for (final entry in cases.entries) {
      test('${entry.key} becomes the right typed error', () async {
        native.handlers['exists'] = (_) =>
            throw PlatformException(code: entry.key, message: 'nope');
        await expectLater(
          android.exists(token(), 'a.txt'),
          throwsA(entry.value),
        );
      });
    }

    test(
      'an unrecognised code degrades to AnchorIoFailure, never leaks',
      () async {
        native.handlers['exists'] = (_) =>
            throw PlatformException(code: 'file_anchor/from_the_future');
        await expectLater(
          android.exists(token(), 'a.txt'),
          throwsA(
            allOf(isA<AnchorIoFailure>(), isNot(isA<PlatformException>())),
          ),
        );
      },
    );

    test('a missing plugin registration is reported as unsupported', () async {
      native.handlers['exists'] = (_) => throw MissingPluginException('gone');
      await expectLater(
        android.exists(token(), 'a.txt'),
        throwsA(isA<AnchorUnsupported>()),
      );
    });
  });

  group('token guarding', () {
    test('rejects a token from another platform with a typed error', () async {
      final windowsToken = AnchorToken.of(AnchorKind.path, r'C:\Vault');
      await expectLater(
        android.exists(windowsToken, 'a.txt'),
        throwsA(isA<AnchorTokenMalformed>()),
      );
      expect(native.calls, isEmpty, reason: 'must not reach the native side');
    });

    test('sends the bare content uri, not the encoded token', () async {
      native.handlers['exists'] = (_) => true;
      await android.exists(token(), 'a.txt');
      expect(native.argsFor('exists')['uri'], safToken);
    });

    test('releaseUnused drops tokens belonging to other platforms', () async {
      native.handlers['releaseUnused'] = (_) => 3;
      final released = await android.releaseUnused({
        token(),
        AnchorToken.of(AnchorKind.path, r'C:\Other'),
      });
      expect(released, 3);
      expect(native.argsFor('releaseUnused')['keep'], [safToken]);
    });
  });

  group('picking', () {
    test('a cancelled picker yields null, not an error', () async {
      native.handlers['pickDirectory'] = (_) => null;
      expect(await android.pickDirectory(), isNull);
    });

    test('a pick builds a durable SAF token from the returned uri', () async {
      native.handlers['pickDirectory'] = (_) => {
        'uri': safToken,
        'displayName': 'Vault',
        'canRename': true,
      };
      final resolved = await android.pickDirectory(purpose: 'Choose vault');
      expect(resolved!.token.kind, AnchorKind.saf);
      expect(resolved.token.payload, safToken);
      expect(resolved.displayName, 'Vault');
      expect(native.argsFor('pickDirectory')['purpose'], 'Choose vault');
    });

    test('reports that Android needs no security scope', () async {
      native.handlers['resolve'] = (_) => {'uri': safToken, 'displayName': 'V'};
      final resolved = await android.resolve(token());
      expect(resolved.capabilities.requiresExplicitScope, isFalse);
      expect(
        resolved.capabilities.canRandomAccessWrite,
        isFalse,
        reason: 'SAF documents are append/replace only',
      );
    });
  });

  group('listing', () {
    test('pages through batches and always closes the session', () async {
      var page = 0;
      native.handlers['beginList'] = (_) => 7;
      native.handlers['listNext'] = (_) {
        page++;
        return page == 1
            ? {
                'entries': [
                  {'relativePath': 'a.md', 'isDirectory': false, 'size': 3},
                  {'relativePath': 'sub', 'isDirectory': true},
                ],
                'done': false,
              }
            : {
                'entries': [
                  {'relativePath': 'b.md', 'isDirectory': false, 'size': 5},
                ],
                'done': true,
              };
      };

      final entries = await android.list(token()).toList();
      expect(entries.map((e) => e.relativePath), ['a.md', 'sub', 'b.md']);
      expect(entries[1].isDirectory, isTrue);
      expect(
        native.methods,
        containsAllInOrder(['beginList', 'listNext', 'listNext', 'endList']),
      );
      expect(native.argsFor('endList')['session'], 7);
    });

    test('closes the session even when a page fails midway', () async {
      native.handlers['beginList'] = (_) => 9;
      native.handlers['listNext'] = (_) =>
          throw PlatformException(code: AnchorErrorCode.revoked);
      await expectLater(
        android.list(token()).toList(),
        throwsA(isA<AnchorRevoked>()),
      );
      expect(
        native.methods,
        contains('endList'),
        reason: 'a leaked native session is a real cost',
      );
    });

    test(
      'requests a batch size rather than one entry per round trip',
      () async {
        native.handlers['beginList'] = (_) => 1;
        native.handlers['listNext'] = (_) => {
          'entries': <Object?>[],
          'done': true,
        };
        await android.list(token()).toList();
        expect(
          native.argsFor('listNext')['batch'],
          FileAnchorAndroid.listBatchSize,
        );
      },
    );
  });

  group('reading', () {
    test('a missing document fails before streaming starts', () async {
      native.handlers['beginRead'] = (_) =>
          throw PlatformException(code: AnchorErrorCode.notFound);
      // The point of Future<Stream>: this throws here, not inside `await for`.
      await expectLater(
        android.openRead(token(), 'gone.md'),
        throwsA(isA<AnchorEntryNotFound>()),
      );
    });

    test('pulls chunks until empty, then ends the session', () async {
      final pages = <Uint8List>[
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5]),
        Uint8List(0),
      ];
      var i = 0;
      native.handlers['beginRead'] = (_) => 42;
      native.handlers['readChunk'] = (_) => pages[i++];

      final stream = await android.openRead(token(), 'a.bin');
      final bytes = (await stream.toList()).expand<int>((c) => c).toList();

      expect(bytes, [1, 2, 3, 4, 5]);
      expect(native.methods.last, 'endRead');
      expect(
        native.argsFor('readChunk')['size'],
        FileAnchorAndroid.readChunkSize,
      );
    });

    test('forwards a byte range', () async {
      native.handlers['beginRead'] = (_) => 1;
      native.handlers['readChunk'] = (_) => Uint8List(0);
      await (await android.openRead(
        token(),
        'a.bin',
        start: 10,
        end: 20,
      )).toList();
      expect(native.argsFor('beginRead')['start'], 10);
      expect(native.argsFor('beginRead')['end'], 20);
    });

    test(
      'validates the range locally instead of asking the platform',
      () async {
        await expectLater(
          android.openRead(token(), 'a.bin', start: -1),
          throwsA(isA<AnchorIoFailure>()),
        );
        await expectLater(
          android.openRead(token(), 'a.bin', start: 9, end: 2),
          throwsA(isA<AnchorIoFailure>()),
        );
        expect(native.calls, isEmpty);
      },
    );
  });

  group('writing', () {
    test('batches small writes and commits once on close', () async {
      native.handlers['beginWrite'] = (_) => 5;
      final sink = await android.openWrite(token(), 'a.bin');
      sink.add([1, 2]);
      sink.add([3]);
      expect(
        native.methods,
        isNot(contains('writeChunk')),
        reason: 'small writes should buffer, not spam the channel',
      );
      await sink.close();
      await sink.done;

      expect(native.argsFor('writeChunk')['bytes'], [1, 2, 3]);
      expect(native.argsFor('endWrite')['commit'], isTrue);
    });

    test('flushes once the buffer threshold is passed', () async {
      native.handlers['beginWrite'] = (_) => 5;
      final sink = await android.openWrite(token(), 'big.bin');
      sink.add(Uint8List(ChannelWriteSinkLimits.threshold + 1));
      await sink.close();
      await sink.done;
      expect(native.methods.where((m) => m == 'writeChunk').length, 1);
    });

    test(
      'aborts the session when a chunk fails, so no half file is left',
      () async {
        native.handlers['beginWrite'] = (_) => 5;
        native.handlers['writeChunk'] = (_) =>
            throw PlatformException(code: AnchorErrorCode.unavailable);

        final sink = await android.openWrite(token(), 'a.bin');
        sink.add([1, 2, 3]);
        await expectLater(sink.close(), throwsA(isA<AnchorUnavailable>()));
        expect(native.argsFor('endWrite')['commit'], isFalse);
      },
    );

    test('rejects writes after close', () async {
      native.handlers['beginWrite'] = (_) => 5;
      final sink = await android.openWrite(token(), 'a.bin');
      await sink.close();
      expect(() => sink.add([1]), throwsStateError);
    });
  });
}

/// Exposes the sink's flush threshold to tests without widening the public API.
abstract final class ChannelWriteSinkLimits {
  static const int threshold = 256 * 1024;
}
