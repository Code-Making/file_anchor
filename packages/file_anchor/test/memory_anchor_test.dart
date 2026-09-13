import 'dart:convert';
import 'dart:typed_data';

import 'package:file_anchor/file_anchor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryAnchor I/O', () {
    test('reads seeded files as text', () async {
      final anchor = MemoryAnchor(files: {'notes.md': utf8.encode('hello')});
      expect(await anchor.readAsString('notes.md'), 'hello');
    });

    test('writes then reads back', () async {
      final anchor = MemoryAnchor();
      await anchor.writeAsString('a.txt', 'first');
      expect(await anchor.readAsString('a.txt'), 'first');
    });

    test('replaces content by default', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('old')});
      await anchor.writeAsString('a.txt', 'new');
      expect(await anchor.readAsString('a.txt'), 'new');
    });

    test('appends when asked', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('one')});
      await anchor.writeAsString('a.txt', '+two', append: true);
      expect(await anchor.readAsString('a.txt'), 'one+two');
    });

    test('normalises backslash paths so Windows callers behave', () async {
      final anchor = MemoryAnchor();
      await anchor.writeAsString(r'sub\deep.txt', 'x');
      expect(await anchor.exists('sub/deep.txt'), isTrue);
    });

    test('sink done completes only after close commits', () async {
      final anchor = MemoryAnchor();
      final sink = await anchor.openWrite('big.bin');
      sink.add([1, 2, 3]);
      expect(
        await anchor.exists('big.bin'),
        isFalse,
        reason: 'bytes must not land before close()',
      );
      await sink.close();
      await sink.done;
      expect(await anchor.readAsBytes('big.bin'), [1, 2, 3]);
    });

    test('streams a large file in chunks without one giant buffer', () async {
      final anchor = MemoryAnchor();
      final payload = Uint8List(5 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i % 256;
      }
      await anchor.writeBytes('big.bin', payload);

      var chunks = 0;
      var total = 0;
      await for (final chunk in await anchor.openRead('big.bin')) {
        chunks++;
        total += chunk.length;
      }
      expect(total, payload.length);
      expect(chunks, greaterThan(1), reason: 'openRead must actually stream');
    });

    test('honours a [start, end) range', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('abcdefghij')});
      final stream = await anchor.openRead('a.txt', start: 2, end: 5);
      final bytes = (await stream.toList()).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'cde');
    });

    test('clamps an out-of-bounds range instead of throwing', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('abc')});
      final stream = await anchor.openRead('a.txt', start: 1, end: 9999);
      final bytes = (await stream.toList()).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'bc');
    });
  });

  group('MemoryAnchor directory operations', () {
    test(
      'non-recursive listing collapses nested paths to their top folder',
      () async {
        final anchor = MemoryAnchor(
          files: {'top.md': utf8.encode('a'), 'sub/inner.md': utf8.encode('b')},
        );
        final names = await anchor.list().map((e) => e.relativePath).toList();
        expect(names, unorderedEquals(['top.md', 'sub']));
      },
    );

    test('recursive listing yields full relative paths', () async {
      final anchor = MemoryAnchor(
        files: {'top.md': utf8.encode('a'), 'sub/inner.md': utf8.encode('b')},
      );
      final names = await anchor
          .list(recursive: true)
          .map((e) => e.relativePath)
          .toList();
      expect(names, unorderedEquals(['top.md', 'sub/inner.md']));
    });

    test('entry name is the final segment of a relative path', () {
      const entry = AnchorEntry(
        relativePath: 'notes/2026/jan.md',
        isDirectory: false,
      );
      expect(entry.name, 'jan.md');
    });

    test('stat reports size for files and flags directories', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('abcd')});
      await anchor.createDirectory('docs');
      expect((await anchor.stat('a.txt')).size, 4);
      expect((await anchor.stat('docs')).isDirectory, isTrue);
    });

    test('deleting a directory removes its children', () async {
      final anchor = MemoryAnchor(files: {'sub/a.md': utf8.encode('a')});
      await anchor.delete('sub');
      expect(await anchor.exists('sub/a.md'), isFalse);
    });
  });

  group('error contract', () {
    test(
      'missing entries throw AnchorEntryNotFound, not a generic failure',
      () async {
        final anchor = MemoryAnchor();
        await expectLater(
          anchor.openRead('nope.txt'),
          throwsA(isA<AnchorEntryNotFound>()),
        );
        await expectLater(
          anchor.stat('nope.txt'),
          throwsA(isA<AnchorEntryNotFound>()),
        );
        await expectLater(
          anchor.delete('nope.txt'),
          throwsA(isA<AnchorEntryNotFound>()),
        );
      },
    );

    test('a released anchor reports revoked, so callers re-prompt', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('x')});
      await anchor.release();
      expect(anchor.isReleased, isTrue);
      await expectLater(
        anchor.readAsString('a.txt'),
        throwsA(isA<AnchorRevoked>()),
      );
    });

    test('failing() reproduces each recovery path', () async {
      for (final failure in <AnchorError>[
        const AnchorRevoked(),
        const AnchorStale(),
        const AnchorUnavailable(),
        const AnchorPermissionDenied(),
        const AnchorQuotaExceeded(),
      ]) {
        final anchor = MemoryAnchor.failing(failure);
        await expectLater(
          anchor.readAsString('a.txt'),
          throwsA(
            predicate<Object>((e) => e.runtimeType == failure.runtimeType),
          ),
        );
      }
    });

    test('unavailable is distinguishable from revoked', () {
      // The whole point of the split: one means retry later, the other means
      // re-prompt the user. Collapsing them makes apps nag over a pulled USB.
      const AnchorError unavailable = AnchorUnavailable();
      expect(unavailable, isNot(isA<AnchorRevoked>()));
      expect(switch (unavailable) {
        AnchorUnavailable() => 'retry',
        AnchorRevoked() => 'reprompt',
        _ => 'other',
      }, 'retry');
    });
  });

  group('security scope', () {
    test('use() balances the scope even when body throws', () async {
      final anchor = MemoryAnchor();
      await expectLater(
        anchor.use(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(anchor.scopeDepth, 0, reason: 'scope must never leak');
    });

    test('nested use() is reference counted, not closed early', () async {
      final anchor = MemoryAnchor(files: {'a.txt': utf8.encode('x')});
      final result = await anchor.use(() async {
        return anchor.use(() async {
          expect(anchor.scopeDepth, 2);
          return anchor.readAsString('a.txt');
        });
      });
      expect(result, 'x');
      expect(anchor.maxScopeDepth, 2);
      expect(anchor.scopeDepth, 0);
    });

    test('reports that it needs an explicit scope, like iOS does', () {
      expect(MemoryAnchor().capabilities.requiresExplicitScope, isTrue);
    });
  });
}
