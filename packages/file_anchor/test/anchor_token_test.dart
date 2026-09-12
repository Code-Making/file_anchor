import 'package:file_anchor/file_anchor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnchorToken', () {
    test('round-trips every kind', () {
      for (final kind in AnchorKind.values) {
        const payload = 'content://com.android.externalstorage/tree/primary%3ADocs';
        final encoded = AnchorToken.of(kind, payload).value;
        final decoded = AnchorToken.parse(encoded);
        expect(decoded.kind, kind);
        expect(decoded.payload, payload);
      }
    });

    test('survives payloads with dots, slashes and unicode', () {
      const payload = 'C:\\Users\\Ali\\Belgeler\\notlar.v1.2/çalışma';
      final decoded = AnchorToken.parse(AnchorToken.of(AnchorKind.path, payload).value);
      expect(decoded.payload, payload);
    });

    test('is carried by a version prefix so the format can evolve', () {
      expect(AnchorToken.of(AnchorKind.saf, 'x').value, startsWith('fa1.'));
    });

    test('rejects a foreign string', () {
      expect(() => AnchorToken.parse('/Users/me/Documents'),
          throwsA(isA<AnchorTokenMalformed>()));
    });

    test('rejects an unknown future version rather than guessing', () {
      expect(() => AnchorToken.parse('fa2.s.eA=='),
          throwsA(isA<AnchorTokenMalformed>()));
    });

    test('rejects an unknown kind code', () {
      expect(() => AnchorToken.parse('fa1.z.eA=='),
          throwsA(isA<AnchorTokenMalformed>()));
    });

    test('rejects a corrupt payload', () {
      expect(() => AnchorToken.parse('fa1.s.!!!!'),
          throwsA(isA<AnchorTokenMalformed>()));
    });

    test('equality is by value, so tokens work as map keys', () {
      expect(AnchorToken.of(AnchorKind.saf, 'a'), AnchorToken.of(AnchorKind.saf, 'a'));
      expect(AnchorToken.of(AnchorKind.saf, 'a'), isNot(AnchorToken.of(AnchorKind.path, 'a')));
    });
  });
}
