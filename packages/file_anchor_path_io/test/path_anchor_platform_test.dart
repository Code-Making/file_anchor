import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A concrete engine with no picker, so the shared logic can be tested.
final class TestPathPlatform extends PathAnchorPlatform {}

void main() {
  late Directory root;
  late TestPathPlatform platform;
  late AnchorToken rootToken;

  AnchorToken tokenFor(String path) => AnchorToken.of(AnchorKind.path, path);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_anchor_test_');
    platform = TestPathPlatform();
    rootToken = tokenFor(root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('resolve', () {
    test('resolves an existing folder', () async {
      final resolved = await platform.resolve(rootToken);
      expect(resolved.displayName, p.basename(root.path));
      expect(resolved.isStale, isFalse);
      expect(resolved.capabilities.requiresExplicitScope, isFalse);
    });

    test('resolves an empty folder, which is not a read failure', () async {
      expect(await root.list().isEmpty, isTrue);
      await expectLater(platform.resolve(rootToken), completes);
    });

    test('a deleted folder whose parent survives is stale, so re-prompt',
        () async {
      final child = Directory(p.join(root.path, 'vault'))..createSync();
      final token = tokenFor(child.path);
      child.deleteSync();
      await expectLater(platform.resolve(token), throwsA(isA<AnchorStale>()));
    });

    test('a detached volume is unavailable, so retry instead of re-prompting',
        () async {
      // No ancestor exists, which is what an unplugged drive looks like.
      final token = tokenFor(p.join('/', 'Volumes', 'NotMounted', 'Vault'));
      await expectLater(
        platform.resolve(token),
        throwsA(isA<AnchorUnavailable>()),
      );
    });

    test('rejects a token belonging to another platform', () async {
      final saf = AnchorToken.of(AnchorKind.saf, 'content://x/tree/y');
      await expectLater(
        platform.resolve(saf),
        throwsA(isA<AnchorTokenMalformed>()),
      );
    });
  });

  group('anchor boundary', () {
    test('refuses ".." so an anchor is a real boundary', () async {
      await expectLater(
        platform.exists(rootToken, '../escaped.txt'),
        throwsA(isA<AnchorUnsupported>()),
      );
      await expectLater(
        platform.exists(rootToken, 'sub/../../escaped.txt'),
        throwsA(isA<AnchorUnsupported>()),
      );
    });

    test('refuses an absolute path', () async {
      await expectLater(
        platform.exists(rootToken, '/etc/passwd'),
        throwsA(isA<AnchorUnsupported>()),
      );
    });

    test('accepts backslashes, so Windows-style callers work everywhere',
        () async {
      await platform.createFile(rootToken, r'sub\deep.txt');
      expect(await platform.exists(rootToken, 'sub/deep.txt'), isTrue);
    });

    test('an empty relative path addresses the anchor root', () async {
      expect(await platform.exists(rootToken, ''), isTrue);
    });
  });

  group('listing', () {
    setUp(() async {
      File(p.join(root.path, 'top.md')).writeAsStringSync('hello');
      Directory(p.join(root.path, 'sub')).createSync();
      File(p.join(root.path, 'sub', 'inner.md')).writeAsStringSync('world!');
    });

    test('non-recursive yields only the top level', () async {
      final entries = await platform.list(rootToken).toList();
      expect(
        entries.map((e) => e.relativePath),
        unorderedEquals(['top.md', 'sub']),
      );
    });

    test('recursive yields forward-slash relative paths on every platform',
        () async {
      final entries = await platform.list(rootToken, recursive: true).toList();
      expect(
        entries.map((e) => e.relativePath),
        unorderedEquals(['top.md', 'sub', 'sub/inner.md']),
      );
      expect(entries.every((e) => !e.relativePath.contains(r'\')), isTrue);
    });

    test('reports sizes for files and none for directories', () async {
      final entries = await platform.list(rootToken, recursive: true).toList();
      final file = entries.firstWhere((e) => e.relativePath == 'top.md');
      final dir = entries.firstWhere((e) => e.relativePath == 'sub');
      expect(file.size, 5);
      expect(file.modified, isNotNull);
      expect(dir.isDirectory, isTrue);
      expect(dir.size, isNull);
    });

    test('a single-file anchor lists exactly itself', () async {
      final token = tokenFor(p.join(root.path, 'top.md'));
      final entries = await platform.list(token).toList();
      expect(entries.single.relativePath, 'top.md');
      expect(entries.single.isDirectory, isFalse);
    });
  });

  group('mutation', () {
    test('createFile makes missing parents, mkdirs-style', () async {
      final entry = await platform.createFile(rootToken, 'a/b/c/note.md');
      expect(entry.relativePath, 'a/b/c/note.md');
      expect(File(p.join(root.path, 'a', 'b', 'c', 'note.md')).existsSync(),
          isTrue);
    });

    test('createFile is idempotent and preserves existing content', () async {
      await platform.createFile(rootToken, 'note.md');
      final sink = await platform.openWrite(rootToken, 'note.md');
      sink.add(utf8.encode('keep me'));
      await sink.close();
      await platform.createFile(rootToken, 'note.md');
      final stat = await platform.stat(rootToken, 'note.md');
      expect(stat.size, 7);
    });

    test('createDirectory is recursive', () async {
      final entry = await platform.createDirectory(rootToken, 'x/y/z');
      expect(entry.isDirectory, isTrue);
      expect(Directory(p.join(root.path, 'x', 'y', 'z')).existsSync(), isTrue);
    });

    test('delete removes a directory and its children', () async {
      await platform.createFile(rootToken, 'sub/a.md');
      await platform.delete(rootToken, 'sub');
      expect(await platform.exists(rootToken, 'sub/a.md'), isFalse);
    });

    test('deleting a missing entry is a typed not-found', () async {
      await expectLater(
        platform.delete(rootToken, 'nope.md'),
        throwsA(isA<AnchorEntryNotFound>()),
      );
    });

    test('stat on a missing entry is a typed not-found', () async {
      await expectLater(
        platform.stat(rootToken, 'nope.md'),
        throwsA(isA<AnchorEntryNotFound>()),
      );
    });
  });

  group('bytes', () {
    test('round-trips content', () async {
      final sink = await platform.openWrite(rootToken, 'a.txt');
      sink.add(utf8.encode('hello world'));
      await sink.close();

      final stream = await platform.openRead(rootToken, 'a.txt');
      final bytes = (await stream.toList()).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'hello world');
    });

    test('appends when asked', () async {
      var sink = await platform.openWrite(rootToken, 'a.txt');
      sink.add(utf8.encode('one'));
      await sink.close();
      sink = await platform.openWrite(rootToken, 'a.txt', append: true);
      sink.add(utf8.encode('+two'));
      await sink.close();

      final stream = await platform.openRead(rootToken, 'a.txt');
      final bytes = (await stream.toList()).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'one+two');
    });

    test('openWrite creates missing parent directories', () async {
      final sink = await platform.openWrite(rootToken, 'deep/nested/a.txt');
      sink.add(utf8.encode('x'));
      await sink.close();
      expect(await platform.exists(rootToken, 'deep/nested/a.txt'), isTrue);
    });

    test('a missing file fails before streaming starts', () async {
      // The contract: a typed error from the Future, not from `await for`.
      await expectLater(
        platform.openRead(rootToken, 'gone.txt'),
        throwsA(isA<AnchorEntryNotFound>()),
      );
    });

    test('reading a directory is an explicit unsupported error', () async {
      await platform.createDirectory(rootToken, 'sub');
      await expectLater(
        platform.openRead(rootToken, 'sub'),
        throwsA(isA<AnchorUnsupported>()),
      );
    });

    test('honours a byte range', () async {
      final sink = await platform.openWrite(rootToken, 'a.txt');
      sink.add(utf8.encode('abcdefghij'));
      await sink.close();

      final stream = await platform.openRead(rootToken, 'a.txt', start: 2, end: 5);
      final bytes = (await stream.toList()).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'cde');
    });

    test('validates the range locally', () async {
      await expectLater(platform.openRead(rootToken, 'a.txt', start: -1),
          throwsA(isA<AnchorIoFailure>()));
      await expectLater(platform.openRead(rootToken, 'a.txt', start: 9, end: 2),
          throwsA(isA<AnchorIoFailure>()));
    });

    test('streams a large file in chunks, not one buffer', () async {
      final payload = Uint8List(6 * 1024 * 1024);
      for (var i = 0; i < payload.length; i += 1024) {
        payload[i] = i % 251;
      }
      final sink = await platform.openWrite(rootToken, 'big.bin');
      sink.add(payload);
      await sink.close();

      var chunks = 0;
      var total = 0;
      await for (final chunk in await platform.openRead(rootToken, 'big.bin')) {
        chunks++;
        total += chunk.length;
      }
      expect(total, payload.length);
      expect(chunks, greaterThan(1));
    });
  });

  group('grants', () {
    test('release is a no-op because a path carries no grant', () async {
      await expectLater(platform.release(rootToken), completes);
      expect(await platform.releaseUnused({rootToken}), 0);
    });
  });
}
